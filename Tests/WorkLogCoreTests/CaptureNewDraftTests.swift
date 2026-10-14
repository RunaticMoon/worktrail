import XCTest
@testable import WorkLogCore

final class CaptureNewDraftTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func environment(defaultKind: CaptureKind = .memo,
                             clock: FixedClock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))) throws -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureNewDraftTests-\(UUID().uuidString)")
        roots.append(root)
        let paths = AppPaths(dataRoot: root.appendingPathComponent("data"),
                             backupRoot: root.appendingPathComponent("backups"))
        var settings = AppSettings()
        settings.aiEnabled = false
        settings.defaultCaptureKind = defaultKind
        try SettingsStore(fileURL: paths.settingsFile).save(settings)
        return try AppEnvironment.open(AppEnvironmentOptions(
            paths: paths, keyStore: InMemoryVaultKeyStore(),
            authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(),
            aiProvider: nil, clock: clock, ids: SequentialIDGenerator()))
    }

    @MainActor
    func testNewMemoClearsContentLinksErrorsAndSavedIdentityWithoutWritingRecords() async throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let env = try environment(clock: clock)
        let project = try env.repo.createProject(name: "연결 프로젝트")
        let tag = try env.repo.findOrCreateTag(name: "연결 태그")
        let draft = CaptureModel(environment: env)
        draft.text = "이미 저장한 메모"
        XCTAssertTrue(draft.submit())
        let savedId = try XCTUnwrap(draft.lastSavedId)
        let savedDate = draft.workDate
        XCTAssertFalse(draft.submit(), "빈 본문 저장 오류도 새 초안에서 지워져야 한다")
        XCTAssertNotNil(draft.errorMessage)
        draft.text = "작성하다 남긴 메모"
        draft.selectionRange = NSRange(location: 2, length: 3)
        draft.addProject(id: project.id)
        draft.addTag(id: tag.id)
        draft.relatedRecords = try draft.searchRelated("이미 저장한 메모")
        XCTAssertEqual(draft.relatedRecords.count, 1)
        draft.workDate = env.calendar.adding(days: -3, to: savedDate)
        clock.advance(by: 86_400)

        XCTAssertTrue(draft.startNewDraft())

        XCTAssertEqual(draft.kind, .memo)
        XCTAssertTrue(draft.text.isEmpty)
        XCTAssertNil(draft.selectionRange)
        XCTAssertTrue(draft.selectedProjectIds.isEmpty)
        XCTAssertTrue(draft.selectedTagIds.isEmpty)
        XCTAssertTrue(draft.relatedRecords.isEmpty)
        XCTAssertNil(draft.errorMessage)
        XCTAssertNil(draft.lastSavedId)
        XCTAssertEqual(draft.workDate, env.calendar.workDate(of: clock.now()))
        XCTAssertEqual(try env.repo.memo(id: savedId)?.body, "이미 저장한 메모")
        XCTAssertEqual(try env.repo.memos(on: savedDate).map(\.id), [savedId])
        XCTAssertTrue(try env.repo.memos(on: draft.workDate).isEmpty)
        XCTAssertTrue(try env.repo.tasks().isEmpty)
        XCTAssertTrue(try RecordLinkStore(repo: env.repo).allLinks().isEmpty)
        XCTAssertEqual(try env.repo.projects().map(\.id), [project.id])
        XCTAssertEqual(try env.repo.tags().map(\.id), [tag.id])
    }

    @MainActor
    func testNewTaskClearsSearchTargetActionAndConfigurationBeforeNextSave() async throws {
        let env = try environment(defaultKind: .memo)
        let task = try env.tasks.createTask(title: "기존 대상 업무")
        let project = try env.repo.createProject(name: "이전 프로젝트")
        let tag = try env.repo.findOrCreateTag(name: "이전 태그")
        let draft = CaptureModel(environment: env)
        draft.kind = .task
        draft.addProject(id: project.id)
        draft.addTag(id: tag.id)
        draft.text = "이전 본문"
        draft.taskQuery = "기존 대상 업무"
        draft.taskSelection = .existing(task.id)
        draft.targetTaskId = task.id
        draft.taskAction = .changeStatus
        draft.statusTarget = .inProgress
        draft.initialStatus = .completed
        draft.projectTrackingMode = .perProject
        draft.relatedRecords = [RelatedRecordCandidate(
            reference: RecordReference(kind: .task, id: task.id), title: task.title)]
        let eventIds = try env.repo.events(taskId: task.id).map(\.id)

        XCTAssertTrue(draft.startNewDraft())

        XCTAssertEqual(draft.kind, .task, "설정 기본값이 메모여도 현재 업무 유형을 유지한다")
        XCTAssertTrue(draft.text.isEmpty)
        XCTAssertTrue(draft.taskQuery.isEmpty)
        XCTAssertEqual(draft.taskSelection, .newTask)
        XCTAssertNil(draft.targetTaskId)
        XCTAssertEqual(draft.taskAction, .addActivity)
        XCTAssertNil(draft.statusTarget)
        XCTAssertNil(draft.pendingCompletion)
        XCTAssertEqual(draft.initialStatus, .planned)
        XCTAssertEqual(draft.projectTrackingMode, .shared)
        XCTAssertTrue(draft.selectedProjectIds.isEmpty)
        XCTAssertTrue(draft.selectedTagIds.isEmpty)
        XCTAssertTrue(draft.relatedRecords.isEmpty)
        XCTAssertEqual(try env.repo.tasks().map(\.id), [task.id])
        XCTAssertEqual(try env.repo.events(taskId: task.id).map(\.id), eventIds)

        draft.text = "새 업무"
        XCTAssertTrue(draft.submit())
        let newTask = try XCTUnwrap(env.repo.task(id: XCTUnwrap(draft.lastSavedId)))
        XCTAssertNotEqual(newTask.id, task.id)
        XCTAssertEqual(newTask.title, "새 업무")
        XCTAssertEqual(newTask.cachedStatus, .planned)
        XCTAssertTrue(try env.repo.taskProjects(taskId: newTask.id).isEmpty)
        XCTAssertTrue(try RecordLinkStore(repo: env.repo).allLinks().isEmpty)
        XCTAssertEqual(try env.tasks.currentStatus(taskId: task.id), .planned)
    }

    @MainActor
    func testSessionResetsOnlyActiveDraftAndKeepsReopenBehaviorForEveryDefault() async throws {
        for defaultKind in CaptureKind.allCases {
            let env = try environment(defaultKind: defaultKind)
            let session = CaptureSessionModel(environment: env)
            session.beginSession()
            let memo = session.memoDraft
            let task = session.taskDraft
            memo.text = "메모 초안"
            task.text = "업무 초안"
            task.taskQuery = "남길 검색어"
            task.initialStatus = .inProgress
            let taskDate = env.calendar.adding(days: -1, to: task.workDate)
            task.workDate = taskDate
            session.select(.memo)

            XCTAssertTrue(session.startNewOrdinaryDraft())

            XCTAssertTrue(session.memoDraft === memo)
            XCTAssertTrue(session.taskDraft === task)
            XCTAssertEqual(session.tab, .memo)
            XCTAssertEqual(session.memoDraft.kind, .memo)
            XCTAssertEqual(session.taskDraft.kind, .task)
            XCTAssertFalse(session.hasDraft(.memo))
            XCTAssertTrue(session.hasDraft(.task))
            XCTAssertEqual(task.text, "업무 초안")
            XCTAssertEqual(task.taskQuery, "남길 검색어")
            XCTAssertEqual(task.initialStatus, .inProgress)
            XCTAssertEqual(task.workDate, taskDate)
            XCTAssertEqual(env.settings.defaultCaptureKind, defaultKind)
            XCTAssertTrue(try env.repo.tasks().isEmpty)
            XCTAssertTrue(try env.repo.memos(on: memo.workDate).isEmpty)

            session.beginSession()
            XCTAssertEqual(session.tab, defaultKind)
            XCTAssertEqual(task.text, "업무 초안", "새 메모를 시작해도 다른 탭 초안은 재열기 후 보존한다")
            session.select(.task)
            XCTAssertTrue(session.startNewOrdinaryDraft())
            XCTAssertEqual(session.tab, .task)
            XCTAssertEqual(task.kind, .task)
            XCTAssertFalse(session.hasDraft(.task))
        }
    }

    @MainActor
    func testSecretTabNewOrdinaryDraftIsNoOp() async throws {
        let env = try environment()
        let session = CaptureSessionModel(environment: env)
        session.memoDraft.text = "남길 메모"
        session.taskDraft.text = "남길 업무"
        session.select(.secret)

        XCTAssertFalse(session.startNewOrdinaryDraft())

        XCTAssertEqual(session.tab, .secret)
        XCTAssertEqual(session.memoDraft.text, "남길 메모")
        XCTAssertEqual(session.taskDraft.text, "남길 업무")
        XCTAssertTrue(try env.repo.tasks().isEmpty)
        XCTAssertTrue(try env.repo.memos(on: session.memoDraft.workDate).isEmpty)
    }

    @MainActor
    func testPendingCompletionMustBeCancelledBeforeStartingNewDraft() async throws {
        let env = try environment(defaultKind: .task)
        let task = try env.tasks.createTask(title: "완료 확인 업무", checklist: ["남은 항목"])
        let session = CaptureSessionModel(environment: env)
        let draft = session.taskDraft
        draft.taskSelection = .existing(task.id)
        draft.taskAction = .changeStatus
        draft.statusTarget = .completed
        draft.text = "완료 확인 중 보존할 내용"
        XCTAssertFalse(session.submitOrdinary())
        XCTAssertEqual(draft.pendingCompletion?.remainingChecklist.count, 1)
        let eventIds = try env.repo.events(taskId: task.id).map(\.id)

        XCTAssertFalse(draft.startNewDraft())
        XCTAssertFalse(session.startNewOrdinaryDraft())

        XCTAssertEqual(draft.text, "완료 확인 중 보존할 내용")
        XCTAssertEqual(draft.taskSelection, .existing(task.id))
        XCTAssertEqual(draft.taskAction, .changeStatus)
        XCTAssertEqual(draft.statusTarget, .completed)
        XCTAssertEqual(draft.pendingCompletion?.remainingChecklist.count, 1)
        XCTAssertEqual(try env.repo.events(taskId: task.id).map(\.id), eventIds)
        draft.cancelCompletion()
        XCTAssertTrue(session.startNewOrdinaryDraft())
        XCTAssertFalse(draft.confirmCompletion(), "새 초안이 이전 업무의 완료 확인을 실행하지 않는다")
        XCTAssertEqual(try env.tasks.currentStatus(taskId: task.id), .planned)
    }

    @MainActor
    func testDetachedDraftAndSessionDoNotDiscardContent() async throws {
        let env = try environment()
        let session = CaptureSessionModel(environment: env)
        session.memoDraft.text = "연결 해제 후 남길 내용"
        let oldDate = env.calendar.adding(days: -1, to: session.memoDraft.workDate)
        session.memoDraft.workDate = oldDate
        session.detach()

        XCTAssertFalse(session.memoDraft.startNewDraft())
        XCTAssertFalse(session.startNewOrdinaryDraft())

        XCTAssertEqual(session.memoDraft.text, "연결 해제 후 남길 내용")
        XCTAssertEqual(session.memoDraft.workDate, oldDate)
    }

    @MainActor
    func testProjectTagRelatedRecordAndTaskQueryAloneCountAsDrafts() async throws {
        let env = try environment()
        let project = try env.repo.createProject(name: "본문 없이 선택한 프로젝트")
        let tag = try env.repo.findOrCreateTag(name: "본문 없이 선택한 태그")
        let session = CaptureSessionModel(environment: env)
        for kind in [CaptureKind.memo, .task] {
            session.select(kind)
            let draft = try XCTUnwrap(session.activeDraft)
            draft.addProject(id: project.id)
            XCTAssertTrue(session.hasDraft(kind))
            session.beginSession()
            XCTAssertEqual(draft.selectedProjectIds, [project.id])
            session.select(kind)
            XCTAssertTrue(session.startNewOrdinaryDraft())
            XCTAssertFalse(session.hasDraft(kind))

            draft.addTag(id: tag.id)
            XCTAssertTrue(session.hasDraft(kind))
            XCTAssertTrue(session.startNewOrdinaryDraft())
            draft.relatedRecords = [RelatedRecordCandidate(
                reference: RecordReference(kind: .memo, id: "related-memo"), title: "관련 기록")]
            XCTAssertTrue(session.hasDraft(kind))
            XCTAssertTrue(session.startNewOrdinaryDraft())
            XCTAssertFalse(session.hasDraft(kind))
        }
        session.taskDraft.taskQuery = "검색어로 입력한 새 업무명"
        XCTAssertTrue(session.hasDraft(.task))
        session.beginSession()
        XCTAssertEqual(session.taskDraft.taskQuery, "검색어로 입력한 새 업무명")
        session.taskDraft.taskQuery = " \n "
        XCTAssertFalse(session.hasDraft(.task))
    }

    @MainActor
    func testTaskConfigurationAloneCountsAsDraftButClockRolloverDoesNot() async throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let env = try environment(defaultKind: .task, clock: clock)
        let session = CaptureSessionModel(environment: env)
        let draft = session.taskDraft
        let changes: [(CaptureModel) -> Void] = [
            { $0.initialStatus = .completed },
            { $0.projectTrackingMode = .perProject },
            { $0.taskAction = .changeStatus },
            { $0.statusTarget = .inProgress },
            { $0.taskSelection = .existing("selected-task") },
            { $0.targetTaskId = "activity-task" }
        ]
        for change in changes {
            change(draft)
            XCTAssertTrue(session.hasDraft(.task))
            XCTAssertTrue(session.startNewOrdinaryDraft())
            XCTAssertFalse(session.hasDraft(.task))
        }
        clock.advance(by: 86_400)
        XCTAssertFalse(session.hasDraft(.memo))
        XCTAssertFalse(session.hasDraft(.task), "날짜 경과만으로 빈 초안이 작성 중이 되지 않는다")
        XCTAssertTrue(session.startNewOrdinaryDraft())
        XCTAssertEqual(draft.workDate, env.calendar.workDate(of: clock.now()))
    }

    @MainActor
    func testSavedTaskDoesNotLeaveSearchQueryAsAnUnsavedDraft() async throws {
        let env = try environment(defaultKind: .task)
        let session = CaptureSessionModel(environment: env)
        session.taskDraft.taskQuery = "검색창에서 입력한 업무명"
        session.taskDraft.text = session.taskDraft.taskQuery

        XCTAssertTrue(session.submitOrdinary())

        XCTAssertTrue(session.taskDraft.taskQuery.isEmpty)
        XCTAssertFalse(session.hasDraft(.task))
        session.markSessionCompleted()
        session.beginSession()
        XCTAssertFalse(session.hasDraft(.task))
    }

    @MainActor
    func testStatusSaveClearsSearchContextButKeepsUnsubmittedBodyAsDraft() async throws {
        for requiresConfirmation in [false, true] {
            for body in ["", "상태 변경과 별도로 남길 본문"] {
                let env = try environment(defaultKind: .task)
                let task = try env.tasks.createTask(title: "상태 변경 업무",
                    checklist: requiresConfirmation ? ["남은 항목"] : [])
                let session = CaptureSessionModel(environment: env)
                let draft = session.taskDraft
                draft.taskQuery = task.title
                draft.taskSelection = .existing(task.id)
                draft.taskAction = .changeStatus
                draft.statusTarget = .completed
                draft.text = body

                XCTAssertEqual(session.submitOrdinary(), !requiresConfirmation)
                if requiresConfirmation { XCTAssertTrue(draft.confirmCompletion()) }

                XCTAssertTrue(draft.taskQuery.isEmpty)
                XCTAssertEqual(draft.taskAction, .addActivity)
                XCTAssertEqual(draft.text, body)
                XCTAssertEqual(session.hasDraft(.task), !body.isEmpty)
                XCTAssertEqual(try env.tasks.currentStatus(taskId: task.id), .completed)
            }
        }
    }
}
