import XCTest
@testable import WorkLogCore

/// WTUX-F946 S: 설정 단축키 검증·정규화가 HotkeyBinding 한 곳을 쓰는지 검증한다.
/// 파싱 오류·별칭/순서 동등 충돌·정규화 저장·레코더 지원 API·검증 실패 시 파일 불변을 확인한다.
final class SettingsHotkeyValidationTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsHotkeyValidationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func environment() throws -> AppEnvironment {
        let root = try makeRoot()
        let paths = AppPaths(dataRoot: root.appendingPathComponent("data"),
                             backupRoot: root.appendingPathComponent("backups"))
        return try AppEnvironment.open(AppEnvironmentOptions(
            paths: paths,
            keyStore: InMemoryVaultKeyStore(),
            authenticator: MockDeviceAuthenticator(),
            pasteboard: InMemoryPasteboard(),
            clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_000)),
            ids: SequentialIDGenerator()))
    }

    private struct FakeHotkeyApplyError: LocalizedError {
        var errorDescription: String? { "단축키 등록 실패: 이미 사용 중인 조합입니다." }
    }

    // MARK: - 파싱 실패 → 형식 오류

    func testUnsupportedKeyRejected() {
        var settings = AppSettings()
        settings.captureHotkey = "ctrl+opt+tab"
        let problems = SettingsStore.validate(settings)
        XCTAssertTrue(problems.contains { $0.contains("입력 단축키(captureHotkey) 형식 오류") },
                      "형식 오류 문구가 필요합니다: \(problems)")
        XCTAssertTrue(problems.contains { $0.contains("지원하지 않는 키") }, "\(problems)")
    }

    func testUnsupportedModifierRejected() {
        var settings = AppSettings()
        settings.searchHotkey = "super+d"
        let problems = SettingsStore.validate(settings)
        XCTAssertTrue(problems.contains { $0.contains("검색 단축키(searchHotkey) 형식 오류") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("지원하지 않는 수정자") }, "\(problems)")
    }

    func testMissingModifierRejected() {
        var settings = AppSettings()
        settings.captureHotkey = "d"
        XCTAssertTrue(SettingsStore.validate(settings).contains { $0.contains("입력 단축키(captureHotkey) 형식 오류") })
    }

    func testMissingKeyRejected() {
        var settings = AppSettings()
        settings.searchHotkey = "ctrl+opt"
        XCTAssertTrue(SettingsStore.validate(settings).contains { $0.contains("검색 단축키(searchHotkey) 형식 오류") })
    }

    // MARK: - 별칭·순서만 다른 동일 조합 → 충돌

    func testAliasAndOrderEquivalentConflict() {
        var settings = AppSettings()
        settings.captureHotkey = "command+control+F"
        settings.searchHotkey = "CTRL+CMD+f"
        let problems = SettingsStore.validate(settings)
        XCTAssertTrue(problems.contains("캡처 단축키와 검색 단축키는 서로 달라야 합니다."), "\(problems)")
        XCTAssertFalse(problems.contains { $0.contains("형식 오류") }, "정상 파싱이어야 합니다: \(problems)")
    }

    func testDistinctValidValuesPass() {
        var settings = AppSettings()
        settings.captureHotkey = "cmd+shift+k"
        settings.searchHotkey = "cmd+shift+l"
        XCTAssertTrue(SettingsStore.validate(settings).isEmpty)
    }

    func testEmptyValueKeepsExistingMessage() {
        var settings = AppSettings()
        settings.captureHotkey = "   "
        let problems = SettingsStore.validate(settings)
        XCTAssertTrue(problems.contains("캡처 단축키(captureHotkey)는 비어 있을 수 없습니다."), "\(problems)")
    }

    // MARK: - 정상값 정규화 저장

    @MainActor func testValidateNormalizesDraftAndSavePersistsCanonical() async throws {
        let env = try environment()
        let model = SettingsModel(environment: env)
        model.draft.captureHotkey = "Opt+Ctrl+K"
        model.draft.searchHotkey = "Alt+Shift+P"

        XCTAssertTrue(model.validate())
        XCTAssertEqual(model.draft.captureHotkey, "ctrl+opt+k")
        XCTAssertEqual(model.draft.searchHotkey, "opt+shift+p")

        XCTAssertTrue(model.save())
        XCTAssertEqual(env.settings.captureHotkey, "ctrl+opt+k")
        XCTAssertEqual(env.settings.searchHotkey, "opt+shift+p")
        XCTAssertEqual(try env.settingsStore.load().captureHotkey, "ctrl+opt+k")
        XCTAssertEqual(try env.settingsStore.load().searchHotkey, "opt+shift+p")
    }

    // MARK: - 레코더 지원 API

    @MainActor func testSetHotkeyWritesCanonicalString() async throws {
        let env = try environment()
        let model = SettingsModel(environment: env)
        model.setHotkey(try HotkeyBinding(parsing: "Opt+Ctrl+K"), for: .capture)
        XCTAssertEqual(model.draft.captureHotkey, "ctrl+opt+k")
        model.setHotkey(try HotkeyBinding(parsing: "command+shift+p"), for: .search)
        XCTAssertEqual(model.draft.searchHotkey, "shift+cmd+p")
    }

    @MainActor func testRestoreDefaultHotkeys() async throws {
        let env = try environment()
        let model = SettingsModel(environment: env)
        model.draft.captureHotkey = "cmd+shift+k"
        model.draft.searchHotkey = "cmd+shift+l"
        model.restoreDefaultHotkeys()
        XCTAssertEqual(model.draft.captureHotkey, "ctrl+opt+space")
        XCTAssertEqual(model.draft.searchHotkey, "ctrl+opt+d")
    }

    @MainActor func testHotkeyDisplayUsesSymbolsAndFallsBackToRaw() async throws {
        let env = try environment()
        let model = SettingsModel(environment: env)
        XCTAssertEqual(model.hotkeyDisplay(for: .capture), "⌃⌥Space")
        XCTAssertEqual(model.hotkeyDisplay(for: .search), "⌃⌥D")
        model.draft.captureHotkey = "지원하지 않는 값"
        XCTAssertEqual(model.hotkeyDisplay(for: .capture), "지원하지 않는 값")
    }

    // MARK: - 검증 실패 시 파일·기존 설정 불변

    func testStoreSaveRejectsUnsupportedHotkeyWithoutTouchingFile() throws {
        let root = try makeRoot()
        let file = root.appendingPathComponent("settings.json")
        let store = SettingsStore(fileURL: file)
        try store.save(AppSettings())
        let before = try Data(contentsOf: file)

        var settings = AppSettings()
        settings.captureHotkey = "ctrl+opt+tab"
        XCTAssertThrowsError(try store.save(settings)) { error in
            guard case WorkLogError.validation = error else {
                return XCTFail("validation 오류 기대: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    @MainActor func testValidationFailureLeavesFileAndEnvironmentSettingsUnchanged() async throws {
        let env = try environment()
        let model = SettingsModel(environment: env)
        XCTAssertTrue(model.save())
        let file = env.options.paths.settingsFile
        let before = try Data(contentsOf: file)
        let saved = env.settings

        model.draft.captureHotkey = "ctrl+opt+tab"
        XCTAssertFalse(model.save())
        XCTAssertFalse(model.errors.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(env.settings, saved)

        model.reset()
        model.draft.captureHotkey = "command+control+F"
        model.draft.searchHotkey = "CTRL+CMD+f"
        XCTAssertFalse(model.save())
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(env.settings, saved)
    }

    // MARK: - 저장 실패 메시지 구분

    @MainActor func testSaveSurfacesLocalizedHotkeyErrorButHidesWorkLogError() async throws {
        let env = try environment()
        let model = SettingsModel(environment: env)

        XCTAssertFalse(model.save(apply: { _ in throw FakeHotkeyApplyError() }))
        XCTAssertEqual(model.errors, ["단축키 등록 실패: 이미 사용 중인 조합입니다."])

        XCTAssertFalse(model.save(apply: { _ in throw WorkLogError.validation("canary-registration") }))
        XCTAssertFalse(model.errors.joined().contains("canary-registration"))
    }
}
