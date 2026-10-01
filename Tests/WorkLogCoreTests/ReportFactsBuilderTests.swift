import XCTest
@testable import WorkLogCore

/// DAY-01~03 / WEEK-01 / PERF-01~02 / QUIZ-02 / SEC-T30:
/// 저장소 원본에서 결정적 리포트 사실(ReportFacts)을 만든다.
final class ReportFactsBuilderTests: XCTestCase {

    private let reportDate = WorkDate("2026-10-05")!

    // MARK: - Helpers

    private func fixtureNow() -> Date {
        (try? FixtureLoader.load()).flatMap { $0.clock?.now }.flatMap(FixtureLoader.date)
            ?? Date(timeIntervalSince1970: 1_790_000_000)
    }

    private func makeRepo(now: Date) throws -> WorkRepository {
        try WorkRepository.inMemory(clock: FixedClock(now), ids: SequentialIDGenerator())
    }

    private func makeBuilder(_ repo: WorkRepository) -> ReportFactsBuilder {
        let periods = Periods()
        let planService = WeekPlanService(repo: repo, periods: periods)
        return ReportFactsBuilder(repo: repo, periods: periods, planService: planService)
    }

    /// 픽스처를 적재한 저장소와 생성기를 만든다.
    private func makeFixtureBuilder() throws -> (repo: WorkRepository, builder: ReportFactsBuilder) {
        let repo = try makeRepo(now: fixtureNow())
        let fixture = try FixtureLoader.load()
        try FixtureSeeder.seed(repo, fixture: fixture)
        return (repo, makeBuilder(repo))
    }

    // MARK: 1. 제출용 주간보고 — 기간·상태·프로젝트별 상태

    func testSubmissionFactsRangesAndStates() throws {
        let (_, builder) = try makeFixtureBuilder()
        let facts = try builder.submissionFacts(reportDate: reportDate, knownAt: fixtureNow())

        XCTAssertEqual(facts.family, .submission)
        XCTAssertEqual(facts.periodType, .weekly)
        XCTAssertEqual(facts.range, DateRange(start: WorkDate("2026-09-28")!, endExclusive: WorkDate("2026-10-05")!))
        XCTAssertEqual(facts.planRange, DateRange(start: WorkDate("2026-10-05")!, endExclusive: WorkDate("2026-10-12")!))
        XCTAssertEqual(facts.knownAt, fixtureNow())

        let taskA = try XCTUnwrap(facts.task("task-A"))
        XCTAssertEqual(taskA.statusAtCutoff, .inProgress)
        XCTAssertEqual(taskA.projectStatuses["project-G"], .completed)
        XCTAssertEqual(taskA.projectStatuses["project-J"], .inProgress)
        XCTAssertEqual(taskA.projectStatuses["project-K"], .planned)
        XCTAssertEqual(taskA.projectIds, ["project-G", "project-J", "project-K"])

        // TIME-T02: 일요일 진행, 월요일 09시 완료 → 지난주 보고는 진행.
        let taskB = try XCTUnwrap(facts.task("task-B"))
        XCTAssertEqual(taskB.statusAtCutoff, .inProgress)

        // 월요일에 뒤늦게 입력한 완료(실제 업무일 10-02).
        let taskC = try XCTUnwrap(facts.task("task-C"))
        XCTAssertEqual(taskC.statusAtCutoff, .completed)
        XCTAssertEqual(taskC.completionDatesInRange, [WorkDate("2026-10-02")!])
        XCTAssertNil(taskC.firstStartedOn)
    }

    // MARK: 2. 확정 계획만 포함, 후보 제외

    func testConfirmedPlansExcludeCandidates() throws {
        let (_, builder) = try makeFixtureBuilder()
        let facts = try builder.submissionFacts(reportDate: reportDate, knownAt: fixtureNow())

        let planItemIds = Set(facts.confirmedPlans.flatMap(\.planItemIds))
        XCTAssertEqual(planItemIds, Set(["plan-J", "plan-docs"]))
        XCTAssertFalse(planItemIds.contains("candidate-K"))
    }

    // MARK: 3. 집계 지표

    func testMetrics() throws {
        let (repo, builder) = try makeFixtureBuilder()
        let facts = try builder.submissionFacts(reportDate: reportDate, knownAt: fixtureNow())

        XCTAssertEqual(facts.metrics.uniqueTaskCount, 3)
        XCTAssertEqual(facts.metrics.projectAssociationCount, 5)

        // source-B-done(10-05)은 기간 밖이라 활동 수에서 제외.
        let expectedActivities = try repo.activities(in: facts.range).filter { $0.recordedAt <= fixtureNow() }
        XCTAssertEqual(facts.metrics.activityCount, expectedActivities.count)
        XCTAssertEqual(facts.metrics.activityCount, 4)
        XCTAssertFalse(facts.sources.contains { $0.id == "activity:source-B-done" })
    }

    // MARK: 4. knownAt — 그때 알던 정보

    func testKnownAtExcludesLaterRecords() throws {
        let (_, builder) = try makeFixtureBuilder()
        let knownSunday = try XCTUnwrap(FixtureLoader.date("2026-10-04T23:59:00+09:00"))
        let facts = try builder.submissionFacts(reportDate: reportDate, knownAt: knownSunday)

        XCTAssertNil(facts.task("task-C"))
        XCTAssertEqual(facts.metrics.uniqueTaskCount, 2)
        XCTAssertFalse(facts.sources.contains { $0.id == "activity:source-C-late" })
        XCTAssertEqual(facts.task("task-B")?.statusAtCutoff, .inProgress)
    }

    // MARK: 5. QUIZ-T03 — 보충 답변은 근거로 누적, 활동으로 집계하지 않음

    func testSupplementIsSourceNotActivity() throws {
        let (_, builder) = try makeFixtureBuilder()
        let facts = try builder.submissionFacts(reportDate: reportDate, knownAt: fixtureNow())

        let supplement = try XCTUnwrap(facts.sources.first { $0.id == "supplement:supplement-A" })
        XCTAssertEqual(supplement.kind, .supplement)
        XCTAssertNil(supplement.workDate)
        XCTAssertEqual(supplement.applies, DateRange(start: WorkDate("2026-09-28")!, endExclusive: WorkDate("2026-10-05")!))
        XCTAssertEqual(supplement.taskId, "task-A")
        XCTAssertTrue(supplement.text.contains("Q:"))
        XCTAssertTrue(supplement.text.contains("A:"))
        XCTAssertEqual(facts.metrics.activityCount, 4)
    }

    // MARK: 6. Memo 근거 + 승인된 링크

    func testMemoSourceAndAcceptedLink() throws {
        let (_, builder) = try makeFixtureBuilder()
        let facts = try builder.submissionFacts(reportDate: reportDate, knownAt: fixtureNow())

        XCTAssertTrue(facts.sourceIds.contains("memo:source-memo-1"))
        let memo = try XCTUnwrap(facts.sources.first { $0.id == "memo:source-memo-1" })
        XCTAssertEqual(memo.kind, .memo)
        XCTAssertNil(memo.taskId)
        XCTAssertEqual(memo.projectIds, ["project-G", "project-J"])

        XCTAssertTrue(facts.memoLinksAccepted.contains(AcceptedMemoLink(memoId: "source-memo-1",
                                                                        taskId: "task-A")))
    }

    // MARK: 7. TIME-T05 — 진행 중이나 활동 없음: Task는 있으나 가짜 활동 없음

    func testInProgressTaskWithoutActivityHasNoFakeActivity() throws {
        let now = fixtureNow()
        let repo = try makeRepo(now: now)
        try repo.insertTask(WorkTask(id: "task-X", title: "활동 없는 진행", createdAt: now))
        try repo.appendEvents([
            DomainEvent(id: "event-X-create", taskId: "task-X", scopeType: .task, scopeId: "task-X",
                        kind: .created, toStatus: .planned, effectiveDate: WorkDate("2026-09-29")!,
                        effectiveOrder: 1, recordedAt: now),
            DomainEvent(id: "event-X-start", taskId: "task-X", scopeType: .task, scopeId: "task-X",
                        kind: .started, toStatus: .inProgress, effectiveDate: WorkDate("2026-09-30")!,
                        effectiveOrder: 2, recordedAt: now),
        ])
        let builder = makeBuilder(repo)

        let facts = try builder.submissionFacts(reportDate: reportDate, knownAt: now)
        let taskX = try XCTUnwrap(facts.task("task-X"))
        XCTAssertEqual(taskX.statusAtCutoff, .inProgress)
        XCTAssertTrue(taskX.activitySourceIds.isEmpty)
        XCTAssertEqual(facts.metrics.activityCount, 0)
    }

    // MARK: 8. digest — generatedAt 무관, 원본 변화 감지

    func testDigestIgnoresGeneratedAtAndDetectsChange() throws {
        let repo = try makeRepo(now: fixtureNow())
        let fixture = try FixtureLoader.load()
        try FixtureSeeder.seed(repo, fixture: fixture)
        let builder = makeBuilder(repo)

        let facts = try builder.submissionFacts(reportDate: reportDate, knownAt: fixtureNow())
        let digest = try ReportFactsBuilder.digest(facts)

        var shifted = facts
        shifted.generatedAt = facts.generatedAt.addingTimeInterval(3600)
        XCTAssertEqual(try ReportFactsBuilder.digest(shifted), digest)

        // 기간 안 활동을 늦게 추가하면 digest가 달라진다.
        try repo.insertActivity(Activity(id: "activity-late", taskId: "task-A", body: "추가 기록",
                                         workDate: WorkDate("2026-10-03")!, recordedAt: fixtureNow()))
        let changed = try builder.submissionFacts(reportDate: reportDate, knownAt: fixtureNow())
        XCTAssertNotEqual(try ReportFactsBuilder.digest(changed), digest)
    }

    // MARK: 9. TIME-T03 — 월요일 00:00 effectiveDate 10-05 사건은 지난주에 없음

    func testMondayEventNotIncludedInPreviousWeek() throws {
        let now = fixtureNow()
        let repo = try makeRepo(now: now)
        try repo.insertTask(WorkTask(id: "task-M", title: "월요일 사건", createdAt: now))
        try repo.appendEvents([
            DomainEvent(id: "event-M-create", taskId: "task-M", scopeType: .task, scopeId: "task-M",
                        kind: .created, toStatus: .planned, effectiveDate: WorkDate("2026-09-29")!,
                        effectiveOrder: 1, recordedAt: now),
            DomainEvent(id: "event-M-done", taskId: "task-M", scopeType: .task, scopeId: "task-M",
                        kind: .completed, toStatus: .completed, effectiveDate: WorkDate("2026-10-05")!,
                        effectiveOrder: 1, recordedAt: try XCTUnwrap(FixtureLoader.date("2026-10-05T00:00:00+09:00"))),
        ])
        let builder = makeBuilder(repo)

        let facts = try builder.submissionFacts(reportDate: reportDate, knownAt: now)
        let taskM = try XCTUnwrap(facts.task("task-M"))
        XCTAssertEqual(taskM.statusAtCutoff, .planned)
        XCTAssertTrue(taskM.completionDatesInRange.isEmpty)
        XCTAssertTrue(taskM.eventsInRange.allSatisfy { $0.effectiveDate < WorkDate("2026-10-05")! })
    }

    // MARK: 10. SEC-T30 — Secret 카나리아가 facts 직렬화에 없음

    func testSecretCanaryNeverAppearsInFacts() throws {
        let (_, builder) = try makeFixtureBuilder()

        // 같은 테스트 안에서 임시 vault에 카나리아를 저장한다.
        let vaultDB = try SQLiteDatabase(path: ":memory:")
        let vault = try SecretVault(db: vaultDB, keyStore: InMemoryVaultKeyStore())
        _ = try vault.create(title: "CANARY-TITLE-a1", groupName: "CANARY-GROUP-c3",
                             rows: [SecretRowInput(key: "CANARY-KEY-d4", value: "CANARY-SECRET-b2")])

        let facts = try builder.submissionFacts(reportDate: reportDate, knownAt: fixtureNow())
        let json = try StableJSON.string(facts)
        XCTAssertFalse(json.contains("CANARY-TITLE-a1"))
        XCTAssertFalse(json.contains("CANARY-SECRET-b2"))
        XCTAssertFalse(json.contains("CANARY-GROUP-c3"))
        XCTAssertFalse(json.contains("CANARY-KEY-d4"))
    }
}
