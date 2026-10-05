import XCTest
@testable import WorkLogCore

/// 작업 F: Secret 조회/편집 분리·가림 문자 차단, 백업·AI 상태 요약, 복구 문구.
/// 가짜 Secret 값만 사용하며 실제 Keychain·자격증명을 읽지 않는다.
final class SecretSettingsUXTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }
    private func paths() throws -> AppPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UXFLF-\(UUID().uuidString)")
        roots.append(root)
        return AppPaths(dataRoot: root.appendingPathComponent("data"), backupRoot: root.appendingPathComponent("backups"))
    }
    private func environment(keyStore: VaultKeyStore = InMemoryVaultKeyStore(),
                             auth: MockDeviceAuthenticator = MockDeviceAuthenticator(),
                             pasteboard: InMemoryPasteboard = InMemoryPasteboard(),
                             aiProvider: AIProvider? = nil,
                             clock: FixedClock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))) throws -> AppEnvironment {
        try AppEnvironment.open(AppEnvironmentOptions(paths: paths(), keyStore: keyStore,
            authenticator: auth, pasteboard: pasteboard, aiProvider: aiProvider, clock: clock, ids: SequentialIDGenerator()))
    }
    @MainActor @discardableResult
    private func savedSecret(_ model: SecretsModel, values: [String], title: String = "회사 테스트") async throws -> [SecretRow] {
        await model.unlock()
        model.beginNew()
        model.title = title
        for value in values {
            model.addRow()
            model.rows[model.rows.count - 1].key = "KEY\(model.rows.count)"
            model.rows[model.rows.count - 1].value = value
        }
        XCTAssertTrue(model.save())
        return model.rows
    }
    private func dateKST(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var c = DateComponents(); c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute
        return WorkCalendar().calendar.date(from: c)!
    }

    // MARK: - 조회/편집 분리

    @MainActor func testReadStateFocusMoveNeverCopiesAndFocusedCopyCopiesOnce() async throws {
        let board = InMemoryPasteboard()
        let env = try environment(pasteboard: board)
        let model = SecretsModel(environment: env)
        _ = try await savedSecret(model, values: ["canary-first", "canary-second"])
        model.open(try XCTUnwrap(model.titles.first))
        XCTAssertFalse(model.isEditing)
        XCTAssertNil(model.focusedRowId)
        XCTAssertNil(board.string)
        let baseline = board.changeCount

        model.moveFocus(by: 1)
        XCTAssertEqual(model.focusedRowId, model.rows[0].id)
        XCTAssertNil(board.string)                              // 포커스 이동만으로는 복사하지 않음
        XCTAssertEqual(board.changeCount, baseline)

        model.copyFocusedRow()
        XCTAssertEqual(board.string, "canary-first")
        let afterFirstCopy = board.changeCount
        XCTAssertEqual(afterFirstCopy, baseline + 1)            // 한 번의 호출에 한 번만 복사

        model.moveFocus(by: 1)
        XCTAssertEqual(model.focusedRowId, model.rows[1].id)
        XCTAssertEqual(board.string, "canary-first")            // 이동은 클립보드를 건드리지 않음
        XCTAssertEqual(board.changeCount, afterFirstCopy)

        model.moveFocus(by: 5)                                  // clamp
        XCTAssertEqual(model.focusedRowId, model.rows[1].id)
        model.moveFocus(by: -5)
        XCTAssertEqual(model.focusedRowId, model.rows[0].id)

        model.copyFocusedRow()
        XCTAssertEqual(board.string, "canary-first")
        XCTAssertEqual(board.changeCount, afterFirstCopy + 1)
    }

    @MainActor func testCopyFocusedRowIgnoredWhileEditing() async throws {
        let board = InMemoryPasteboard()
        let model = SecretsModel(environment: try environment(pasteboard: board))
        _ = try await savedSecret(model, values: ["canary-edit"])
        model.open(try XCTUnwrap(model.titles.first))
        model.moveFocus(by: 1)
        model.beginEditing()
        XCTAssertTrue(model.isEditing)
        let count = board.changeCount
        model.copyFocusedRow()
        XCTAssertNil(board.string)
        XCTAssertEqual(board.changeCount, count)
    }

    @MainActor func testCancelEditingRestoresOriginalsAndClearsPreview() async throws {
        let env = try environment()
        let model = SecretsModel(environment: env)
        let originals = try await savedSecret(model, values: ["canary-original"], title: "원본 제목")
        model.open(try XCTUnwrap(model.titles.first))
        model.beginEditing()
        model.title = "바뀐 제목"
        model.groupName = "바뀐 그룹"
        model.rows[0].key = "CHANGED"
        model.rows[0].value = "canary-changed"
        model.acceptPaste("pending=canary-pending")
        XCTAssertFalse(model.preview.isEmpty)

        model.cancelEditing()
        XCTAssertFalse(model.isEditing)
        XCTAssertNil(model.focusedRowId)
        XCTAssertEqual(model.rows, originals)
        XCTAssertEqual(model.title, "원본 제목")
        XCTAssertEqual(model.groupName, "")
        XCTAssertTrue(model.preview.isEmpty)
        XCTAssertTrue(model.pasteText.isEmpty)
        XCTAssertTrue(model.maskedRowIds.isEmpty)
    }

    @MainActor func testEditingStateTransitions() async throws {
        let model = SecretsModel(environment: try environment())
        await model.unlock()
        model.beginNew()
        XCTAssertTrue(model.isEditing)
        model.addRow(); model.rows[0].key = "K"; model.rows[0].value = "canary-draft"
        model.lock()
        await model.unlock()
        XCTAssertTrue(model.hasRecoverableDraft)
        model.recoverDraft()
        XCTAssertTrue(model.isEditing)
    }

    // MARK: - 가림 문자 차단

    @MainActor func testMaskedOnlyValueIsNotSavedAndOtherRowsPreserved() async throws {
        let env = try environment()
        let model = SecretsModel(environment: env)
        await model.unlock()
        model.beginNew()
        model.title = "가림 테스트"
        model.addRow(); model.rows[0].key = "MASK"; model.rows[0].value = "●●●"
        model.addRow(); model.rows[1].key = "REAL"; model.rows[1].value = " canary-real "
        let maskedId = model.rows[0].id

        XCTAssertFalse(model.save())
        XCTAssertEqual(model.maskedRowIds, [maskedId])
        XCTAssertEqual(model.message, "가림 문자(•)만 있는 값은 저장하지 않았습니다. 실제 값을 입력하세요.")
        XCTAssertFalse(model.message?.contains("●●●") == true)   // 값 문자열 미포함
        XCTAssertEqual(model.rows.count, 2)                       // 다른 행·입력 보존
        XCTAssertEqual(model.rows[1].value, " canary-real ")
        XCTAssertTrue(model.isEditing)                            // 저장 실패 → 편집 유지
        XCTAssertTrue(model.titles.isEmpty)                       // 아무 것도 저장되지 않음

        // 해당 행을 고치면 다음 저장에서 해제된다.
        model.rows[0].value = " canary-fixed "
        XCTAssertTrue(model.save())
        XCTAssertTrue(model.maskedRowIds.isEmpty)
        XCTAssertFalse(model.isEditing)
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertEqual(model.rows[0].value, "canary-fixed")
        XCTAssertEqual(model.rows[1].value, "canary-real")
        XCTAssertEqual(model.titles.map(\.title), ["가림 테스트"])
    }

    // MARK: - 백업 요약

    @MainActor func testLastSuccessLabelThreeCases() {
        let cal = WorkCalendar()
        let success = dateKST(2026, 10, 5, 9, 12)      // 2026-10-05(월) 09:12 KST
        XCTAssertEqual(BackupModel.successLabel(status: BackupStatus(lastSuccessAt: success), calendar: cal),
                       "마지막 성공 10월 5일(월) 09:12")
        XCTAssertEqual(BackupModel.successLabel(status: BackupStatus(), calendar: cal),
                       "아직 성공한 백업이 없습니다")
        XCTAssertEqual(BackupModel.successLabel(status: BackupStatus(
            lastSuccessAt: success, lastFailureAt: success.addingTimeInterval(60)), calendar: cal),
                       "마지막 시도 실패 · 마지막 성공 10월 5일(월) 09:12")
        // 실패가 성공보다 과거면 실패를 언급하지 않는다.
        XCTAssertEqual(BackupModel.successLabel(status: BackupStatus(
            lastSuccessAt: success, lastFailureAt: success.addingTimeInterval(-60)), calendar: cal),
                       "마지막 성공 10월 5일(월) 09:12")
    }

    @MainActor func testBackupLocationLabelAbbreviatesHome() {
        XCTAssertEqual(BackupModel.homeRelative("/Users/fake/Library/Backups", home: "/Users/fake"),
                       "~/Library/Backups")
        XCTAssertEqual(BackupModel.homeRelative("/Users/fake", home: "/Users/fake"), "~")
        XCTAssertEqual(BackupModel.homeRelative("/Volumes/Ext/Backups", home: "/Users/fake"),
                       "/Volumes/Ext/Backups")
        // 접두어만 같은 다른 디렉터리는 줄이지 않는다.
        XCTAssertEqual(BackupModel.homeRelative("/Users/fake2/Backups", home: "/Users/fake"),
                       "/Users/fake2/Backups")
    }

    @MainActor func testBackupLocationLabelUsesFolderPath() throws {
        let env = try environment()
        let model = BackupModel(environment: env)
        XCTAssertEqual(model.backupLocationLabel, env.options.paths.backupRoot.path)
    }

    // MARK: - AI 상태 요약

    @MainActor func testAIConnectionSummaryReflectsRuntimeRunner() throws {
        let noAI = SettingsModel(environment: try environment())
        XCTAssertEqual(noAI.aiConnectionSummary, .notConfigured)
        XCTAssertEqual(noAI.aiConnectionSummary.title, "AI에 연결되어 있지 않습니다")
        XCTAssertEqual(noAI.aiConnectionSummary.detail,
                       "기록·검색·기록 기반 초안은 그대로 사용할 수 있습니다. 필요할 때 설정에서 연결하세요.")

        let withAI = SettingsModel(environment: try environment(aiProvider: MockAIProvider()))
        XCTAssertEqual(withAI.aiConnectionSummary, .connected)
        XCTAssertEqual(withAI.aiConnectionSummary.title, "AI에 연결되어 있습니다")
        XCTAssertEqual(AIConnectionSummary.unavailable(reason: "네트워크 오류").detail, "네트워크 오류")
    }

    // MARK: - 복구 문구

    func testRecoveryMessages() {
        XCTAssertEqual(RecoveryMessage.captureSaveFailed.text,
                       "저장하지 못했습니다 · 입력은 그대로 있습니다 · 다시 저장하세요")
        XCTAssertEqual(RecoveryMessage.aiDraftFailed.text,
                       "AI 초안을 만들지 못했습니다 · 기존 본문은 그대로입니다 · 다시 시도하세요")
        XCTAssertEqual(RecoveryMessage.searchFailed.failed, "검색하지 못했습니다")
        XCTAssertEqual(RecoveryMessage(failed: "a", preserved: "b", retry: "c").text, "a · b · c")
    }

    // 내부 공백·개행 보존 trim, 부분 수정 시 다른 행 id·값 유지, 새 버전·이전 버전 복원·휴지통 복원은
    // 기존 테스트가 이미 검증한다:
    // - Tests/WorkLogCoreTests/SecretsSettingsBackupPresentationTests.swift
    //   testAuthenticatedCreatePartialEditKeepsStableIDsAndOtherRows (부분 수정·trim 보존)
    //   testRevisionRestoreTrashRestoreAndPurge (버전 생성·이전 버전 복원·휴지통 복원)
}
