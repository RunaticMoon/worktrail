import Foundation

// MARK: - WorkTask / TaskProject / ChecklistItem / Activity / DomainEvent
//
// Task 원문과 상태 이력(append-only). 상태 전이 규칙·재생은 이 저장소의 범위가 아니다.
extension WorkRepository {

    // MARK: Task

    public func insertTask(_ task: WorkTask) throws {
        try db.transaction {
            try db.runV("""
                INSERT INTO task
                    (id, title, due_on, created_at, project_tracking_mode, revision, deleted_at, cached_status)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, task.id, task.title, task.dueOn, task.createdAt,
                   task.projectTrackingMode.rawValue, task.revision, task.deletedAt,
                   task.cachedStatus?.rawValue)
            for tagId in task.tagIds {
                try db.runV("INSERT OR IGNORE INTO task_tag (task_id, tag_id) VALUES (?, ?)",
                           task.id, tagId)
            }
        }
        onSourceChanged?("task", task.id)
    }

    public func updateTaskTitle(id: String, title: String) throws {
        let n = try db.runV("UPDATE task SET title = ?, revision = revision + 1 WHERE id = ?", title, id)
        if n == 0 { throw WorkLogError.notFound("task \(id)") }
        onSourceChanged?("task", id)
    }

    public func updateTaskDue(id: String, dueOn: WorkDate?) throws {
        let n = try db.runV("UPDATE task SET due_on = ? WHERE id = ?", dueOn, id)
        if n == 0 { throw WorkLogError.notFound("task \(id)") }
    }

    public func setTaskTrackingMode(id: String, mode: ProjectTrackingMode) throws {
        let n = try db.runV("UPDATE task SET project_tracking_mode = ? WHERE id = ?", mode.rawValue, id)
        if n == 0 { throw WorkLogError.notFound("task \(id)") }
    }

    public func setTaskCachedStatus(id: String, status: TaskStatus?) throws {
        let n = try db.runV("UPDATE task SET cached_status = ? WHERE id = ?", status?.rawValue, id)
        if n == 0 { throw WorkLogError.notFound("task \(id)") }
    }

    public func task(id: String, includeDeleted: Bool = false) throws -> WorkTask? {
        let sql = includeDeleted
            ? "SELECT * FROM task WHERE id = ?"
            : "SELECT * FROM task WHERE id = ? AND deleted_at IS NULL"
        return try db.queryOneV(sql, id).map { try taskRow($0) }
    }

    /// created_at 오름차순.
    public func tasks(includeDeleted: Bool = false) throws -> [WorkTask] {
        let sql = includeDeleted
            ? "SELECT * FROM task ORDER BY created_at ASC, id ASC"
            : "SELECT * FROM task WHERE deleted_at IS NULL ORDER BY created_at ASC, id ASC"
        return try db.queryV(sql).map { try taskRow($0) }
    }

    /// 제목 부분 일치(LIKE). `%`, `_`, `\`는 리터럴로 취급한다.
    public func searchTasksByTitle(_ text: String, limit: Int = 20) throws -> [WorkTask] {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        return try db.queryV("""
            SELECT * FROM task WHERE title LIKE ? ESCAPE '\\' AND deleted_at IS NULL
            ORDER BY created_at ASC, id ASC LIMIT ?
            """, pattern, limit).map { try taskRow($0) }
    }

    // MARK: TaskProject

    /// 이미 활성 연결이면 기존 행을 반환한다. 해제된 연결은 되살린다(행이 유일하기 때문).
    @discardableResult
    public func linkProject(taskId: String, projectId: String, trackingEnabled: Bool,
                            linkedOn: WorkDate) throws -> TaskProject {
        try db.transaction {
            if let row = try db.queryOneV("SELECT * FROM task_project WHERE task_id = ? AND project_id = ?",
                                         taskId, projectId) {
                if row.string("removed_on") == nil {
                    return try taskProjectRow(row)
                }
                guard let existingId = row.string("id") else {
                    throw WorkLogError.storage("task_project row 손상")
                }
                try db.runV("""
                    UPDATE task_project SET tracking_enabled = ?, linked_on = ?, removed_on = NULL
                    WHERE id = ?
                    """, trackingEnabled, linkedOn, existingId)
                return TaskProject(id: existingId, taskId: taskId, projectId: projectId,
                                   trackingEnabled: trackingEnabled, linkedOn: linkedOn)
            }
            let id = ids.make()
            try db.runV("""
                INSERT INTO task_project (id, task_id, project_id, tracking_enabled, linked_on, removed_on)
                VALUES (?, ?, ?, ?, ?, NULL)
                """, id, taskId, projectId, trackingEnabled, linkedOn)
            return TaskProject(id: id, taskId: taskId, projectId: projectId,
                               trackingEnabled: trackingEnabled, linkedOn: linkedOn)
        }
    }

    /// 연결 해제. 행을 지우지 않고 removed_on을 설정한다.
    public func unlinkProject(taskId: String, projectId: String, removedOn: WorkDate) throws {
        let n = try db.runV("""
            UPDATE task_project SET removed_on = ?
            WHERE task_id = ? AND project_id = ? AND removed_on IS NULL
            """, removedOn, taskId, projectId)
        if n == 0 { throw WorkLogError.notFound("active link task=\(taskId) project=\(projectId)") }
    }

    public func taskProjects(taskId: String, includeRemoved: Bool = false) throws -> [TaskProject] {
        let sql = includeRemoved
            ? "SELECT * FROM task_project WHERE task_id = ? ORDER BY linked_on ASC, id ASC"
            : "SELECT * FROM task_project WHERE task_id = ? AND removed_on IS NULL ORDER BY linked_on ASC, id ASC"
        return try db.queryV(sql, taskId).map { try taskProjectRow($0) }
    }

    /// 프로젝트에 현재 연결된 활성 링크.
    public func taskProjects(projectId: String) throws -> [TaskProject] {
        try db.queryV("""
            SELECT * FROM task_project WHERE project_id = ? AND removed_on IS NULL
            ORDER BY linked_on ASC, id ASC
            """, projectId).map { try taskProjectRow($0) }
    }

    // MARK: ChecklistItem

    public func insertChecklistItem(_ item: ChecklistItem) throws {
        try db.transaction {
            try db.runV("""
                INSERT INTO checklist_item (id, task_id, text, sort_order, deleted_at)
                VALUES (?, ?, ?, ?, ?)
                """, item.id, item.taskId, item.text, item.sortOrder, item.deletedAt)
            for projectId in item.projectIds {
                try db.runV("INSERT OR IGNORE INTO checklist_project (checklist_item_id, project_id) VALUES (?, ?)",
                           item.id, projectId)
            }
        }
    }

    public func updateChecklistText(id: String, text: String) throws {
        let n = try db.runV("UPDATE checklist_item SET text = ? WHERE id = ?", text, id)
        if n == 0 { throw WorkLogError.notFound("checklist_item \(id)") }
    }

    public func checklistItems(taskId: String, includeDeleted: Bool = false) throws -> [ChecklistItem] {
        let sql = includeDeleted
            ? "SELECT * FROM checklist_item WHERE task_id = ? ORDER BY sort_order ASC, id ASC"
            : "SELECT * FROM checklist_item WHERE task_id = ? AND deleted_at IS NULL ORDER BY sort_order ASC, id ASC"
        return try db.queryV(sql, taskId).map { try checklistRow($0) }
    }

    public func checklistItem(id: String) throws -> ChecklistItem? {
        try db.queryOneV("SELECT * FROM checklist_item WHERE id = ?", id).map { try checklistRow($0) }
    }

    public func softDeleteChecklistItem(id: String) throws {
        let n = try db.runV("UPDATE checklist_item SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL",
                           clock.now(), id)
        if n == 0 { throw WorkLogError.notFound("checklist_item \(id)") }
    }

    // MARK: Activity

    public func insertActivity(_ activity: Activity) throws {
        try db.transaction {
            try db.runV("""
                INSERT INTO activity
                    (id, task_id, body, work_date, recorded_at, kind, revision, deleted_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, activity.id, activity.taskId, activity.body, activity.workDate,
                   activity.recordedAt, activity.kind.rawValue, activity.revision, activity.deletedAt)
            for projectId in activity.projectIds {
                try db.runV("INSERT OR IGNORE INTO activity_project (activity_id, project_id) VALUES (?, ?)",
                           activity.id, projectId)
            }
            for checklistItemId in activity.checklistItemIds {
                try db.runV("INSERT OR IGNORE INTO activity_checklist (activity_id, checklist_item_id) VALUES (?, ?)",
                           activity.id, checklistItemId)
            }
        }
        onSourceChanged?("activity", activity.id)
    }

    public func activity(id: String) throws -> Activity? {
        try db.queryOneV("SELECT * FROM activity WHERE id = ?", id).map { try activityRow($0) }
    }

    /// work_date, recorded_at 오름차순.
    public func activities(taskId: String) throws -> [Activity] {
        try db.queryV("""
            SELECT * FROM activity WHERE task_id = ? AND deleted_at IS NULL
            ORDER BY work_date ASC, recorded_at ASC, id ASC
            """, taskId).map { try activityRow($0) }
    }

    public func activities(on date: WorkDate) throws -> [Activity] {
        try db.queryV("""
            SELECT * FROM activity WHERE work_date = ? AND deleted_at IS NULL
            ORDER BY recorded_at ASC, id ASC
            """, date).map { try activityRow($0) }
    }

    public func activities(in range: DateRange) throws -> [Activity] {
        try db.queryV("""
            SELECT * FROM activity WHERE work_date >= ? AND work_date < ? AND deleted_at IS NULL
            ORDER BY work_date ASC, recorded_at ASC, id ASC
            """, range.start, range.endExclusive).map { try activityRow($0) }
    }

    // MARK: DomainEvent (append-only)

    public func appendEvent(_ event: DomainEvent) throws {
        try insertEventRow(event)
    }

    /// 여러 사건을 한 transaction으로 저장한다.
    public func appendEvents(_ events: [DomainEvent]) throws {
        try db.transaction {
            for event in events { try insertEventRow(event) }
        }
    }

    public func events(taskId: String) throws -> [DomainEvent] {
        try db.queryV("""
            SELECT * FROM domain_event WHERE task_id = ?
            ORDER BY effective_date ASC, effective_order ASC, recorded_at ASC, id ASC
            """, taskId).map { try eventRow($0) }
    }

    public func allEvents() throws -> [DomainEvent] {
        try db.queryV("""
            SELECT * FROM domain_event
            ORDER BY effective_date ASC, effective_order ASC, recorded_at ASC, id ASC
            """).map { try eventRow($0) }
    }

    public func events(onOrBefore date: WorkDate) throws -> [DomainEvent] {
        try db.queryV("""
            SELECT * FROM domain_event WHERE effective_date <= ?
            ORDER BY effective_date ASC, effective_order ASC, recorded_at ASC, id ASC
            """, date).map { try eventRow($0) }
    }

    public func events(in range: DateRange) throws -> [DomainEvent] {
        try db.queryV("""
            SELECT * FROM domain_event WHERE effective_date >= ? AND effective_date < ?
            ORDER BY effective_date ASC, effective_order ASC, recorded_at ASC, id ASC
            """, range.start, range.endExclusive).map { try eventRow($0) }
    }

    /// 해당 Task·업무일의 다음 effective_order (MAX+1, 없으면 1).
    public func nextEffectiveOrder(taskId: String, on date: WorkDate) throws -> Int {
        try db.scalarIntV("""
            SELECT COALESCE(MAX(effective_order), 0) + 1 FROM domain_event
            WHERE task_id = ? AND effective_date = ?
            """, taskId, date)
    }

    private func insertEventRow(_ event: DomainEvent) throws {
        try db.runV("""
            INSERT INTO domain_event
                (id, task_id, scope_type, scope_id, kind, to_status, effective_date, effective_time,
                 effective_order, recorded_at, supersedes_event_id, note, activity_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, event.id, event.taskId, event.scopeType.rawValue, event.scopeId,
               event.kind.rawValue, event.toStatus?.rawValue, event.effectiveDate,
               event.effectiveTime, event.effectiveOrder, event.recordedAt,
               event.supersedesEventId, event.note, event.activityId)
    }

    // MARK: - Row mapping

    private func taskRow(_ row: SQLRow) throws -> WorkTask {
        guard let id = row.string("id"), let title = row.string("title"),
              let createdAt = row.date("created_at") else {
            throw WorkLogError.storage("task row 손상")
        }
        let modeRaw = row.string("project_tracking_mode") ?? ProjectTrackingMode.shared.rawValue
        let mode = ProjectTrackingMode(rawValue: modeRaw) ?? .shared
        let tagIds = try db.queryV("""
            SELECT tag_id FROM task_tag WHERE task_id = ? ORDER BY tag_id ASC
            """, id).compactMap { $0.string("tag_id") }
        let cachedStatus = row.string("cached_status").flatMap(TaskStatus.init(rawValue:))
        return WorkTask(id: id, title: title, dueOn: row.workDate("due_on"), createdAt: createdAt,
                        projectTrackingMode: mode, revision: row.int("revision") ?? 1,
                        deletedAt: row.date("deleted_at"), tagIds: tagIds, cachedStatus: cachedStatus)
    }

    private func taskProjectRow(_ row: SQLRow) throws -> TaskProject {
        guard let id = row.string("id"), let taskId = row.string("task_id"),
              let projectId = row.string("project_id"),
              let linkedOn = row.workDate("linked_on") else {
            throw WorkLogError.storage("task_project row 손상")
        }
        return TaskProject(id: id, taskId: taskId, projectId: projectId,
                           trackingEnabled: row.bool("tracking_enabled"), linkedOn: linkedOn,
                           removedOn: row.workDate("removed_on"))
    }

    private func checklistRow(_ row: SQLRow) throws -> ChecklistItem {
        guard let id = row.string("id"), let taskId = row.string("task_id"),
              let text = row.string("text") else {
            throw WorkLogError.storage("checklist_item row 손상")
        }
        let projectIds = try db.queryV("""
            SELECT project_id FROM checklist_project WHERE checklist_item_id = ? ORDER BY project_id ASC
            """, id).compactMap { $0.string("project_id") }
        return ChecklistItem(id: id, taskId: taskId, text: text, sortOrder: row.int("sort_order") ?? 0,
                             projectIds: projectIds, deletedAt: row.date("deleted_at"))
    }

    private func activityRow(_ row: SQLRow) throws -> Activity {
        guard let id = row.string("id"), let taskId = row.string("task_id"),
              let body = row.string("body"), let workDate = row.workDate("work_date"),
              let kindRaw = row.string("kind"), let kind = ActivityKind(rawValue: kindRaw) else {
            throw WorkLogError.storage("activity row 손상")
        }
        let projectIds = try db.queryV("""
            SELECT project_id FROM activity_project WHERE activity_id = ? ORDER BY project_id ASC
            """, id).compactMap { $0.string("project_id") }
        let checklistItemIds = try db.queryV("""
            SELECT checklist_item_id FROM activity_checklist WHERE activity_id = ?
            ORDER BY checklist_item_id ASC
            """, id).compactMap { $0.string("checklist_item_id") }
        return Activity(id: id, taskId: taskId, body: body, workDate: workDate,
                        recordedAt: row.date("recorded_at") ?? Date(timeIntervalSince1970: 0),
                        kind: kind, projectIds: projectIds, checklistItemIds: checklistItemIds,
                        revision: row.int("revision") ?? 1, deletedAt: row.date("deleted_at"))
    }

    private func eventRow(_ row: SQLRow) throws -> DomainEvent {
        guard let id = row.string("id"), let taskId = row.string("task_id"),
              let scopeRaw = row.string("scope_type"), let scopeType = EventScopeType(rawValue: scopeRaw),
              let scopeId = row.string("scope_id"),
              let kindRaw = row.string("kind"), let kind = DomainEventKind(rawValue: kindRaw),
              let effectiveDate = row.workDate("effective_date") else {
            throw WorkLogError.storage("domain_event row 손상")
        }
        let toStatus = row.string("to_status").flatMap(TaskStatus.init(rawValue:))
        return DomainEvent(id: id, taskId: taskId, scopeType: scopeType, scopeId: scopeId,
                           kind: kind, toStatus: toStatus, effectiveDate: effectiveDate,
                           effectiveTime: row.date("effective_time"),
                           effectiveOrder: row.int("effective_order") ?? 0,
                           recordedAt: row.date("recorded_at") ?? Date(timeIntervalSince1970: 0),
                           supersedesEventId: row.string("supersedes_event_id"),
                           note: row.string("note"), activityId: row.string("activity_id"))
    }
}
