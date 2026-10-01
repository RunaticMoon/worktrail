import Foundation
import Observation

@Observable @MainActor public final class BackupModel {
    public private(set) var backups: [BackupInfo] = []
    public private(set) var status = BackupStatus()
    public private(set) var message: String?
    public private(set) var verifiedIds: Set<String> = []
    public private(set) var isBusy = false
    public private(set) var offersOrdinaryOnlyRestore = false
    public var pendingRestore: BackupInfo?
    public var includeSecrets = true
    @ObservationIgnored private var environment: AppEnvironment?
    public init(environment: AppEnvironment) { self.environment = environment; load() }
    public var folder: URL? { environment?.options.paths.backupRoot }
    public func detach() { environment = nil }
    public func load() {
        guard let environment else { return }
        do {
            backups = try environment.backup.listBackups(); status = environment.backup.status
            if status.lastSuccessAt == nil { status.lastSuccessAt = backups.first?.manifest.createdAt }
        }
        catch { recordFailure(error) }
    }
    public func create() async {
        guard !isBusy, let environment else { return }
        isBusy = true; defer { isBusy = false }
        do {
            let service = environment.backup
            _ = try await Task.detached { try service.createBackup(reason: .manual) }.value
            load(); message = "백업을 만들었습니다."
        } catch { status = environment.backup.status; recordFailure(error) }
    }
    @discardableResult public func verify(_ backup: BackupInfo) async -> Bool {
        guard !isBusy, let environment else { return false }
        isBusy = true; defer { isBusy = false }
        do {
            let service = environment.backup
            try await Task.detached { try service.verify(backup) }.value
            verifiedIds.insert(backup.id)
            message = "백업 형식·해시·데이터베이스 무결성 검증을 통과했습니다."; return true
        } catch { verifiedIds.remove(backup.id); recordFailure(error); return false }
    }
    public func requestRestore(_ backup: BackupInfo) async {
        guard await verify(backup) else { return }
        pendingRestore = backup; includeSecrets = true; offersOrdinaryOnlyRestore = false
    }
    public func cancelRestore() { pendingRestore = nil }
    public func recordFailure(_ error: Error) {
        switch error as? BackupFailure {
        case .vaultKeyMissing?, .vaultKeyMismatch?:
            offersOrdinaryOnlyRestore = true; includeSecrets = false
            message = "Secret 키가 없거나 백업의 키와 다릅니다. 키 없이 Secret을 복구할 수 없으며 같은 Mac의 기존 Keychain 키가 필요합니다. Secret을 제외하고 일반 기록만 복원할 수 있습니다."
        case .hashMismatch?, .integrityFailed?:
            message = "백업 파일이 손상되었거나 내용이 변경되었습니다. 다른 복원 지점을 선택하세요."
        case .manifestMissing?, .manifestInvalid?:
            message = "백업 형식을 확인할 수 없습니다. 다른 복원 지점을 선택하세요."
        case .unsupportedSchema?:
            message = "이 앱보다 새로운 데이터 형식입니다. 백업을 만든 버전 이상의 앱으로 복원하세요."
        default:
            message = "백업 작업을 완료하지 못했습니다. 폴더 권한과 여유 공간을 확인하세요."
        }
    }
    /// Use after the caller has released every connection to the target databases.
    @discardableResult public func restoreAfterClosing(_ backup: BackupInfo, into paths: AppPaths,
        keyStore: VaultKeyStore, includeVault: Bool, clock: Clock) async -> Bool {
        guard environment == nil else {
            message = "저장소 연결을 먼저 닫아야 합니다. 앱을 다시 열고 시도하세요."; return false
        }
        guard !isBusy else { return false }
        isBusy = true; defer { isBusy = false }
        do {
            try await Task.detached {
                try BackupService.restore(backup, into: paths, keyStore: keyStore, includeVault: includeVault, clock: clock)
            }.value
            pendingRestore = nil; message = "복원을 완료했습니다. 앱을 다시 열어 복원한 기록을 사용하세요."; return true
        } catch { pendingRestore = backup; recordFailure(error); return false }
    }
    public static func reasonLabel(_ reason: BackupReason) -> String {
        switch reason {
        case .daily: return "일일 백업"
        case .manual: return "수동 백업"
        case .preMigration: return "데이터 형식 변경 전"
        case .preRestore: return "복원 직전 보존본"
        }
    }
    public static func size(_ backup: BackupInfo) -> Int64 { backup.manifest.files.reduce(0) { $0 + Int64($1.size) } }
}
