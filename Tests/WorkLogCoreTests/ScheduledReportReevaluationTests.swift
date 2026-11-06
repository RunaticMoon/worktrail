import XCTest
@testable import WorkLogCore

/// PERF-62: 활동 가져오기 이후 예약 리포트 재평가.
///
/// catch-up 이후 새 활동이 도착하면, 그 활동이 영향을 주는 성공한 기간만 자동 모드로 다시
/// 평가한다. 원본이 그대로면 AI 호출도 새 버전도 없고, 확정·편집본은 보존된다.
final class ScheduledReportReevaluationTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    @MainActor
    func testMaintenanceFindsNewDeadlinesWithoutImportsAndDoesNotDuplicate() async throws {
        let clock = FixedClock(kst(2026, 10, 20, 23))
        let env = try makeEnv(now: clock.now(), clock: clock)
        _ = try env.tasks.captureMemo(body: "오늘 기록", workDate: WorkDate("2026-10-20")!)
        let coordinator = ScheduledReportCoordinator(catchUp: { _ = try await env.runStartupCatchUp() },
                                                     reevaluate: { _ in XCTFail("No imports") })
        try await coordinator.runCatchUp()
        XCTAssertNil(try dailyReport(env, on: WorkDate("2026-10-20")!))
        clock.advance(by: 7200)
        try await coordinator.maintenance()
        let report = try XCTUnwrap(dailyReport(env, on: WorkDate("2026-10-20")!))
        let count = try versions(env, reportId: report.id).count
        try await coordinator.maintenance()
        XCTAssertEqual(try versions(env, reportId: report.id).count, count)
        clock.advance(by: 3 * 86400) // wake after several missed deadlines
        try await coordinator.maintenance()
        XCTAssertNotNil(try dailyReport(env, on: WorkDate("2026-10-23")!))
    }

    @MainActor
    func testShutdownCancelsAndJoinsCatchUpAndRejectsNewWork() async throws {
        let started = expectation(description: "catch-up entered")
        var exited = false
        var reevaluations = 0
        let coordinator = ScheduledReportCoordinator(catchUp: {
            started.fulfill()
            defer { exited = true }
            try await Task.sleep(for: .seconds(60))
        }, reevaluate: { _ in reevaluations += 1 })
        let startup = Task { try await coordinator.runCatchUp() }
        await fulfillment(of: [started], timeout: 2)
        await coordinator.importsLanded(DateRange(start: WorkDate("2026-10-01")!, endExclusive: WorkDate("2026-10-02")!))
        await coordinator.shutdown()
        XCTAssertTrue(exited)
        do { try await startup.value; XCTFail("cancelled") } catch is CancellationError { }
        try await coordinator.maintenance()
        XCTAssertEqual(reevaluations, 0)
    }

    func testFailedReevaluationPersistsAndRecoversAfterReopenWithZeroNewImports() async throws {
        let clock = FixedClock(kst(2026, 10, 21, 10))
        var env: AppEnvironment? = try makeEnv(now: clock.now(), clock: clock)
        let options = env!.options
        let day = WorkDate("2026-10-20")!
        _ = try env!.tasks.captureMemo(body: "기록", workDate: day)
        _ = try await env!.runStartupCatchUp()
        let reportID = try XCTUnwrap(dailyReport(env!, on: day)).id
        let imported = event(occurredAt: kst(2026, 10, 20, 12))
        XCTAssertEqual(try env!.repo.importActivities([imported], connection: connection()), 1)
        try env!.repo.db.execute("CREATE TRIGGER fail_report BEFORE INSERT ON report_version BEGIN SELECT RAISE(ABORT, 'fixture'); END")
        do {
            _ = try await env!.reevaluateScheduledReports(affecting: DateRange(start: day, endExclusive: WorkDate("2026-10-21")!))
            XCTFail("Failure must reach caller")
        } catch { }
        XCTAssertEqual(try env!.repo.scheduledJob(type: .dailyClose, periodKey: day.iso)?.state, .failed)
        try env!.repo.db.execute("DROP TRIGGER fail_report")
        env = nil
        let reopened = try AppEnvironment.open(options)
        XCTAssertEqual(try reopened.repo.importActivities([imported], connection: connection()), 0)
        _ = try await reopened.runStartupCatchUp()
        XCTAssertEqual(try versions(reopened, reportId: reportID).count, 1, "Backoff survives reopening")
        clock.advance(by: 3600)
        _ = try await reopened.runStartupCatchUp()
        XCTAssertEqual(try reopened.repo.scheduledJob(type: .dailyClose, periodKey: day.iso)?.state, .succeeded)
        XCTAssertEqual(try versions(reopened, reportId: reportID).count, 2)
        _ = try await reopened.runStartupCatchUp()
        XCTAssertEqual(try versions(reopened, reportId: reportID).count, 2)
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScheduledReportReevaluationTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func makePaths() throws -> AppPaths {
        let root = try makeTempDir()
        return AppPaths(dataRoot: root.appendingPathComponent("data", isDirectory: true),
                        backupRoot: root.appendingPathComponent("backups", isDirectory: true))
    }

    private func makeEnv(now: Date, aiProvider: AIProvider? = nil,
                         clock: FixedClock? = nil) throws -> AppEnvironment {
        let options = AppEnvironmentOptions(paths: try makePaths(),
                                            keyStore: InMemoryVaultKeyStore(),
                                            authenticator: MockDeviceAuthenticator(),
                                            pasteboard: InMemoryPasteboard(),
                                            aiProvider: aiProvider,
                                            clock: clock ?? FixedClock(now),
                                            ids: SequentialIDGenerator())
        return try AppEnvironment.open(options)
    }

    /// KST 기준 시각. 업무일 경계 계산이 한국 시간대임을 명시한다.
    private func kst(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour))!
    }

    private func connection() -> ActivityConnection {
        var connection = ActivityConnection(source: .github)
        connection.enabled = true
        connection.baseURL = "https://api.github.com"
        connection.account = "sample-user"
        return connection
    }

    private func event(id: String = "gh-1", occurredAt: Date,
                       title: String = "PR #12 병합") -> ImportedActivity {
        ImportedActivity(id: id, occurredAt: occurredAt, title: title,
                         detail: "가져온 활동 본문", url: "https://example.test/pr/12")
    }

    private func dailyReport(_ env: AppEnvironment, on date: WorkDate) throws -> Report? {
        try env.repo.report(family: .performance, periodType: .daily, periodKey: date.iso)
    }

    private func versions(_ env: AppEnvironment, reportId: String) throws -> [ReportVersion] {
        try env.repo.reportVersions(reportId: reportId)
    }

    private func facts(_ env: AppEnvironment, snapshotId: String) throws -> ReportFacts {
        let snapshot = try XCTUnwrap(env.repo.sourceSnapshot(id: snapshotId))
        return try StableJSON.decode(ReportFacts.self, from: Data(snapshot.frozenFactsJSON.utf8))
    }

    /// AI 입력 payload에서 facts.range.start만 꺼낸다.
    private struct CatchUpPayload: Decodable {
        struct Facts: Decodable {
            struct Range: Decodable { let start: WorkDate }
            let periodType: PeriodType
            let range: Range
        }
        let facts: Facts
    }

    private func payloadFacts(_ provider: MockAIProvider) throws -> [(PeriodType, WorkDate)] {
        try provider.receivedInputs.map {
            let payload = try JSONDecoder().decode(CatchUpPayload.self,
                                                   from: Data($0.payloadJSON.utf8))
            return (payload.facts.periodType, payload.facts.range.start)
        }
    }

    // MARK: - 1. 가져오기 후 영향 기간 재평가

    func testImportAfterCatchUpReevaluatesDayBefore() async throws {
        let now = kst(2026, 10, 21, 10)          // 수요일 10:00 KST
        let env = try makeEnv(now: now)
        let today = env.calendar.workDate(of: now)
        let dayBefore = env.calendar.adding(days: -1, to: today)
        _ = try env.tasks.captureMemo(body: "어제 기록", workDate: dayBefore)

        _ = try await env.runStartupCatchUp()
        let job = try XCTUnwrap(env.repo.scheduledJob(type: .dailyClose, periodKey: dayBefore.iso))
        XCTAssertEqual(job.state, .succeeded)

        let report = try XCTUnwrap(dailyReport(env, on: dayBefore))
        let v1 = try XCTUnwrap(try versions(env, reportId: report.id).last)
        XCTAssertFalse(try facts(env, snapshotId: v1.sourceSnapshotId)
            .sources.contains { $0.kind == .github }, "가져오기 전 스냅샷에는 활동이 없다")

        // D-1 12:00 KST에 발생한 활동을 가져온다. recordedAt은 지금이다.
        XCTAssertEqual(try env.repo.importActivities([event(occurredAt: kst(2026, 10, 20, 12))],
                                                     connection: connection()), 1)

        let created = try await env.reevaluateScheduledReports(
            affecting: DateRange(start: dayBefore, endExclusive: today))
        XCTAssertEqual(created, 1, "새 버전을 만든 기간 수를 반환한다")

        let all = try versions(env, reportId: report.id)
        XCTAssertEqual(all.count, 2)
        let v2 = try XCTUnwrap(all.last)
        XCTAssertEqual(v2.state, .draft)
        let replaced = try XCTUnwrap(all.first { $0.id == v1.id })
        XCTAssertEqual(replaced.state, .superseded, "편집되지 않은 초안은 새 버전으로 대체된다")
        XCTAssertEqual(replaced.content, v1.content, "대체된 초안의 본문은 보존한다")
        XCTAssertNil(v2.basedOnVersionId, "대체는 기반 버전을 남기지 않는다")

        let v2Facts = try facts(env, snapshotId: v2.sourceSnapshotId)
        let imported = v2Facts.sources.filter { $0.kind == .github }
        XCTAssertEqual(imported.count, 1)
        XCTAssertTrue(imported[0].text.contains("PR #12"), "가져온 활동이 frozen facts에 포함된다")
        XCTAssertEqual(v2.content.contains("PR #12"), true)

        let after = try XCTUnwrap(env.repo.scheduledJob(type: .dailyClose, periodKey: dayBefore.iso))
        XCTAssertEqual(after.state, .succeeded)
        XCTAssertEqual(after.attempts, job.attempts, "재평가는 시도 횟수를 바꾸지 않는다")
    }

    func testRepeatedReevaluationWithUnchangedSourcesCreatesNothing() async throws {
        let now = kst(2026, 10, 21, 10)
        let provider = MockAIProvider()
        let env = try makeEnv(now: now, aiProvider: provider)
        let today = env.calendar.workDate(of: now)
        let dayBefore = env.calendar.adding(days: -1, to: today)
        _ = try env.tasks.captureMemo(body: "어제 기록", workDate: dayBefore)
        _ = try await env.runStartupCatchUp()

        let report = try XCTUnwrap(dailyReport(env, on: dayBefore))
        XCTAssertEqual(try versions(env, reportId: report.id).count, 1)

        XCTAssertEqual(try env.repo.importActivities([event(occurredAt: kst(2026, 10, 20, 12))],
                                                     connection: connection()), 1)
        let affected = DateRange(start: dayBefore, endExclusive: today)
        let firstCreated = try await env.reevaluateScheduledReports(affecting: affected)
        XCTAssertEqual(firstCreated, 1)

        let versionsAfterFirst = try versions(env, reportId: report.id)
        XCTAssertEqual(versionsAfterFirst.count, 2)
        let aiCallsAfterFirst = provider.runCount
        XCTAssertGreaterThan(aiCallsAfterFirst, 0)

        let secondCreated = try await env.reevaluateScheduledReports(affecting: affected)
        XCTAssertEqual(secondCreated, 0)
        XCTAssertEqual(try versions(env, reportId: report.id).count, 2,
                       "원본 digest가 같으면 새 버전을 만들지 않는다")
        XCTAssertEqual(provider.runCount, aiCallsAfterFirst,
                       "원본이 그대로면 AI를 다시 호출하지 않는다")
    }

    func testConfirmedAndEditedVersionsPreserved() async throws {
        let now = kst(2026, 10, 21, 10)

        // 확정본은 덮어쓰지 않고 그 위에 새 버전을 만든다.
        do {
            let env = try makeEnv(now: now)
            let todayDate = env.calendar.workDate(of: now)
            let dayBefore = env.calendar.adding(days: -1, to: todayDate)
            _ = try env.tasks.captureMemo(body: "어제 기록", workDate: dayBefore)
            _ = try await env.runStartupCatchUp()
            let report = try XCTUnwrap(dailyReport(env, on: dayBefore))
            let v1 = try XCTUnwrap(try versions(env, reportId: report.id).last)
            _ = try env.reports.confirm(versionId: v1.id)

            XCTAssertEqual(try env.repo.importActivities([event(occurredAt: kst(2026, 10, 20, 12))],
                                                         connection: connection()), 1)
            let created = try await env.reevaluateScheduledReports(
                affecting: DateRange(start: dayBefore, endExclusive: todayDate))
            XCTAssertEqual(created, 1)

            let all = try versions(env, reportId: report.id)
            XCTAssertEqual(all.count, 2)
            let confirmed = try XCTUnwrap(all.first { $0.id == v1.id })
            XCTAssertEqual(confirmed.state, .confirmed, "확정본은 불변")
            XCTAssertEqual(confirmed.content, v1.content)
            let latest = try XCTUnwrap(all.last)
            XCTAssertEqual(latest.basedOnVersionId, v1.id, "확정본 위에 새 버전을 만든다")
            XCTAssertEqual(latest.state, .draft)
        }

        // 편집본도 보존하고 그 위에 새 버전을 만든다.
        do {
            let env = try makeEnv(now: now.addingTimeInterval(3_600))
            let todayDate = env.calendar.workDate(of: now)
            let dayBefore = env.calendar.adding(days: -1, to: todayDate)
            _ = try env.tasks.captureMemo(body: "어제 기록", workDate: dayBefore)
            _ = try await env.runStartupCatchUp()
            let report = try XCTUnwrap(dailyReport(env, on: dayBefore))
            let v1 = try XCTUnwrap(try versions(env, reportId: report.id).last)
            let edited = try env.reports.edit(versionId: v1.id, content: "사용자가 다듬은 초안")

            XCTAssertEqual(try env.repo.importActivities([event(occurredAt: kst(2026, 10, 20, 12))],
                                                         connection: connection()), 1)
            let created = try await env.reevaluateScheduledReports(
                affecting: DateRange(start: dayBefore, endExclusive: todayDate))
            XCTAssertEqual(created, 1)

            let all = try versions(env, reportId: report.id)
            let kept = try XCTUnwrap(all.first { $0.id == edited.id })
            XCTAssertEqual(kept.state, .edited)
            XCTAssertEqual(kept.content, "사용자가 다듬은 초안")
            XCTAssertEqual(try XCTUnwrap(all.last).basedOnVersionId, edited.id)
        }
    }

    func testEarliestDateMovedEarlierPlansMissingDays() async throws {
        let now = kst(2026, 10, 21, 10)
        let env = try makeEnv(now: now)
        let today = env.calendar.workDate(of: now)
        let dayBefore = env.calendar.adding(days: -1, to: today)
        _ = try env.tasks.captureMemo(body: "어제 기록", workDate: dayBefore)
        _ = try await env.runStartupCatchUp()

        let tenDaysAgo = env.calendar.adding(days: -10, to: today)
        XCTAssertNil(try env.repo.scheduledJob(type: .dailyClose, periodKey: tenDaysAgo.iso))
        XCTAssertEqual(try env.repo.importActivities(
            [event(id: "gh-10", occurredAt: kst(2026, 10, 11, 12))],
            connection: connection()), 1)

        let created = try await env.reevaluateScheduledReports(
            affecting: DateRange(start: tenDaysAgo,
                                 endExclusive: env.calendar.adding(days: 1, to: tenDaysAgo)))
        XCTAssertEqual(created, 0, "catch-up이 이미 만든 기간은 digest가 같아 새 버전이 없다")
        let earlier = try XCTUnwrap(env.repo.scheduledJob(type: .dailyClose,
                                                          periodKey: tenDaysAgo.iso))
        XCTAssertEqual(earlier.state, .succeeded)
        let earlierReport = try XCTUnwrap(dailyReport(env, on: tenDaysAgo))
        XCTAssertFalse(try versions(env, reportId: earlierReport.id).isEmpty)

        // 92일 상한 밖(120일 전) 기록은 새 작업/리포트를 만들지 않는다.
        let tooOld = env.calendar.adding(days: -120, to: today)
        XCTAssertEqual(try env.repo.importActivities(
            [event(id: "gh-120", occurredAt: kst(2026, 6, 23, 12))],
            connection: connection()), 1)
        _ = try await env.reevaluateScheduledReports(
            affecting: DateRange(start: tooOld,
                                 endExclusive: env.calendar.adding(days: 1, to: tooOld)))

        let floor = env.calendar.adding(days: -92, to: today)
        let dailyKeys = try env.repo.scheduledJobs(states: [.succeeded])
            .filter { $0.type == .dailyClose }
            .compactMap { WorkDate($0.periodKey) }
        XCTAssertFalse(dailyKeys.contains(tooOld))
        XCTAssertTrue(dailyKeys.allSatisfy { $0 >= floor },
                      "dailyClose는 92일 창 안에서만: \(dailyKeys.map(\.iso))")
        let tooOldReport = try dailyReport(env, on: tooOld)
        XCTAssertNil(tooOldReport)
    }

    /// 가져오기마다 92일 catch-up 계획을 다시 돌리면 실패로 남은 작업을 매번 재시도한다.
    /// 가장 이른 기록 업무일이 그대로인 동안에는 재계획을 건너뛰고, 앞당겨졌을 때만 다시 계획한다.
    func testUnchangedEarliestDateDoesNotReplayCatchUpPlan() async throws {
        let now = kst(2026, 10, 21, 10)
        let env = try makeEnv(now: now)
        let today = env.calendar.workDate(of: now)
        let dayBefore = env.calendar.adding(days: -1, to: today)
        _ = try env.tasks.captureMemo(body: "어제 기록", workDate: dayBefore)
        _ = try await env.runStartupCatchUp()

        // 최근 92일 안에 실패로 남은 작업(시도 1회). 재계획이 돌면 실행기가 pending/failed에서 다시 집어 간다.
        let threeDaysAgo = env.calendar.adding(days: -3, to: today)
        XCTAssertTrue(try env.repo.insertScheduledJobIfAbsent(ScheduledJob(
            id: env.repo.ids.make(), type: .dailyClose, periodKey: threeDaysAgo.iso,
            scheduledFor: kst(2026, 10, 18, 23), state: .failed, attempts: 1)))

        // 같은 업무일에 도착한 가져오기: 가장 이른 기록 업무일(D-1)이 그대로라 재계획하지 않는다.
        XCTAssertEqual(try env.repo.importActivities(
            [event(id: "gh-1", occurredAt: kst(2026, 10, 20, 12))], connection: connection()), 1)
        _ = try await env.reevaluateScheduledReports(
            affecting: DateRange(start: dayBefore, endExclusive: today))
        var failed = try XCTUnwrap(env.repo.scheduledJob(type: .dailyClose, periodKey: threeDaysAgo.iso))
        XCTAssertEqual(failed.state, .failed, "재계획이 없으면 실패 작업을 다시 시도하지 않는다")
        XCTAssertEqual(failed.attempts, 1)

        // 가장 이른 기록 업무일이 앞당겨지면 그때만 다시 계획해 실패 작업을 재시도한다.
        let tenDaysAgo = env.calendar.adding(days: -10, to: today)
        XCTAssertEqual(try env.repo.importActivities(
            [event(id: "gh-10", occurredAt: kst(2026, 10, 11, 12))], connection: connection()), 1)
        _ = try await env.reevaluateScheduledReports(
            affecting: DateRange(start: tenDaysAgo,
                                 endExclusive: env.calendar.adding(days: 1, to: tenDaysAgo)))
        failed = try XCTUnwrap(env.repo.scheduledJob(type: .dailyClose, periodKey: threeDaysAgo.iso))
        XCTAssertEqual(failed.attempts, 2, "가장 이른 기록이 앞당겨지면 재계획이 실패 작업을 다시 시도한다")
        XCTAssertEqual(failed.state, .succeeded)
    }

    /// 월요일 알림 시각(기본 09:00) 전에 앱을 켜고 그날 가져오기가 도착하면, 알림 시각이 지난 뒤의
    /// 재평가가 그 주 월요일 검토 작업을 계획·실행해야 한다. 계획 조건이 "가장 이른 기록 업무일이
    /// 앞당겨졌는가"뿐이면 이 작업은 다음 날/다음 실행까지 누락된다.
    func testMondayReviewPlannedWhenReminderTimePasses() async throws {
        let mondayMorning = kst(2026, 10, 19, 8)        // 월요일 08:00 KST (알림 09:00 이전)
        let clock = FixedClock(mondayMorning)
        let env = try makeEnv(now: mondayMorning, clock: clock)
        let monday = env.calendar.workDate(of: mondayMorning)
        let sunday = env.calendar.adding(days: -1, to: monday)
        _ = try env.tasks.captureMemo(body: "일요일 기록", workDate: sunday)
        _ = try await env.runStartupCatchUp()

        let weekKey = env.periods.periodKey(.weekly, containing: monday)
        XCTAssertNil(try env.repo.scheduledJob(type: .mondayReview, periodKey: weekKey),
                     "알림 시각 전에는 월요일 검토 작업을 계획하지 않는다")

        // 알림 시각이 지난 뒤 같은 업무일에 도착한 가져오기 → 지금 due인 작업을 계획·실행한다.
        clock.set(kst(2026, 10, 19, 10))
        _ = try await env.reevaluateScheduledReports(
            affecting: DateRange(start: sunday, endExclusive: monday))

        let job = try XCTUnwrap(env.repo.scheduledJob(type: .mondayReview, periodKey: weekKey))
        XCTAssertEqual(job.state, .succeeded, "월요일 검토 작업을 실행까지 마친다")
        XCTAssertEqual(job.scheduledFor, kst(2026, 10, 19, 9))
        let submission = try env.repo.report(family: .submission, periodType: .weekly,
                                             periodKey: monday.iso)
        XCTAssertNotNil(submission, "월요일 검토 작업은 제출용 주간보고 초안을 만든다")
    }

    func testAIOnlyWithinRecentDays() async throws {
        let now = kst(2026, 10, 21, 10)
        let provider = MockAIProvider()
        let env = try makeEnv(now: now, aiProvider: provider)
        let today = env.calendar.workDate(of: now)
        let dayBefore = env.calendar.adding(days: -1, to: today)
        _ = try env.tasks.captureMemo(body: "어제 기록", workDate: dayBefore)
        _ = try await env.runStartupCatchUp()

        let tenDaysAgo = env.calendar.adding(days: -10, to: today)
        XCTAssertEqual(try env.repo.importActivities(
            [event(id: "gh-10", occurredAt: kst(2026, 10, 11, 12))],
            connection: connection()), 1)
        _ = try await env.reevaluateScheduledReports(
            affecting: DateRange(start: tenDaysAgo,
                                 endExclusive: env.calendar.adding(days: 1, to: tenDaysAgo)))

        let cutoff = env.calendar.adding(days: -7, to: today)
        let payloads = try payloadFacts(provider)
        XCTAssertFalse(payloads.isEmpty)
        // AI 사용 여부는 기간 종류가 아니라 작업의 scheduledFor로 결정된다. daily 작업의
        // scheduledFor는 대상일 다음 날이므로, daily 기간 시작도 cutoff 이후여야 한다.
        let dailyStarts = payloads.filter { $0.0 == .daily }.map(\.1)
        XCTAssertFalse(dailyStarts.isEmpty)
        XCTAssertTrue(dailyStarts.allSatisfy { $0 >= cutoff },
                      "AI daily 입력은 최근 7일 작업에만: \(dailyStarts.map(\.iso))")
        XCTAssertFalse(payloads.contains { $0.1 == tenDaysAgo && $0.0 == .daily },
                       "10일 전 daily는 결정적 초안이어야 한다")

        let oldReport = try XCTUnwrap(dailyReport(env, on: tenDaysAgo))
        let oldVersion = try XCTUnwrap(try versions(env, reportId: oldReport.id).last)
        XCTAssertEqual(oldVersion.generator, "deterministic")
    }

    // MARK: - 2. 조정자: catch-up과 가져오기 직렬화

    @MainActor
    func testImportsBeforeCatchUpAreMergedAndReevaluatedOnceAfterCatchUp() async throws {
        let gate = CatchUpGate()
        var seen: [DateRange] = []
        let coordinator = ScheduledReportCoordinator(
            catchUp: { await gate.wait() },
            reevaluate: { seen.append($0) })

        let first = DateRange(start: WorkDate("2026-10-01")!, endExclusive: WorkDate("2026-10-02")!)
        let second = DateRange(start: WorkDate("2026-10-05")!, endExclusive: WorkDate("2026-10-06")!)
        await coordinator.importsLanded(first)
        await coordinator.importsLanded(second)
        XCTAssertEqual(coordinator.phase, .notStarted)
        XCTAssertTrue(seen.isEmpty, "catch-up 전에는 재평가하지 않는다")

        let task = Task { try await coordinator.runCatchUp() }
        await gate.waitUntilStarted()
        XCTAssertEqual(coordinator.phase, .running)
        XCTAssertTrue(seen.isEmpty, "catch-up이 끝나기 전에는 재평가하지 않는다")

        await gate.open()
        try await task.value
        XCTAssertEqual(coordinator.phase, .finished)
        XCTAssertEqual(seen, [DateRange(start: WorkDate("2026-10-01")!,
                                        endExclusive: WorkDate("2026-10-06")!)],
                       "catch-up 전 가져오기는 버리지 않고 보류했다가 합집합 한 번으로 재평가한다")
        XCTAssertNil(coordinator.lastError)
    }

    /// catch-up이 실패해도 보류해 둔 가져오기 구간은 잃지 않는다. 호출자에게 오류를 전달하기 전에
    /// 정확히 한 번 재평가하고, 그 뒤 phase는 finished로 남아 다음 가져오기가 바로 실행된다.
    @MainActor
    func testCatchUpFailureStillReevaluatesMergedRangeOnce() async throws {
        var seen: [DateRange] = []
        let landed = DateRange(start: WorkDate("2026-10-01")!, endExclusive: WorkDate("2026-10-02")!)
        let coordinator = ScheduledReportCoordinator(
            catchUp: { throw WorkLogError.storage("catch-up 실패") },
            reevaluate: { seen.append($0) })

        await coordinator.importsLanded(landed)
        XCTAssertTrue(seen.isEmpty, "catch-up 전에는 재평가하지 않는다")

        do {
            try await coordinator.runCatchUp()
            XCTFail("catch-up 오류는 호출자에게 전달해야 한다")
        } catch {
            XCTAssertTrue(String(describing: error).contains("catch-up 실패"))
        }

        XCTAssertEqual(coordinator.phase, .finished)
        XCTAssertEqual(seen, [landed], "catch-up이 실패해도 보류한 구간을 정확히 한 번 재평가한다")
        XCTAssertNil(coordinator.lastError, "재평가 자체는 성공했으므로 오류가 아니다")
    }

    @MainActor
    func testCancellationStopsFurtherReevaluationsAndIsNotRecordedAsError() async throws {
        let first = DateRange(start: WorkDate("2026-10-01")!, endExclusive: WorkDate("2026-10-02")!)
        let second = DateRange(start: WorkDate("2026-10-05")!, endExclusive: WorkDate("2026-10-06")!)
        let third = DateRange(start: WorkDate("2026-10-07")!, endExclusive: WorkDate("2026-10-08")!)
        var seen: [DateRange] = []
        var worker: Task<Void, Never>?
        let coordinator = ScheduledReportCoordinator(
            catchUp: {},
            reevaluate: { range in
                seen.append(range)
                worker?.cancel()
            })
        try await coordinator.runCatchUp()

        // 첫 재평가가 작업을 취소한다. 조정자는 남은 구간을 시작하지 않는다.
        worker = Task {
            await coordinator.importsLanded(first)
            await coordinator.importsLanded(second)
        }
        await worker?.value
        XCTAssertEqual(seen, [first], "취소 뒤에는 다음 구간을 시작하지 않는다")
        XCTAssertNil(coordinator.lastError, "취소는 오류가 아니다")

        // 취소로 중단된 구간은 버리지 않고 보류했다가 다음 가져오기에서 이어서 재평가한다.
        // (새 가져오기 구간을 먼저 평가하고, 보류해 둔 구간을 바로 이어서 한 번 더 평가한다.)
        await coordinator.importsLanded(third)
        XCTAssertEqual(seen.count, 2, "보류 구간과 새 구간을 합쳐 재평가한다")
        let resumed = seen[1]
        XCTAssertLessThanOrEqual(resumed.start, first.start,
                                 "중단된 구간의 시작을 포함해야 한다: \(resumed)")
        XCTAssertGreaterThanOrEqual(resumed.endExclusive, first.endExclusive,
                                    "중단된 구간의 끝을 포함해야 한다: \(resumed)")
        XCTAssertLessThanOrEqual(resumed.start, second.start,
                                 "취소 중 보류된 다음 구간도 함께 이어받는다: \(resumed)")
        XCTAssertGreaterThanOrEqual(resumed.endExclusive, second.endExclusive,
                                    "취소 중 보류된 다음 구간도 함께 이어받는다: \(resumed)")
    }

    @MainActor
    func testReevaluationFailureIsReportedToOnError() async throws {
        var reported: [String] = []
        let coordinator = ScheduledReportCoordinator(
            catchUp: {},
            reevaluate: { _ in throw WorkLogError.storage("재평가 실패") },
            onError: { reported.append(String(describing: $0)) })
        try await coordinator.runCatchUp()
        await coordinator.importsLanded(DateRange(start: WorkDate("2026-10-01")!,
                                                  endExclusive: WorkDate("2026-10-02")!))
        XCTAssertEqual(reported.count, 1, "실패는 onError로 한 번 알린다")
        XCTAssertTrue(reported[0].contains("재평가 실패"))
        XCTAssertNotNil(coordinator.lastError)
    }

    @MainActor
    func testImportsDuringCatchUpMergeIntoOneReevaluation() async throws {
        let gate = CatchUpGate()
        var seen: [DateRange] = []
        let coordinator = ScheduledReportCoordinator(
            catchUp: { await gate.wait() },
            reevaluate: { seen.append($0) })

        let task = Task { try await coordinator.runCatchUp() }
        await gate.waitUntilStarted()
        XCTAssertEqual(coordinator.phase, .running)

        let first = DateRange(start: WorkDate("2026-10-01")!, endExclusive: WorkDate("2026-10-02")!)
        let second = DateRange(start: WorkDate("2026-10-05")!, endExclusive: WorkDate("2026-10-06")!)
        await coordinator.importsLanded(first)
        await coordinator.importsLanded(second)
        XCTAssertTrue(seen.isEmpty, "catch-up이 끝나기 전에는 재평가하지 않는다")

        await gate.open()
        try await task.value
        XCTAssertEqual(coordinator.phase, .finished)
        XCTAssertEqual(seen, [DateRange(start: WorkDate("2026-10-01")!,
                                        endExclusive: WorkDate("2026-10-06")!)],
                       "겹치는 구간은 합집합으로 한 번만 재평가한다")
    }

    @MainActor
    func testImportsAfterCatchUpReevaluatesImmediately() async throws {
        var seen: [DateRange] = []
        let coordinator = ScheduledReportCoordinator(
            catchUp: {},
            reevaluate: { seen.append($0) })
        try await coordinator.runCatchUp()
        XCTAssertEqual(coordinator.phase, .finished)

        let landed = DateRange(start: WorkDate("2026-10-03")!, endExclusive: WorkDate("2026-10-04")!)
        await coordinator.importsLanded(landed)
        XCTAssertEqual(seen, [landed])
    }

    @MainActor
    func testReevaluationErrorCapturedAndLaterImportRetries() async throws {
        var attempts = 0
        var seen: [DateRange] = []
        var shouldFail = true
        let coordinator = ScheduledReportCoordinator(
            catchUp: {},
            reevaluate: { range in
                seen.append(range)
                attempts += 1
                if shouldFail { throw WorkLogError.storage("재평가 실패") }
            })
        try await coordinator.runCatchUp()

        await coordinator.importsLanded(DateRange(start: WorkDate("2026-10-01")!,
                                                  endExclusive: WorkDate("2026-10-02")!))
        XCTAssertEqual(attempts, 1)
        XCTAssertNotNil(coordinator.lastError, "오류는 lastError로 노출하고 앱을 중단시키지 않는다")

        shouldFail = false
        await coordinator.importsLanded(DateRange(start: WorkDate("2026-10-02")!,
                                                  endExclusive: WorkDate("2026-10-03")!))
        XCTAssertEqual(attempts, 2, "다음 가져오기에서 자연히 재시도한다")
        XCTAssertNil(coordinator.lastError)
        XCTAssertEqual(seen.last, DateRange(start: WorkDate("2026-10-01")!, endExclusive: WorkDate("2026-10-03")!))
    }

    /// 가져오기 실패·취소 시에는 importsLanded가 호출되지 않으므로 재평가도 없다.
    /// 성공한 예약 작업은 succeeded로 남고, 다음 성공 가져오기가 그 기간을 재평가한다.
    @MainActor
    func testNoImportMeansNoReevaluationAfterFailedOrCancelledCollection() async throws {
        var calls = 0
        let coordinator = ScheduledReportCoordinator(
            catchUp: {},
            reevaluate: { _ in calls += 1 })
        try await coordinator.runCatchUp()
        XCTAssertEqual(coordinator.phase, .finished)
        XCTAssertEqual(calls, 0)
    }

    // MARK: - helpers

    /// catch-up이 시작되었음을 알리고, open() 전까지 매달리는 게이트.
    private actor CatchUpGate {
        private var opened = false
        private var started = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var openContinuation: CheckedContinuation<Void, Never>?

        func wait() async {
            started = true
            let waiters = startWaiters
            startWaiters = []
            for waiter in waiters { waiter.resume() }
            if opened { return }
            await withCheckedContinuation { openContinuation = $0 }
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func open() {
            opened = true
            openContinuation?.resume()
            openContinuation = nil
        }
    }
}
