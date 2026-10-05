import Foundation

/// 한국어 날짜 문구의 공통 표현. 화면마다 다른 형식이 생기지 않도록 한다.
/// 요일은 `WorkCalendar`의 시간대·ISO 주(월요일 시작) 기준으로 계산한다.
public enum KoreanDateLabel {

    /// ISO 요일(월=1 … 일=7) → 한국어 한 글자.
    public static func weekdayName(_ isoWeekday: Int) -> String {
        let names = ["월", "화", "수", "목", "금", "토", "일"]
        guard (1...names.count).contains(isoWeekday) else { return "" }
        return names[isoWeekday - 1]
    }

    /// "10월 5일(월)". `includeYear`가 true면 "2026년 10월 5일(월)".
    public static func monthDayWeekday(_ date: WorkDate, calendar: WorkCalendar,
                                       includeYear: Bool = false) -> String {
        let weekday = weekdayName(calendar.isoWeekday(date))
        let base = "\(date.month)월 \(date.day)일(\(weekday))"
        return includeYear ? "\(date.year)년 \(base)" : base
    }

    /// "9월 28일(월) ~ 10월 4일(일)". `endExclusive`의 전날까지 표시한다.
    /// `includeYear`가 true면 시작 날짜에 연도를 붙이고, 끝 날짜의 연도가 다를 때만 끝에도 붙인다.
    public static func range(_ range: DateRange, calendar: WorkCalendar,
                             includeYear: Bool = false) -> String {
        let last = calendar.adding(days: -1, to: range.endExclusive)
        let start = monthDayWeekday(range.start, calendar: calendar, includeYear: includeYear)
        let end = monthDayWeekday(last, calendar: calendar,
                                  includeYear: includeYear && last.year != range.start.year)
        return "\(start) ~ \(end)"
    }
}
