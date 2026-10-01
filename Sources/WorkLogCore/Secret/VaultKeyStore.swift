import Foundation

/// vault 암호화 키(256비트)의 보관 추상화.
/// 키 자체는 절대 vault.sqlite·설정 파일·백업·로그에 넣지 않는다.
/// Secret 경로는 이 저장소 외부로 키를 노출하지 않으며 네트워크·AI 호출이 없다.
public protocol VaultKeyStore: AnyObject, Sendable {
    /// 32바이트 키. 없으면 nil.
    func loadKey(id: String) throws -> Data?
    func storeKey(_ key: Data, id: String) throws
    func deleteKey(id: String) throws
}

/// 테스트·Linux 개발용 메모리 키 저장소. 프로세스가 끝나면 사라진다.
public final class InMemoryVaultKeyStore: VaultKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: Data] = [:]

    public init() {}

    public func loadKey(id: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return keys[id]
    }

    public func storeKey(_ key: Data, id: String) throws {
        lock.lock(); defer { lock.unlock() }
        keys[id] = key
    }

    public func deleteKey(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        keys.removeValue(forKey: id)
    }
}

#if canImport(Security) && os(macOS)
import Security

/// macOS Keychain 기반 키 저장소.
/// kSecClassGenericPassword, service = 전달받은 service, account = key id,
/// kSecAttrAccessibleWhenUnlockedThisDeviceOnly, iCloud 동기화 안 함.
///
/// 주의: Linux CI/검증 환경에서는 컴파일 대상이 아니라 실행 검증이 불가능하다(미검증).
public final class KeychainVaultKeyStore: VaultKeyStore {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    private func baseQuery(id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
    }

    public func loadKey(id: String) throws -> Data? {
        var query = baseQuery(id: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw WorkLogError.storage("Keychain 키 조회 실패(\(status))")
        }
        return data
    }

    public func storeKey(_ key: Data, id: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        var addQuery = baseQuery(id: id)
        addQuery.merge(attributes) { _, new in new }
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(baseQuery(id: id) as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw WorkLogError.storage("Keychain 키 갱신 실패(\(updateStatus))")
            }
        } else if status != errSecSuccess {
            throw WorkLogError.storage("Keychain 키 저장 실패(\(status))")
        }
    }

    public func deleteKey(id: String) throws {
        let status = SecItemDelete(baseQuery(id: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WorkLogError.storage("Keychain 키 삭제 실패(\(status))")
        }
    }
}
#endif
