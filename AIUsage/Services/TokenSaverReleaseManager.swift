import Foundation
import Combine
import QuotaBackend

// MARK: - Token Saver release manager

@MainActor
final class TokenSaverReleaseManager: ObservableObject {
    struct Status {
        var staged: TokenSaverReleaseStagedRules?
        var installedBinaryVersion: String?
        var binaryInspected = false
        var brewAvailable = false
        var latest: TokenSaverRelease?
        var checkedAt: Date?
        var isBusy = false
        var error: String?
        var notice: String?
        var isCurrent: Bool { staged?.commit == latest?.commit && staged != nil && latest != nil }
    }

    @Published private(set) var statuses: [TokenSaverReleaseTool: Status] = [:]
    // Shared by all three repositories: anonymous GitHub quota belongs to the originating IP.
    @Published private(set) var retryAfter: Date?
    private let now: () -> Date
    private let client: TokenSaverReleaseClient
    private let store: TokenSaverReleaseStore
    private let reapplyRules: () throws -> Void
    private let rtk: TokenSaverReleaseRTK

    init(client: TokenSaverReleaseClient? = nil, store: TokenSaverReleaseStore = .init(),
         rtk: TokenSaverReleaseRTK = .init(), now: @escaping () -> Date = Date.init,
         reapplyRules: @escaping () throws -> Void = {
             try TokenSaverSettingsStore.save(TokenSaverSettingsStore.load())
         }) {
        let resolvedClient = client ?? TokenSaverReleaseClient(cacheURL: TokenSaverReleaseClient.defaultCacheURL)
        self.now = now
        self.client = resolvedClient
        self.store = store
        self.reapplyRules = reapplyRules
        self.rtk = rtk
        for tool in TokenSaverReleaseTool.allCases {
            var status = Status()
            if tool == .rtk { status.brewAvailable = rtk.brewURL != nil }
            if let cached = resolvedClient.cached(for: tool) {
                status.latest = cached.release
                status.checkedAt = cached.checkedAt
            }
            do { status.staged = try store.staged(tool) }
            catch { status.error = error.localizedDescription }
            statuses[tool] = status
        }
    }

    func check(_ tool: TokenSaverReleaseTool) async {
        guard statuses[tool]?.isBusy != true, !isCoolingDown else { return }
        let previousLatest = statuses[tool]?.latest ?? client.cached(for: tool)?.release
        let previousCheckedAt = statuses[tool]?.checkedAt ?? client.cached(for: tool)?.checkedAt
        statuses[tool, default: Status()].isBusy = true
        statuses[tool]?.error = nil
        statuses[tool]?.notice = nil
        // A failed refresh must not leave an old release eligible for installation.
        statuses[tool]?.latest = nil
        statuses[tool]?.checkedAt = nil
        defer { statuses[tool]?.isBusy = false }
        do {
            statuses[tool]?.staged = nil
            statuses[tool]?.staged = try store.staged(tool)
            if tool == .rtk {
                statuses[tool]?.installedBinaryVersion = nil
                statuses[tool]?.binaryInspected = false
                do {
                    statuses[tool]?.installedBinaryVersion = try await rtk.installedVersion()
                    statuses[tool]?.binaryInspected = true
                } catch { record(error, for: tool) }
            }
            statuses[tool]?.latest = try await client.latest(for: tool)
            statuses[tool]?.checkedAt = now()
        } catch {
            if let releaseError = error as? TokenSaverReleaseError, case .rateLimited = releaseError,
               let previousLatest {
                statuses[tool]?.latest = previousLatest
                statuses[tool]?.checkedAt = previousCheckedAt
            } else {
                client.clearCached(for: tool)
            }
            record(error, for: tool)
        }
    }

    var isCoolingDown: Bool { retryAfter.map { $0 > now() } ?? false }

    private func record(_ error: Error, for tool: TokenSaverReleaseTool) {
        statuses[tool]?.error = error.localizedDescription
        if let releaseError = error as? TokenSaverReleaseError,
           case .rateLimited(let reset) = releaseError {
            let date = reset.flatMap(TimeInterval.init).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
            let deadline = date.flatMap { $0 > now() ? $0 : nil } ?? now().addingTimeInterval(60)
            retryAfter = max(retryAfter ?? deadline, deadline)
        }
    }

    func updateRTK() async {
        let tool = TokenSaverReleaseTool.rtk
        guard statuses[tool]?.isBusy != true, statuses[tool]?.installedBinaryVersion != nil else { return }
        statuses[tool]?.isBusy = true
        statuses[tool]?.error = nil
        statuses[tool]?.notice = nil
        defer { statuses[tool]?.isBusy = false }
        do {
            statuses[tool]?.installedBinaryVersion = try await rtk.upgrade()
            statuses[tool]?.binaryInspected = true
            statuses[tool]?.notice = "Homebrew RTK upgrade finished. Installed Homebrew version is separate from the latest GitHub release."
        } catch {
            statuses[tool]?.installedBinaryVersion = nil
            statuses[tool]?.binaryInspected = false
            statuses[tool]?.error = error.localizedDescription
        }
    }

    func stage(_ tool: TokenSaverReleaseTool) async {
        guard !isCoolingDown, statuses[tool]?.isBusy != true, let release = statuses[tool]?.latest,
              tool.skillPath != nil else { return }
        statuses[tool]?.isBusy = true
        statuses[tool]?.error = nil
        statuses[tool]?.notice = nil
        defer { statuses[tool]?.isBusy = false }
        do {
            let markdown = try await client.skill(for: release)
            statuses[tool]?.staged = try store.stage(release, markdown: markdown)
            do {
                try reapplyRules()
                statuses[tool]?.notice = "Upstream reference saved; compact built-in policies reapplied for enabled tools. Full upstream text is not injected. New coding session reload required. Disabled tools remain staged only."
            } catch {
                statuses[tool]?.error = "Downloaded/staged rules, but not applied: \(error.localizedDescription)"
                statuses[tool]?.notice = nil
            }
        } catch { record(error, for: tool) }
    }
}
