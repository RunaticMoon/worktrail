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
    /// 설정 화면의 "마지막 성공" 요약. 실패가 마지막이면 함께 알리고, 성공 기록이 없으면 안내한다.
    public var lastSuccessLabel: String {
        Self.successLabel(status: status, calendar: environment?.calendar ?? WorkCalendar())
    }
    static func successLabel(status: BackupStatus, calendar: WorkCalendar) -> String {
        guard let last = status.lastSuccessAt else { return "아직 성공한 백업이 없습니다" }
        let label = koreanDateTime(last, calendar: calendar)
        if let failure = status.lastFailureAt, failure > last {
            return "마지막 시도 실패 · 마지막 성공 \(label)"
        }
        return "마지막 성공 \(label)"
    }
    /// 백업 위치를 홈 디렉터리 기준 "~" 표기로 줄인 경로.
    public var backupLocationLabel: String {
        guard let folder else { return "" }
        return Self.homeRelative(folder.path)
    }
    static func homeRelative(_ path: String,
                             home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        guard !path.isEmpty else { return path }
        let normalizedHome = home != "/" && home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !normalizedHome.isEmpty,
              path == normalizedHome || path.hasPrefix(normalizedHome + "/") else { return path }
        return "~" + path.dropFirst(normalizedHome.count)
    }
    private static let koreanWeekdays = ["일", "월", "화", "수", "목", "금", "토"]
    /// "10월 5일(월) 09:12" 형식. KoreanDateLabel이 이 브랜치에 없어 동일 형식을 여기서 구성한다.
    private static func koreanDateTime(_ date: Date, calendar: WorkCalendar) -> String {
        let c = calendar.calendar.dateComponents([.month, .day, .weekday, .hour, .minute], from: date)
        let name = koreanWeekdays[((c.weekday ?? 1) - 1 + 7) % 7]
        let hour = String(format: "%02d", c.hour ?? 0)
        let minute = String(format: "%02d", c.minute ?? 0)
        return "\(c.month ?? 0)월 \(c.day ?? 0)일(\(name)) \(hour):\(minute)"
    }
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
