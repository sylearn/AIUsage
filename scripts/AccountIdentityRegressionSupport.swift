import Foundation
import QuotaBackend

// 仅替换系统边界。账号保存、匹配、协调、隐藏、删除均编译并运行正式源码。
// 不访问 Keychain、不扫描用户目录、不启动主 App。
final class AccountCredentialStore {
    static let shared = AccountCredentialStore()
    static var multiWorkspaceProviders: Set<String> { QuotaBackend.AccountCredentialStore.multiWorkspaceProviders }
    static func isMultiWorkspace(_ id: String) -> Bool { QuotaBackend.AccountCredentialStore.isMultiWorkspace(id) }
    static func normalizedAuthFilePath(_ path: String) -> String { QuotaBackend.AccountCredentialStore.normalizedAuthFilePath(path) }
    static func credentialsShareCanonicalIdentity(_ a: AccountCredential, _ b: AccountCredential) -> Bool {
        QuotaBackend.AccountCredentialStore.credentialsShareCanonicalIdentity(a, b)
    }
    struct Plan {
        let remappedCredentialIDs: [String: String] = [:]
        var isEmpty: Bool { true }
    }
    var credentials: [AccountCredential] = []
    func loadCredentials(for id: String) -> [AccountCredential] { credentials.filter { $0.providerId == id } }
    func loadAllCredentials() -> [AccountCredential] { credentials }
    func loadCredential(providerId: String, credentialId: String) -> AccountCredential? {
        credentials.first { $0.providerId == providerId && $0.id == credentialId }
    }
    func saveCredential(_ credential: AccountCredential) throws {
        credentials.removeAll { $0.id == credential.id }
        credentials.append(credential)
    }
    func deleteCredential(_ credential: AccountCredential) { credentials.removeAll { $0.id == credential.id } }
    func planCredentialDeduplication(for id: String? = nil) -> Plan { Plan() }
    func commitCredentialDeduplication(_ plan: Plan) -> Bool { true }
    func bootstrapCredentialIndex(references: [AccountCredentialReference]) {}
}

final class SecureAccountVault {
    static let shared = SecureAccountVault()
    var accounts: [StoredProviderAccount] = []
    func loadAccounts() -> [StoredProviderAccount] { accounts }
    func saveAccounts(_ accounts: [StoredProviderAccount]) throws { self.accounts = accounts }
}

enum ProviderManagedImportStore {
    static func reuseManagedImportIfPossible(existingCredential: AccountCredential, incomingCredential: inout AccountCredential) {}
    static func cleanupOrphanedManagedImports(referencedBy credentials: [AccountCredential]) {}
}

enum ProviderAuthManager {}
