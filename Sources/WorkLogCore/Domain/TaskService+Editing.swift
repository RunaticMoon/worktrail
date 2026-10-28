import Foundation

/// Editable task properties never replace the task or its append-only state history.
public struct TaskPropertiesDraft: Equatable, Sendable {
    public var title: String
    public var dueOn: WorkDate?
    public var dueReminderDaysBefore: Int?
    public var projectIds: Set<String>
    public var tagNames: [String]

    public init(title: String, dueOn: WorkDate?, dueReminderDaysBefore: Int? = nil,
                projectIds: Set<String>, tagNames: [String]) {
        self.title = title; self.dueOn = dueOn; self.dueReminderDaysBefore = dueReminderDaysBefore
        self.projectIds = projectIds; self.tagNames = tagNames
    }
}

public struct StatusCorrectionPreview: Sendable {
    public let original: DomainEvent
    public let replacement: DomainEvent
    public let invalidation: DomainEvent
    public let conflicts: [String]
    public var canSave: Bool { conflicts.isEmpty }
}

extension TaskService {
    public func updateProperties(taskId: String, draft: TaskPropertiesDraft) throws {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw WorkLogError.validation("업무명을 입력하세요.") }
        let reminder = draft.dueOn == nil ? nil : draft.dueReminderDaysBefore
        if let reminder, !(0...365).contains(reminder) {
            throw WorkLogError.validation("알림 시작일은 0~365일 전으로 선택하세요.")
        }
        try repo.db.transaction {
            guard let task = try repo.task(id: taskId) else { throw WorkLogError.notFound("task \(taskId)") }
            let links = try repo.taskProjects(taskId: taskId)
            let currentIds = Set(links.map(\.projectId))
            for id in draft.projectIds {
                guard let project = try repo.project(id: id), project.archivedAt == nil || currentIds.contains(id) else {
                    throw WorkLogError.validation("선택한 프로젝트가 삭제되거나 보관되었습니다. 다시 선택하세요.")
                }
            }
            let tags = Set(draft.tagNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            let tagIds = try tags.sorted().map { try repo.findOrCreateTag(name: $0).id }
            try repo.db.runV("""
                UPDATE task SET title = ?, due_on = ?, due_reminder_days_before = ?, revision = revision + 1
                WHERE id = ? AND deleted_at IS NULL
                """, title, draft.dueOn, reminder, taskId)
            try repo.db.runV("DELETE FROM task_tag WHERE task_id = ?", taskId)
            for tagId in tagIds { try repo.db.runV("INSERT INTO task_tag (task_id, tag_id) VALUES (?, ?)", taskId, tagId) }
            let date = repo.calendar.workDate(of: repo.clock.now())
            for id in currentIds.subtracting(draft.projectIds) {
                try repo.db.runV("UPDATE task_project SET removed_on = ? WHERE task_id = ? AND project_id = ?", date, taskId, id)
            }
            for id in draft.projectIds.subtracting(currentIds) {
                // Reuse the connection row and all project events; no automatic status propagation.
                if try repo.db.queryOneV("SELECT id FROM task_project WHERE task_id = ? AND project_id = ?", taskId, id) != nil {
                    try repo.db.runV("UPDATE task_project SET removed_on = NULL WHERE task_id = ? AND project_id = ?", taskId, id)
                } else {
                    try repo.db.runV("""
                        INSERT INTO task_project (id, task_id, project_id, tracking_enabled, linked_on, removed_on)
                        VALUES (?, ?, ?, ?, ?, NULL)
                        """, repo.ids.make(), taskId, id, task.projectTrackingMode == .perProject, date)
                }
            }
        }
        // The search index observes only the committed, complete edit.
        repo.onSourceChanged?("task", taskId)
    }

    public func editChecklistItem(itemId: String, text: String, projectIds: [String]) throws {
        guard var item = try repo.checklistItem(id: itemId), item.deletedAt == nil else {
            throw WorkLogError.notFound("checklist_item \(itemId)")
        }
        item.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !item.text.isEmpty else { throw WorkLogError.validation("체크리스트 내용을 입력하세요.") }
        let allowed = Set(try repo.taskProjects(taskId: item.taskId).map(\.projectId))
        guard Set(projectIds).isSubset(of: allowed) else {
            throw WorkLogError.validation("업무에 연결된 프로젝트만 선택할 수 있습니다.")
        }
        item.projectIds = Array(Set(projectIds)).sorted()
        try restoreChecklistItem(item)
    }

    /// Restores editable fields/deletion only. Completion events remain exactly as recorded.
    public func restoreChecklistItem(_ item: ChecklistItem) throws {
        guard let existing = try repo.checklistItem(id: item.id), existing.taskId == item.taskId else {
            throw WorkLogError.notFound("checklist_item \(item.id)")
        }
        try repo.db.transaction {
            try repo.db.runV("UPDATE checklist_item SET text = ?, sort_order = ?, deleted_at = ? WHERE id = ?",
                            item.text, item.sortOrder, item.deletedAt, item.id)
            try repo.db.runV("DELETE FROM checklist_project WHERE checklist_item_id = ?", item.id)
            for projectId in Set(item.projectIds) {
                try repo.db.runV("INSERT INTO checklist_project (checklist_item_id, project_id) VALUES (?, ?)", item.id, projectId)
            }
        }
        repo.onSourceChanged?("task", item.taskId)
    }

    public func deleteChecklistItem(itemId: String) throws {
        try repo.softDeleteChecklistItem(id: itemId)
    }

    public func reorderChecklist(taskId: String, itemIds: [String]) throws {
        try repo.db.transaction {
            let existing = try repo.checklistItems(taskId: taskId)
            guard itemIds.count == existing.count, Set(itemIds) == Set(existing.map(\.id)) else {
                throw WorkLogError.conflict("체크리스트가 변경되었습니다. 다시 불러오세요.")
            }
            for (index, id) in itemIds.enumerated() {
                try repo.db.runV("UPDATE checklist_item SET sort_order = ? WHERE id = ?", index + 1, id)
            }
        }
        repo.onSourceChanged?("task", taskId)
    }

    public func previewStatusCorrection(taskId: String, eventId: String, workDate: WorkDate,
                                        kind: DomainEventKind, createdStatus: TaskStatus? = nil,
                                        note: String? = nil) throws -> StatusCorrectionPreview {
        let events = try repo.events(taskId: taskId)
        guard let original = StateReplay.effectiveEvents(events, knownAt: nil).first(where: { $0.id == eventId }),
              original.kind.isStatusEvent else {
            throw WorkLogError.conflict("이미 정정되었거나 상태 사건이 아닙니다. 이력을 다시 불러오세요.")
        }
        guard kind.isStatusEvent, (original.kind == .created) == (kind == .created) else {
            throw WorkLogError.validation("생성 사건과 이후 상태 변경 사건은 서로 바꿀 수 없습니다.")
        }
        let status: TaskStatus
        switch kind {
        case .created:
            guard let createdStatus else { throw WorkLogError.validation("생성 상태를 선택하세요.") }
            status = createdStatus
        case .started, .resumed: status = .inProgress
        case .reopened: status = original.scopeType == .checklistItem ? .planned : .inProgress
        case .paused: status = .onHold
        case .completed: status = .completed
        case .cancelled: status = .cancelled
        case .replanned: status = .planned
        default: throw WorkLogError.validation("정정할 상태 사건을 선택하세요.")
        }
        let now = repo.clock.now()
        let order = original.effectiveDate == workDate ? original.effectiveOrder : try repo.nextEffectiveOrder(taskId: taskId, on: workDate)
        let replacement = DomainEvent(id: "correction-preview-\(eventId)", taskId: taskId,
            scopeType: original.scopeType, scopeId: original.scopeId, kind: kind, toStatus: status,
            effectiveDate: workDate, effectiveTime: original.effectiveDate == workDate ? original.effectiveTime : nil,
            effectiveOrder: order, recordedAt: now,
            supersedesEventId: original.id, note: note)
        let invalidation = DomainEvent(id: "void-preview-\(eventId)", taskId: taskId,
            scopeType: original.scopeType, scopeId: original.scopeId, kind: .voided,
            effectiveDate: original.effectiveDate, effectiveOrder: original.effectiveOrder,
            recordedAt: now, supersedesEventId: original.id, note: note)
        let before = Set(StateReplay.replay(events, through: nil, knownAt: nil).violations)
        let combined = events + [invalidation, replacement]
        let violations = StateReplay.replay(combined, through: nil, knownAt: nil).violations.filter { !before.contains($0) }
        let conflicts = violations.map { violation in
            let date = combined.first { $0.id == violation.eventId }?.effectiveDate.iso ?? ""
            return "\(date) · \(violation.kind.rawValue): \(violation.reason)"
        }
        return StatusCorrectionPreview(original: original, replacement: replacement, invalidation: invalidation, conflicts: conflicts)
    }

    @discardableResult public func correctStatusEvent(taskId: String, eventId: String, workDate: WorkDate,
                                                     kind: DomainEventKind, createdStatus: TaskStatus? = nil,
                                                     note: String? = nil) throws -> DomainEvent {
        let replacement: DomainEvent = try repo.db.transaction {
            let preview = try previewStatusCorrection(taskId: taskId, eventId: eventId, workDate: workDate,
                                                      kind: kind, createdStatus: createdStatus, note: note)
            guard preview.canSave else { throw WorkLogError.invalidTransition(preview.conflicts.joined(separator: "\n")) }
            var invalidation = preview.invalidation, replacement = preview.replacement
            invalidation.id = repo.ids.make(); replacement.id = repo.ids.make()
            try repo.appendEvents([invalidation, replacement])
            let replay = StateReplay.replay(try repo.events(taskId: taskId), through: nil, knownAt: nil)
            try repo.setTaskCachedStatus(id: taskId, status: replay.taskStatus(taskId))
            return replacement
        }
        repo.onSourceChanged?("task", taskId)
        return replacement
    }
}
