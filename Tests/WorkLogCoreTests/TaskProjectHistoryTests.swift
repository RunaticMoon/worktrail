import XCTest
@testable import WorkLogCore

/// Task–Project 연결 이력(구간)이 편집·과거 조회·보고·데이박스에서 동일하게
/// `linkedOn <= date < removedOn` 규칙으로 동작하는지 검증한다.
final class TaskProjectHistoryTests: XCTestCase {
    private let periods = Periods()
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    // MARK: - Helpers

    /// 03:00Z = 12:00 KST. 업무일 계산이 의도한 날짜가 되도록 정오를 쓴다.
    private func instant(_ iso: String) -> Date {
        SQLDate.parse("\(iso)T03:00:00Z")!
    }

    private func make(now: String = "2026-10-22") throws -> (WorkRepository, TaskService, FixedClock) {
        let clock = FixedClock(instant(now))
        let repo = try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator())
        return (repo, TaskService(repo: repo), clock)
    }

    private func move(_ clock: FixedClock, to iso: String) {
        clock.set(instant(iso))
    }

    private func editProjects(_ service: TaskService, taskId: String, title: String,
                              projectIds: Set<String>) throws {
        try service.updateProperties(taskId: taskId, draft: TaskPropertiesDraft(
            title: title, dueOn: nil, projectIds: projectIds, tagNames: []))
    }

    private func detailProjectIds(_ detail: TaskDetail) -> Set<String> {
        Set(detail.projects.map(\.project.id))
    }

    private func factsTask(repo: WorkRepository, taskId: String, on date: WorkDate,
                           knownAt: Date) throws -> FactTask {
        let builder = ReportFactsBuilder(repo: repo, periods: periods,
                                         planService: WeekPlanService(repo: repo, periods: periods))
        let facts = try builder.build(family: .performance, periodType: .daily,
                                      range: periods.range(.daily, containing: date), knownAt: knownAt)
        return try XCTUnwrap(facts.tasks.first { $0.id == taskId })
    }

    private func dayBoxProjectIds(repo: WorkRepository, taskId: String, on date: WorkDate) throws -> [String] {
        let box = try DayBoxService(repo: repo).dayBox(for: date)
        return try XCTUnwrap(box.tasks.first { $0.taskId == taskId }).projectIds
    }

    private func makeReportService(repo: WorkRepository) -> ReportService {
        let builder = ReportFactsBuilder(repo: repo, periods: periods,
                                         planService: WeekPlanService(repo: repo, periods: periods))
        return ReportService(repo: repo, periods: periods, factsBuilder: builder,
                             store: ReportStore(repo: repo), templates: TemplateStore(repo: repo),
                             runner: nil, evaluationPeriods: EvaluationPeriodService(repo: repo))
    }

    /// 10-22에 P로 연결하고 10-23 해제, 10-26 재연결, 10-28 해제하는 기본 이력.
    @discardableResult
    private func runStandardLinkCycle(_ repo: WorkRepository, _ service: TaskService,
                                      _ clock: FixedClock, title: String)
        throws -> (task: WorkTask, projectId: String, linkId: String) {
        let task = try service.createTask(title: title, initialStatus: .inProgress,
                                          workDate: WorkDate("2026-10-22")!,
                                          projectNames: ["이력프로젝트"], trackingMode: .perProject)
        let link = try XCTUnwrap(try repo.taskProjects(taskId: task.id).first)
        move(clock, to: "2026-10-23")
        try editProjects(service, taskId: task.id, title: title, projectIds: [])
        move(clock, to: "2026-10-26")
        try editProjects(service, taskId: task.id, title: title, projectIds: [link.projectId])
        move(clock, to: "2026-10-28")
        try editProjects(service, taskId: task.id, title: title, projectIds: [])
        return (task, link.projectId, link.id)
    }

    // MARK: - (a) 편집 이력이 detail/facts/dayBox에서 동일

    func testHistoricalMembershipIsConsistentAcrossDetailFactsAndDayBox() throws {
        let (repo, service, clock) = try make()
        let task = try service.createTask(title: "이력업무", initialStatus: .inProgress,
                                          workDate: WorkDate("2026-10-22")!,
                                          projectNames: ["이력프로젝트"], trackingMode: .perProject)
        let projectId = try XCTUnwrap(try repo.taskProjects(taskId: task.id).first).projectId

        move(clock, to: "2026-10-23")
        try editProjects(service, taskId: task.id, title: "이력업무", projectIds: [])
        move(clock, to: "2026-10-26")
        try editProjects(service, taskId: task.id, title: "이력업무", projectIds: [projectId])
        // 재연결 직후의 현재 상세에는 P가 보인다.
        XCTAssertEqual(detailProjectIds(try service.detail(taskId: task.id)), [projectId])
        move(clock, to: "2026-10-28")
        try editProjects(service, taskId: task.id, title: "이력업무", projectIds: [])
        // 마지막 해제 뒤 현재 상세에는 P가 없다.
        XCTAssertTrue(try service.detail(taskId: task.id).projects.isEmpty)

        let expected: [(String, Bool)] = [
            ("2026-10-22", true),
            ("2026-10-23", false),
            ("2026-10-24", false),
            ("2026-10-25", false),
            ("2026-10-26", true),
            ("2026-10-27", true),
            ("2026-10-28", false),
        ]
        for (iso, present) in expected {
            let date = WorkDate(iso)!
            let detail = try service.detail(taskId: task.id, asOf: date)
            XCTAssertEqual(detailProjectIds(detail).contains(projectId), present, "detail \(iso)")
            XCTAssertEqual(detail.projects.first?.project.id, present ? projectId : nil, "detail project \(iso)")

            let facts = try factsTask(repo: repo, taskId: task.id, on: date, knownAt: clock.now())
            XCTAssertEqual(facts.projectIds.contains(projectId), present, "facts \(iso)")
            XCTAssertEqual(facts.projectIds, present ? [projectId] : [], "facts ids \(iso)")

            let boxIds = try dayBoxProjectIds(repo: repo, taskId: task.id, on: date)
            XCTAssertEqual(boxIds.contains(projectId), present, "dayBox \(iso)")
        }
    }

    // MARK: - (c) 프로젝트별 상태·이벤트·검색

    func testPerProjectStatusSearchAndDomainEventsSurviveUnlinkAndRelink() throws {
        let (repo, service, clock) = try make()
        let index = try SearchIndex(repo: repo)
        let task = try service.createTask(title: "상태업무", initialStatus: .inProgress,
                                          workDate: WorkDate("2026-10-22")!,
                                          projectNames: ["이력프로젝트"], trackingMode: .perProject)
        let link = try XCTUnwrap(try repo.taskProjects(taskId: task.id).first)
        try service.changeProjectStatus(taskId: task.id, projectId: link.projectId,
                                        kind: .completed, workDate: WorkDate("2026-10-22")!)
        let events = try repo.events(taskId: task.id)
        XCTAssertEqual(try index.search(SearchQuery(text: "이력프로젝트", types: [.task])).map(\.sourceId),
                       [task.id])

        move(clock, to: "2026-10-23")
        try editProjects(service, taskId: task.id, title: "상태업무", projectIds: [])
        // 해제되면 프로젝트 이름으로 더 이상 검색되지 않고, 이벤트도 그대로다.
        XCTAssertTrue(try index.search(SearchQuery(text: "이력프로젝트", types: [.task])).isEmpty)
        XCTAssertEqual(try repo.events(taskId: task.id), events)
        XCTAssertTrue(try service.detail(taskId: task.id).projects.isEmpty)

        move(clock, to: "2026-10-26")
        try editProjects(service, taskId: task.id, title: "상태업무", projectIds: [link.projectId])
        // 재연결해도 같은 연결 행·같은 프로젝트 상태 이벤트를 재사용한다.
        XCTAssertEqual(try repo.taskProjects(taskId: task.id).map(\.id), [link.id])
        XCTAssertEqual(try service.detail(taskId: task.id).projects.first?.status, .completed)
        XCTAssertEqual(try repo.events(taskId: task.id), events)
        XCTAssertEqual(try index.search(SearchQuery(text: "이력프로젝트", types: [.task])).map(\.sourceId),
                       [task.id])
        // 과거 조회도 같은 상태를 보여 준다.
        XCTAssertEqual(try service.detail(taskId: task.id, asOf: WorkDate("2026-10-24")!).projects.count, 0)
        XCTAssertEqual(try service.detail(taskId: task.id, asOf: WorkDate("2026-10-27")!).projects.first?.status,
                       .completed)
    }

    // MARK: - (d) 확정 리포트는 이후 편집에도 불변

    func testConfirmedReportVersionIsImmutableAcrossLaterLinkEdits() async throws {
        let (repo, service, clock) = try make()
        let task = try service.createTask(title: "보고업무", initialStatus: .inProgress,
                                          workDate: WorkDate("2026-10-22")!,
                                          projectNames: ["이력프로젝트"], trackingMode: .perProject)
        let projectId = try XCTUnwrap(try repo.taskProjects(taskId: task.id).first).projectId
        move(clock, to: "2026-10-23")
        try editProjects(service, taskId: task.id, title: "보고업무", projectIds: [])
        move(clock, to: "2026-10-28")

        let reports = makeReportService(repo: repo)
        let day = WorkDate("2026-10-24")!
        let first = try await reports.generatePerformance(periodType: .daily, containing: day,
                                                          mode: .userRequested, useAI: false)
        XCTAssertFalse(try XCTUnwrap(first.facts.tasks.first { $0.id == task.id }).projectIds.contains(projectId))
        guard case .created(let draft) = first.outcome else {
            return XCTFail("expected a new draft version, got \(first.outcome)")
        }
        let confirmed = try reports.confirm(versionId: draft.id)
        XCTAssertEqual(confirmed.state, .confirmed)

        let storedVersion = try XCTUnwrap(try repo.reportVersion(id: confirmed.id))
        let storedSnapshot = try XCTUnwrap(try repo.sourceSnapshot(id: storedVersion.sourceSnapshotId))
        let frozen = try StableJSON.decode(ReportFacts.self, from: storedSnapshot.frozenFactsJSON)
        XCTAssertFalse(try XCTUnwrap(frozen.tasks.first { $0.id == task.id }).projectIds.contains(projectId))

        // 확정 후 10-29 재연결, 10-30 해제 — 확정본은 그대로여야 한다.
        move(clock, to: "2026-10-29")
        try editProjects(service, taskId: task.id, title: "보고업무", projectIds: [projectId])
        move(clock, to: "2026-10-30")
        try editProjects(service, taskId: task.id, title: "보고업무", projectIds: [])

        XCTAssertEqual(try repo.reportVersion(id: confirmed.id), storedVersion)
        XCTAssertEqual(try repo.sourceSnapshot(id: storedSnapshot.id), storedSnapshot)

        // 10-24 초안을 다시 만들어도 과거 사실은 P를 포함하지 않는다.
        let again = try await reports.generatePerformance(periodType: .daily, containing: day,
                                                          mode: .userRequested, useAI: false)
        XCTAssertFalse(try XCTUnwrap(again.facts.tasks.first { $0.id == task.id }).projectIds.contains(projectId))
    }

    // MARK: - (e) interval 저장 실패 시 전체 편집 롤백

    func testIntervalInsertFailureRollsBackEditAndLinks() throws {
        let (repo, service, clock) = try make()
        let task = try service.createTask(title: "보존업무", initialStatus: .inProgress,
                                          workDate: WorkDate("2026-10-22")!,
                                          projectNames: ["이력프로젝트"], trackingMode: .perProject)
        let link = try XCTUnwrap(try repo.taskProjects(taskId: task.id).first)
        move(clock, to: "2026-10-23")
        try editProjects(service, taskId: task.id, title: "보존업무", projectIds: [])

        let taskBefore = try XCTUnwrap(try repo.task(id: task.id))
        let linksBefore = try repo.taskProjects(taskId: task.id, includeRemoved: true)
        let intervalsBefore = try repo.taskProjectIntervals(taskProjectId: link.id)
        try repo.db.execute("""
            CREATE TRIGGER fail_interval_insert BEFORE INSERT ON task_project_interval
            BEGIN SELECT RAISE(ABORT, 'injected interval insert'); END;
            """)

        move(clock, to: "2026-10-26")
        XCTAssertThrowsError(try editProjects(service, taskId: task.id, title: "실패업무",
                                              projectIds: [link.projectId]))
        XCTAssertEqual(try repo.task(id: task.id), taskBefore)
        XCTAssertEqual(try repo.taskProjects(taskId: task.id, includeRemoved: true), linksBefore)
        XCTAssertEqual(try repo.taskProjectIntervals(taskProjectId: link.id), intervalsBefore)
    }

    func testIntervalUpdateFailureRollsBackSameDayRelink() throws {
        let (repo, service, clock) = try make()
        let task = try service.createTask(title: "보존업무", initialStatus: .inProgress,
                                          workDate: WorkDate("2026-10-22")!,
                                          projectNames: ["이력프로젝트"], trackingMode: .perProject)
        let link = try XCTUnwrap(try repo.taskProjects(taskId: task.id).first)
        move(clock, to: "2026-10-23")
        try editProjects(service, taskId: task.id, title: "보존업무", projectIds: [])

        let taskBefore = try XCTUnwrap(try repo.task(id: task.id))
        let linksBefore = try repo.taskProjects(taskId: task.id, includeRemoved: true)
        let intervalsBefore = try repo.taskProjectIntervals(taskProjectId: link.id)
        // 같은 날 재연결은 기존 구간을 UPDATE로 되살린다.
        try repo.db.execute("""
            CREATE TRIGGER fail_interval_update BEFORE UPDATE ON task_project_interval
            BEGIN SELECT RAISE(ABORT, 'injected interval update'); END;
            """)

        XCTAssertThrowsError(try editProjects(service, taskId: task.id, title: "실패업무",
                                              projectIds: [link.projectId]))
        XCTAssertEqual(try repo.task(id: task.id), taskBefore)
        XCTAssertEqual(try repo.taskProjects(taskId: task.id, includeRemoved: true), linksBefore)
        XCTAssertEqual(try repo.taskProjectIntervals(taskProjectId: link.id), intervalsBefore)
    }

    // MARK: - (g) 같은 날 재연결과 반복 주기

    func testSameDayUnlinkRelinkReopensSingleInterval() throws {
        let (repo, service, clock) = try make()
        let task = try service.createTask(title: "반복업무", initialStatus: .inProgress,
                                          workDate: WorkDate("2026-10-22")!,
                                          projectNames: ["이력프로젝트"], trackingMode: .perProject)
        let link = try XCTUnwrap(try repo.taskProjects(taskId: task.id).first)

        // 같은 날(10-23) 해제 후 재연결: 열린 구간은 정확히 하나, 그날 소속은 true.
        move(clock, to: "2026-10-23")
        try editProjects(service, taskId: task.id, title: "반복업무", projectIds: [])
        try editProjects(service, taskId: task.id, title: "반복업무", projectIds: [link.projectId])
        var intervals = try repo.taskProjectIntervals(taskProjectId: link.id)
        XCTAssertEqual(intervals.filter { $0.removedOn == nil }.count, 1)
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals.first?.linkedOn, WorkDate("2026-10-22"))
        XCTAssertTrue(try service.detail(taskId: task.id, asOf: WorkDate("2026-10-23")!)
            .projects.map(\.project.id).contains(link.projectId))

        // 서로 다른 날짜로 세 번 반복: (10-24 해제, 10-25 재연결) ...
        let cycles: [(String, String)] = [("2026-10-24", "2026-10-25"),
                                          ("2026-10-26", "2026-10-27"),
                                          ("2026-10-28", "2026-10-29")]
        for (off, on) in cycles {
            move(clock, to: off)
            try editProjects(service, taskId: task.id, title: "반복업무", projectIds: [])
            move(clock, to: on)
            try editProjects(service, taskId: task.id, title: "반복업무", projectIds: [link.projectId])
        }

        intervals = try repo.taskProjectIntervals(taskProjectId: link.id)
        let expected: [(String, String?)] = [("2026-10-22", "2026-10-24"),
                                             ("2026-10-25", "2026-10-26"),
                                             ("2026-10-27", "2026-10-28"),
                                             ("2026-10-29", nil)]
        XCTAssertEqual(intervals.map { ($0.linkedOn.iso, $0.removedOn?.iso) }.map { "\($0.0)|\($0.1 ?? "-")" },
                       expected.map { "\($0.0)|\($0.1 ?? "-")" })
        XCTAssertEqual(intervals.filter { $0.removedOn == nil }.count, 1)
        XCTAssertTrue(try service.detail(taskId: task.id).projects.map(\.project.id).contains(link.projectId))
    }

    // MARK: - DB 재시작

    func testHistoricalMembershipSurvivesDatabaseReopen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskProjectHistory-\(UUID().uuidString)")
        roots.append(root)
        let dbPath = root.appendingPathComponent("work.sqlite").path
        let clock = FixedClock(instant("2026-10-22"))

        var repo = try WorkRepository(db: SQLiteDatabase(path: dbPath), clock: clock,
                                      ids: SequentialIDGenerator())
        let service = TaskService(repo: repo)
        let task = try service.createTask(title: "재시작업무", initialStatus: .inProgress,
                                          workDate: WorkDate("2026-10-22")!,
                                          projectNames: ["이력프로젝트"], trackingMode: .perProject)
        let link = try XCTUnwrap(try repo.taskProjects(taskId: task.id).first)
        move(clock, to: "2026-10-23")
        try editProjects(service, taskId: task.id, title: "재시작업무", projectIds: [])
        move(clock, to: "2026-10-26")
        try editProjects(service, taskId: task.id, title: "재시작업무", projectIds: [link.projectId])
        move(clock, to: "2026-10-28")
        try editProjects(service, taskId: task.id, title: "재시작업무", projectIds: [])

        let dates = ["2026-10-22", "2026-10-24", "2026-10-26", "2026-10-28"].map { WorkDate($0)! }
        let detailBefore = try dates.map { detailProjectIds(try service.detail(taskId: task.id, asOf: $0)) }
        let intervalsBefore = try repo.taskProjectIntervals(taskProjectId: link.id)
        repo.db.close()

        repo = try WorkRepository(db: SQLiteDatabase(path: dbPath), clock: clock,
                                  ids: SequentialIDGenerator())
        let reopened = TaskService(repo: repo)
        let detailAfter = try dates.map { detailProjectIds(try reopened.detail(taskId: task.id, asOf: $0)) }
        XCTAssertEqual(detailAfter, detailBefore)
        XCTAssertEqual(try repo.taskProjectIntervals(taskProjectId: link.id), intervalsBefore)
    }
}
