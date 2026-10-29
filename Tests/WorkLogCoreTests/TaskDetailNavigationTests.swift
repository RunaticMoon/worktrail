import XCTest
@testable import WorkLogCore

final class TaskDetailNavigationTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func environment() throws -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskDetailNavigationTests-\(UUID().uuidString)")
        roots.append(root)
        let paths = AppPaths(dataRoot: root.appendingPathComponent("data"),
                             backupRoot: root.appendingPathComponent("backups"))
        var settings = AppSettings(); settings.aiEnabled = false
        try SettingsStore(fileURL: paths.settingsFile).save(settings)
        return try AppEnvironment.open(AppEnvironmentOptions(
            paths: paths, keyStore: InMemoryVaultKeyStore(),
            authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(),
            aiProvider: nil, clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_000)),
            ids: SequentialIDGenerator()))
    }

    @MainActor func testRejectedTaskChangeKeepsDraftsAndSavesOnlyToOriginalTask() async throws {
        let env = try environment()
        let a = try env.tasks.createTask(title: "업무 A", projectNames: ["프로젝트 A"])
        let b = try env.tasks.createTask(title: "업무 B")
        let model = TaskDetailModel(environment: env)
        XCTAssertTrue(model.load(taskId: a.id))
        let projectId = try XCTUnwrap(model.detail?.projects.first?.project.id)
        let date = env.calendar.adding(days: -1, to: model.today)
        model.workDate = date; model.activityProjectId = projectId
        model.activityText = " A에만 저장할 진행 기록 \n"
        model.checklistText = "A에만 추가할 체크리스트"
        model.statusNote = "A의 상태 사유"

        XCTAssertFalse(model.load(taskId: b.id))
        XCTAssertFalse(model.load(taskId: "missing-task"))
        XCTAssertEqual(model.detail?.task.id, a.id)
        XCTAssertNil(model.asOf)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.workDate, date)
        XCTAssertEqual(model.activityProjectId, projectId)
        XCTAssertEqual(model.activityText, " A에만 저장할 진행 기록 \n")
        XCTAssertEqual(model.checklistText, "A에만 추가할 체크리스트")
        XCTAssertEqual(model.statusNote, "A의 상태 사유")

        model.addActivity()
        model.addChecklistItem()
        let stored = try env.tasks.detail(taskId: a.id)
        XCTAssertEqual(stored.activities.map(\.body), [" A에만 저장할 진행 기록 \n"])
        XCTAssertEqual(stored.activities.first?.workDate, date)
        XCTAssertEqual(stored.activities.first?.projectIds, [projectId])
        XCTAssertEqual(stored.checklist.map { $0.item.text }, ["A에만 추가할 체크리스트"])
        XCTAssertTrue(try env.tasks.detail(taskId: b.id).activities.isEmpty)
        XCTAssertTrue(try env.tasks.detail(taskId: b.id).checklist.isEmpty)
        XCTAssertEqual(model.statusNote, "A의 상태 사유")
        XCTAssertTrue(model.hasUnsavedInput)
    }

    @MainActor func testEveryInputIncludingWhitespaceBlocksSelectionChanges() async throws {
        let env = try environment()
        let a = try env.tasks.createTask(title: "업무 A")
        let b = try env.tasks.createTask(title: "업무 B")
        let fields: [ReferenceWritableKeyPath<TaskDetailModel, String>] = [
            \.activityText, \.checklistText, \.statusNote
        ]
        for field in fields {
            let model = TaskDetailModel(environment: env)
            XCTAssertTrue(model.load(taskId: a.id))
            XCTAssertFalse(model.hasUnsavedInput)
            model[keyPath: field] = " \n"
            XCTAssertTrue(model.hasUnsavedInput)
            XCTAssertFalse(model.load(taskId: b.id))
            XCTAssertFalse(model.load(taskId: a.id, asOf: model.today))
            XCTAssertEqual(model.detail?.task.id, a.id)
            XCTAssertEqual(model[keyPath: field], " \n")
            XCTAssertNil(model.asOf)
        }
    }

    @MainActor func testDiscardThenSwitchClearsTaskSpecificStateAndUndo() async throws {
        let env = try environment()
        let a = try env.tasks.createTask(title: "업무 A", projectNames: ["프로젝트 A"], checklist: ["원래 항목"])
        let b = try env.tasks.createTask(title: "업무 B")
        let model = TaskDetailModel(environment: env)
        XCTAssertTrue(model.load(taskId: a.id))
        let itemId = try XCTUnwrap(model.detail?.checklist.first?.item.id)
        XCTAssertTrue(model.editChecklist(itemId: itemId, text: "수정된 항목", projectIds: []))
        XCTAssertEqual(model.checklistUndoCount, 1)
        model.complete()
        let completionCheck = try XCTUnwrap(model.completionCheck)
        let statusEvents = model.statusEvents
        let date = env.calendar.adding(days: -1, to: model.today)
        model.workDate = date
        model.activityProjectId = try XCTUnwrap(model.detail?.projects.first?.project.id)
        model.activityText = "진행 초안"; model.checklistText = "항목 초안"; model.statusNote = "상태 초안"

        XCTAssertFalse(model.load(taskId: b.id))
        XCTAssertEqual(model.completionCheck, completionCheck)
        XCTAssertEqual(model.statusEvents, statusEvents)
        XCTAssertEqual(model.checklistUndoCount, 1)
        XCTAssertEqual(model.workDate, date)

        model.discardInput()
        XCTAssertFalse(model.hasUnsavedInput)
        XCTAssertEqual(model.detail?.task.id, a.id, "입력 폐기 자체는 업무를 전환하지 않는다")
        XCTAssertEqual(model.workDate, date)
        XCTAssertTrue(model.load(taskId: b.id))
        XCTAssertEqual(model.detail?.task.id, b.id)
        XCTAssertEqual(model.activityText, "")
        XCTAssertEqual(model.checklistText, "")
        XCTAssertEqual(model.statusNote, "")
        XCTAssertEqual(model.workDate, model.today)
        XCTAssertNil(model.activityProjectId)
        XCTAssertNil(model.completionCheck)
        XCTAssertNil(model.noticeMessage)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.checklistUndoCount, 0)
        XCTAssertTrue(model.statusEvents.allSatisfy { $0.taskId == b.id })
        model.undoChecklistEdit()
        XCTAssertEqual(try env.repo.checklistItem(id: itemId)?.text, "수정된 항목")
    }

    @MainActor func testSameSelectionRefreshKeepsDraftDateScopeAndUndoWhileRefreshingData() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "업무", projectNames: ["프로젝트"], checklist: ["기존 항목"])
        let model = TaskDetailModel(environment: env)
        XCTAssertTrue(model.load(taskId: task.id))
        let itemId = try XCTUnwrap(model.detail?.checklist.first?.item.id)
        XCTAssertTrue(model.editChecklist(itemId: itemId, text: "수정된 항목", projectIds: []))
        let date = env.calendar.adding(days: -1, to: model.today)
        let projectId = try XCTUnwrap(model.detail?.projects.first?.project.id)
        model.workDate = date; model.activityProjectId = projectId
        model.activityText = "편집 중인 진행"; model.checklistText = "편집 중인 항목"; model.statusNote = "상태 사유"
        _ = try env.tasks.addActivity(taskId: task.id, body: "외부에서 추가한 기록")

        XCTAssertTrue(model.load(taskId: task.id))
        XCTAssertEqual(model.detail?.activities.map(\.body), ["외부에서 추가한 기록"])
        XCTAssertEqual(model.activityText, "편집 중인 진행")
        XCTAssertEqual(model.checklistText, "편집 중인 항목")
        XCTAssertEqual(model.statusNote, "상태 사유")
        XCTAssertEqual(model.workDate, date)
        XCTAssertEqual(model.activityProjectId, projectId)
        XCTAssertEqual(model.checklistUndoCount, 1)
        XCTAssertTrue(model.hasUnsavedInput)
    }

    @MainActor func testHistoricalSelectionChangesAreGuardedWithoutLosingAsOfOrDraftContext() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "업무", projectNames: ["프로젝트"])
        let other = try env.tasks.createTask(title: "다른 업무")
        let model = TaskDetailModel(environment: env)
        let asOf = model.today
        XCTAssertTrue(model.load(taskId: task.id, asOf: asOf))
        let date = env.calendar.adding(days: -1, to: asOf)
        let projectId = try XCTUnwrap(model.detail?.projects.first?.project.id)
        let events = model.statusEvents
        model.workDate = date; model.activityProjectId = projectId; model.activityText = "보존할 입력"

        XCTAssertFalse(model.load(taskId: task.id))
        XCTAssertFalse(model.load(taskId: other.id, asOf: date))
        XCTAssertEqual(model.asOf, asOf)
        XCTAssertEqual(model.detail?.task.id, task.id)
        XCTAssertEqual(model.statusEvents, events)
        XCTAssertEqual(model.workDate, date)
        XCTAssertEqual(model.activityProjectId, projectId)
        XCTAssertEqual(model.activityText, "보존할 입력")
        XCTAssertTrue(model.load(taskId: task.id, asOf: asOf), "같은 과거 기준 새로고침은 허용한다")
        model.addActivity()
        XCTAssertEqual(model.activityText, "보존할 입력")
        XCTAssertTrue(try env.repo.activities(taskId: task.id).isEmpty, "과거 기준은 읽기 전용이다")
        model.discardInput()
        XCTAssertTrue(model.load(taskId: task.id))
        XCTAssertNil(model.asOf)
        XCTAssertEqual(model.workDate, date)
        XCTAssertEqual(model.activityProjectId, projectId)
    }

    @MainActor func testSavingOneFieldKeepsOtherDraftsAndExistingStatusNoteBehavior() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "업무")
        let model = TaskDetailModel(environment: env)
        XCTAssertTrue(model.load(taskId: task.id))
        model.activityText = "진행 기록"; model.checklistText = "체크리스트"; model.statusNote = "시작 사유"
        model.addActivity()
        XCTAssertEqual(model.activityText, "")
        XCTAssertEqual(model.checklistText, "체크리스트")
        XCTAssertEqual(model.statusNote, "시작 사유")
        XCTAssertTrue(model.hasUnsavedInput)

        model.activityText = "다음 진행 초안"
        model.addChecklistItem()
        XCTAssertEqual(model.activityText, "다음 진행 초안")
        XCTAssertEqual(model.checklistText, "")
        XCTAssertEqual(model.statusNote, "시작 사유")
        model.changeStatus(.started)
        XCTAssertEqual(model.detail?.status, .inProgress)
        XCTAssertEqual(model.statusNote, "시작 사유", "상태 저장 후 사유를 유지하는 기존 동작을 보존한다")
        XCTAssertEqual(model.activityText, "다음 진행 초안")
        XCTAssertEqual(try env.repo.events(taskId: task.id).first { $0.kind == .started }?.note, "시작 사유")
    }

    @MainActor func testFailedSaveKeepsDraftAndBlocksSwitch() async throws {
        let env = try environment()
        let a = try env.tasks.createTask(title: "업무 A")
        let b = try env.tasks.createTask(title: "업무 B")
        let model = TaskDetailModel(environment: env)
        XCTAssertTrue(model.load(taskId: a.id))
        model.checklistText = " \n"
        model.addChecklistItem()
        XCTAssertNotNil(model.errorMessage)
        let error = model.errorMessage
        XCTAssertTrue(model.hasUnsavedInput)
        XCTAssertFalse(model.load(taskId: b.id))
        XCTAssertEqual(model.errorMessage, error)
        XCTAssertEqual(model.checklistText, " \n")
        XCTAssertEqual(model.detail?.task.id, a.id)
        XCTAssertTrue(try env.repo.checklistItems(taskId: a.id).isEmpty)
    }

    @MainActor func testSavedStatusNotesRemainVisibleButAllowHistoricalNavigation() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "업무", projectNames: ["프로젝트"], trackingMode: .perProject)
        let model = TaskDetailModel(environment: env)
        XCTAssertTrue(model.load(taskId: task.id))
        let projectId = try XCTUnwrap(model.detail?.projects.first?.project.id)
        let statusChanges: [(String, () -> Void)] = [
            ("업무 시작 사유", { model.changeStatus(.started) }),
            ("프로젝트 완료 사유", { model.changeProjectStatus(projectId: projectId, kind: .completed) }),
            ("업무 완료 사유", { model.complete() })
        ]
        for (note, save) in statusChanges {
            model.statusNote = note
            XCTAssertTrue(model.hasUnsavedInput)
            save()
            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(model.statusNote, note)
            XCTAssertFalse(model.hasUnsavedInput, "저장된 사유를 보여 주는 것만으로 이동을 막지 않는다")
            XCTAssertTrue(model.load(taskId: task.id), "동일 업무 새로고침은 저장 기준을 유지한다")
            XCTAssertFalse(model.hasUnsavedInput)
            let events = try env.repo.events(taskId: task.id)
            XCTAssertTrue(events.contains { $0.note == note })
            XCTAssertTrue(model.load(taskId: task.id, asOf: model.today))
            model.changeStatus(.reopened)
            XCTAssertEqual(try env.repo.events(taskId: task.id), events, "과거 화면 전환 후에는 상태를 쓰지 않는다")
            XCTAssertTrue(model.load(taskId: task.id))
        }
    }

    @MainActor func testEditingSavedNoteBlocksNavigationAndDiscardResetsItsBaseline() async throws {
        let env = try environment()
        let a = try env.tasks.createTask(title: "업무 A")
        let b = try env.tasks.createTask(title: "업무 B")
        let model = TaskDetailModel(environment: env)
        XCTAssertTrue(model.load(taskId: a.id))
        model.statusNote = "저장된 사유"
        model.changeStatus(.started)
        XCTAssertFalse(model.hasUnsavedInput)

        model.statusNote = "새 상태 사유"
        XCTAssertTrue(model.load(taskId: a.id))
        XCTAssertTrue(model.hasUnsavedInput, "새로고침이 실제 편집을 저장된 것으로 취급하면 안 된다")
        XCTAssertFalse(model.load(taskId: b.id))
        XCTAssertFalse(model.load(taskId: a.id, asOf: model.today))
        XCTAssertEqual(model.statusNote, "새 상태 사유")
        model.statusNote = "저장된 사유"
        XCTAssertFalse(model.hasUnsavedInput)
        model.statusNote = ""
        XCTAssertTrue(model.hasUnsavedInput, "저장 후 사유를 지우는 편집도 보호한다")
        XCTAssertFalse(model.load(taskId: b.id))

        model.discardInput()
        XCTAssertFalse(model.hasUnsavedInput)
        XCTAssertTrue(model.load(taskId: b.id))
        model.statusNote = "저장된 사유"
        XCTAssertTrue(model.hasUnsavedInput, "이전 업무의 저장 기준이 새 업무로 넘어가면 안 된다")
        XCTAssertFalse(model.load(taskId: a.id))
    }

    @MainActor func testFailedStatusWritesDoNotAcceptTheEditedNote() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "업무", projectNames: ["프로젝트"], trackingMode: .perProject)
        let other = try env.tasks.createTask(title: "다른 업무")
        let model = TaskDetailModel(environment: env)
        XCTAssertTrue(model.load(taskId: task.id))
        model.statusNote = "저장된 시작 사유"; model.changeStatus(.started)
        XCTAssertFalse(model.hasUnsavedInput)
        let projectId = try XCTUnwrap(model.detail?.projects.first?.project.id)
        let before = try env.repo.events(taskId: task.id)
        try env.repo.db.execute("CREATE TRIGGER fail_navigation_status BEFORE INSERT ON domain_event BEGIN SELECT RAISE(ABORT, 'fixture status save failure'); END;")
        defer { try? env.repo.db.execute("DROP TRIGGER fail_navigation_status") }
        let failedSaves: [() -> Void] = [
            { model.changeStatus(.paused) },
            { model.changeProjectStatus(projectId: projectId, kind: .completed) },
            { model.complete(confirmRemaining: true) }
        ]
        for save in failedSaves {
            model.statusNote = "저장하지 못한 사유"
            save()
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(model.statusNote, "저장하지 못한 사유")
            XCTAssertTrue(model.hasUnsavedInput)
            XCTAssertFalse(model.load(taskId: other.id))
            XCTAssertEqual(try env.repo.events(taskId: task.id), before)
            model.statusNote = "저장된 시작 사유"
            XCTAssertFalse(model.hasUnsavedInput, "실패는 마지막 성공 시점의 저장 기준을 바꾸지 않는다")
        }
    }

    @MainActor func testPendingOrCancelledCompletionKeepsNoteDirtyUntilSaved() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "업무", checklist: ["남은 항목"])
        let other = try env.tasks.createTask(title: "다른 업무")
        let model = TaskDetailModel(environment: env)
        XCTAssertTrue(model.load(taskId: task.id))
        model.statusNote = "완료 사유"
        model.complete()
        XCTAssertNotNil(model.completionCheck)
        XCTAssertTrue(model.hasUnsavedInput)
        XCTAssertFalse(model.load(taskId: other.id))
        model.cancelCompletion()
        XCTAssertTrue(model.hasUnsavedInput)
        XCTAssertEqual(model.statusNote, "완료 사유")
        model.complete(confirmRemaining: true)
        XCTAssertEqual(model.detail?.status, .completed)
        XCTAssertEqual(model.statusNote, "완료 사유")
        XCTAssertFalse(model.hasUnsavedInput)
        XCTAssertTrue(model.load(taskId: other.id))
        XCTAssertEqual(model.statusNote, "")
        XCTAssertFalse(model.hasUnsavedInput)
    }

    @MainActor func testAcceptedLoadFailureDoesNotRetainPreviousTaskOrWriteToIt() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "기존 업무", projectNames: ["프로젝트"], checklist: ["원래 항목"])
        let model = TaskDetailModel(environment: env)
        XCTAssertTrue(model.load(taskId: task.id))
        let itemId = try XCTUnwrap(model.detail?.checklist.first?.item.id)
        XCTAssertTrue(model.editChecklist(itemId: itemId, text: "수정된 항목", projectIds: []))
        model.activityProjectId = try XCTUnwrap(model.detail?.projects.first?.project.id)
        model.workDate = env.calendar.adding(days: -1, to: model.today)

        XCTAssertTrue(model.load(taskId: "missing-task"), "로드 실패도 입력 때문에 거절된 선택과 구분한다")
        XCTAssertNil(model.detail)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.statusEvents.isEmpty)
        XCTAssertNil(model.activityProjectId)
        XCTAssertEqual(model.workDate, model.today)
        XCTAssertEqual(model.checklistUndoCount, 0)
        model.activityText = "존재하지 않는 업무에는 저장하지 않음"
        model.addActivity()
        XCTAssertEqual(model.activityText, "존재하지 않는 업무에는 저장하지 않음")
        XCTAssertTrue(model.hasUnsavedInput)
        XCTAssertTrue(try env.repo.activities(taskId: task.id).isEmpty)
        XCTAssertFalse(model.load(taskId: task.id))
        model.discardInput()
        XCTAssertTrue(model.load(taskId: task.id))
        XCTAssertEqual(model.detail?.task.id, task.id)
        XCTAssertNil(model.errorMessage)
    }
}
