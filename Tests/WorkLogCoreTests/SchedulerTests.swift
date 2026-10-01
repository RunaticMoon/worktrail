import XCTest
@testable import WorkLogCore

private actor CallCounter {
    private var counts: [String: Int] = [:]
    func increment(_ key: String) { counts[key, default: 0] += 1 }
    func total() -> Int { counts.values.reduce(0, +) }
    func snapshot() -> [String: Int] { counts }
}

final class SchedulerTests: XCTestCase {

    private func kst(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        return cal.date(from: c)!
    }

    private func date(_ iso: String) -> WorkDate { WorkDate(iso)! }

    private func makeRunner(now: Date, since: WorkDate,
                            settings: AppSettings = AppSettings()) throws -> (SchedulerRunner, WorkRepository) {
        let repo = try WorkRepository.inMemory(clock: FixedClock(now), ids: SequentialIDGenerator(),
                                               calendar: WorkCalendar())
        let runner = SchedulerRunner(repo: repo, periods: Periods(), clock: FixedClock(now),
                                     settings: settings, since: since)
        return (runner, repo)
    }

    // MARK: SCH-T01 — since 당일 자정 직후에는 그날 dailyClose 하나

    func testDueDailyCloseAtNextMidnight() {
        let now = kst(2026, 10, 6, 0, 0, 5)
        let jobs = SchedulePlanner.dueJobs(now: now, since: date("2026-10-05"), existingKeys: [],
                                           settings: AppSettings(), periods: Periods())
        let dailies = jobs.filter { $0.type == .dailyClose }
        XCTAssertEqual(dailies.count, 1)
        XCTAssertEqual(dailies.first?.periodKey, "2026-10-05")
        XCTAssertEqual(dailies.first?.range, Periods().day(date("2026-10-05")))
        XCTAssertEqual(dailies.first?.scheduledFor, kst(2026, 10, 6, 0, 0, 0))
        // 월요일 검토도 실행 시점이 지났다.
        XCTAssertTrue(jobs.contains { $0.type == .mondayReview })
    }

    // MARK: SCH-T02 — 며칠치 누락 daily를 날짜순으로, 늦은 복구 판정

    func testMissedDailyJobsInDateOrderAndLate() {
        let now = kst(2026, 10, 5, 10, 0, 0)
        let jobs = SchedulePlanner.dueJobs(now: now, since: date("2026-10-01"), existingKeys: [],
                                           settings: AppSettings(), periods: Periods())
        let dailies = jobs.filter { $0.type == .dailyClose }
        XCTAssertEqual(dailies.map { $0.periodKey },
                       ["2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04"])
        for job in dailies {
            XCTAssertLessThan(job.scheduledFor, now)
            XCTAssertTrue(SchedulePlanner.isLate(scheduledFor: job.scheduledFor, executedAt: now))
        }
        // 전체가 scheduledFor 오름차순.
        for i in 1..<jobs.count {
            XCTAssertLessThanOrEqual(jobs[i - 1].scheduledFor, jobs[i].scheduledFor)
        }
    }

    // MARK: SCH-T03 — 두 번 실행해도 작업당 한 번, 행 중복 없음

    func testRunDueIsIdempotentPerJob() async throws {
        let now = kst(2026, 10, 6, 0, 0, 5)
        let (runner, repo) = try makeRunner(now: now, since: date("2026-10-05"))
        let counter = CallCounter()
        let handler: (DueJob) async throws -> Void = { job in
            await counter.increment(SchedulePlanner.key(for: job.type, periodKey: job.periodKey))
        }

        let first = try await runner.runDue(handler: handler)
        XCTAssertFalse(first.isEmpty)
        let second = try await runner.runDue(handler: handler)
        XCTAssertTrue(second.isEmpty)

        let counts = await counter.snapshot()
        XCTAssertEqual(Set(counts.values), [1]) // 작업당 정확히 1회
        XCTAssertEqual(counts.count, first.count)

        let all = try repo.scheduledJobs()
        XCTAssertEqual(Set(all.map { SchedulePlanner.key(for: $0.type, periodKey: $0.periodKey) }).count, all.count)
        XCTAssertEqual(all.count, first.count)
        XCTAssertTrue(all.allSatisfy { $0.state == .succeeded })
    }

    // MARK: SCH-T03 — 실패는 failed로 남고 maxAttempts까지 재시도

    func testRunDueFailureRetriesThenStops() async throws {
        let now = kst(2026, 10, 6, 0, 0, 5)
        let (runner, repo) = try makeRunner(now: now, since: date("2026-10-05"))
        let counter = CallCounter()
        let handler: (DueJob) async throws -> Void = { job in
            await counter.increment(SchedulePlanner.key(for: job.type, periodKey: job.periodKey))
            throw WorkLogError.storage("boom")
        }

        _ = try await runner.runDue(maxAttempts: 3, handler: handler)
        let failedOnce = try repo.scheduledJobs(states: [.failed])
        XCTAssertFalse(failedOnce.isEmpty)
        XCTAssertTrue(failedOnce.allSatisfy { $0.attempts == 1 && $0.lastError != nil })

        _ = try await runner.runDue(maxAttempts: 3, handler: handler)
        _ = try await runner.runDue(maxAttempts: 3, handler: handler)
        let callsAfterMax = await counter.total()

        // maxAttempts 도달 후에는 더 실행하지 않는다.
        let noMore = try await runner.runDue(maxAttempts: 3, handler: handler)
        XCTAssertTrue(noMore.isEmpty)
        let totalAfterNoMore = await counter.total()
        XCTAssertEqual(totalAfterNoMore, callsAfterMax)

        let failed = try repo.scheduledJobs(states: [.failed])
        XCTAssertTrue(failed.allSatisfy { $0.state == .failed && $0.attempts == 3 && $0.lastError != nil })
    }

    // MARK: SCH-T03 — running으로 남은 행은 되돌려 재실행

    func testResetStaleRunningAndRerun() async throws {
        let now = kst(2026, 10, 6, 0, 0, 5)
        let (runner, repo) = try makeRunner(now: now, since: date("2026-10-05"))

        let stale = ScheduledJob(id: "stale-1", type: .dailyClose, periodKey: "2026-10-05",
                                 scheduledFor: kst(2026, 10, 6, 0, 0, 0), state: .running, attempts: 1)
        XCTAssertTrue(try repo.insertScheduledJobIfAbsent(stale))
        // UNIQUE(type, period_key) — 중복은 무시된다.
        XCTAssertFalse(try repo.insertScheduledJobIfAbsent(ScheduledJob(
            id: "stale-2", type: .dailyClose, periodKey: "2026-10-05",
            scheduledFor: kst(2026, 10, 6, 0, 0, 0))))

        let counter = CallCounter()
        let result = try await runner.runDue { job in
            await counter.increment(SchedulePlanner.key(for: job.type, periodKey: job.periodKey))
        }
        let daily = result.first { $0.type == .dailyClose && $0.periodKey == "2026-10-05" }
        XCTAssertEqual(daily?.state, .succeeded)
        XCTAssertEqual(daily?.attempts, 2)

        let keys = try repo.scheduledJobKeys()
        let all = try repo.scheduledJobs()
        XCTAssertEqual(keys.count, all.count) // 중복 행 없음
    }

    // MARK: 월요일 09:00 경계

    func testMondayReviewAroundReminderTime() {
        let before = SchedulePlanner.dueJobs(now: kst(2026, 10, 5, 8, 59, 59), since: date("2026-10-05"),
                                             existingKeys: [], settings: AppSettings(), periods: Periods())
        XCTAssertFalse(before.contains { $0.type == .mondayReview })

        let after = SchedulePlanner.dueJobs(now: kst(2026, 10, 5, 9, 0, 0), since: date("2026-10-05"),
                                            existingKeys: [], settings: AppSettings(), periods: Periods())
        let reviews = after.filter { $0.type == .mondayReview }
        XCTAssertEqual(reviews.count, 1)
        XCTAssertEqual(reviews.first?.periodKey, "2026-W41")
        XCTAssertEqual(reviews.first?.range,
                       DateRange(start: date("2026-09-28"), endExclusive: date("2026-10-05")))
        XCTAssertEqual(reviews.first?.scheduledFor, kst(2026, 10, 5, 9, 0, 0))
    }

    // MARK: range 복원 — (type, periodKey) → range

    func testRangeReconstructionFromPeriodKey() {
        let periods = Periods()
        XCTAssertEqual(SchedulePlanner.range(for: .dailyClose, periodKey: "2026-10-05", periods: periods),
                       DateRange(start: date("2026-10-05"), endExclusive: date("2026-10-06")))
        XCTAssertEqual(SchedulePlanner.range(for: .weeklyPerformance, periodKey: "2026-W41", periods: periods),
                       DateRange(start: date("2026-10-05"), endExclusive: date("2026-10-12")))
        XCTAssertEqual(SchedulePlanner.range(for: .mondayReview, periodKey: "2026-W41", periods: periods),
                       DateRange(start: date("2026-09-28"), endExclusive: date("2026-10-05")))
        XCTAssertEqual(SchedulePlanner.range(for: .monthlyPerformance, periodKey: "2026-10", periods: periods),
                       DateRange(start: date("2026-10-01"), endExclusive: date("2026-11-01")))
        XCTAssertEqual(SchedulePlanner.range(for: .quarterlyPerformance, periodKey: "2026-Q4", periods: periods),
                       DateRange(start: date("2026-10-01"), endExclusive: date("2027-01-01")))
        XCTAssertNil(SchedulePlanner.range(for: .backup, periodKey: "x", periods: periods))
    }

    // MARK: isLate 여유(grace)

    func testIsLateGrace() {
        let scheduled = kst(2026, 10, 5, 0, 0, 0)
        XCTAssertFalse(SchedulePlanner.isLate(scheduledFor: scheduled, executedAt: scheduled.addingTimeInterval(900)))
        XCTAssertTrue(SchedulePlanner.isLate(scheduledFor: scheduled, executedAt: scheduled.addingTimeInterval(901)))
    }
}
