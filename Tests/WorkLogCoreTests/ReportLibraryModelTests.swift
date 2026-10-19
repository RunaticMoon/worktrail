import XCTest
@testable import WorkLogCore

/// WTRP-11FC G: 저장된 리포트 보관함 표시 모델(ReportLibraryModel) 테스트.
/// 생성·저장은 기존 ReportService를 그대로 쓰고(useAI: false), 표시 계층만 검증한다.
final class ReportLibraryModelTests: XCTestCase {
    private var roots: [URL] = []
    private let today = WorkDate("2026-10-19")!   // 월요일

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []; super.tearDown()
    }

    private func environment() throws -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReportLibraryModelTests-\(UUID().uuidString)")
        roots.append(root)
        let paths = AppPaths(dataRoot: root.appendingPathComponent("data"),
                             backupRoot: root.appendingPathComponent("backups"))
        var settings = AppSettings(); settings.aiEnabled = false
        try SettingsStore(fileURL: paths.settingsFile).save(settings)
        return try AppEnvironment.open(AppEnvironmentOptions(
            paths: paths, keyStore: InMemoryVaultKeyStore(),
            authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(),
            aiProvider: nil, clock: FixedClock(WorkCalendar().startOfDay(today)),
            ids: SequentialIDGenerator()))
    }

    /// 기록 한 건을 넣어 결정적 초안이 비어 있지 않게 한다.
    private func seedRecord(_ env: AppEnvironment, date: WorkDate) throws {
        let task = try env.tasks.createTask(title: "보관함 테스트 업무",
                                            initialStatus: .inProgress, workDate: date)
        _ = try env.tasks.addActivity(taskId: task.id, body: "보관함 표시 검증 근거", workDate: date)
    }

    private struct Seeded {
        let env: AppEnvironment
        let daily: ReportGenerationResult
        let weekly: ReportGenerationResult
        let weeklyEarlier: ReportGenerationResult
        let monthly: ReportGenerationResult
        let quarterly: ReportGenerationResult
        let submission: ReportGenerationResult
    }

    /// daily/weekly(두 주)/monthly/quarterly 성과 리포트 + weekly 제출용 리포트.
    private func seedAll() async throws -> Seeded {
        let env = try environment()
        try seedRecord(env, date: WorkDate("2026-10-14")!)
        try seedRecord(env, date: WorkDate("2026-10-07")!)
        let daily = try await env.reports.generatePerformance(
            periodType: .daily, containing: WorkDate("2026-10-14")!,
            mode: .userRequested, useAI: false)
        let weekly = try await env.reports.generatePerformance(
            periodType: .weekly, containing: WorkDate("2026-10-14")!,
            mode: .userRequested, useAI: false)
        let weeklyEarlier = try await env.reports.generatePerformance(
            periodType: .weekly, containing: WorkDate("2026-10-07")!,
            mode: .userRequested, useAI: false)
        let monthly = try await env.reports.generatePerformance(
            periodType: .monthly, containing: WorkDate("2026-10-14")!,
            mode: .userRequested, useAI: false)
        let quarterly = try await env.reports.generatePerformance(
            periodType: .quarterly, containing: WorkDate("2026-10-14")!,
            mode: .userRequested, useAI: false)
        let submission = try await env.reports.generateSubmission(
            reportDate: today, mode: .userRequested, useAI: false)
        return Seeded(env: env, daily: daily, weekly: weekly, weeklyEarlier: weeklyEarlier,
                      monthly: monthly, quarterly: quarterly, submission: submission)
    }

    // MARK: - 1. 기간별 개수·정렬·계열 필터

    @MainActor func testLoadCountsItemsAndOrdering() async throws {
        let s = try await seedAll()
        let model = ReportLibraryModel(environment: s.env)
        XCTAssertEqual(model.periodType, .weekly, "기본 기간은 주간")
        XCTAssertNil(model.familyFilter, "기본은 두 계열 모두")
        XCTAssertTrue(model.allItems.isEmpty)

        model.load()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.allItems.count, 6)
        XCTAssertEqual(model.count(for: .daily), 1)
        XCTAssertEqual(model.count(for: .weekly), 3)      // 성과 2 + 제출용 1
        XCTAssertEqual(model.count(for: .monthly), 1)
        XCTAssertEqual(model.count(for: .quarterly), 1)
        XCTAssertEqual(model.count(for: .yearly), 0)

        // range.start 내림차순, 같은 시작일이면 submission 먼저.
        let weeklyIds = model.items.map(\.id)
        XCTAssertEqual(weeklyIds, [s.submission.report.id, s.weekly.report.id, s.weeklyEarlier.report.id])
        XCTAssertEqual(model.items.map(\.report.family),
                       [.submission, .performance, .performance])

        // 계열 필터는 count와 items 양쪽에 적용된다.
        model.familyFilter = .performance
        XCTAssertEqual(model.count(for: .weekly), 2)
        XCTAssertEqual(model.items.map(\.id), [s.weekly.report.id, s.weeklyEarlier.report.id])
        model.familyFilter = .submission
        XCTAssertEqual(model.count(for: .weekly), 1)
        XCTAssertEqual(model.items.map(\.id), [s.submission.report.id])
        XCTAssertEqual(model.count(for: .daily), 0, "제출용은 주간 전용이다")
        model.familyFilter = nil

        model.periodType = .monthly
        XCTAssertEqual(model.items.map(\.id), [s.monthly.report.id])
        model.periodType = .quarterly
        XCTAssertEqual(model.items.map(\.id), [s.quarterly.report.id])
        model.periodType = .daily
        XCTAssertEqual(model.items.map(\.id), [s.daily.report.id])
        model.periodType = .yearly
        XCTAssertTrue(model.items.isEmpty)
    }

    // MARK: - 2. 기간·계열·상태 라벨

    @MainActor func testPeriodFamilyAndStateLabels() async throws {
        let s = try await seedAll()
        let model = ReportLibraryModel(environment: s.env)
        model.load()

        model.periodType = .daily
        XCTAssertEqual(model.items.first?.periodLabel, "2026-10-14 (수)")
        XCTAssertEqual(model.items.first?.familyLabel, "성과자료")

        model.periodType = .weekly
        let submission = try XCTUnwrap(model.items.first { $0.id == s.submission.report.id })
        XCTAssertEqual(submission.periodLabel, "2026-10-12 ~ 2026-10-18")
        XCTAssertEqual(submission.familyLabel, "주간보고")
        let weekly = try XCTUnwrap(model.items.first { $0.id == s.weekly.report.id })
        XCTAssertEqual(weekly.periodLabel, "2026-10-12 ~ 2026-10-18")

        model.periodType = .monthly
        XCTAssertEqual(model.items.first?.periodLabel, "2026년 10월")
        model.periodType = .quarterly
        XCTAssertEqual(model.items.first?.periodLabel, "2026년 4분기")

        // 초안 → 확정. 최신 버전 상태가 라벨이 된다.
        model.periodType = .daily
        let daily = try XCTUnwrap(model.items.first)
        XCTAssertEqual(daily.stateLabel, "초안")
        XCTAssertNil(daily.confirmedVersion)
        XCTAssertEqual(daily.versionCount, 1)

        let versionId = try XCTUnwrap(daily.latestVersion?.id)
        _ = try s.env.reports.confirm(versionId: versionId)
        model.load()
        let confirmed = try XCTUnwrap(model.items.first)
        XCTAssertEqual(confirmed.stateLabel, "확정")
        XCTAssertEqual(confirmed.confirmedVersion?.id, versionId)
        XCTAssertEqual(confirmed.confirmedVersion?.state, .confirmed)
        XCTAssertEqual(confirmed.versionCount, 1)

        // 확정본을 수정하면 edited 새 버전이 최신이 되고, 확정본은 그대로 남는다.
        _ = try s.env.reports.edit(versionId: versionId, content: "확정 후 수정 본문")
        model.load()
        let edited = try XCTUnwrap(model.items.first)
        XCTAssertEqual(edited.stateLabel, "수정본")
        XCTAssertEqual(edited.versionCount, 2)
        XCTAssertEqual(edited.latestVersion?.state, .edited)
        XCTAssertEqual(edited.confirmedVersion?.id, versionId)
        XCTAssertEqual(edited.latestVersion?.version, 2)
    }

    // MARK: - 3. 선택·본문·선택 해제

    @MainActor func testSelectionContentAndResetOnPeriodChange() async throws {
        let s = try await seedAll()
        let model = ReportLibraryModel(environment: s.env)
        model.load()

        // 선택 전에는 본문이 없다.
        XCTAssertNil(model.selectedId)
        XCTAssertNil(model.selectedItem)
        XCTAssertNil(model.selectedContent)

        model.select(s.submission.report.id)
        XCTAssertEqual(model.selectedId, s.submission.report.id)
        XCTAssertEqual(model.selectedItem?.report.family, .submission)
        let expected = try s.env.repo.reportVersions(reportId: s.submission.report.id)
            .max { $0.version < $1.version }?.content
        XCTAssertEqual(model.selectedContent, expected)
        XCTAssertFalse(model.selectedContent?.isEmpty ?? true)

        // items에 없는 id는 선택되지 않는다.
        model.select("없는-리포트")
        XCTAssertNil(model.selectedId)

        // 기간 종류를 바꿔 선택이 사라지면 nil.
        model.select(s.weekly.report.id)
        XCTAssertEqual(model.selectedId, s.weekly.report.id)
        model.periodType = .monthly
        XCTAssertNil(model.selectedId)
        XCTAssertNil(model.selectedItem)
        XCTAssertNil(model.selectedContent)

        // 같은 기간 종류 안에서 유지되는 선택은 그대로 둔다.
        model.periodType = .weekly
        model.select(s.weekly.report.id)
        model.familyFilter = .performance
        XCTAssertEqual(model.selectedId, s.weekly.report.id, "필터 안에 남아 있으면 유지")
        model.familyFilter = .submission
        XCTAssertNil(model.selectedId, "필터 밖으로 밀려나면 해제")

        // 선택 해제는 명시적으로도 가능하다.
        model.familyFilter = nil
        model.select(s.weekly.report.id)
        model.select(nil)
        XCTAssertNil(model.selectedId)
        XCTAssertNil(model.selectedContent)
    }

    // MARK: - 4. 버전 없는 리포트

    @MainActor func testItemWithoutVersionsHasNoContent() async throws {
        let env = try environment()
        let range = DateRange(start: WorkDate("2025-11-01")!,
                              endExclusive: WorkDate("2026-11-01")!)
        // report.evaluation_period_id는 evaluation_period(id)를 참조한다.
        try env.repo.insertEvaluationPeriod(
            EvaluationPeriod(id: "eval-1", range: range, createdAt: env.options.clock.now()))
        let report = Report(id: "report-empty", family: .performance, periodType: .yearly,
                            periodKey: "eval-1",
                            range: range,
                            evaluationPeriodId: "eval-1",
                            createdAt: env.options.clock.now())
        try env.repo.insertReport(report)

        let model = ReportLibraryModel(environment: env)
        model.load()
        model.periodType = .yearly
        let item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(item.id, "report-empty")
        XCTAssertNil(item.latestVersion)
        XCTAssertNil(item.confirmedVersion)
        XCTAssertEqual(item.versionCount, 0)
        XCTAssertEqual(item.stateLabel, "본문 없음")
        XCTAssertEqual(item.periodLabel, "평가 기간 2025-11-01 ~ 2026-10-31")
        XCTAssertEqual(item.familyLabel, "성과자료")

        model.select(item.id)
        XCTAssertNil(model.selectedContent)
    }
}
