import XCTest
@testable import WorkLogCore

final class TaskEditingWorkflowTests: XCTestCase {
    private let monday = WorkDate("2026-10-26")!
    private let friday = WorkDate("2026-10-23")!
    private let thursday = WorkDate("2026-10-22")!
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func make() throws -> (WorkRepository, TaskService, FixedClock) {
        let clock = FixedClock(SQLDate.parse("2026-10-26T00:00:00Z")!)
        let repo = try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator())
        return (repo, TaskService(repo: repo), clock)
    }

    private func environment(clock: FixedClock) throws -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TaskEdit-\(UUID().uuidString)")
        roots.append(root)
        let paths = AppPaths(dataRoot: root.appendingPathComponent("data"), backupRoot: root.appendingPathComponent("backups"))
        var settings = AppSettings(); settings.aiEnabled = false
        try SettingsStore(fileURL: paths.settingsFile).save(settings)
        return try AppEnvironment.open(AppEnvironmentOptions(paths: paths, keyStore: InMemoryVaultKeyStore(),
            authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(), aiProvider: nil,
            clock: clock, ids: SequentialIDGenerator()))
    }

    func testPropertiesPreserveIdentityHistoryAndRefreshSearch() throws {
        let (repo, service, _) = try make()
        let index = try SearchIndex(repo: repo)
        let task = try service.createTask(title: "잘못된이름", workDate: thursday, dueOn: friday,
            projectNames: ["원래프로젝트"], trackingMode: .perProject, tagNames: ["이전태그"])
        let originalProject = try XCTUnwrap(try repo.taskProjects(taskId: task.id).first)
        try service.changeProjectStatus(taskId: task.id, projectId: originalProject.projectId, kind: .completed, workDate: friday)
        let events = try repo.events(taskId: task.id)
        let other = try repo.createProject(name: "새프로젝트")
        var draft = TaskPropertiesDraft(title: "수정업무이름", dueOn: monday, dueReminderDaysBefore: 2,
            projectIds: [other.id], tagNames: ["수정태그", "수정태그"])
        try service.updateProperties(taskId: task.id, draft: draft)
        let edited = try XCTUnwrap(try repo.task(id: task.id))
        XCTAssertEqual(edited.id, task.id); XCTAssertEqual(edited.createdAt, task.createdAt)
        XCTAssertEqual(edited.title, draft.title); XCTAssertEqual(edited.dueOn, monday)
        XCTAssertEqual(edited.tagIds.count, 1)
        XCTAssertEqual(try repo.events(taskId: task.id), events)
        XCTAssertEqual(try service.currentStatus(taskId: task.id), .planned)
        XCTAssertEqual(try index.search(SearchQuery(text: "수정업무이름", types: [.task])).map(\.sourceId), [task.id])
        XCTAssertTrue(try index.search(SearchQuery(text: "잘못된이름", types: [.task])).isEmpty)
        XCTAssertTrue(try index.search(SearchQuery(text: "원래프로젝트", types: [.task])).isEmpty)
        draft.projectIds.insert(originalProject.projectId); draft.dueOn = nil
        try service.updateProperties(taskId: task.id, draft: draft)
        XCTAssertNil(try repo.task(id: task.id)?.dueOn)
        XCTAssertNil(try repo.task(id: task.id)?.dueReminderDaysBefore)
        let restored = try service.detail(taskId: task.id)
        XCTAssertEqual(restored.projects.first { $0.project.id == originalProject.projectId }?.status, .completed)
        XCTAssertEqual(restored.projects.first { $0.project.id == other.id }?.status, .planned)
    }

    func testPropertyFailureRollsBackTitleTagsLinksAndSearch() throws {
        let (repo, service, _) = try make()
        let index = try SearchIndex(repo: repo)
        let task = try service.createTask(title: "보존업무명", workDate: thursday, tagNames: ["기존태그"])
        let before = try repo.task(id: task.id)
        try repo.db.execute("CREATE TRIGGER fail_task_edit BEFORE INSERT ON task_tag BEGIN SELECT RAISE(ABORT, 'injected edit failure'); END;")
        let draft = TaskPropertiesDraft(title: "실패업무명", dueOn: friday, projectIds: [], tagNames: ["새태그"])
        XCTAssertThrowsError(try service.updateProperties(taskId: task.id, draft: draft))
        XCTAssertEqual(try repo.task(id: task.id), before)
        XCTAssertEqual(try repo.tags().map(\.name), ["기존태그"])
        XCTAssertEqual(try index.search(SearchQuery(text: "보존업무명", types: [.task])).map(\.sourceId), [task.id])
        XCTAssertTrue(try index.search(SearchQuery(text: "실패업무명", types: [.task])).isEmpty)
        var empty = draft; empty.title = "  \n "
        XCTAssertThrowsError(try service.updateProperties(taskId: task.id, draft: empty))
    }

    func testCorrectionPreservesKnownAtOriginalAndCompletionReopenCycles() throws {
        let (repo, service, clock) = try make()
        let task = try service.createTask(title: "이력", initialStatus: .inProgress, workDate: thursday)
        _ = try service.completeTask(taskId: task.id, workDate: friday, confirmRemaining: true)
        let original = try XCTUnwrap(try repo.events(taskId: task.id).last)
        try service.changeTaskStatus(taskId: task.id, kind: .reopened, workDate: monday)
        _ = try service.completeTask(taskId: task.id, workDate: monday, confirmRemaining: true)
        let knownBefore = clock.now()
        clock.advance(by: 60)
        let replacement = try service.correctStatusEvent(taskId: task.id, eventId: original.id,
            workDate: thursday, kind: .completed, note: "날짜 정정")
        XCTAssertNil(replacement.effectiveTime)
        XCTAssertEqual(replacement.recordedAt, clock.now())
        XCTAssertEqual(try service.detail(taskId: task.id, knownAt: knownBefore).completionDates, [friday, monday])
        XCTAssertEqual(try service.detail(taskId: task.id).completionDates, [thursday, monday])
        let all = try repo.events(taskId: task.id)
        XCTAssertTrue(all.contains(original)); XCTAssertEqual(all.filter { $0.kind == .voided }.count, 1)
        XCTAssertEqual(all.filter { $0.kind == .reopened }.count, 1)
        XCTAssertTrue(StateReplay.replay(all, through: nil, knownAt: nil).violations.isEmpty)
    }

    func testCorrectionKeepsSameDayOrderAndRejectsBrokenLaterTransitions() throws {
        let (repo, service, _) = try make()
        let task = try service.createTask(title: "같은날", workDate: friday)
        try service.changeTaskStatus(taskId: task.id, kind: .started, workDate: friday)
        _ = try service.completeTask(taskId: task.id, workDate: friday, confirmRemaining: true)
        let complete = try XCTUnwrap(try repo.events(taskId: task.id).last)
        try service.changeTaskStatus(taskId: task.id, kind: .reopened, workDate: friday)
        let events = try repo.events(taskId: task.id)
        let conflicts = try service.previewStatusCorrection(taskId: task.id, eventId: complete.id, workDate: friday, kind: .paused)
        XCTAssertFalse(conflicts.canSave)
        XCTAssertTrue(conflicts.conflicts.joined().contains("reopened"))
        XCTAssertThrowsError(try service.correctStatusEvent(taskId: task.id, eventId: complete.id, workDate: monday, kind: .completed))
        XCTAssertEqual(try repo.events(taskId: task.id), events)
        let replacement = try service.correctStatusEvent(taskId: task.id, eventId: complete.id, workDate: friday, kind: .completed)
        XCTAssertEqual(replacement.effectiveOrder, complete.effectiveOrder)
        XCTAssertEqual(try service.currentStatus(taskId: task.id), .inProgress)
        XCTAssertThrowsError(try service.correctStatusEvent(taskId: task.id, eventId: complete.id, workDate: friday, kind: .completed))
    }

    func testCorrectionWriteFailureRollsBackInvalidationAndCache() throws {
        let (repo, service, _) = try make()
        let task = try service.createTask(title: "원자정정", workDate: thursday)
        _ = try service.completeTask(taskId: task.id, workDate: friday, confirmRemaining: true)
        let original = try XCTUnwrap(try repo.events(taskId: task.id).last)
        let before = try repo.events(taskId: task.id)
        try repo.db.execute("CREATE TRIGGER fail_replacement BEFORE INSERT ON domain_event WHEN NEW.kind = 'completed' BEGIN SELECT RAISE(ABORT, 'injected correction failure'); END;")
        XCTAssertThrowsError(try service.correctStatusEvent(taskId: task.id, eventId: original.id, workDate: thursday, kind: .completed))
        XCTAssertEqual(try repo.events(taskId: task.id), before)
        XCTAssertEqual(try repo.task(id: task.id)?.cachedStatus, .completed)
        XCTAssertEqual(try service.detail(taskId: task.id).completionDates, [friday])
    }

    func testChecklistEditDeleteUndoAndReorderPreserveCompletionAndSnapshots() throws {
        let (repo, service, clock) = try make()
        let index = try SearchIndex(repo: repo)
        let task = try service.createTask(title: "목록관리", workDate: thursday, projectNames: ["연결프로젝트"])
        let project = try XCTUnwrap(try repo.taskProjects(taskId: task.id).first)
        let first = try service.addChecklistItem(taskId: task.id, text: "옛문구")
        let second = try service.addChecklistItem(taskId: task.id, text: "다음항목")
        try service.setChecklistItem(itemId: first.id, done: true, workDate: friday)
        let events = try repo.events(taskId: task.id)
        let plans = WeekPlanService(repo: repo, periods: Periods())
        let item = try plans.addItem(weekStart: monday, taskId: task.id, scopeType: .checklistItem, scopeId: first.id, label: first.text)
        _ = try plans.confirm(weekStart: monday, itemIds: [item.id])
        let store = ReportStore(repo: repo)
        let range = DateRange(start: thursday, endExclusive: monday)
        let report = try store.ensureReport(family: .submission, periodType: .weekly, periodKey: "fake", range: range)
        let facts = ReportFacts(family: .submission, periodType: .weekly, timezone: "Asia/Seoul", generatedAt: clock.now(),
            range: range, statusCutoff: clock.now(), knownAt: clock.now(), projects: [], tasks: [], sources: [], metrics: ReportMetrics())
        let outcome = try store.saveGenerated(reportId: report.id, facts: facts, draft: GeneratedDraft(content: "확정 옛문구", generator: "deterministic"), mode: .userRequested)
        guard case .created(let version) = outcome else { return XCTFail("draft expected") }
        _ = try store.confirm(versionId: version.id)
        let snapshot = try repo.sourceSnapshot(id: version.sourceSnapshotId)
        let confirmed = try repo.reportVersion(id: version.id)
        try service.editChecklistItem(itemId: first.id, text: "새로운문구", projectIds: [project.projectId])
        XCTAssertEqual(try service.detail(taskId: task.id).checklist.first?.done, true)
        XCTAssertEqual(try index.search(SearchQuery(text: "새로운문구", types: [.task])).map(\.sourceId), [task.id])
        let edited = try XCTUnwrap(try repo.checklistItem(id: first.id))
        try service.reorderChecklist(taskId: task.id, itemIds: [second.id, first.id])
        XCTAssertEqual(try repo.checklistItems(taskId: task.id).map(\.id), [second.id, first.id])
        try service.deleteChecklistItem(itemId: first.id)
        XCTAssertTrue(try index.search(SearchQuery(text: "새로운문구", types: [.task])).isEmpty)
        try service.restoreChecklistItem(edited)
        XCTAssertEqual(try repo.events(taskId: task.id), events)
        XCTAssertEqual(try service.currentStatus(taskId: task.id), .planned)
        XCTAssertEqual(try plans.plan(weekStart: monday)?.items.first?.label, "옛문구")
        clock.advance(by: 60)
        let original = try XCTUnwrap(events.first { $0.scopeType == .checklistItem })
        _ = try service.correctStatusEvent(taskId: task.id, eventId: original.id, workDate: thursday, kind: .completed)
        XCTAssertEqual(try repo.sourceSnapshot(id: version.sourceSnapshotId), snapshot)
        XCTAssertEqual(try repo.reportVersion(id: version.id), confirmed)
        let unrelated = try repo.createProject(name: "무관프로젝트")
        XCTAssertThrowsError(try service.editChecklistItem(itemId: first.id, text: "잘못된범위", projectIds: [unrelated.id]))
        XCTAssertThrowsError(try service.editChecklistItem(itemId: first.id, text: " \n ", projectIds: []))
    }

    func testChecklistReorderAndEditFailureAreAtomic() throws {
        let (repo, service, _) = try make()
        let task = try service.createTask(title: "실패보존", workDate: thursday)
        let first = try service.addChecklistItem(taskId: task.id, text: "첫항목")
        let second = try service.addChecklistItem(taskId: task.id, text: "둘째항목")
        try repo.db.execute("CREATE TRIGGER fail_order BEFORE UPDATE OF sort_order ON checklist_item WHEN OLD.sort_order = 1 BEGIN SELECT RAISE(ABORT, 'injected order failure'); END;")
        XCTAssertThrowsError(try service.reorderChecklist(taskId: task.id, itemIds: [second.id, first.id]))
        XCTAssertEqual(try repo.checklistItems(taskId: task.id), [first, second])
        XCTAssertThrowsError(try service.editChecklistItem(itemId: first.id, text: "실패문구", projectIds: []))
        XCTAssertEqual(try repo.checklistItem(id: first.id), first)
    }

    func testExcludedPlanRestoresEveryScopeAndDeduplicatesDirectAdd() throws {
        let (repo, service, _) = try make()
        let task = try service.createTask(title: "복원", workDate: thursday, projectNames: ["계획프로젝트"], checklist: ["계획체크"])
        let project = try XCTUnwrap(try repo.taskProjects(taskId: task.id).first)
        let checklist = try XCTUnwrap(try repo.checklistItems(taskId: task.id).first)
        let plans = WeekPlanService(repo: repo, periods: Periods())
        let scopes: [(PlanScopeType, String?)] = [(.wholeTask, nil), (.taskProject, TaskProject.scopeId(taskId: task.id, projectId: project.projectId)), (.checklistItem, checklist.id)]
        for (scope, scopeId) in scopes {
            let item = try plans.addItem(weekStart: monday, taskId: task.id, scopeType: scope, scopeId: scopeId, label: "사용자문구")
            _ = try plans.confirm(weekStart: monday, itemIds: [item.id])
            try plans.exclude(itemId: item.id)
            try plans.restore(itemId: item.id)
            let restored = try XCTUnwrap(try plans.plan(weekStart: monday)?.items.first { $0.id == item.id })
            XCTAssertEqual(restored.state, .candidate); XCTAssertEqual(restored.label, "사용자문구")
            XCTAssertNil(restored.confirmedAt); XCTAssertEqual(restored.scopeId, scopeId)
            XCTAssertTrue(try plans.confirmedFacts(weekStart: monday).isEmpty)
            try plans.exclude(itemId: item.id)
            let direct = try plans.addItem(weekStart: monday, taskId: task.id, scopeType: scope, scopeId: scopeId, label: "교체하면안됨")
            XCTAssertEqual(direct.id, item.id); XCTAssertEqual(direct.label, "사용자문구")
        }
        XCTAssertEqual(try plans.plan(weekStart: monday)?.items.count, 3)
        XCTAssertEqual(try repo.events(taskId: task.id).count, 1)
        XCTAssertNil(try service.detail(taskId: task.id).firstStartedOn)
        let id = try XCTUnwrap(try plans.plan(weekStart: monday)?.items.first?.id)
        try plans.exclude(itemId: id)
        try repo.db.execute("CREATE TRIGGER fail_restore BEFORE UPDATE ON week_plan_item BEGIN SELECT RAISE(ABORT, 'injected restore failure'); END;")
        XCTAssertThrowsError(try plans.restore(itemId: id))
        XCTAssertEqual(try plans.plan(weekStart: monday)?.items.first?.state, .excluded)
    }

    @MainActor func testDetailUsesSelectedWorkDateAcrossAllScopesAndKeepsRecordedAt() throws {
        let clock = FixedClock(SQLDate.parse("2026-10-26T00:00:00Z")!)
        let env = try environment(clock: clock)
        let task = try env.tasks.createTask(title: "과거입력", workDate: thursday, projectNames: ["적용"], trackingMode: .perProject, checklist: ["확인"])
        let model = TaskDetailModel(environment: env); model.load(taskId: task.id)
        model.workDate = friday; model.activityText = "지난 금요일 기록"; model.addActivity()
        model.changeStatus(.started)
        let projectId = try XCTUnwrap(model.detail?.projects.first?.project.id)
        model.statusNote = "업무일을 지정한 상태 사유"
        model.changeProjectStatus(projectId: projectId, kind: .completed)
        model.setChecklist(itemId: try XCTUnwrap(model.detail?.checklist.first?.item.id), done: true)
        model.complete()
        let events = try env.repo.events(taskId: task.id).filter { $0.kind != .created }
        XCTAssertTrue(events.allSatisfy { $0.effectiveDate == friday && $0.effectiveTime == nil && $0.recordedAt == clock.now() })
        XCTAssertEqual(model.detail?.activities.first?.workDate, friday)
        XCTAssertEqual(model.detail?.activities.first?.recordedAt, clock.now())
        XCTAssertEqual(model.detail?.completionDates, [friday])
        let day = try env.dayBox.dayBox(for: friday)
        XCTAssertTrue(day.timeline.contains { $0.taskId == task.id && $0.eventKind == .completed && $0.kind == .taskStatus })
        XCTAssertTrue(day.timeline.allSatisfy { $0.effectiveTime == nil && $0.recordedAt == clock.now() })
        let facts = try env.factsBuilder.build(family: .submission, periodType: .weekly,
            range: DateRange(start: friday, endExclusive: monday), knownAt: clock.now())
        XCTAssertTrue(facts.sources.contains { $0.taskId == task.id && $0.workDate == friday && $0.text.contains("지난 금요일") })
        XCTAssertTrue(try env.dayBox.dayBox(for: monday).timeline.isEmpty)
        XCTAssertEqual(model.workDate, friday)
        model.load(taskId: task.id, asOf: friday); model.changeStatus(.reopened)
        XCTAssertEqual(try env.repo.events(taskId: task.id).count, events.count + 1)
    }

    @MainActor func testExecutionFiltersUseKSTDayBoundaryAndPartialChecklistPlan() throws {
        let clock = FixedClock(SQLDate.parse("2026-10-25T15:00:00Z")!) // Monday 00:00 KST
        let env = try environment(clock: clock)
        let due = try env.tasks.createTask(title: "오늘", workDate: friday, dueOn: monday, projectNames: ["교집합"])
        let overdue = try env.tasks.createTask(title: "지연", workDate: friday, dueOn: friday, projectNames: ["교집합"], checklist: ["일부"])
        _ = try env.tasks.createTask(title: "완료", initialStatus: .completed, workDate: friday, dueOn: monday)
        _ = try env.tasks.createTask(title: "취소", initialStatus: .cancelled, workDate: friday, dueOn: monday)
        let hold = try env.tasks.createTask(title: "보류", initialStatus: .onHold, workDate: friday, dueOn: monday)
        let noDue = try env.tasks.createTask(title: "없음", workDate: friday)
        let checklist = try XCTUnwrap(try env.repo.checklistItems(taskId: overdue.id).first)
        let planned = try env.plans.addItem(weekStart: monday, taskId: overdue.id, scopeType: .checklistItem, scopeId: checklist.id, label: "일부")
        _ = try env.plans.confirm(weekStart: monday, itemIds: [planned.id])
        let model = TaskListModel(environment: env); model.load()
        model.executionFilter = .dueToday
        XCTAssertEqual(Set(model.filteredRows.map(\.id)), [due.id, hold.id])
        model.stateFilter = .active; XCTAssertEqual(model.filteredRows.map(\.id), [due.id])
        model.stateFilter = .onHold; XCTAssertEqual(model.filteredRows.map(\.id), [hold.id])
        model.stateFilter = .all; model.executionFilter = .overdue
        XCTAssertEqual(model.filteredRows.filter { $0.projectNames.contains("교집합") }.map(\.id), [overdue.id])
        model.executionFilter = .thisWeek
        XCTAssertEqual(model.filteredRows.map(\.id), [overdue.id])
        XCTAssertTrue(model.filteredRows[0].planScopeSummary?.contains("일부 범위") == true)
        model.executionFilter = .noDueDate; XCTAssertEqual(model.filteredRows.map(\.id), [noDue.id])
        model.clearFilters(); XCTAssertEqual(model.filteredRows.count, 6)
        clock.set(SQLDate.parse("2026-10-25T14:59:59Z")!); model.load(); model.executionFilter = .dueToday
        XCTAssertTrue(model.filteredRows.isEmpty)
        XCTAssertEqual(try env.tasks.currentStatus(taskId: hold.id), .onHold)
    }
    func testDueCandidateRegenerationUsesNewDateAndPreservesConfirmedPlans() throws {
        let (repo, service, _) = try make()
        let plans = WeekPlanService(repo: repo, periods: Periods())
        let task = try service.createTask(title: "이번주에생성", workDate: monday, dueOn: monday)
        let candidates = try plans.generateCandidates(weekStart: monday)
        let candidate = try XCTUnwrap(candidates.first { $0.taskId == task.id })
        XCTAssertEqual(candidate.candidateReason, "이번 주 마감")
        try service.updateProperties(taskId: task.id, draft: TaskPropertiesDraft(title: task.title,
            dueOn: WorkDate("2026-11-02"), projectIds: [], tagNames: []))
        XCTAssertTrue(try plans.generateCandidates(weekStart: monday).isEmpty)
        try service.updateTaskDue(taskId: task.id, dueOn: monday, dueReminderDaysBefore: nil)
        let refreshed = try XCTUnwrap(try plans.generateCandidates(weekStart: monday).first)
        _ = try plans.confirm(weekStart: monday, itemIds: [refreshed.id])
        try service.updateTaskDue(taskId: task.id, dueOn: nil, dueReminderDaysBefore: nil)
        XCTAssertEqual(try plans.generateCandidates(weekStart: monday).first?.state, .confirmed)
        XCTAssertEqual(try plans.plan(weekStart: monday)?.items.first?.id, refreshed.id)
    }

    @MainActor func testEditsAndRestorePersistWhenDatabaseIsReopened() throws {
        let clock = FixedClock(SQLDate.parse("2026-10-26T00:00:00Z")!)
        let env = try environment(clock: clock)
        let task = try env.tasks.createTask(title: "재시작전", workDate: thursday, checklist: ["첫째", "둘째"])
        let items = try env.repo.checklistItems(taskId: task.id)
        try env.tasks.updateProperties(taskId: task.id, draft: TaskPropertiesDraft(title: "재시작후",
            dueOn: monday, projectIds: [], tagNames: ["태그"]))
        try env.tasks.reorderChecklist(taskId: task.id, itemIds: items.reversed().map(\.id))
        let plan = try env.plans.addItem(weekStart: monday, taskId: task.id, scopeType: .wholeTask, scopeId: nil, label: "보존문구")
        try env.plans.exclude(itemId: plan.id); try env.plans.restore(itemId: plan.id)
        let db = try SQLiteDatabase(path: env.options.paths.workDatabase.path)
        let reopened = try WorkRepository(db: db, clock: clock, ids: SequentialIDGenerator(prefix: "reopened"))
        XCTAssertEqual(try reopened.task(id: task.id)?.title, "재시작후")
        XCTAssertEqual(try reopened.task(id: task.id)?.dueOn, monday)
        XCTAssertEqual(try reopened.checklistItems(taskId: task.id).map(\.id), items.reversed().map(\.id))
        let reopenedPlans = WeekPlanService(repo: reopened, periods: Periods())
        XCTAssertEqual(try reopenedPlans.plan(weekStart: monday)?.items.first?.state, .candidate)
        XCTAssertEqual(try reopenedPlans.plan(weekStart: monday)?.items.first?.label, "보존문구")
        XCTAssertEqual(try reopenedPlans.plan(weekStart: monday)?.items.first?.id, plan.id)
    }

    @MainActor func testChecklistUndoAndPropertyDraftFailurePreserveInputs() throws {
        let clock = FixedClock(SQLDate.parse("2026-10-26T00:00:00Z")!)
        let env = try environment(clock: clock)
        let task = try env.tasks.createTask(title: "실패후입력", workDate: thursday, checklist: ["원본"])
        let model = TaskDetailModel(environment: env); model.load(taskId: task.id)
        let item = try XCTUnwrap(model.detail?.checklist.first?.item)
        model.setChecklist(itemId: item.id, done: true)
        let events = try env.repo.events(taskId: task.id)
        model.deleteChecklist(itemId: item.id)
        XCTAssertEqual(model.checklistUndoCount, 1)
        model.undoChecklistEdit()
        XCTAssertEqual(model.detail?.checklist.first?.item.id, item.id)
        XCTAssertEqual(model.detail?.checklist.first?.done, true)
        XCTAssertEqual(try env.repo.events(taskId: task.id), events)
        let draft = TaskPropertiesDraft(title: "", dueOn: monday, projectIds: [], tagNames: [])
        XCTAssertFalse(model.saveProperties(draft)); XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.detail?.task.title, task.title)
        model.activityText = "저장 전 입력"; model.checklistText = "추가 전 입력"
        let original = try XCTUnwrap(try env.repo.events(taskId: task.id).first { $0.scopeType == .checklistItem })
        XCTAssertTrue(model.correctEvent(original, date: friday, kind: .completed, createdStatus: .planned, note: "날짜"))
        XCTAssertEqual(model.activityText, "저장 전 입력"); XCTAssertEqual(model.checklistText, "추가 전 입력")
        XCTAssertTrue(model.noticeMessage?.contains("초안") == true)
    }

}
