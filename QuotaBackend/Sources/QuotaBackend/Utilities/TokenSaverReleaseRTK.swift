import Foundation
import Darwin

/// Only explicit Homebrew RTK upgrades; never installs Homebrew, installs RTK, or invokes a shell.
public struct TokenSaverReleaseRTK: Sendable {
    public struct Output: Sendable {
        public let status: Int32
        public let text: String
        public init(status: Int32, text: String) { self.status = status; self.text = text }
    }
    public typealias Runner = @Sendable (URL, [String]) async throws -> Output
    public let brewURL: URL?
    private let runner: Runner
    private static let paths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    public init(brewURL: URL? = TokenSaverReleaseRTK.trustedBrewURL(),
                runner: @escaping Runner = { url, arguments in try await TokenSaverReleaseRTK.run(url, arguments: arguments) }) {
        self.brewURL = brewURL.flatMap { Self.paths.contains($0.path) ? $0 : nil }
        self.runner = runner
    }

    public static func trustedBrewURL() -> URL? {
        let fm = FileManager.default
        return paths.compactMap { path -> URL? in
            let url = URL(fileURLWithPath: path)
            let target = url.resolvingSymlinksInPath()
            let prefix = path.hasPrefix("/opt/") ? "/opt/homebrew/" : "/usr/local/Homebrew/"
            guard target.path == path || target.path.hasPrefix(prefix), fm.isExecutableFile(atPath: path) else { return nil }
            var current = target
            while current.path != "/" {
                guard let attrs = try? fm.attributesOfItem(atPath: current.path),
                      let owner = attrs[.ownerAccountID] as? NSNumber,
                      owner.uint32Value == 0 || owner.uint32Value == getuid(),
                      let permissions = attrs[.posixPermissions] as? NSNumber,
                      permissions.intValue & 0o002 == 0 else { return nil }
                current.deleteLastPathComponent()
            }
            return url
        }.first
    }

    public func installedVersion() async throws -> String? {
        guard let brewURL else { throw Failure.unavailable }
        let result = try await runner(brewURL, ["list", "--versions", "rtk"])
        if result.status == 1 && result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        guard result.status == 0 else { throw Failure.command(result.status, result.text) }
        let fields = result.text.split(whereSeparator: \.isWhitespace).map(String.init)
        if fields.isEmpty { return nil }
        guard fields.first == "rtk", fields.count > 1,
              fields.dropFirst().allSatisfy({ $0.count <= 80 && $0.utf8.allSatisfy { byte in
                  (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || [46, 45, 95, 43].contains(byte)
              } }) else { throw Failure.invalidVersion }
        return fields.dropFirst().joined(separator: ", ")
    }

    public func upgrade() async throws -> String? {
        guard let brewURL, try await installedVersion() != nil else { throw Failure.notInstalled }
        let result = try await runner(brewURL, ["upgrade", "rtk"])
        guard result.status == 0 else { throw Failure.command(result.status, result.text) }
        return try await installedVersion()
    }

    public enum Failure: LocalizedError {
        case unavailable, notInstalled, invalidVersion, command(Int32, String), limit
        public var errorDescription: String? {
            switch self {
            case .unavailable: "Trusted Homebrew not found at /opt/homebrew/bin/brew or /usr/local/bin/brew. Install/update RTK externally."
            case .notInstalled: "RTK is not installed in Homebrew. AIUsage will not install it."
            case .invalidVersion: "Homebrew installed-version response was not recognized."
            case .command(let status, let text): "Homebrew exited \(status): \(text.prefix(500))"
            case .limit: "Homebrew exceeded the 180-second or 128 KiB output limit. Check its external status before retrying."
            }
        }
    }

    public static func run(_ url: URL, arguments: [String]) async throws -> Output {
        guard paths.contains(url.path), trustedBrewURL()?.path == url.path,
              arguments == ["list", "--versions", "rtk"] || arguments == ["upgrade", "rtk"] else { throw Failure.unavailable }
        return try await runValidatedProcess(url, arguments: arguments)
    }

    private static func stopProcessBounded(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        for _ in 0..<8 {
            if !process.isRunning { break }
            Darwin.usleep(20_000)
        }
        if process.isRunning, pid > 0 {
            _ = kill(pid, SIGKILL)
            for _ in 0..<8 {
                if !process.isRunning { break }
                Darwin.usleep(20_000)
            }
        }
        if !process.isRunning {
            process.waitUntilExit()
        }
    }

    internal static func runValidatedProcess(_ url: URL, arguments: [String]) async throws -> Output {
        let worker = Task.detached { () throws -> Output in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = url
            process.arguments = arguments
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                                   "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1", "HOMEBREW_NO_ANALYTICS": "1"]
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            defer { try? pipe.fileHandleForReading.close() }
            let handle = pipe.fileHandleForReading.fileDescriptor
            guard fcntl(handle, F_SETFL, O_NONBLOCK) != -1 else {
                stopProcessBounded(process)
                throw Failure.limit
            }
            let deadline = Date().addingTimeInterval(180)
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                if Date() >= deadline || Task.isCancelled {
                    stopProcessBounded(process)
                    throw Failure.limit
                }
                let count = Darwin.read(handle, &buffer, buffer.count)
                if count > 0 {
                    guard data.count + count <= 128 * 1024 else {
                        stopProcessBounded(process)
                        throw Failure.limit
                    }
                    data.append(contentsOf: buffer.prefix(count))
                } else if count == 0 {
                    // A child may close its output before exiting; retain the deadline.
                    if !process.isRunning { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                } else if errno == EAGAIN || errno == EINTR {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                } else {
                    stopProcessBounded(process)
                    throw Failure.limit
                }
            }
            process.waitUntilExit()
            if process.terminationReason == .uncaughtSignal { throw Failure.limit }
            return Output(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self))
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
