import XCTest
@testable import WorkLogCore

/// UXFL-E55A D: 업무·프로젝트 Core 요약·범위.
///
/// - KoreanDateLabel(요일·범위·연도).
/// - 진행 기록의 공통/프로젝트 범위와 라벨, 요약(프로젝트 상태·체크리스트).
/// - 프로젝트 부분 완료가 Task 전체 상태를 바꾸지 않음.
/// - 이번 주 계획 확정 전후 isInThisWeekPlan과 Task 상태·시작일 불변.
/// - 업무 목록 정렬·마감 라벨·프로젝트 이름.
/// - 프로젝트 목록/상세와 선택 유지, 추적 꺼진 연결.
final class TaskProjectUXTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func environment() throws -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskProjectUXTests-\(UUID().uuidString)")
        roots.append(root)
        let paths = AppPaths(dataRoot: root.appendingPathComponent("data"),
                             backupRoot: root.appendingPathComponent("backups"))
        var settings = AppSettings()
        settings.aiEnabled = false
        try SettingsStore(fileURL: paths.settingsFile).save(settings)
        return try AppEnvironment.open(AppEnvironmentOptions(
            paths: paths, keyStore: InMemoryVaultKeyStore(),
            authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(),
            aiProvider: nil,
            clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_000)),
            ids: SequentialIDGenerator()))
    }

    // MARK: - KoreanDateLabel

    func testKoreanDateLabelFormatsWeekdayRangeAndYear() async throws {
        let env = try environment()
        let cal = env.calendar
        let monday = WorkDate(year: 2026, month: 10, day: 5)
        let sunday = WorkDate(year: 2026, month: 10, day: 4)
        XCTAssertEqual(KoreanDateLabel.monthDayWeekday(monday, calendar: cal), "10월 5일(월)")
        XCTAssertEqual(KoreanDateLabel.monthDayWeekday(sunday, calendar: cal), "10월 4일(일)")

        let range = DateRange(start: WorkDate(year: 2026, month: 9, day: 28),
                              endExclusive: WorkDate(year: 2026, month: 10, day: 5))
        XCTAssertEqual(KoreanDateLabel.range(range, calendar: cal), "9월 28일(월) ~ 10월 4일(일)")

        let yearDate = WorkDate(year: 2025, month: 12, day: 29)
        XCTAssertEqual(KoreanDateLabel.monthDayWeekday(yearDate, calendar: cal), "12월 29일(월)")
        XCTAssertEqual(KoreanDateLabel.monthDayWeekday(yearDate, calendar: cal, includeYear: true),
                       "2025년 12월 29일(월)")
    }

    // MARK: - 진행 기록 범위

    @MainActor
    func testActivityScopeCommonAndProject() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "업무", projectNames: ["Gamma"],
                                            trackingMode: .perProject)
        let model = TaskDetailModel(environment: env)
        model.load(taskId: task.id)

        XCTAssertEqual(model.activityScopeOptions.map { $0.label }, ["공통", "Gamma"])
        XCTAssertNil(model.activityScopeOptions.first?.id)

        model.activityText = "공통 기록"
        model.addActivity()
        XCTAssertEqual(model.activityText, "")
        XCTAssertEqual(model.detail?.activities.count, 1)
        XCTAssertEqual(model.detail?.activities.first?.projectIds, [])
        let common = try XCTUnwrap(model.detail?.activities.first)
        XCTAssertEqual(model.activityScopeLabel(common), "공통")

        let projectId = try XCTUnwrap(model.detail?.projects.first?.project.id)
        model.activityProjectId = projectId
        model.activityText = "프로젝트 기록"
        model.addActivity()
        XCTAssertEqual(model.activityText, "")
        XCTAssertEqual(model.detail?.activities.count, 2)
        let last = try XCTUnwrap(model.detail?.activities.last)
        XCTAssertEqual(last.projectIds, [projectId])
        XCTAssertEqual(model.activityScopeLabel(last), "Gamma")
        XCTAssertEqual(model.activityProjectId, projectId, "연속 기록을 위해 범위를 유지한다")
    }

    // MARK: - 프로젝트 상태 요약

    @MainActor
    func testProjectStatusSummaryLeavesOverallStatusUnchanged() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "업무", projectNames: ["Gamma", "Beta"],
                                            trackingMode: .perProject)
        let model = TaskDetailModel(environment: env)
        model.load(taskId: task.id)
        model.changeStatus(.started)
        XCTAssertEqual(model.detail?.status, .inProgress)
        XCTAssertEqual(model.projectStatusSummary, "Beta 예정 · Gamma 예정")

        let gammaId = try XCTUnwrap(model.detail?.projects.first { $0.project.name == "Gamma" }?.project.id)
        model.changeProjectStatus(projectId: gammaId, kind: .completed)
        XCTAssertEqual(model.projectStatusSummary, "Beta 예정 · Gamma 완료")
        XCTAssertEqual(model.detail?.status, .inProgress, "프로젝트 완료는 Task 전체 상태를 바꾸지 않는다")
        XCTAssertEqual(try env.tasks.currentStatus(taskId: task.id), .inProgress)
    }

    // MARK: - 체크리스트 요약

    @MainActor
    func testChecklistSummaryAndAllDoneKeepsTaskOpen() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "업무", checklist: ["a", "b", "c"])
        let model = TaskDetailModel(environment: env)
        model.load(taskId: task.id)
        XCTAssertEqual(model.checklistSummary, "체크리스트 0/3")

        let items = try XCTUnwrap(model.detail?.checklist.map { $0.item.id })
        model.setChecklist(itemId: items[0], done: true)
        model.setChecklist(itemId: items[1], done: true)
        XCTAssertEqual(model.checklistSummary, "체크리스트 2/3")
        XCTAssertEqual(model.detail?.status, .planned)

        model.setChecklist(itemId: items[2], done: true)
        XCTAssertEqual(model.checklistSummary, "체크리스트 3/3")
        XCTAssertEqual(try env.tasks.currentStatus(taskId: task.id), .planned,
                       "체크리스트를 모두 완료해도 Task는 자동 완료되지 않는다")

        model.complete()
        XCTAssertEqual(model.detail?.status, .completed, "전체 완료는 명시 실행으로만")
    }

    @MainActor
    func testCompletionScopeLinesShowRemainingRange() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "업무", projectNames: ["Gamma"],
                                            trackingMode: .perProject,
                                            checklist: ["a", "b", "c", "d"])
        let model = TaskDetailModel(environment: env)
        model.load(taskId: task.id)
        model.complete()
        XCTAssertEqual(model.detail?.status, .planned)
        XCTAssertEqual(model.completionScopeLines,
                       ["남은 체크리스트 4개: a, b, c, 그 외 1개",
                        "적용 상태가 완료되지 않은 프로젝트: Gamma(예정)"])
        model.cancelCompletion()
        XCTAssertTrue(model.completionScopeLines.isEmpty)
    }

    // MARK: - 이번 주 계획

    @MainActor
    func testIsInThisWeekPlanBeforeAndAfterConfirmation() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "업무")
        let model = TaskDetailModel(environment: env)
        model.load(taskId: task.id)
        XCTAssertFalse(model.isInThisWeekPlan)

        let today = env.calendar.workDate(of: env.options.clock.now())
        let weekStart = env.periods.weekStart(containing: today)
        let item = try env.plans.addItem(weekStart: weekStart, taskId: task.id,
                                         scopeType: .wholeTask, scopeId: nil, label: nil)
        model.load(taskId: task.id)
        XCTAssertFalse(model.isInThisWeekPlan, "확정 전 후보는 포함으로 보지 않는다")

        _ = try env.plans.confirm(weekStart: weekStart, itemIds: [item.id])
        model.load(taskId: task.id)
        XCTAssertTrue(model.isInThisWeekPlan)
        XCTAssertEqual(try env.tasks.currentStatus(taskId: task.id), .planned,
                       "계획 확정은 상태를 바꾸지 않는다")
        XCTAssertNil(model.detail?.firstStartedOn, "계획 확정은 시작일을 만들지 않는다")
    }

    // MARK: - 업무 목록

    @MainActor
    func testTaskListSortsAndLabelsDue() async throws {
        let env = try environment()
        let today = env.calendar.workDate(of: env.options.clock.now())
        let overdue = env.calendar.adding(days: -1, to: today)
        let future = env.calendar.adding(days: 2, to: today)
        let a = try env.tasks.createTask(title: "지난 마감", dueOn: overdue)
        let b = try env.tasks.createTask(title: "예정 마감", dueOn: future)
        let c = try env.tasks.createTask(title: "마감 없음")
        let d = try env.tasks.createTask(title: "완료 업무", initialStatus: .completed, dueOn: overdue)

        let model = TaskListModel(environment: env)
        model.load()
        XCTAssertEqual(model.rows.map { $0.id }, [a.id, b.id, c.id, d.id])

        let rowA = try XCTUnwrap(model.rows.first { $0.id == a.id })
        XCTAssertTrue(rowA.isOverdue)
        XCTAssertEqual(rowA.dueLabel,
                       "마감 지남 · " + KoreanDateLabel.monthDayWeekday(overdue, calendar: env.calendar))
        let rowB = try XCTUnwrap(model.rows.first { $0.id == b.id })
        XCTAssertFalse(rowB.isOverdue)
        XCTAssertEqual(rowB.dueLabel,
                       "마감 " + KoreanDateLabel.monthDayWeekday(future, calendar: env.calendar))
        let rowC = try XCTUnwrap(model.rows.first { $0.id == c.id })
        XCTAssertNil(rowC.dueLabel)
        let rowD = try XCTUnwrap(model.rows.first { $0.id == d.id })
        XCTAssertFalse(rowD.isOverdue)
        XCTAssertEqual(rowD.dueLabel,
                       "마감 " + KoreanDateLabel.monthDayWeekday(overdue, calendar: env.calendar))

        model.query = "마감"
        XCTAssertEqual(Set(model.filteredRows.map { $0.id }), Set([a.id, b.id, c.id]))
        model.query = "완료"
        XCTAssertEqual(model.filteredRows.map { $0.id }, [d.id])
        model.query = ""
        XCTAssertEqual(model.filteredRows.count, 4)
    }

    @MainActor
    func testTaskListMarksConfirmedWeekPlanAndProjectNames() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "업무", projectNames: ["Gamma", "Alpha"])
        let today = env.calendar.workDate(of: env.options.clock.now())
        let weekStart = env.periods.weekStart(containing: today)
        let item = try env.plans.addItem(weekStart: weekStart, taskId: task.id,
                                         scopeType: .wholeTask, scopeId: nil, label: nil)
        _ = try env.plans.confirm(weekStart: weekStart, itemIds: [item.id])

        let model = TaskListModel(environment: env)
        model.load()
        let row = try XCTUnwrap(model.rows.first { $0.id == task.id })
        XCTAssertTrue(row.isInThisWeekPlan)
        XCTAssertEqual(row.projectNames, ["Alpha", "Gamma"], "제거되지 않은 연결을 이름순으로")
        XCTAssertEqual(row.status, .planned)
    }

    // MARK: - 프로젝트

    @MainActor
    func testProjectsModelCountsStatusAndKeepsSelection() async throws {
        let env = try environment()
        let tracking = try env.tasks.createTask(title: "추적 업무", projectNames: ["Gamma"],
                                                trackingMode: .perProject)
        let shared = try env.tasks.createTask(title: "공유 업무", projectNames: ["Beta"])

        let model = ProjectsModel(environment: env)
        model.load()
        XCTAssertEqual(model.projects.map { $0.name }, ["Beta", "Gamma"])
        let gamma = try XCTUnwrap(model.projects.first { $0.name == "Gamma" })
        XCTAssertEqual(gamma.totalTaskCount, 1)
        XCTAssertEqual(gamma.openTaskCount, 1)
        XCTAssertEqual(model.projects.first { $0.name == "Beta" }?.totalTaskCount, 1)

        model.select(gamma.id)
        XCTAssertEqual(model.selectedProjectId, gamma.id)
        let gammaRow = try XCTUnwrap(model.tasks.first)
        XCTAssertEqual(gammaRow.id, tracking.id)
        XCTAssertTrue(gammaRow.tracksProjectStatus)
        XCTAssertEqual(gammaRow.projectStatus, .planned)
        XCTAssertEqual(gammaRow.overallStatus, .planned)

        _ = try env.tasks.changeProjectStatus(taskId: tracking.id, projectId: gamma.id, kind: .completed)
        model.load()
        XCTAssertEqual(model.selectedProjectId, gamma.id, "load 후에도 선택을 유지한다")
        let updated = try XCTUnwrap(model.tasks.first)
        XCTAssertEqual(updated.projectStatus, .completed)
        XCTAssertEqual(updated.overallStatus, .planned, "프로젝트만 완료 처리하면 전체 상태는 그대로")
        XCTAssertEqual(model.projects.first { $0.name == "Gamma" }?.openTaskCount, 0)

        model.select(try XCTUnwrap(model.projects.first { $0.name == "Beta" }?.id))
        let betaRow = try XCTUnwrap(model.tasks.first)
        XCTAssertEqual(betaRow.id, shared.id)
        XCTAssertFalse(betaRow.tracksProjectStatus, "추적 꺼진 연결은 프로젝트 기준 상태가 없다")
        XCTAssertNil(betaRow.projectStatus)
        XCTAssertEqual(betaRow.overallStatus, .planned)
    }
}
