import Foundation

#if os(macOS)
import LocalAuthentication
#endif

// Secret 잠금 세션. 기기 인증 게이트 + 30분 미사용 잠금.
// AI·네트워크 호출이 없고, Secret 값·키를 print·로그·에러 메시지로 남기지 않는다.

/// 기기 인증 결과.
public enum DeviceAuthResult: Equatable, Sendable {
    case success
    case cancelled
    case failed(String)
    case unavailable
}

/// 기기 인증 추상화(Touch ID·암호 등). 테스트에서는 Mock을 주입한다.
public protocol DeviceAuthenticator: AnyObject, Sendable {
    func authenticate(reason: String) async -> DeviceAuthResult
}

/// 테스트용 인증기. 다음 결과를 지정하고 호출 횟수를 기록한다.
public final class MockDeviceAuthenticator: DeviceAuthenticator, @unchecked Sendable {
    private let mutex = NSLock()
    private var result: DeviceAuthResult
    private var count = 0

    public init(result: DeviceAuthResult = .success) {
        self.result = result
    }

    /// 다음 호출에 돌려줄 결과. NSLock으로 보호한다.
    public var nextResult: DeviceAuthResult {
        get { mutex.lock(); defer { mutex.unlock() }; return result }
        set { mutex.lock(); result = newValue; mutex.unlock() }
    }

    public var callCount: Int {
        mutex.lock(); defer { mutex.unlock() }
        return count
    }

    public func authenticate(reason: String) async -> DeviceAuthResult {
        withMutex {
            count += 1
            return result
        }
    }

    /// async 문맥에서 NSLock을 직접 잠그지 않도록 동기 스코프로 감싼다.
    private func withMutex<T>(_ body: () throws -> T) rethrows -> T {
        mutex.lock(); defer { mutex.unlock() }
        return try body()
    }
}

#if os(macOS)
/// macOS LocalAuthentication 기반 인증기(.deviceOwnerAuthentication = Touch ID 또는 암호).
/// 인증 이유(reason)는 UI에만 쓰고 Secret 값을 담지 않는다.
///
/// 주의: Linux 검증 환경에서는 컴파일 대상이 아니라 실행 검증이 불가능하다(미검증).
public final class LocalDeviceAuthenticator: DeviceAuthenticator, @unchecked Sendable {
    public init() {}

    public func authenticate(reason: String) async -> DeviceAuthResult {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                      localizedReason: reason)
            return ok ? .success : .cancelled
        } catch {
            // 값·키를 담지 않는 일반 메시지만 돌려준다.
            return .failed("device authentication failed")
        }
    }
}
#endif

/// vault가 잠긴 이유.
public enum VaultLockReason: String, Sendable {
    case manual
    case idle
    case screenLocked
    case appQuit
    case authFailed
}

public enum VaultSessionState: Equatable, Sendable {
    case locked
    case unlocked
}

/// SecretVault 앞단의 잠금 세션.
///
/// - 제목 검색은 잠금 중에도 가능하고, 값 접근은 unlock(withUnlocked)을 통과해야 한다.
/// - idle은 Secret 접근·편집·복사 활동으로만 갱신된다. 일반 앱 사용은 갱신하지 않는다.
/// - 내부 상태는 NSLock으로 보호하고, 인증 await 동안에는 lock을 잡지 않는다.
public final class VaultSession: @unchecked Sendable {
    private let vault: SecretVault
    private let authenticator: DeviceAuthenticator
    private let clock: Clock

    private let mutex = NSLock()
    private var timeout: TimeInterval
    private var sessionState: VaultSessionState = .locked
    private var lastActivity: Date?
    private var lockHandler: (@Sendable (VaultLockReason) -> Void)?

    public init(vault: SecretVault, authenticator: DeviceAuthenticator, clock: Clock,
                idleTimeout: TimeInterval = 30 * 60) {
        self.vault = vault
        self.authenticator = authenticator
        self.clock = clock
        self.timeout = idleTimeout
    }

    /// idle 만료 시간(초). 설정 화면에서 변경할 수 있다.
    public var idleTimeout: TimeInterval {
        get { mutex.lock(); defer { mutex.unlock() }; return timeout }
        set { mutex.lock(); timeout = newValue; mutex.unlock() }
    }

    /// 잠금 시 사유와 함께 호출된다. 이미 잠긴 상태에서 다시 잠그면 호출하지 않는다.
    public var onLock: (@Sendable (VaultLockReason) -> Void)? {
        get { mutex.lock(); defer { mutex.unlock() }; return lockHandler }
        set { mutex.lock(); lockHandler = newValue; mutex.unlock() }
    }

    /// 조회 시 idle 만료면 .idle로 잠그고 .locked를 돌려준다.
    public var state: VaultSessionState {
        mutex.lock()
        let expired = expireForIdleLocked(now: clock.now())
        let current = sessionState
        let handler = expired ? lockHandler : nil
        mutex.unlock()
        handler?(.idle)
        return current
    }

    /// vault 키가 없으면 인증을 호출하지 않고 vaultKeyMissing을 던진다.
    /// 이미 unlocked(만료 전)면 인증 없이 활동만 갱신한다.
    /// 인증 결과가 success가 아니면 vaultLocked를 던지고 locked를 유지한다.
    public func unlock(reason: String) async throws {
        guard vault.keyStatus == .ready else {
            throw WorkLogError.vaultKeyMissing
        }

        var idleHandler: (@Sendable (VaultLockReason) -> Void)?
        let alreadyUnlocked: Bool = withMutex {
            if expireForIdleLocked(now: clock.now()) {
                idleHandler = lockHandler
            }
            if sessionState == .unlocked {
                lastActivity = clock.now()
                return true
            }
            return false
        }
        idleHandler?(.idle)
        if alreadyUnlocked { return }

        let result = await authenticator.authenticate(reason: reason)
        if result == .success {
            withMutex {
                sessionState = .unlocked
                lastActivity = clock.now()
            }
        } else {
            throw WorkLogError.vaultLocked
        }
    }

    /// 이미 locked면 onLock을 호출하지 않는다.
    public func lock(_ reason: VaultLockReason) {
        mutex.lock()
        guard sessionState == .unlocked else {
            mutex.unlock()
            return
        }
        sessionState = .locked
        lastActivity = nil
        let handler = lockHandler
        mutex.unlock()
        handler?(reason)
    }

    /// 타이머·이벤트용: 만료면 잠그고 true.
    @discardableResult
    public func checkIdle() -> Bool {
        mutex.lock()
        let expired = expireForIdleLocked(now: clock.now())
        let handler = expired ? lockHandler : nil
        mutex.unlock()
        handler?(.idle)
        return expired
    }

    /// 잠금 상태와 무관한 제목 검색. 활동 시각을 갱신하지 않는다.
    public func searchTitles(_ query: String, limit: Int = 50) throws -> [SecretMetadata] {
        try vault.searchTitles(query, limit: limit)
    }

    // MARK: - SecretVault 파사드(잠금 게이트 통과 후에만 값 접근)
    //
    // SecretVault의 복호화·쓰기 메서드는 internal이므로 앱 계층은 이 파사드를 거쳐야 한다.
    // 모든 메서드는 withUnlocked를 통과하며, 잠금이면 vaultLocked를 던진다.

    public func create(title: String?, groupName: String?,
                       rows: [SecretRowInput]) throws -> SecretMetadata {
        try withUnlocked { try $0.create(title: title, groupName: groupName, rows: rows) }
    }

    public func save(secretId: String, changes: SecretChangeSet) throws -> SecretSaveOutcome {
        try withUnlocked { try $0.save(secretId: secretId, changes: changes) }
    }

    public func rename(secretId: String, title: String, groupName: String?) throws {
        try withUnlocked { try $0.rename(secretId: secretId, title: title, groupName: groupName) }
    }

    public func currentRows(secretId: String) throws -> [SecretRow] {
        try withUnlocked { try $0.currentRows(secretId: secretId) }
    }

    public func revisions(secretId: String) throws -> [SecretRevisionInfo] {
        try withUnlocked { try $0.revisions(secretId: secretId) }
    }

    public func rows(secretId: String, revisionId: String) throws -> [SecretRow] {
        try withUnlocked { try $0.rows(secretId: secretId, revisionId: revisionId) }
    }

    public func restoreRevision(secretId: String, revisionId: String) throws -> SecretSaveOutcome {
        try withUnlocked { try $0.restoreRevision(secretId: secretId, revisionId: revisionId) }
    }

    public func moveToTrash(secretId: String) throws {
        try withUnlocked { try $0.moveToTrash(secretId: secretId) }
    }

    public func restoreFromTrash(secretId: String) throws {
        try withUnlocked { try $0.restoreFromTrash(secretId: secretId) }
    }

    public func trash() throws -> [SecretMetadata] {
        try withUnlocked { try $0.trash() }
    }

    public func purge(secretId: String) throws {
        try withUnlocked { try $0.purge(secretId: secretId) }
    }

    public func saveDraft(_ payload: SecretPayload) throws {
        try withUnlocked { try $0.saveDraft(payload) }
    }

    public func loadDraft() throws -> SecretPayload? {
        try withUnlocked { try $0.loadDraft() }
    }

    public func clearDraft() throws {
        try withUnlocked { try $0.clearDraft() }
    }

    /// 잠금이면 vaultLocked를 던진다(만료 검사 포함). 성공 시 활동 시각을 갱신한 뒤 body를 실행한다.
    func withUnlocked<T>(_ body: (SecretVault) throws -> T) throws -> T {
        mutex.lock()
        if expireForIdleLocked(now: clock.now()) {
            let handler = lockHandler
            mutex.unlock()
            handler?(.idle)
            throw WorkLogError.vaultLocked
        }
        guard sessionState == .unlocked else {
            mutex.unlock()
            throw WorkLogError.vaultLocked
        }
        lastActivity = clock.now()
        mutex.unlock()
        return try body(vault)
    }

    /// 현재 행에서 rowId의 value를 ClipboardGuard로 복사한다. 활동 시각을 갱신한다.
    public func copyValue(secretId: String, rowId: String, to guard: ClipboardGuard) throws {
        try withUnlocked { vault in
            guard let row = try vault.currentRows(secretId: secretId).first(where: { $0.id == rowId }) else {
                throw WorkLogError.notFound("Secret row \(rowId)")
            }
            `guard`.copySecret(row.value)
        }
    }

    // MARK: - 내부(mutex 보유 상태에서 호출)

    /// idle 만료면 잠근다. unlocked → locked 전환이 일어났으면 true.
    private func expireForIdleLocked(now: Date) -> Bool {
        guard sessionState == .unlocked, let last = lastActivity else { return false }
        guard now.timeIntervalSince(last) >= timeout else { return false }
        sessionState = .locked
        lastActivity = nil
        return true
    }

    /// async 문맥에서 NSLock을 직접 잠그지 않도록 동기 스코프로 감싼다.
    private func withMutex<T>(_ body: () throws -> T) rethrows -> T {
        mutex.lock(); defer { mutex.unlock() }
        return try body()
    }
}
