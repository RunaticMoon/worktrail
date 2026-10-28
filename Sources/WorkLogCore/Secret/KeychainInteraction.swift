import Foundation

/// The file-based macOS Keychain UI policy is process-wide. Serialize every
/// WorkLog Keychain operation and restore the exact prior policy before unlocking.
/// Injected functions keep regression tests independent of the user's Keychain.
final class KeychainInteractionGate: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let getAllowed: () throws -> Bool
    private let setAllowed: (Bool) throws -> Void

    init(getAllowed: @escaping () throws -> Bool, setAllowed: @escaping (Bool) throws -> Void) {
        self.getAllowed = getAllowed; self.setAllowed = setAllowed
    }

    func perform<T>(allowUserInteraction: Bool, _ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        // Interactive operations join the same lock but never override a policy
        // already disabled by another caller or a surrounding operation.
        guard !allowUserInteraction else { return try operation() }
        let wasAllowed = try getAllowed()
        if wasAllowed { try setAllowed(false) }
        let result = Result { try operation() }
        if wasAllowed { try setAllowed(true) }
        return try result.get()
    }
}

#if canImport(Security) && os(macOS)
import Security

public enum KeychainInteraction {
    private static let gate = KeychainInteractionGate(getAllowed: {
        var allowed: DarwinBoolean = false
        let status = SecKeychainGetUserInteractionAllowed(&allowed)
        guard status == errSecSuccess else {
            throw WorkLogError.storage("Keychain 인증 UI 상태 조회 실패(\(status))")
        }
        return allowed.boolValue
    }, setAllowed: { allowed in
        let status = SecKeychainSetUserInteractionAllowed(allowed)
        guard status == errSecSuccess else {
            throw WorkLogError.storage("Keychain 인증 UI 상태 복원/설정 실패(\(status))")
        }
    })

    /// Query flags/LAContext target the data-protection Keychain and do not
    /// reliably suppress legacy file-Keychain ACL prompts. Do not change ACLs,
    /// accessibility, search lists or the user's Keychain lock settings here.
    public static func perform<T>(allowUserInteraction: Bool,
                                  _ operation: () throws -> T) throws -> T {
        try gate.perform(allowUserInteraction: allowUserInteraction, operation)
    }
}
#endif
