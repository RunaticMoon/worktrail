import Foundation

/// `settings.json`을 안전하게 읽고 쓰는 저장소.
///
/// - Secret·토큰·키는 저장하지 않는다(AppSettings에 그러한 필드가 없다).
/// - 읽기: 파일이 없으면 기본값을 반환하고 파일을 만들지 않는다. 손상된 JSON은 덮어쓰지 않고 storage 오류로 알린다.
/// - 쓰기: 검증 실패 시 파일을 건드리지 않는다. 성공 시 정렬 키 JSON을 원자적으로 교체하고 권한 0600을 적용한다.
public final class SettingsStore {

    private let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    // MARK: - 읽기

    /// 파일이 없으면 `AppSettings()`를 반환한다(파일 생성 없음).
    /// JSON이 손상됐으면 `WorkLogError.storage`를 던지고 기존 파일을 덮어쓰지 않는다.
    public func load() throws -> AppSettings {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return AppSettings()
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw WorkLogError.storage("설정 파일을 읽을 수 없습니다: \(fileURL.path)")
        }
        do {
            return try StableJSON.decode(AppSettings.self, from: data)
        } catch {
            throw WorkLogError.storage("설정 파일 형식이 올바르지 않습니다: \(fileURL.path)")
        }
    }

    // MARK: - 쓰기

    /// 검증 실패 시 `WorkLogError.validation`을 던지고 파일을 변경하지 않는다.
    /// 성공 시 StableJSON(정렬 키)로 원자적으로 교체하고 권한 0600, 상위 디렉터리가 없으면 0700으로 만든다.
    public func save(_ settings: AppSettings) throws {
        let problems = SettingsStore.validate(settings)
        guard problems.isEmpty else {
            throw WorkLogError.validation(problems.joined(separator: "\n"))
        }

        let data = try StableJSON.encode(settings)
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        }
        // 처음부터 0600인 임시 파일에 쓰고 rename(2)으로 원자적으로 교체한다
        // (교체 전후 어느 순간에도 넓은 권한의 설정 파일이 생기지 않게 한다).
        let tempURL = directory.appendingPathComponent(".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: tempURL.path, contents: data,
                                     attributes: [.posixPermissions: 0o600]) else {
            throw WorkLogError.storage("설정 임시 파일을 만들 수 없습니다: \(directory.path)")
        }
        guard rename(tempURL.path, fileURL.path) == 0 else {
            try? fileManager.removeItem(at: tempURL)
            throw WorkLogError.storage("설정 파일을 교체할 수 없습니다: \(fileURL.path)")
        }
    }

    // MARK: - 검증

    /// 한국어 오류 메시지 목록. 빈 배열이면 유효하다.
    public static func validate(_ settings: AppSettings) -> [String] {
        var problems: [String] = []

        if !(1...1440).contains(settings.secretIdleLockMinutes) {
            problems.append("Secret 자동 잠금 시간(secretIdleLockMinutes)은 1~1440분이어야 합니다. "
                + "현재 \(settings.secretIdleLockMinutes)")
        }
        if !(10...3600).contains(settings.clipboardClearSeconds) {
            problems.append("클립보드 지우기 시간(clipboardClearSeconds)은 10~3600초여야 합니다. "
                + "현재 \(settings.clipboardClearSeconds)")
        }
        if !(1...3650).contains(settings.backupRetentionDays) {
            problems.append("백업 보존 일수(backupRetentionDays)는 1~3650일이어야 합니다. "
                + "현재 \(settings.backupRetentionDays)")
        }
        if !isTimeOfDay(settings.mondayReminderTime) {
            problems.append("월요일 알림 시각(mondayReminderTime)은 \"HH:mm\"(00:00~23:59) 형식이어야 합니다. "
                + "현재 \(settings.mondayReminderTime)")
        }
        if !(0...3).contains(settings.maxQuizQuestions) {
            problems.append("성과 질문 최대 개수(maxQuizQuestions)는 0~3이어야 합니다. "
                + "현재 \(settings.maxQuizQuestions)")
        }
        if !(1...4).contains(settings.aiConcurrency) {
            problems.append("AI 동시 실행 수(aiConcurrency)는 1~4여야 합니다. 현재 \(settings.aiConcurrency)")
        }
        if TimeZone(identifier: settings.timeZoneIdentifier) == nil {
            problems.append("시간대(timeZoneIdentifier)가 올바르지 않습니다: \(settings.timeZoneIdentifier)")
        }

        let capture = settings.captureHotkey.trimmingCharacters(in: .whitespacesAndNewlines)
        let search = settings.searchHotkey.trimmingCharacters(in: .whitespacesAndNewlines)
        if capture.isEmpty {
            problems.append("캡처 단축키(captureHotkey)는 비어 있을 수 없습니다.")
        }
        if search.isEmpty {
            problems.append("검색 단축키(searchHotkey)는 비어 있을 수 없습니다.")
        }
        if !capture.isEmpty && capture == search {
            problems.append("캡처 단축키와 검색 단축키는 서로 달라야 합니다.")
        }

        return problems
    }

    /// "HH:mm"(00:00~23:59) 형식인지.
    private static func isTimeOfDay(_ value: String) -> Bool {
        value.range(of: #"^(?:[01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) != nil
    }
}
