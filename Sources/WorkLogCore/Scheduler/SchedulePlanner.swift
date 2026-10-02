import Foundation

/// 실행 시점이 지난 예약 작업 하나. `ScheduledJob` 행에서 복원할 수 있도록 range는
/// (type, periodKey)로 다시 계산 가능해야 한다.
public struct DueJob: Hashable, Sendable {
    public var type: ScheduledJobType
    public var periodKey: String
    public var range: DateRange
    public var scheduledFor: Date

    public init(type: ScheduledJobType, periodKey: String, range: DateRange, scheduledFor: Date) {
        self.type = type
        self.periodKey = periodKey
        self.range = range
        self.scheduledFor = scheduledFor
    }
}

/// 놓친 마감 작업을 찾는 계획기. DB·네트워크에 접근하지 않고 순수 계산만 한다.
public enum SchedulePlanner {

    /// 실행 완료 여부를 판단하는 키. `ScheduledJob`의 UNIQUE(type, period_key)와 같은 모양이다.
    public static func key(for type: ScheduledJobType, periodKey: String) -> String {
        "\(type.rawValue)|\(periodKey)"
    }

    /// since(첫 설치일 등) 이후 now까지 실행 시점이 지난 작업 중 existingKeys에 없는 것.
    /// scheduledFor 오름차순, 같으면 type rawValue 순. backup은 다루지 않는다.
    public static func dueJobs(now: Date, since: WorkDate, existingKeys: Set<String>,
                               settings: AppSettings, periods: Periods) -> [DueJob] {
        let calendar = periods.calendar
        let today = calendar.workDate(of: now)
        var jobs: [DueJob] = []

        func append(_ type: ScheduledJobType, _ periodKey: String, _ range: DateRange, _ scheduledFor: Date) {
            guard !existingKeys.contains(key(for: type, periodKey: periodKey)) else { return }
            jobs.append(DueJob(type: type, periodKey: periodKey, range: range, scheduledFor: scheduledFor))
        }

        // dailyClose: since <= d < today 인 각 날짜, scheduledFor = d+1일 자정.
        var d = since
        while d < today {
            let range = periods.day(d)
            append(.dailyClose, periods.periodKey(.daily, containing: d), range,
                   calendar.startOfDay(range.endExclusive))
            d = calendar.adding(days: 1, to: d)
        }

        // 성과 리포트: endExclusive <= today 이고 endExclusive > since 인 각 기간, scheduledFor = endExclusive 자정.
        func performanceJobs(_ type: ScheduledJobType, _ periodType: PeriodType) {
            var cursor = since
            while cursor < today {
                let range = periods.range(periodType, containing: cursor)
                if range.endExclusive > today { break }
                append(type, periods.periodKey(periodType, containing: range.start), range,
                       calendar.startOfDay(range.endExclusive))
                cursor = range.endExclusive
            }
        }
        performanceJobs(.weeklyPerformance, .weekly)
        performanceJobs(.monthlyPerformance, .monthly)
        performanceJobs(.quarterlyPerformance, .quarterly)

        // mondayReview: since <= m <= today 인 월요일, scheduledFor = m의 설정 시각, now >= scheduledFor 일 때만.
        var monday = periods.weekStart(containing: since)
        if monday < since { monday = calendar.adding(days: 7, to: monday) }
        while monday <= today {
            let scheduledFor = reminderInstant(on: monday, calendar: calendar, settings: settings)
            if now >= scheduledFor {
                let week = periods.submissionWeek(reportDate: monday)
                append(.mondayReview, periods.periodKey(.weekly, containing: monday), week.previous, scheduledFor)
            }
            monday = calendar.adding(days: 7, to: monday)
        }

        return jobs.sorted { lhs, rhs in
            if lhs.scheduledFor != rhs.scheduledFor { return lhs.scheduledFor < rhs.scheduledFor }
            return lhs.type.rawValue < rhs.type.rawValue
        }
    }

    /// executedAt이 scheduledFor + grace보다 늦으면 true.
    /// 자정 실행 성공을 늦은 복구로 잘못 표시하지 않기 위해 여유를 둔다.
    public static func isLate(scheduledFor: Date, executedAt: Date, grace: TimeInterval = 900) -> Bool {
        executedAt.timeIntervalSince(scheduledFor) > grace
    }

    /// (type, periodKey)로부터 range를 복원한다. 실행기가 pending 행에서 DueJob을 만들 때 사용한다.
    /// 지원하지 않는 유형(backup 등)이나 키 형식이 아니면 nil.
    public static func range(for type: ScheduledJobType, periodKey: String, periods: Periods) -> DateRange? {
        let calendar = periods.calendar
        switch type {
        case .dailyClose:
            guard let d = WorkDate(periodKey) else { return nil }
            return periods.day(d)
        case .weeklyPerformance, .mondayReview:
            guard let monday = monday(fromISOWeekKey: periodKey, calendar: calendar) else { return nil }
            if type == .mondayReview {
                let previousStart = calendar.adding(days: -7, to: monday)
                return DateRange(start: previousStart, endExclusive: monday)
            }
            return DateRange(start: monday, endExclusive: calendar.adding(days: 7, to: monday))
        case .monthlyPerformance:
            let parts = periodKey.split(separator: "-")
            guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]),
                  (1...12).contains(month) else { return nil }
            let start = WorkDate(year: year, month: month, day: 1)
            return DateRange(start: start, endExclusive: calendar.adding(months: 1, to: start))
        case .quarterlyPerformance:
            let parts = periodKey.split(separator: "-")
            guard parts.count == 2, let year = Int(parts[0]), parts[1].first == "Q",
                  let quarter = Int(parts[1].dropFirst()), (1...4).contains(quarter) else { return nil }
            let start = WorkDate(year: year, month: (quarter - 1) * 3 + 1, day: 1)
            return DateRange(start: start, endExclusive: calendar.adding(months: 3, to: start))
        case .backup:
            return nil
        }
    }

    // MARK: - Helpers

    private static func monday(fromISOWeekKey key: String, calendar: WorkCalendar) -> WorkDate? {
        let parts = key.split(separator: "-")
        guard parts.count == 2, parts[1].first == "W", let year = Int(parts[0]),
              let week = Int(parts[1].dropFirst()) else { return nil }
        var comps = DateComponents()
        comps.yearForWeekOfYear = year
        comps.weekOfYear = week
        comps.weekday = 2 // Monday
        guard let date = calendar.calendar.date(from: comps) else { return nil }
        return calendar.workDate(of: date)
    }

    /// 월요일 검토 알림 시각("HH:mm"). 형식이 잘못되면 09:00으로 본다.
    static func reminderInstant(on date: WorkDate, calendar: WorkCalendar, settings: AppSettings) -> Date {
        let start = calendar.startOfDay(date)
        let parts = settings.mondayReminderTime.split(separator: ":")
        var hour = 9, minute = 0
        if parts.count == 2, let h = Int(parts[0]), let mi = Int(parts[1]),
           (0...23).contains(h), (0...59).contains(mi) {
            hour = h; minute = mi
        }
        return calendar.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start) ?? start
    }
}
