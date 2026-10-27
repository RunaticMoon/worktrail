import Foundation

public struct TaskDueReminder: Equatable, Sendable, Identifiable {
    public let taskID: String
    public let title: String
    public let dueOn: WorkDate
    public let reminderDate: WorkDate
    public let scheduledFor: Date
    public var id: String { "worklog.task-due.\(taskID).\(reminderDate.iso)" }
}

/// 선택한 N일 전부터 마감 당일까지 매일 업무 시간대의 오전 9시에 알린다.
/// 과거 시각은 재생하지 않으므로 앱 재실행이나 반복 갱신이 중복 알림을 만들지 않는다.
public enum TaskReminderPlanner {
    public static func reminders(tasks: [WorkTask], now: Date, calendar: WorkCalendar,
                                 limit: Int = 60) -> [TaskDueReminder] {
        guard limit > 0 else { return [] }
        let today = calendar.workDate(of: now)
        var result: [TaskDueReminder] = []
        for task in tasks {
            guard task.deletedAt == nil, task.cachedStatus != .completed, task.cachedStatus != .cancelled,
                  let dueOn = task.dueOn, dueOn >= today, let days = task.dueReminderDaysBefore,
                  (0...365).contains(days) else { continue }
            var day = max(today, calendar.adding(days: -days, to: dueOn))
            while day <= dueOn {
                let start = calendar.startOfDay(day)
                if let fire = calendar.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: start),
                   fire > now {
                    result.append(TaskDueReminder(taskID: task.id, title: task.title, dueOn: dueOn,
                                                  reminderDate: day, scheduledFor: fire))
                }
                day = calendar.adding(days: 1, to: day)
            }
        }
        return Array(result.sorted {
            if $0.scheduledFor != $1.scheduledFor { return $0.scheduledFor < $1.scheduledFor }
            if $0.dueOn != $1.dueOn { return $0.dueOn < $1.dueOn }
            return $0.taskID < $1.taskID
        }.prefix(limit))
    }
}
