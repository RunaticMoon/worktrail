#if os(macOS)
import Foundation
import Observation
import UserNotifications
import WorkLogCore

/// 시스템 예약 알림은 앱이 닫혀 있어도 전달된다. 앱 실행·저장·주기 갱신 때
/// 가장 가까운 60건을 유지해 시스템의 예약 개수 제한 안에서 다음 알림을 채운다.
@Observable @MainActor final class TaskNotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    private(set) var errorMessage: String?
    @ObservationIgnored var onOpenTask: ((String) -> Void)?
    @ObservationIgnored private let center: UNUserNotificationCenter
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var needsRefresh = false
    private static let prefix = "worklog.task-due."

    override init() {
        center = .current()
        super.init()
        center.delegate = self
    }

    func refresh(environment: AppEnvironment) async {
        guard !isRefreshing else { needsRefresh = true; return }
        isRefreshing = true
        repeat {
            needsRefresh = false
            await reconcile(environment: environment)
        } while needsRefresh
        isRefreshing = false
    }

    private func reconcile(environment: AppEnvironment) async {
        do {
            // 상태 캐시가 아닌 사건 재생 결과로 완료·취소 여부를 확인한다.
            var tasks = try environment.repo.tasks()
            for index in tasks.indices {
                tasks[index].cachedStatus = try environment.tasks.currentStatus(taskId: tasks[index].id)
            }
            let allPending = await center.pendingNotificationRequests()
            let pending = allPending.filter { $0.identifier.hasPrefix(Self.prefix) }
            let otherCount = allPending.count - pending.count
            let reminders = TaskReminderPlanner.reminders(tasks: tasks,
                now: environment.options.clock.now(), calendar: environment.calendar,
                limit: max(0, 60 - otherCount))
            let wanted = Set(reminders.map(\.id))
            center.removePendingNotificationRequests(withIdentifiers:
                pending.filter { !wanted.contains($0.identifier) }.map(\.identifier))
            guard tasks.contains(where: { $0.dueOn != nil && $0.dueReminderDaysBefore != nil
                && $0.cachedStatus != .completed && $0.cachedStatus != .cancelled }) else {
                errorMessage = nil
                return
            }
            let settings = await center.notificationSettings()
            var authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            if settings.authorizationStatus == .notDetermined {
                authorized = try await center.requestAuthorization(options: [.alert, .sound])
            }
            guard authorized else {
                errorMessage = "마감 알림이 꺼져 있습니다. macOS 시스템 설정의 알림에서 WorkLog 알림을 허용하세요."
                return
            }
            let existing = Dictionary(uniqueKeysWithValues: pending.map { ($0.identifier, $0) })
            for reminder in reminders {
                let content = UNMutableNotificationContent()
                content.title = reminder.title
                let daysLeft = environment.calendar.daysBetween(reminder.reminderDate, reminder.dueOn)
                content.body = daysLeft == 0 ? "오늘 마감인 업무입니다."
                    : "마감까지 \(daysLeft)일 · \(reminder.dueOn.iso)"
                content.sound = .default
                content.userInfo = ["taskID": reminder.taskID]
                var components = environment.calendar.calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second], from: reminder.scheduledFor)
                components.calendar = environment.calendar.calendar
                components.timeZone = environment.calendar.timeZone
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                if let previous = existing[reminder.id], previous.content.title == content.title,
                   previous.content.body == content.body,
                   (previous.trigger as? UNCalendarNotificationTrigger)?.dateComponents == components { continue }
                try await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
            }
            errorMessage = nil
        } catch {
            errorMessage = "마감 알림을 예약하지 못했습니다. 알림 권한을 확인하고 다시 시도하세요."
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let taskID = response.notification.request.content.userInfo["taskID"] as? String {
            Task { @MainActor [weak self] in self?.onOpenTask?(taskID) }
        }
        completionHandler()
    }
}
#endif
