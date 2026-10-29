import XCTest
@testable import WorkLogCore

/// 설정 파일 저장소: 누락 키 관대 디코딩, 원자적 저장·권한, 손상 JSON 보존, 검증.
final class SettingsStoreTests: XCTestCase {

    private var tempRoots: [URL] = []

    override func tearDown() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoots.append(root)
        return root
    }

    private func makeStore() throws -> (SettingsStore, URL) {
        let root = try makeRoot()
        let file = root.appendingPathComponent("settings.json")
        return (SettingsStore(fileURL: file), file)
    }

    private func permissions(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let value = attrs[.posixPermissions] as? NSNumber
        return value?.intValue ?? -1
    }

    /// `AppSettings`의 저장 프로퍼티 이름. 검증 문구에 내부 식별자가 새지 않았는지 검사하는 기준이다.
    private func appSettingsPropertyNames() -> [String] {
        Mirror(reflecting: AppSettings()).children.compactMap(\.label)
    }

    // MARK: 1 — 파일 없음 → 기본값, 파일 생성 안 됨

    func testLoadWithoutFileReturnsDefaultsAndCreatesNothing() throws {
        let (store, file) = try makeStore()
        let settings = try store.load()
        XCTAssertEqual(settings, AppSettings())
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: 2 — save → load 왕복 동일, 파일 권한 0600

    func testSaveThenLoadRoundTripAndPermissions() throws {
        let (store, file) = try makeStore()
        var settings = AppSettings()
        settings.secretIdleLockMinutes = 45
        settings.clipboardClearSeconds = 300
        settings.backupRetentionDays = 90
        settings.mondayReminderTime = "08:15"
        settings.maxQuizQuestions = 2
        settings.aiConcurrency = 4
        settings.timeZoneIdentifier = "America/New_York"
        settings.captureHotkey = "cmd+shift+k"
        settings.searchHotkey = "cmd+shift+l"
        settings.menuBarResident = false
        settings.launchAtLogin = true
        settings.codexExecutablePath = "/usr/local/bin/codex"
        settings.skillBindings = ["weekly": "team-weekly"]

        try store.save(settings)

        let loaded = try store.load()
        XCTAssertEqual(loaded, settings)
        XCTAssertEqual(try permissions(of: file), 0o600)
    }

    // MARK: 3 — 일부 키만 있는 JSON → 해당 값 + 나머지 기본값, 알 수 없는 키 무시

    func testPartialAndUnknownKeysDecodeLeniently() throws {
        let (store, file) = try makeStore()
        let json = #"{"secretIdleLockMinutes": 10, "unknownFeature": {"enabled": true}}"#
        try Data(json.utf8).write(to: file)

        let loaded = try store.load()
        XCTAssertEqual(loaded.secretIdleLockMinutes, 10)

        let defaults = AppSettings()
        XCTAssertEqual(loaded.clipboardClearSeconds, defaults.clipboardClearSeconds)
        XCTAssertEqual(loaded.backupRetentionDays, defaults.backupRetentionDays)
        XCTAssertEqual(loaded.mondayReminderTime, defaults.mondayReminderTime)
        XCTAssertEqual(loaded.maxQuizQuestions, defaults.maxQuizQuestions)
        XCTAssertEqual(loaded.timeZoneIdentifier, defaults.timeZoneIdentifier)
        XCTAssertEqual(loaded.captureHotkey, defaults.captureHotkey)
        XCTAssertEqual(loaded.searchHotkey, defaults.searchHotkey)
        XCTAssertEqual(loaded.aiConcurrency, defaults.aiConcurrency)
        XCTAssertEqual(loaded.skillBindings, defaults.skillBindings)
    }

    func testEmptyObjectGivesAllDefaults() throws {
        let (store, file) = try makeStore()
        try Data("{}".utf8).write(to: file)
        XCTAssertEqual(try store.load(), AppSettings())
    }

    // MARK: 4 — 손상 JSON → storage 오류, 파일 내용 그대로

    func testCorruptJSONThrowsStorageAndPreservesFile() throws {
        let (store, file) = try makeStore()
        let corrupt = "{ this is not json"
        try Data(corrupt.utf8).write(to: file)

        XCTAssertThrowsError(try store.load()) { error in
            guard case WorkLogError.storage = error else {
                return XCTFail("storage 오류 기대: \(error)")
            }
        }
        XCTAssertEqual(String(decoding: try Data(contentsOf: file), as: UTF8.self), corrupt)
    }

    // MARK: 5 — 각 검증 위반 → validation 오류, 기존 파일 변경 없음

    func testValidationRejectsInvalidValuesWithoutTouchingFile() throws {
        let (store, file) = try makeStore()
        let valid = AppSettings()
        try store.save(valid)
        let before = try Data(contentsOf: file)

        var cases: [(String, (inout AppSettings) -> Void)] = []
        cases.append(("secretIdleLockMinutes", { $0.secretIdleLockMinutes = 0 }))
        cases.append(("clipboardClearSeconds", { $0.clipboardClearSeconds = 9 }))
        cases.append(("backupRetentionDays", { $0.backupRetentionDays = 3651 }))
        cases.append(("mondayReminderTime", { $0.mondayReminderTime = "24:00" }))
        cases.append(("maxQuizQuestions", { $0.maxQuizQuestions = 4 }))
        cases.append(("aiConcurrency", { $0.aiConcurrency = 0 }))
        cases.append(("timeZoneIdentifier", { $0.timeZoneIdentifier = "Not/AZone" }))
        cases.append(("captureHotkey empty", { $0.captureHotkey = "  " }))
        cases.append(("hotkeys equal", { $0.searchHotkey = $0.captureHotkey }))

        for (label, mutate) in cases {
            var settings = AppSettings()
            mutate(&settings)
            XCTAssertThrowsError(try store.save(settings), label) { error in
                guard case WorkLogError.validation = error else {
                    return XCTFail("[\(label)] validation 오류 기대: \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: file), before, "[\(label)] 파일이 변경됨")
        }
    }

    func testValidateReturnsEmptyForDefaults() {
        XCTAssertTrue(SettingsStore.validate(AppSettings()).isEmpty)
    }

    // MARK: 5b — 검증 문구는 화면 레이블을 쓰고 내부 프로퍼티 이름을 노출하지 않는다

    func testBackupRetentionValidationMessageUsesVisibleLabel() throws {
        var settings = AppSettings()
        settings.backupRetentionDays = 0

        let problems = SettingsStore.validate(settings)

        XCTAssertFalse(problems.isEmpty, "백업 보관 기간 위반이 보고되지 않음")
        let message = try XCTUnwrap(problems.first)
        XCTAssertTrue(message.contains("백업 보관 기간"), message)
        XCTAssertTrue(message.contains("1~3650일"), "범위 정보가 유지돼야 합니다: \(message)")
        XCTAssertTrue(message.contains("현재 0일"), "현재 값 정보가 유지돼야 합니다: \(message)")
        for name in appSettingsPropertyNames() {
            XCTAssertFalse(message.contains(name), "내부 프로퍼티 이름이 노출됨: \(name) in \(message)")
        }
        XCTAssertNil(message.range(of: "[a-z]+[A-Z]", options: .regularExpression),
                     "내부 camelCase 이름이 노출됨: \(message)")
    }

    /// 모든 필드를 위반 값으로 채워 나오는 모든 검증 문구에 `AppSettings` 프로퍼티 이름이 없어야 한다.
    /// (단축키는 파싱 실패와 빈 값 두 경로가 있어 각각 확인한다.)
    func testEveryValidationMessageAvoidsInternalPropertyNames() {
        let hotkeyVariants: [(String, (inout AppSettings) -> Void)] = [
            ("파싱 실패", { $0.captureHotkey = "ctrl+opt+tab"; $0.searchHotkey = "super+d" }),
            ("빈 값", { $0.captureHotkey = "   "; $0.searchHotkey = "\n" }),
        ]
        // 위반한 필드의 화면/서술형 문구가 모두 보고되는지 확인한다(문제 개수 고정값에 의존하지 않는다).
        let expectedLabels = ["미사용 시 자동 잠금", "복사 후 클립보드 지우기", "백업 보관 기간",
                              "월요일 검토 알림", "성과 질문 최대 개수", "AI 동시 실행 수",
                              "업무 시간대", "빠른 입력 단축키", "검색 단축키"]
        let propertyNames = appSettingsPropertyNames()
        XCTAssertFalse(propertyNames.isEmpty, "AppSettings 프로퍼티 이름을 찾지 못했습니다")

        for (variant, mutateHotkeys) in hotkeyVariants {
            var settings = AppSettings()
            settings.secretIdleLockMinutes = 0
            settings.clipboardClearSeconds = 0
            settings.backupRetentionDays = 0
            settings.mondayReminderTime = "99:99"
            settings.maxQuizQuestions = 9
            settings.aiConcurrency = 9
            settings.timeZoneIdentifier = "No/Such_Zone"
            mutateHotkeys(&settings)

            let problems = SettingsStore.validate(settings)
            let joined = problems.joined(separator: "\n")
            for label in expectedLabels {
                XCTAssertTrue(joined.contains(label),
                              "[\(variant)] \(label) 위반이 보고돼야 합니다: \(problems)")
            }
            for message in problems {
                for name in propertyNames {
                    XCTAssertFalse(message.contains(name),
                                   "[\(variant)] 내부 프로퍼티 이름이 노출됨: \(name) in \(message)")
                }
                XCTAssertNil(message.range(of: "[a-z]+[A-Z]", options: .regularExpression),
                             "[\(variant)] 내부 camelCase 이름이 노출됨: \(message)")
            }
        }
    }

    // MARK: 6 — 상위 디렉터리 없으면 0700으로 생성

    func testSaveCreatesMissingParentDirectory() throws {
        let root = try makeRoot()
        let nested = root.appendingPathComponent("a/b", isDirectory: true)
        let file = nested.appendingPathComponent("settings.json")
        let store = SettingsStore(fileURL: file)

        try store.save(AppSettings())

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertEqual(try permissions(of: nested), 0o700)
    }

    // MARK: 7 — 검색 단축키 기본값 ctrl+opt+d, 저장된 값 보존

    func testSearchHotkeyDefaultIsCtrlOptD() {
        XCTAssertEqual(AppSettings().searchHotkey, "ctrl+opt+d")
    }

    func testMissingSearchHotkeyDecodesToCtrlOptD() throws {
        let (store, file) = try makeStore()
        try Data(#"{"captureHotkey": "ctrl+opt+space"}"#.utf8).write(to: file)

        let loaded = try store.load()
        XCTAssertEqual(loaded.searchHotkey, "ctrl+opt+d")
    }

    func testStoredSearchHotkeyIsPreservedAcrossRoundTrip() throws {
        let (store, file) = try makeStore()

        for stored in ["ctrl+opt+f", "cmd+shift+l"] {
            let json = #"{"searchHotkey": ""# + stored + #""}"#
            try Data(json.utf8).write(to: file)

            let loaded = try store.load()
            XCTAssertEqual(loaded.searchHotkey, stored, "저장된 \(stored)이 보존돼야 함")

            try store.save(loaded)
            let raw = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            XCTAssertTrue(raw.contains(#""searchHotkey":"# + "\"" + stored + "\""),
                          "재인코딩 후에도 \(stored)이 유지돼야 함: \(raw)")
            XCTAssertEqual(try store.load().searchHotkey, stored)
        }
    }
}
