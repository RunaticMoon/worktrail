import XCTest
@testable import WorkLogCore

/// PERF-03 / REP-T05~T08: 평가 기간 제안·저장·확정 연결.
final class EvaluationPeriodServiceTests: XCTestCase {

    private func date(_ iso: String) -> WorkDate { WorkDate(iso)! }

    private func makeSetup(now: Date = Date(timeIntervalSince1970: 1_790_000_000))
        throws -> (WorkRepository, EvaluationPeriodService, FixedClock) {
        let clock = FixedClock(now)
        let repo = try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator())
        return (repo, EvaluationPeriodService(repo: repo), clock)
    }

    // MARK: 6 / REP-T05 — 첫 평가는 시작일 필수, range는 [start, end+1)

    func testFirstPeriodRequiresStartAndBuildsRange() throws {
        let (_, service, _) = try makeSetup()

        XCTAssertThrowsError(try service.propose(start: nil, endInclusive: date("2026-09-30"))) { error in
            guard case WorkLogError.validation = error else {
                return XCTFail("validation 오류 기대: \(error)")
            }
        }

        let proposal = try service.propose(start: date("2026-01-01"), endInclusive: date("2026-09-30"))
        XCTAssertEqual(proposal.range,
                       DateRange(start: date("2026-01-01"), endExclusive: date("2026-10-01")))
        XCTAssertNil(proposal.previousPeriodId)
        XCTAssertTrue(proposal.warnings.isEmpty)
    }

    // MARK: 7 / REP-T06 — 다음 평가는 직전 확정 종료 다음 날, previousPeriodId 설정

    func testNextPeriodDerivesStartFromConfirmedEnd() throws {
        let (_, service, _) = try makeSetup()
        let (first, _) = try service.create(start: date("2025-10-01"), endInclusive: date("2026-09-30"))
        try service.markConfirmed(periodId: first.id, reportVersionId: "rv-1")

        let proposal = try service.propose(start: nil, endInclusive: date("2027-09-30"))
        XCTAssertEqual(proposal.range,
                       DateRange(start: date("2026-10-01"), endExclusive: date("2027-10-01")))
        XCTAssertEqual(proposal.previousPeriodId, first.id)

        let (second, _) = try service.create(start: nil, endInclusive: date("2027-09-30"))
        XCTAssertEqual(second.range,
                       DateRange(start: date("2026-10-01"), endExclusive: date("2027-10-01")))
        XCTAssertEqual(second.previousPeriodId, first.id)
    }

    // MARK: 8 / REP-T07 — 같은 기간 새 버전 확정 → range·다음 시작일 불변

    func testNewVersionKeepsRangeAndNextStart() throws {
        let (repo, service, _) = try makeSetup()
        let (first, _) = try service.create(start: date("2025-10-01"), endInclusive: date("2026-09-30"))
        try service.markConfirmed(periodId: first.id, reportVersionId: "rv-1")
        let before = try service.propose(start: nil, endInclusive: date("2027-09-30"))

        try service.markConfirmed(periodId: first.id, reportVersionId: "rv-2")

        let stored = try XCTUnwrap(try repo.evaluationPeriod(id: first.id))
        XCTAssertEqual(stored.range, first.range)
        XCTAssertEqual(stored.confirmedReportVersionId, "rv-2")

        let after = try service.propose(start: nil, endInclusive: date("2027-09-30"))
        XCTAssertEqual(after.range, before.range)
        XCTAssertEqual(after.previousPeriodId, before.previousPeriodId)
    }

    // MARK: 9 / REP-T08 — clock이 종료일보다 훨씬 뒤여도 range 끝 = endInclusive+1

    func testClockDoesNotExtendRange() throws {
        let farFuture = Date(timeIntervalSince1970: 1_900_000_000) // 2030년대
        let (_, service, clock) = try makeSetup(now: farFuture)

        let (period, _) = try service.create(start: date("2026-01-01"), endInclusive: date("2026-09-30"))
        XCTAssertEqual(period.range.endExclusive, date("2026-10-01"))
        XCTAssertEqual(period.createdAt, clock.now())
        XCTAssertEqual(clock.now(), farFuture)
    }

    // MARK: 10 — 확정 안 된 기간만 있으면 nextStart 없음 → start 필수

    func testUnconfirmedPeriodsDoNotProvideStart() throws {
        let (repo, service, _) = try makeSetup()
        try repo.insertEvaluationPeriod(EvaluationPeriod(
            id: "u1",
            range: DateRange(start: date("2025-10-01"), endExclusive: date("2026-10-01")),
            createdAt: Date(timeIntervalSince1970: 0)))

        XCTAssertThrowsError(try service.propose(start: nil, endInclusive: date("2027-09-30"))) { error in
            guard case WorkLogError.validation = error else {
                return XCTFail("validation 오류 기대: \(error)")
            }
        }
    }

    // MARK: 11 — 겹치는 start 지정 → 겹침 경고

    func testOverlappingRangeProducesWarning() throws {
        let (_, service, _) = try makeSetup()
        let (first, _) = try service.create(start: date("2025-10-01"), endInclusive: date("2026-09-30"))
        try service.markConfirmed(periodId: first.id, reportVersionId: "rv-1")

        let proposal = try service.propose(start: date("2026-06-01"), endInclusive: date("2027-05-31"))
        XCTAssertEqual(proposal.warnings.count, 1)
        XCTAssertTrue(proposal.warnings[0].contains("겹"))
    }

    // MARK: 12 — 저장 왕복

    func testStoredPeriodRoundTrip() throws {
        let (repo, service, _) = try makeSetup()
        let (period, warnings) = try service.create(start: date("2026-01-01"), endInclusive: date("2026-09-30"))
        XCTAssertTrue(warnings.isEmpty)

        let loaded = try XCTUnwrap(try repo.evaluationPeriod(id: period.id))
        XCTAssertEqual(loaded, period)
        XCTAssertEqual(try repo.evaluationPeriods(), [period])
    }

    // MARK: 존재하지 않는 id 연결 → notFound

    func testMarkConfirmedMissingPeriodThrowsNotFound() throws {
        let (_, service, _) = try makeSetup()
        XCTAssertThrowsError(try service.markConfirmed(periodId: "nope", reportVersionId: "rv-1")) { error in
            guard case WorkLogError.notFound = error else {
                return XCTFail("notFound 오류 기대: \(error)")
            }
        }
    }
}
