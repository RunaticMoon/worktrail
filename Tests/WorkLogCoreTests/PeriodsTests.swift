import XCTest
@testable import WorkLogCore

final class PeriodsTests: XCTestCase {

    private let periods = Periods()

    // KST 기준 순간 생성 헬퍼.
    private func kst(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        return cal.date(from: c)!
    }

    private func date(_ iso: String) -> WorkDate { WorkDate(iso)! }

    // MARK: TIME-T01 — 제출용 주간보고 구간

    func testSubmissionWeekSplitsPreviousAndPlan() {
        let expectedPrevious = DateRange(start: date("2026-09-28"), endExclusive: date("2026-10-05"))
        let expectedPlan = DateRange(start: date("2026-10-05"), endExclusive: date("2026-10-12"))

        for iso in ["2026-10-05", "2026-10-07"] {
            let result = periods.submissionWeek(reportDate: date(iso))
            XCTAssertEqual(result.previous, expectedPrevious, "previous for \(iso)")
            XCTAssertEqual(result.plan, expectedPlan, "plan for \(iso)")
        }
    }

    // MARK: TIME-T03 — 상태 기준 시점

    func testStateCutoffIsEndExclusiveLocalMidnight() {
        let range = DateRange(start: date("2026-09-28"), endExclusive: date("2026-10-05"))
        XCTAssertEqual(periods.stateCutoff(of: range), kst(2026, 10, 5, 0, 0, 0))
        XCTAssertEqual(periods.instants(of: range).start, kst(2026, 9, 28, 0, 0, 0))
        XCTAssertEqual(periods.instants(of: range).endExclusive, kst(2026, 10, 5, 0, 0, 0))
    }

    // MARK: 월·분기·연 경계

    func testMonthQuarterYearBoundaries() {
        XCTAssertEqual(periods.range(.monthly, containing: date("2026-10-15")),
                       DateRange(start: date("2026-10-01"), endExclusive: date("2026-11-01")))
        XCTAssertEqual(periods.range(.quarterly, containing: date("2026-10-15")),
                       DateRange(start: date("2026-10-01"), endExclusive: date("2027-01-01")))
        XCTAssertEqual(periods.range(.quarterly, containing: date("2026-07-01")),
                       DateRange(start: date("2026-07-01"), endExclusive: date("2026-10-01")))
        XCTAssertEqual(periods.range(.quarterly, containing: date("2026-12-31")),
                       DateRange(start: date("2026-10-01"), endExclusive: date("2027-01-01")))
        XCTAssertEqual(periods.range(.yearly, containing: date("2026-12-31")),
                       DateRange(start: date("2026-01-01"), endExclusive: date("2027-01-01")))
        XCTAssertEqual(periods.range(.weekly, containing: date("2026-10-07")),
                       DateRange(start: date("2026-10-05"), endExclusive: date("2026-10-12")))
    }

    // MARK: ISO 주 키

    func testPeriodKeysIncludingISOWeekYear() {
        XCTAssertEqual(periods.periodKey(.daily, containing: date("2026-10-05")), "2026-10-05")
        XCTAssertEqual(periods.periodKey(.weekly, containing: date("2026-10-05")), "2026-W41")
        XCTAssertEqual(periods.periodKey(.monthly, containing: date("2026-10-05")), "2026-10")
        XCTAssertEqual(periods.periodKey(.quarterly, containing: date("2026-10-05")), "2026-Q4")
        XCTAssertEqual(periods.periodKey(.yearly, containing: date("2026-10-05")), "2026")

        // 2026-12-31은 ISO week-year 2026의 53주차, 2027-01-01도 같은 주.
        XCTAssertEqual(periods.periodKey(.weekly, containing: date("2026-12-31")), "2026-W53")
        XCTAssertEqual(periods.periodKey(.weekly, containing: date("2027-01-01")), "2026-W53")
    }

    // MARK: REP-T04 — 기간 분할

    func testSplitWeekByMonth() {
        let week = DateRange(start: date("2026-09-28"), endExclusive: date("2026-10-05"))
        let pieces = periods.split(week, by: .monthly)
        XCTAssertEqual(pieces, [
            DateRange(start: date("2026-09-28"), endExclusive: date("2026-10-01")),
            DateRange(start: date("2026-10-01"), endExclusive: date("2026-10-05")),
        ])
        XCTAssertTrue(periods.split(DateRange(start: date("2026-10-05"), endExclusive: date("2026-10-05")),
                                    by: .monthly).isEmpty)
    }

    // MARK: REP-T05/T06/T07 — 평가 기간 시작일 규칙

    func testEvaluationNextStartRules() {
        XCTAssertNil(EvaluationPeriods.nextStart(after: []))

        let created = Date(timeIntervalSince1970: 1_790_000_000)
        let confirmed = EvaluationPeriod(
            id: "e1",
            range: DateRange(start: date("2025-10-01"), endExclusive: date("2026-10-01")),
            confirmedReportVersionId: "v1", createdAt: created)

        // 확정 기간이 있으면 다음 시작일 = 그 종료일.
        XCTAssertEqual(EvaluationPeriods.nextStart(after: [confirmed]), date("2026-10-01"))

        // 미확정 기간은 nextStart에 영향을 주지 않는다.
        let unconfirmed = EvaluationPeriod(
            id: "e2",
            range: DateRange(start: date("2026-10-01"), endExclusive: date("2027-10-01")),
            confirmedReportVersionId: nil, createdAt: created)
        XCTAssertEqual(EvaluationPeriods.nextStart(after: [confirmed, unconfirmed]), date("2026-10-01"))

        // 같은 평가 기간 id에 버전만 추가돼도(기간 목록 불변) nextStart 불변.
        var newVersion = confirmed
        newVersion.confirmedReportVersionId = "v2"
        XCTAssertEqual(EvaluationPeriods.nextStart(after: [newVersion]), date("2026-10-01"))
    }

    // MARK: REP-T08 — 종료일 포함 → endExclusive 다음 날

    func testEvaluationPropose() throws {
        let proposed = try EvaluationPeriods.propose(
            start: date("2026-01-01"), endInclusive: date("2026-09-30"),
            existing: [], calendar: WorkCalendar())
        XCTAssertEqual(proposed, DateRange(start: date("2026-01-01"), endExclusive: date("2026-10-01")))

        // 시작을 정할 수 없으면 validation.
        XCTAssertThrowsError(try EvaluationPeriods.propose(
            start: nil, endInclusive: date("2026-09-30"), existing: [], calendar: WorkCalendar())) { error in
            guard case WorkLogError.validation = error else { return XCTFail("validation 기대: \(error)") }
        }

        // end < start면 validation.
        XCTAssertThrowsError(try EvaluationPeriods.propose(
            start: date("2026-10-01"), endInclusive: date("2026-09-30"),
            existing: [], calendar: WorkCalendar())) { error in
            guard case WorkLogError.validation = error else { return XCTFail("validation 기대: \(error)") }
        }

        // 확정 기간에서 시작일을 파생한다.
        let confirmed = EvaluationPeriod(
            id: "e1",
            range: DateRange(start: date("2025-10-01"), endExclusive: date("2026-10-01")),
            confirmedReportVersionId: "v1", createdAt: Date(timeIntervalSince1970: 0))
        let derived = try EvaluationPeriods.propose(
            start: nil, endInclusive: date("2027-09-30"), existing: [confirmed], calendar: WorkCalendar())
        XCTAssertEqual(derived, DateRange(start: date("2026-10-01"), endExclusive: date("2027-10-01")))
    }

    func testEvaluationBoundaryWarnings() {
        let confirmed = EvaluationPeriod(
            id: "e1",
            range: DateRange(start: date("2025-10-01"), endExclusive: date("2026-10-01")),
            confirmedReportVersionId: "v1", createdAt: Date(timeIntervalSince1970: 0))

        let overlapping = DateRange(start: date("2026-06-01"), endExclusive: date("2027-01-01"))
        XCTAssertEqual(EvaluationPeriods.boundaryWarnings(overlapping, periodId: nil, existing: [confirmed]).count, 1)

        // 같은 id의 기존 기간은 비교에서 제외.
        XCTAssertTrue(EvaluationPeriods.boundaryWarnings(overlapping, periodId: "e1", existing: [confirmed]).isEmpty)

        // 공백.
        let gapped = DateRange(start: date("2026-11-01"), endExclusive: date("2027-10-01"))
        XCTAssertEqual(EvaluationPeriods.boundaryWarnings(gapped, periodId: nil, existing: [confirmed]).count, 1)
    }
}
