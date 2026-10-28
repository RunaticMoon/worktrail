#if os(macOS)
import Foundation
import Security
import WorkLogCore

/// Dedicated WorkLog namespace; never accesses company/CLI keychain entries.
final class ServiceKeychainCredentialStore: ServiceCredentialStore, @unchecked Sendable {
    private let service: String
    init(service: String = AppIdentity.default.bundleIdentifier + ".service-credentials") { self.service = service }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    func read(account: String) throws -> String? {
        try read(account: account, allowAuthenticationUI: false)
    }
    func read(account: String, allowAuthenticationUI: Bool) throws -> String? {
        var request = query(account); request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = try KeychainInteraction.perform(allowUserInteraction: allowAuthenticationUI) {
            SecItemCopyMatching(request as CFDictionary, &result)
        }
        record(status)
        if status == errSecItemNotFound { return nil }
        if status == errSecInteractionNotAllowed || status == errSecInteractionRequired || status == errSecAuthFailed {
            throw AIProviderError(.notLoggedIn, "Keychain 접근 승인이 필요합니다. 설정에서 연결 상태 확인 또는 활동 수집의 지금 수집을 눌러 승인하세요.")
        }
        guard status == errSecSuccess, let data = result as? Data, let credential = String(data: data, encoding: .utf8) else {
            throw AIProviderError(.notLoggedIn, "WorkLog의 서비스 인증 저장소를 열 수 없습니다.")
        }
        return credential
    }
    func write(_ credential: String, account: String) throws {
        try KeychainInteraction.perform(allowUserInteraction: true) {
            let attributes: [String: Any] = [kSecValueData as String: Data(credential.utf8)]
            var status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var item = query(account); item[kSecValueData as String] = Data(credential.utf8)
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            }
            record(status)
            guard status == errSecSuccess else { throw AIProviderError(.notLoggedIn, "서비스 인증을 안전하게 저장할 수 없습니다.") }
        }
    }
    func delete(account: String) throws {
        let status = try KeychainInteraction.perform(allowUserInteraction: true) {
            SecItemDelete(query(account) as CFDictionary)
        }
        record(status)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIProviderError(.notLoggedIn, "서비스 인증을 삭제할 수 없습니다.")
        }
    }
    private func record(_ status: OSStatus) {
        let expected = status == errSecSuccess || status == errSecItemNotFound
        AppDiagnostics.shared.record(expected ? .operationSucceeded : .operationFailed,
            category: .keychain, level: expected ? .info : .error,
            fields: [.osStatus: .integer(Int(status))])
    }
}
#endif
