import Foundation

/// 업무 기간 계산. 모든 기간은 끝을 제외하는 `[start, endExclusive)` 구간이다.
/// 시간대·주 시작(ISO 월요일)은 `WorkCalendar`가 정한다.
public struct Periods: Sendable {
    public let calendar: WorkCalendar

    public init(calendar: WorkCalendar = WorkCalendar()) {
        self.calendar = calendar
    }

    /// 하루 구간 `[d, d+1)`.
    public func day(_ d: WorkDate) -> DateRange {
        DateRange(start: d, endExclusive: calendar.adding(days: 1, to: d))
    }

    /// d가 속한 주의 월요일(ISO 주 시작).
    public func weekStart(containing d: WorkDate) -> WorkDate {
        let weekday = calendar.isoWeekday(d) // 월=1 … 일=7
        return calendar.adding(days: -(weekday - 1), to: d)
    }

    /// type 경계로 d를 포함하는 기간.
    public func range(_ type: PeriodType, containing d: WorkDate) -> DateRange {
        switch type {
        case .daily:
            return day(d)
        case .weekly:
            let start = weekStart(containing: d)
            return DateRange(start: start, endExclusive: calendar.adding(days: 7, to: start))
        case .monthly:
            let start = WorkDate(year: d.year, month: d.month, day: 1)
            return DateRange(start: start, endExclusive: calendar.adding(months: 1, to: start))
        case .quarterly:
            let quarterStartMonth = ((d.month - 1) / 3) * 3 + 1
            let start = WorkDate(year: d.year, month: quarterStartMonth, day: 1)
            return DateRange(start: start, endExclusive: calendar.adding(months: 3, to: start))
        case .yearly:
            let start = WorkDate(year: d.year, month: 1, day: 1)
            return DateRange(start: start, endExclusive: calendar.adding(months: 12, to: start))
        }
    }

    /// 기간 키. daily "2026-10-05", weekly ISO 주 "2026-W41"(ISO week-year), monthly "2026-10",
    /// quarterly "2026-Q4", yearly "2026".
    public func periodKey(_ type: PeriodType, containing d: WorkDate) -> String {
        switch type {
        case .daily:
            return d.iso
        case .weekly:
            let comps = calendar.calendar.dateComponents([.yearForWeekOfYear, .weekOfYear],
                                                         from: calendar.startOfDay(d))
            let year = comps.yearForWeekOfYear ?? d.year
            let week = comps.weekOfYear ?? 1
            return String(format: "%04d-W%02d", year, week)
        case .monthly:
            return String(format: "%04d-%02d", d.year, d.month)
        case .quarterly:
            return String(format: "%04d-Q%d", d.year, ((d.month - 1) / 3) + 1)
        case .yearly:
            return String(format: "%04d", d.year)
        }
    }

    /// 제출용 주간보고: reportDate가 속한 주 = plan, 그 직전 주 = previous.
    public func submissionWeek(reportDate: WorkDate) -> (previous: DateRange, plan: DateRange) {
        let plan = range(.weekly, containing: reportDate)
        let previousStart = calendar.adding(days: -7, to: plan.start)
        return (DateRange(start: previousStart, endExclusive: plan.start), plan)
    }

    /// 기간 종료 상태 기준 순간 = endExclusive 날짜의 지역 자정 (일요일 종료 = 월요일 00:00 KST).
    public func stateCutoff(of range: DateRange) -> Date {
        calendar.startOfDay(range.endExclusive)
    }

    /// 순간 구간 `[start 자정, endExclusive 자정)`.
    public func instants(of range: DateRange) -> (start: Date, endExclusive: Date) {
        (calendar.startOfDay(range.start), calendar.startOfDay(range.endExclusive))
    }

    /// range를 type 경계로 나눈 조각.
    /// 예: [2026-09-28, 2026-10-05) 주를 monthly로 → [09-28, 10-01), [10-01, 10-05)
    public func split(_ range: DateRange, by type: PeriodType) -> [DateRange] {
        guard range.start < range.endExclusive else { return [] }
        var pieces: [DateRange] = []
        var cursor = range.start
        while cursor < range.endExclusive {
            let boundary = self.range(type, containing: cursor)
            let pieceEnd = min(range.endExclusive, boundary.endExclusive)
            pieces.append(DateRange(start: cursor, endExclusive: pieceEnd))
            cursor = pieceEnd
        }
        return pieces
    }
}
