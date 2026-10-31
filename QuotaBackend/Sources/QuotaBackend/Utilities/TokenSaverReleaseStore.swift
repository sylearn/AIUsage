import Foundation
import CryptoKit

/// A single atomic receipt includes the skill text and its digest, so interrupted updates
/// cannot advertise a version whose text was not staged. Loading validates the receipt and
/// content digest; callers must opt in and scope text to coding-agent instruction files.
public struct TokenSaverReleaseStagedRules: Codable, Equatable, Sendable {
    public let tool: TokenSaverReleaseTool
    public let repository: String
    public let version: String
    public let commit: String
    public let stagedAt: Date
    public let markdown: Data
    public let sha256: String
}

public struct TokenSaverReleaseStore: Sendable {
    public let root: URL
    public init(root: URL = TokenSaverReleaseStore.defaultRoot) { self.root = root.standardizedFileURL }
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIUsage/Rules", isDirectory: true)
    }

    public func staged(_ tool: TokenSaverReleaseTool) throws -> TokenSaverReleaseStagedRules? {
        try validateStorage()
        let file = receiptURL(tool)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 256 * 1024 else {
            throw TokenSaverReleaseError.unsafeStorage
        }
        let receipt = try JSONDecoder().decode(TokenSaverReleaseStagedRules.self, from: Data(contentsOf: file))
        guard receipt.tool == tool, receipt.repository == tool.repository, tool.skillPath != nil,
              TokenSaverReleaseClient.validSHA(receipt.commit), !receipt.version.isEmpty,
              !receipt.markdown.isEmpty, receipt.markdown.count <= 128 * 1024,
              Self.digest(receipt.markdown) == receipt.sha256 else { throw TokenSaverReleaseError.invalidMetadata }
        return receipt
    }

    @discardableResult
    public func stage(_ release: TokenSaverRelease, markdown: Data) throws -> TokenSaverReleaseStagedRules {
        guard release.tool.skillPath != nil else { throw TokenSaverReleaseError.manualInstallation }
        guard TokenSaverReleaseClient.validSHA(release.commit), !release.version.isEmpty,
              !markdown.isEmpty, markdown.count <= 128 * 1024,
              let text = String(data: markdown, encoding: .utf8), text.contains("name:"), !text.contains("\0") else {
            throw TokenSaverReleaseError.invalidMetadata
        }
        try validateStorage()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try validateStorage()
        let receipt = TokenSaverReleaseStagedRules(tool: release.tool, repository: release.tool.repository,
            version: release.version, commit: release.commit, stagedAt: Date(), markdown: markdown,
            sha256: Self.digest(markdown))
        try JSONEncoder().encode(receipt).write(to: receiptURL(release.tool), options: .atomic)
        return receipt
    }

    private func receiptURL(_ tool: TokenSaverReleaseTool) -> URL { root.appendingPathComponent("\(tool.rawValue).json") }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func validateStorage() throws {
        guard root.isFileURL, root.path != "/" else { throw TokenSaverReleaseError.unsafeStorage }
        // Reject links in every managed ancestor and receipt. Only the exact root-owned
        // macOS /var -> private/var and /tmp -> private/tmp aliases are permitted.
        var ancestor = root
        while ancestor.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: ancestor.path),
               attributes[.type] as? FileAttributeType != .typeDirectory {
                let expected = ["/var": "private/var", "/tmp": "private/tmp"][ancestor.path]
                let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)
                guard attributes[.type] as? FileAttributeType == .typeSymbolicLink,
                      (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
                      let expected, destination == expected || destination == "/" + expected else {
                    throw TokenSaverReleaseError.unsafeStorage
                }
            }
            ancestor.deleteLastPathComponent()
        }
        for tool in TokenSaverReleaseTool.allCases {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: receiptURL(tool).path),
               attributes[.type] as? FileAttributeType != .typeRegular { throw TokenSaverReleaseError.unsafeStorage }
        }
    }
}
