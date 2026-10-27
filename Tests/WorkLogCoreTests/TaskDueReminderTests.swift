import XCTest
@testable import WorkLogCore

final class TaskDueReminderTests: XCTestCase {
    private let calendar = WorkCalendar()
    private func day(_ value: String) -> WorkDate { WorkDate(value)! }
    private func instant(_ value: String, hour: Int = 8, calendar: WorkCalendar = WorkCalendar()) -> Date {
        calendar.calendar.date(bySettingHour: hour, minute: 0, second: 0,
                               of: calendar.startOfDay(WorkDate(value)!))!
    }
    private func task(id: String = "task", due: String = "2026-11-02", days: Int? = 3,
                      status: TaskStatus = .planned) -> WorkTask {
        WorkTask(id: id, title: "가짜 마감 업무", dueOn: day(due), createdAt: instant("2026-10-28"),
                 cachedStatus: status, dueReminderDaysBefore: days)
    }

    func testReminderWindowCrossesMonthAndStopsOnDueDate() {
        let reminders = TaskReminderPlanner.reminders(tasks: [task()], now: instant("2026-10-28"), calendar: calendar)
        XCTAssertEqual(reminders.map(\.reminderDate), ["2026-10-30", "2026-10-31", "2026-11-01", "2026-11-02"].map(day))
        XCTAssertEqual(reminders.first?.scheduledFor, instant("2026-10-30", hour: 9))
        XCTAssertEqual(Set(reminders.map(\.id)).count, 4)
    }

    func testPastFireTimesAndClosedTasksAreNotRescheduled() {
        var deleted = task(id: "deleted"); deleted.deletedAt = instant("2026-10-29")
        let tasks = [task(), task(id: "done", status: .completed), task(id: "cancel", status: .cancelled),
                     task(id: "off", days: nil), task(id: "past", due: "2026-10-29"), deleted]
        let reminders = TaskReminderPlanner.reminders(tasks: tasks, now: instant("2026-10-30", hour: 10), calendar: calendar)
        XCTAssertEqual(reminders.map(\.reminderDate), ["2026-10-31", "2026-11-01", "2026-11-02"].map(day))
        XCTAssertTrue(reminders.allSatisfy { $0.taskID == "task" })
        XCTAssertTrue(TaskReminderPlanner.reminders(tasks: tasks, now: instant("2026-11-03"), calendar: calendar).isEmpty)
    }

    func testZeroDayAndLimitChooseEarliestRemindersDeterministically() {
        let tasks = [task(id: "z", due: "2026-11-02", days: 0), task(id: "a", due: "2026-11-01", days: 0)]
        let reminders = TaskReminderPlanner.reminders(tasks: tasks, now: instant("2026-10-30"), calendar: calendar, limit: 1)
        XCTAssertEqual(reminders.map(\.taskID), ["a"])
        XCTAssertEqual(reminders.first?.scheduledFor, instant("2026-11-01", hour: 9))
    }

    func testDueTodayIsScheduledOnlyBeforeNineAndOldTaskJSONStillDecodes() throws {
        let dueToday = task(due: "2026-10-28", days: 0)
        XCTAssertEqual(TaskReminderPlanner.reminders(tasks: [dueToday], now: instant("2026-10-28"), calendar: calendar).count, 1)
        XCTAssertTrue(TaskReminderPlanner.reminders(tasks: [dueToday], now: instant("2026-10-28", hour: 9), calendar: calendar).isEmpty)
        var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(dueToday)) as? [String: Any])
        oldJSON.removeValue(forKey: "dueReminderDaysBefore")
        let decoded = try JSONDecoder().decode(WorkTask.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        XCTAssertEqual(decoded.dueOn, dueToday.dueOn)
        XCTAssertNil(decoded.dueReminderDaysBefore)
    }

    func testCompletionCancellationAndReopenChangeReminderPlan() throws {
        let now = instant("2026-10-28")
        let repo = try WorkRepository.inMemory(clock: FixedClock(now), ids: SequentialIDGenerator())
        let service = TaskService(repo: repo)
        let created = try service.createTask(title: "상태 알림", dueOn: day("2026-10-28"), dueReminderDaysBefore: 0)
        func plannedIDs() throws -> [String] {
            TaskReminderPlanner.reminders(tasks: try repo.tasks(), now: now, calendar: calendar).map(\.id)
        }
        let initialIDs = try plannedIDs()
        XCTAssertEqual(initialIDs.count, 1)
        _ = try service.completeTask(taskId: created.id, confirmRemaining: true)
        XCTAssertTrue(try plannedIDs().isEmpty)
        try service.changeTaskStatus(taskId: created.id, kind: .reopened)
        XCTAssertEqual(try plannedIDs(), initialIDs)
        try service.changeTaskStatus(taskId: created.id, kind: .cancelled)
        XCTAssertTrue(try plannedIDs().isEmpty)
    }

    func testCalendarPreservesNineAMAcrossDaylightSavingChange() {
        let losAngeles = WorkCalendar(timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        let reminders = TaskReminderPlanner.reminders(tasks: [task()],
            now: instant("2026-10-29", calendar: losAngeles), calendar: losAngeles)
        XCTAssertEqual(reminders.count, 4)
        XCTAssertTrue(reminders.allSatisfy { losAngeles.calendar.component(.hour, from: $0.scheduledFor) == 9 })
        XCTAssertEqual(reminders[2].scheduledFor.timeIntervalSince(reminders[1].scheduledFor), 25 * 3600)
    }

    func testV6UpgradePreservesDueDateAndDefaultsRemindersOff() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try Migrator.migrate(db, migrations: WorkSchema.migrations.filter { $0.version <= 6 })
        try db.run("""
            INSERT INTO task (id, title, due_on, created_at, project_tracking_mode, revision)
            VALUES (?, ?, ?, ?, ?, ?)
            """, ["old", "기존 업무", "2026-11-02", "2026-10-28T00:00:00.000Z", "shared", 1])
        let repo = try WorkRepository(db: db, clock: FixedClock(instant("2026-10-28")), ids: SequentialIDGenerator())
        XCTAssertEqual(try repo.task(id: "old")?.dueOn, day("2026-11-02"))
        XCTAssertNil(try repo.task(id: "old")?.dueReminderDaysBefore)
        XCTAssertTrue(try db.integrityCheck())
    }

    func testCreateEditAndClearDeadlinePersistTogetherAndRejectInvalidReminder() throws {
        let repo = try WorkRepository.inMemory(clock: FixedClock(instant("2026-10-28")), ids: SequentialIDGenerator())
        let service = TaskService(repo: repo)
        let created = try service.createTask(title: "업무", dueOn: day("2026-11-02"), dueReminderDaysBefore: 3)
        XCTAssertEqual(try repo.task(id: created.id)?.dueReminderDaysBefore, 3)
        try service.updateTaskDue(taskId: created.id, dueOn: day("2026-11-03"), dueReminderDaysBefore: 0)
        XCTAssertEqual(try repo.task(id: created.id)?.dueOn, day("2026-11-03"))
        XCTAssertEqual(try repo.task(id: created.id)?.dueReminderDaysBefore, 0)
        XCTAssertThrowsError(try service.updateTaskDue(taskId: created.id, dueOn: day("2026-11-03"), dueReminderDaysBefore: -1))
        XCTAssertThrowsError(try service.createTask(title: "유효하지 않음", dueReminderDaysBefore: 3))
        XCTAssertThrowsError(try service.createTask(title: "유효하지 않음", dueOn: day("2026-11-03"), dueReminderDaysBefore: 366))
        XCTAssertEqual(try repo.tasks().count, 1)
        try service.updateTaskDue(taskId: created.id, dueOn: nil, dueReminderDaysBefore: 3)
        XCTAssertNil(try repo.task(id: created.id)?.dueOn)
        XCTAssertNil(try repo.task(id: created.id)?.dueReminderDaysBefore)
    }

    @MainActor func testCaptureKeepsDeadlineOnFailureThenResetsAfterSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TaskDueReminder-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(dataRoot: root.appendingPathComponent("data"), backupRoot: root.appendingPathComponent("backup"))
        let env = try AppEnvironment.open(AppEnvironmentOptions(paths: paths, keyStore: InMemoryVaultKeyStore(),
            authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(),
            clock: FixedClock(instant("2026-10-28")), ids: SequentialIDGenerator()))
        let session = CaptureSessionModel(environment: env)
        let model = session.taskDraft
        model.dueOn = day("2026-11-02"); model.dueReminderDaysBefore = 7
        XCTAssertTrue(session.hasDraft(.task), "마감 설정만 해도 초안이다")
        XCTAssertFalse(model.submit())
        XCTAssertEqual(model.dueOn, day("2026-11-02"))
        XCTAssertEqual(model.dueReminderDaysBefore, 7)
        model.text = "마감 있는 새 업무"
        XCTAssertTrue(model.submit())
        let saved = try XCTUnwrap(env.repo.task(id: XCTUnwrap(model.lastSavedId)))
        XCTAssertEqual(saved.dueOn, day("2026-11-02"))
        XCTAssertEqual(saved.dueReminderDaysBefore, 7)
        XCTAssertNil(model.dueOn); XCTAssertNil(model.dueReminderDaysBefore)
        let detail = TaskDetailModel(environment: env)
        detail.load(taskId: saved.id)
        detail.setDueReminderDaysBefore(1)
        XCTAssertEqual(detail.detail?.task.dueReminderDaysBefore, 1)
        detail.setDueDate(nil)
        XCTAssertNil(detail.detail?.task.dueOn); XCTAssertNil(detail.detail?.task.dueReminderDaysBefore)
    }
}
