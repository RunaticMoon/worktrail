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
}
