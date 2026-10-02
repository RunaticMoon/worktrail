import Foundation

/// 지역 달력의 날짜(시각 없음). 실제 업무일·마감일·기간 경계에 사용한다.
/// 직렬화 형식은 ISO `yyyy-MM-dd`.
public struct WorkDate: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year; self.month = month; self.day = day
    }

    /// "2026-10-05" 형식. 형식이 다르거나 존재하지 않는 날짜면 nil.
    public init?(_ iso: String) {
        let parts = iso.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var comps = DateComponents(); comps.year = y; comps.month = m; comps.day = d
        let cal = WorkCalendar.gregorian(timeZone: TimeZone(identifier: "UTC")!)
        guard let date = cal.date(from: comps) else { return nil }
        let back = cal.dateComponents([.year, .month, .day], from: date)
        guard back.year == y, back.month == m, back.day == d else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var description: String { iso }

    public static func < (lhs: WorkDate, rhs: WorkDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let d = WorkDate(s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid WorkDate: \(s)")
        }
        self = d
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(iso)
    }
}

/// 업무 달력. 기본 시간대 Asia/Seoul, ISO 월요일 시작 주.
/// 모든 기간은 끝을 제외하는 [start, endExclusive) 구간이다.
public struct WorkCalendar: Sendable {
    public let timeZone: TimeZone
    public let calendar: Calendar

    public init(timeZone: TimeZone = TimeZone(identifier: "Asia/Seoul")!) {
        self.timeZone = timeZone
        self.calendar = WorkCalendar.gregorian(timeZone: timeZone)
    }

    public static func gregorian(timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.firstWeekday = 2 // Monday
        cal.minimumDaysInFirstWeek = 4 // ISO 8601
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }

    /// 순간(Date)이 속하는 지역 날짜.
    public func workDate(of instant: Date) -> WorkDate {
        let c = calendar.dateComponents([.year, .month, .day], from: instant)
        return WorkDate(year: c.year!, month: c.month!, day: c.day!)
    }

    /// 해당 날짜의 지역 자정(시작 순간).
    public func startOfDay(_ date: WorkDate) -> Date {
        var c = DateComponents(); c.year = date.year; c.month = date.month; c.day = date.day
        return calendar.date(from: c)!
    }

    public func adding(days: Int, to date: WorkDate) -> WorkDate {
        let base = calendar.date(byAdding: .day, value: days, to: startOfDay(date))!
        return workDate(of: base)
    }

    public func adding(months: Int, to date: WorkDate) -> WorkDate {
        let base = calendar.date(byAdding: .month, value: months, to: startOfDay(date))!
        return workDate(of: base)
    }

    /// ISO 요일: 월요일=1 … 일요일=7
    public func isoWeekday(_ date: WorkDate) -> Int {
        let w = calendar.component(.weekday, from: startOfDay(date)) // Sunday=1
        return w == 1 ? 7 : w - 1
    }

    public func daysBetween(_ a: WorkDate, _ b: WorkDate) -> Int {
        calendar.dateComponents([.day], from: startOfDay(a), to: startOfDay(b)).day!
    }
}

/// 끝을 제외하는 날짜 구간 [start, endExclusive).
public struct DateRange: Hashable, Codable, Sendable, CustomStringConvertible {
    public let start: WorkDate
    public let endExclusive: WorkDate

    public init(start: WorkDate, endExclusive: WorkDate) {
        precondition(start <= endExclusive, "DateRange start must be <= endExclusive")
        self.start = start; self.endExclusive = endExclusive
    }

    public func contains(_ date: WorkDate) -> Bool { start <= date && date < endExclusive }
    public var isEmpty: Bool { start == endExclusive }
    public var description: String { "[\(start.iso), \(endExclusive.iso))" }

    /// 두 구간의 교집합. 겹치지 않으면 nil.
    public func intersection(_ other: DateRange) -> DateRange? {
        let s = max(start, other.start), e = min(endExclusive, other.endExclusive)
        return s < e ? DateRange(start: s, endExclusive: e) : nil
    }
}
