import XCTest
@testable import WorkLogCore

final class CaptureDraftReceiptTests: XCTestCase {
    private var roots: [URL] = []
    private let today = WorkDate("2026-10-28")!
    private let yesterday = WorkDate("2026-10-27")!

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    private func environment() throws -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureReceipt-\(UUID().uuidString)")
        roots.append(root)
        let paths = AppPaths(dataRoot: root, backupRoot: root.appendingPathComponent("backups"))
        var settings = AppSettings(); settings.aiEnabled = false
        try SettingsStore(fileURL: paths.settingsFile).save(settings)
        return try AppEnvironment.open(AppEnvironmentOptions(paths: paths, keyStore: InMemoryVaultKeyStore(),
            authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(),
            clock: FixedClock(WorkCalendar().startOfDay(today)), ids: SequentialIDGenerator()))
    }

    /// Exercise a real filesystem failure independently of UID/permission semantics.
    /// Restoring the inaccessible directory leaves its previous checkpoint unchanged.
    private func withCheckpointFailure(_ env: AppEnvironment, operation: () throws -> Void) throws {
        let fm = FileManager.default
        let directory = env.options.paths.dataRoot.appendingPathComponent("capture-drafts")
        let parked = env.options.paths.dataRoot.appendingPathComponent("unavailable-capture-drafts")
        try fm.moveItem(at: directory, to: parked)
        try Data("temporarily unavailable directory".utf8).write(to: directory)
        defer {
            try? fm.removeItem(at: directory)
            try? fm.moveItem(at: parked, to: directory)
        }
        try operation()
    }

    private func failReceiptWrites(_ env: AppEnvironment) throws {
        try env.repo.db.execute("CREATE TEMP TRIGGER fail_capture_receipt BEFORE INSERT ON capture_draft_receipt BEGIN SELECT RAISE(ABORT, 'fixture receipt failure'); END;")
    }

    @MainActor func testCommittedMemoAndTaskAreNotRestoredAfterCheckpointCleanupFails() async throws {
        for kind in [CaptureKind.memo, .task] {
            let env = try environment()
            let session = CaptureSessionModel(environment: env)
            session.select(kind)
            let draft = try XCTUnwrap(session.activeDraft)
            draft.text = "한 번만 저장할 기록"
            let other = kind == .memo ? session.taskDraft : session.memoDraft
            other.text = "다른 탭 미저장 초안"
            XCTAssertTrue(session.flushCheckpoints())
            let original = draft.checkpoint(), otherSnapshot = other.checkpoint()
            try withCheckpointFailure(env) {
                XCTAssertTrue(session.submitOrdinary(), "레코드와 receipt가 커밋되면 파일 갱신 실패와 별개로 성공")
                XCTAssertTrue(session.checkpointFailed)
                XCTAssertTrue(session.checkpointMessage?.contains("기록은 저장되었습니다") == true)
                draft.resetWorkDateToToday() // The panel does this after a successful save.
                XCTAssertTrue(session.checkpointMessage?.contains("기록은 저장되었습니다") == true)
                XCTAssertFalse(session.flushCheckpoints())
                XCTAssertTrue(session.checkpointMessage?.contains("기록은 저장되었습니다") == true)
            }
            let storage = CaptureDraftStore(directory: env.options.paths.dataRoot.appendingPathComponent("capture-drafts"))
            XCTAssertEqual(try storage.load(kind == .memo ? .memo : .task), original, "파일에는 제출 전 초안이 그대로 남아 있음")
            XCTAssertEqual(try env.repo.db.scalarInt("SELECT COUNT(*) FROM capture_draft_receipt"), 1)
            let reopenedEnvironment = try AppEnvironment.open(env.options)
            let restored = CaptureSessionModel(environment: reopenedEnvironment)
            restored.select(kind)
            XCTAssertFalse(restored.hasDraft(kind))
            XCTAssertFalse(restored.recoveredKinds.contains(kind))
            XCTAssertFalse(restored.submitOrdinary())
            XCTAssertEqual(kind == .memo ? restored.taskDraft.checkpoint() : restored.memoDraft.checkpoint(), otherSnapshot)
            XCTAssertEqual(try env.repo.memos(on: today).count, kind == .memo ? 1 : 0)
            XCTAssertEqual(try env.repo.tasks().count, kind == .task ? 1 : 0)
            session.detach(); restored.detach()
        }
    }

    @MainActor func testReceiptFailureRollsBackRecordLinksIndexAndCompleteInputForBothTabs() async throws {
        for kind in [CaptureKind.memo, .task] {
            let env = try environment()
            let project = try env.repo.createProject(name: "분류")
            let tag = try env.repo.findOrCreateTag(name: "태그")
            let related = try env.tasks.createTask(title: "연결 업무", workDate: today)
            let session = CaptureSessionModel(environment: env)
            session.select(kind)
            let draft = try XCTUnwrap(session.activeDraft)
            draft.text = "롤백검색 고유본문\n상세"
            draft.workDate = yesterday
            draft.dueOn = today; draft.dueReminderDaysBefore = 1
            draft.addProject(id: project.id); draft.addTag(id: tag.id)
            draft.relatedRecords = [RelatedRecordCandidate(reference: RecordReference(kind: .task, id: related.id), title: related.title)]
            draft.selectionRange = NSRange(location: 2, length: 3)
            let before = draft.checkpoint()
            XCTAssertTrue(session.flushCheckpoints())
            try failReceiptWrites(env)
            XCTAssertFalse(session.submitOrdinary())
            XCTAssertEqual(draft.checkpoint(), before)
            XCTAssertEqual(draft.selectionRange, NSRange(location: 2, length: 3))
            XCTAssertNil(draft.lastSavedId)
            XCTAssertNotNil(draft.errorMessage)
            XCTAssertEqual(draft.kind, kind == .memo ? .memo : .task)
            XCTAssertTrue(try env.repo.memos(on: yesterday).isEmpty)
            XCTAssertEqual(try env.repo.tasks().map(\.id), [related.id])
            XCTAssertEqual(draft.tasks.map(\.id), [related.id], "후보 역시 롤백 뒤 DB에서 다시 읽음")
            XCTAssertTrue(try RecordLinkStore(repo: env.repo).links(for: RecordReference(kind: .task, id: related.id)).isEmpty)
            XCTAssertTrue(try env.search.search(SearchQuery(text: "롤백검색")).isEmpty, "commit 전에 수행된 onSourceChanged 색인도 롤백")
            XCTAssertEqual(try env.repo.db.scalarInt("SELECT COUNT(*) FROM capture_draft_receipt"), 0)
            try env.repo.db.execute("DROP TRIGGER fail_capture_receipt;")
            XCTAssertTrue(session.submitOrdinary())
            XCTAssertEqual(try env.search.search(SearchQuery(text: "롤백검색")).count, 1)
            XCTAssertEqual(try env.repo.db.scalarInt("SELECT COUNT(*) FROM capture_draft_receipt"), 1)
            session.detach()
        }
    }

    @MainActor func testStatusSubmissionRecoversUnusedDraftAndFollowsLaterSubmissionReceipt() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "상태 변경", workDate: yesterday)
        let session = CaptureSessionModel(environment: env)
        session.select(.task)
        let draft = session.taskDraft
        draft.text = "아직 제출하지 않은 새 업무\n본문 유지"
        draft.taskSelection = .existing(task.id); draft.taskAction = .changeStatus
        draft.statusTarget = .inProgress; draft.workDate = yesterday
        draft.dueOn = today; draft.dueReminderDaysBefore = 0
        let original = draft.checkpoint()
        XCTAssertTrue(session.flushCheckpoints())
        try withCheckpointFailure(env) { XCTAssertTrue(session.submitOrdinary()) }
        XCTAssertEqual(try env.tasks.currentStatus(taskId: task.id), .inProgress)
        let afterStatus = draft.checkpoint()
        XCTAssertNotEqual(afterStatus.draftID, original.draftID)
        let restored = CaptureSessionModel(environment: env)
        restored.select(.task)
        XCTAssertEqual(restored.taskDraft.checkpoint(), afterStatus)
        XCTAssertEqual(restored.taskDraft.taskSelection, .newTask)
        XCTAssertEqual(restored.taskDraft.text, original.text)
        XCTAssertEqual(restored.taskDraft.dueOn, original.dueOn)
        XCTAssertTrue(restored.recoveredKinds.contains(.task))
        restored.continueRecoveredDraft()
        // Leave the original pre-status file in place through a second submission.
        try withCheckpointFailure(env) { XCTAssertTrue(restored.submitOrdinary()) }
        let reopened = CaptureSessionModel(environment: env)
        XCTAssertFalse(reopened.hasDraft(.task))
        XCTAssertFalse(reopened.recoveredKinds.contains(.task))
        XCTAssertEqual(try env.repo.tasks().count, 2)
        XCTAssertEqual(try env.repo.events(taskId: task.id).filter { $0.kind == .started }.count, 1)
        XCTAssertEqual(try env.repo.db.scalarInt("SELECT COUNT(*) FROM capture_draft_receipt"), 2)
        session.detach(); restored.detach(); reopened.detach()
    }

    @MainActor func testDirectCompletionConfirmationRollsBackReceiptFailureAndRecoversUnusedText() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "확인 필요", workDate: yesterday, checklist: ["미완료 항목"])
        let session = CaptureSessionModel(environment: env)
        session.select(.task)
        let draft = session.taskDraft
        draft.taskSelection = .existing(task.id); draft.taskAction = .changeStatus
        draft.statusTarget = .completed; draft.workDate = yesterday
        draft.text = "완료와 별개로 보존할 초안"
        XCTAssertTrue(session.flushCheckpoints())
        XCTAssertFalse(session.submitOrdinary())
        let pending = try XCTUnwrap(draft.pendingCompletion), original = draft.checkpoint()
        XCTAssertEqual(try env.repo.db.scalarInt("SELECT COUNT(*) FROM capture_draft_receipt"), 0)
        try failReceiptWrites(env)
        XCTAssertFalse(draft.confirmCompletion())
        XCTAssertEqual(draft.checkpoint(), original)
        XCTAssertEqual(draft.pendingCompletion, pending)
        XCTAssertEqual(try env.tasks.currentStatus(taskId: task.id), .planned)
        XCTAssertEqual(draft.tasks.first?.cachedStatus, .planned)
        XCTAssertTrue(try env.repo.events(taskId: task.id).filter { $0.kind == .completed }.isEmpty)
        try env.repo.db.execute("DROP TRIGGER fail_capture_receipt;")
        try withCheckpointFailure(env) {
            XCTAssertTrue(draft.confirmCompletion(), "CapturePanel에서 session을 거치지 않는 실제 완료 확인 경로")
            XCTAssertTrue(session.checkpointFailed)
            XCTAssertTrue(session.checkpointMessage?.contains("기록은 저장되었습니다") == true)
        }
        XCTAssertEqual(try env.tasks.currentStatus(taskId: task.id), .completed)
        let restored = CaptureSessionModel(environment: env)
        XCTAssertEqual(restored.taskDraft.checkpoint(), draft.checkpoint())
        XCTAssertEqual(restored.taskDraft.text, original.text)
        XCTAssertEqual(restored.taskDraft.taskSelection, .newTask)
        XCTAssertNil(restored.taskDraft.pendingCompletion)
        XCTAssertFalse(restored.taskDraft.confirmCompletion())
        XCTAssertEqual(try env.repo.events(taskId: task.id).filter { $0.kind == .completed }.count, 1)
        session.detach(); restored.detach()
    }

    @MainActor func testActivityReceiptFailureRollsBackAndStaleSubmittedCheckpointCannotRepeat() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "진행 대상", workDate: today)
        let session = CaptureSessionModel(environment: env)
        session.select(.task)
        session.taskDraft.taskSelection = .existing(task.id)
        session.taskDraft.text = "활동고유검색 본문"
        let original = session.taskDraft.checkpoint()
        XCTAssertTrue(session.flushCheckpoints())
        try failReceiptWrites(env)
        XCTAssertFalse(session.submitOrdinary())
        XCTAssertEqual(session.taskDraft.checkpoint(), original)
        XCTAssertEqual(try env.repo.db.scalarInt("SELECT COUNT(*) FROM activity"), 0)
        XCTAssertTrue(try env.search.search(SearchQuery(text: "활동고유검색")).isEmpty)
        try env.repo.db.execute("DROP TRIGGER fail_capture_receipt;")
        try withCheckpointFailure(env) { XCTAssertTrue(session.submitOrdinary()) }
        XCTAssertFalse(CaptureSessionModel(environment: env).hasDraft(.task))
        let staleModel = CaptureModel(environment: env)
        staleModel.kind = .task; staleModel.restore(original)
        XCTAssertFalse(staleModel.submit(), "DB receipt도 중복을 차단하므로 오래 열린 다른 모델도 재제출 불가")
        XCTAssertEqual(staleModel.checkpoint(), original)
        XCTAssertEqual(try env.repo.db.scalarInt("SELECT COUNT(*) FROM activity"), 1)
        session.detach()
    }

    @MainActor func testLegacyCheckpointGetsStableReceiptIdentityEvenWhenUpgradeCannotBeWritten() async throws {
        for kind in [CaptureKind.memo, .task] {
            let env = try environment()
            let session = CaptureSessionModel(environment: env)
            session.select(kind)
            let draft = try XCTUnwrap(session.activeDraft)
            draft.text = "이전 버전 초안"
            var legacy = draft.checkpoint(); legacy.draftID = nil
            let data = try StableJSON.encode(legacy)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("draftID"))
            let storage = CaptureDraftStore(directory: env.options.paths.dataRoot.appendingPathComponent("capture-drafts"))
            let recordKind: RecordCaptureKind = kind == .memo ? .memo : .task
            try storage.save(legacy, kind: recordKind)
            let restored = CaptureSessionModel(environment: env)
            restored.select(kind); restored.continueRecoveredDraft()
            let upgraded = try XCTUnwrap(restored.activeDraft?.checkpoint().draftID)
            XCTAssertTrue(upgraded.hasPrefix("legacy-\(recordKind.rawValue)-"))
            try withCheckpointFailure(env) { XCTAssertTrue(restored.submitOrdinary()) }
            XCTAssertNil(try storage.load(recordKind)?.draftID)
            XCTAssertFalse(CaptureSessionModel(environment: env).hasDraft(kind))
            XCTAssertEqual(try env.repo.db.scalarInt("SELECT COUNT(*) FROM capture_draft_receipt WHERE draft_id=?", [upgraded]), 1)
            session.detach(); restored.detach()
        }
    }

    @MainActor func testCorruptReceiptChainsNeverRestoreSubmittedAction() async throws {
        for corruption in ["cycle", "length", "json", "version"] {
            let env = try environment()
            let session = CaptureSessionModel(environment: env)
            session.memoDraft.text = "복구하면 안 되는 제출 완료 초안"
            session.taskDraft.text = "정상 독립 초안"
            let original = session.memoDraft.checkpoint()
            XCTAssertTrue(session.flushCheckpoints())
            let receipts = CaptureDraftReceipts(repo: env.repo)
            let originalID = try XCTUnwrap(original.draftID)
            switch corruption {
            case "cycle": try receipts.record(originalID, remaining: original)
            case "length":
                var currentID = originalID
                for index in 0..<129 {
                    var next = original; next.draftID = "chain-\(index)"
                    try receipts.record(currentID, remaining: next)
                    currentID = next.draftID!
                }
            case "json":
                try env.repo.db.run("INSERT INTO capture_draft_receipt(draft_id,saved_at,remaining_checkpoint_json) VALUES(?,?,?)",
                                    [originalID, env.options.clock.now(), "invalid-json"])
            default:
                var next = original; next.schemaVersion = 999; next.draftID = "bad-version"
                try receipts.record(originalID, remaining: next)
            }
            let restored = CaptureSessionModel(environment: env)
            XCTAssertTrue(restored.checkpointFailed, corruption)
            XCTAssertFalse(restored.hasDraft(.memo), corruption)
            XCTAssertFalse(restored.submitOrdinary(), corruption)
            XCTAssertEqual(restored.taskDraft.text, "정상 독립 초안")
            XCTAssertTrue(try env.repo.memos(on: today).isEmpty)
            session.detach(); restored.detach()
        }
    }

    @MainActor func testSecretTabDoesNotCreateSubmissionReceipt() async throws {
        let env = try environment()
        let session = CaptureSessionModel(environment: env)
        session.memoDraft.text = "미제출 일반 초안"
        session.select(.secret)
        XCTAssertFalse(session.submitOrdinary())
        XCTAssertEqual(try env.repo.db.scalarInt("SELECT COUNT(*) FROM capture_draft_receipt"), 0)
        XCTAssertTrue(try env.repo.memos(on: today).isEmpty)
        session.detach()
    }
}
