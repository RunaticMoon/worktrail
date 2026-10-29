import Foundation
import Observation

@Observable @MainActor public final class TaskDetailModel {
    public private(set) var detail: TaskDetail?
    public private(set) var errorMessage: String?
    public private(set) var completionCheck: CompletionCheck?
    public private(set) var asOf: WorkDate?
    public var workDate: WorkDate
    public var statusNote = ""
    private var savedStatusNote = ""
    public private(set) var statusEvents: [DomainEvent] = []
    public private(set) var noticeMessage: String?
    public private(set) var checklistUndoCount = 0
    @ObservationIgnored private var checklistUndo: [ChecklistUndo] = []
    private enum ChecklistUndo { case item(ChecklistItem), order([String]) }
    public var activityText = ""
    /// 진행 기록의 범위. nil = Task 공통 기록, 값이 있으면 그 프로젝트 기록.
    public var activityProjectId: String?
    public var checklistText = ""
    @ObservationIgnored public var onChanged: (() -> Void)?
    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private var taskId: String?

    public init(environment: AppEnvironment) {
        self.environment = environment
        workDate = environment.calendar.workDate(of: environment.options.clock.now())
    }
    public var hasUnsavedInput: Bool {
        !activityText.isEmpty || !checklistText.isEmpty || statusNote != savedStatusNote
    }

    public func discardInput() {
        activityText = ""; checklistText = ""; statusNote = ""; savedStatusNote = ""
    }

    /// false면 선택과 입력을 그대로 유지한다. true는 조회 성공 여부가 아닌 선택 수락 여부다.
    @discardableResult public func load(taskId: String, asOf: WorkDate? = nil) -> Bool {
        guard (self.taskId == taskId && self.asOf == asOf) || !hasUnsavedInput else { return false }
        // 다른 업무의 입력·범위·실행 취소 이력을 새 업무로 넘기지 않는다.
        if self.taskId != taskId {
            discardInput()
            activityProjectId = nil; workDate = today; noticeMessage = nil
            checklistUndo = []; checklistUndoCount = 0
        }
        self.taskId = taskId; self.asOf = asOf; completionCheck = nil
        do {
            detail = try environment.tasks.detail(taskId: taskId, asOf: asOf)
            statusEvents = try environment.repo.events(taskId: taskId).filter {
                ($0.kind.isStatusEvent || $0.kind == .voided) && (asOf == nil || $0.effectiveDate <= asOf!)
            }
            errorMessage = nil
            // 연결이 해제된 프로젝트를 범위로 들고 있으면 공통으로 되돌린다.
            if let selected = activityProjectId,
               !(detail?.projects.contains { $0.project.id == selected } ?? false) {
                activityProjectId = nil
            }
        } catch {
            detail = nil; statusEvents = []
            errorMessage = "업무를 불러오지 못했습니다. 다시 선택하세요."
        }
        return true
    }
    @discardableResult private func update(_ action: (String) throws -> Void) -> Bool {
        guard asOf == nil, let taskId else { return false }
        do { try action(taskId); load(taskId: taskId); onChanged?(); return true }
        catch {
            errorMessage = (error as? WorkLogError)?.localizedDescription ?? "변경을 저장하지 못했습니다. 입력은 그대로입니다. 다시 시도하세요."
            return false
        }
    }
    public var workCalendar: WorkCalendar { environment.calendar }
    public var today: WorkDate { environment.calendar.workDate(of: environment.options.clock.now()) }

    public func setDueDate(_ dueOn: WorkDate?) {
        update { try environment.tasks.updateTaskDue(taskId: $0, dueOn: dueOn,
            dueReminderDaysBefore: dueOn == nil ? nil : detail?.task.dueReminderDaysBefore) }
    }

    public func setDueReminderDaysBefore(_ days: Int?) {
        update { try environment.tasks.updateTaskDue(taskId: $0, dueOn: detail?.task.dueOn,
            dueReminderDaysBefore: days) }
    }

    public func changeStatus(_ kind: DomainEventKind) {
        if update({ try environment.tasks.changeTaskStatus(taskId: $0, kind: kind, workDate: workDate, note: statusNote.isEmpty ? nil : statusNote) }) {
            savedStatusNote = statusNote
        }
    }
    public func complete(confirmRemaining: Bool = false) {
        guard asOf == nil, let taskId else { return }
        do {
            let result = try environment.tasks.completeTask(taskId: taskId, workDate: workDate, confirmRemaining: confirmRemaining, note: statusNote.isEmpty ? nil : statusNote)
            if result.completed {
                savedStatusNote = statusNote
                load(taskId: taskId); onChanged?()
            } else { completionCheck = result; errorMessage = nil }
        } catch { errorMessage = (error as? WorkLogError)?.localizedDescription ?? "완료하지 못했습니다. 업무 상태를 확인하세요." }
    }
    public func cancelCompletion() { completionCheck = nil }
    public func setChecklist(itemId: String, done: Bool) {
        update { _ in try environment.tasks.setChecklistItem(itemId: itemId, done: done, workDate: workDate) }
    }
    public func addChecklistItem() {
        update { _ = try environment.tasks.addChecklistItem(taskId: $0, text: checklistText); checklistText = "" }
    }
    public func changeProjectStatus(projectId: String, kind: DomainEventKind) {
        if update({ try environment.tasks.changeProjectStatus(taskId: $0, projectId: projectId, kind: kind, workDate: workDate, note: statusNote.isEmpty ? nil : statusNote) }) {
            savedStatusNote = statusNote
        }
    }
    public func addActivity() {
        guard !activityText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "진행 내용을 입력하세요."; return
        }
        // activityProjectId는 저장 후에도 유지한다(같은 범위로 연속 기록 편의). 본문만 비운다.
        let scope = activityProjectId.map { [$0] } ?? []
        update { _ = try environment.tasks.addActivity(taskId: $0, body: activityText, workDate: workDate, projectIds: scope); activityText = "" }
    }

    public var availableProjects: [Project] {
        let current = Set(detail?.projects.map { $0.project.id } ?? [])
        return ((try? environment.repo.projects(includeArchived: true)) ?? []).filter { $0.archivedAt == nil || current.contains($0.id) }
    }

    public var propertiesDraft: TaskPropertiesDraft? {
        guard let detail else { return nil }
        let ids = Set(detail.task.tagIds)
        let names = ((try? environment.repo.tags()) ?? []).filter { ids.contains($0.id) }.map(\.name)
        return TaskPropertiesDraft(title: detail.task.title, dueOn: detail.task.dueOn,
            dueReminderDaysBefore: detail.task.dueReminderDaysBefore,
            projectIds: Set(detail.projects.map { $0.project.id }), tagNames: names)
    }

    @discardableResult public func saveProperties(_ draft: TaskPropertiesDraft) -> Bool {
        update { try environment.tasks.updateProperties(taskId: $0, draft: draft) }
    }

    @discardableResult public func editChecklist(itemId: String, text: String, projectIds: [String]) -> Bool {
        guard let original = detail?.checklist.first(where: { $0.item.id == itemId })?.item else { return false }
        let saved = update { _ in try environment.tasks.editChecklistItem(itemId: itemId, text: text, projectIds: projectIds) }
        if saved { checklistUndo.append(.item(original)); checklistUndoCount = checklistUndo.count }
        return saved
    }

    public func deleteChecklist(itemId: String) {
        guard let original = detail?.checklist.first(where: { $0.item.id == itemId })?.item else { return }
        if update({ _ in try environment.tasks.deleteChecklistItem(itemId: itemId) }) {
            checklistUndo.append(.item(original)); checklistUndoCount = checklistUndo.count
        }
    }

    public func moveChecklist(itemId: String, before targetId: String) {
        guard let items = detail?.checklist.map({ $0.item.id }), let from = items.firstIndex(of: itemId),
              let target = items.firstIndex(of: targetId), from != target else { return }
        var reordered = items; reordered.remove(at: from)
        reordered.insert(itemId, at: target > from ? target - 1 : target)
        saveChecklistOrder(reordered, previous: items)
    }

    public func moveChecklist(itemId: String, offset: Int) {
        guard let items = detail?.checklist.map({ $0.item.id }), let from = items.firstIndex(of: itemId),
              items.indices.contains(from + offset) else { return }
        var reordered = items; reordered.remove(at: from); reordered.insert(itemId, at: from + offset)
        saveChecklistOrder(reordered, previous: items)
    }

    private func saveChecklistOrder(_ ids: [String], previous: [String]) {
        if update({ try environment.tasks.reorderChecklist(taskId: $0, itemIds: ids) }) {
            checklistUndo.append(.order(previous)); checklistUndoCount = checklistUndo.count
        }
    }

    public func undoChecklistEdit() {
        guard let undo = checklistUndo.last else { return }
        if update({ id in
            switch undo {
            case .item(let item): try environment.tasks.restoreChecklistItem(item)
            case .order(let ids): try environment.tasks.reorderChecklist(taskId: id, itemIds: ids)
            }
        }) { checklistUndo.removeLast(); checklistUndoCount = checklistUndo.count }
    }

    public func checklistScopeLabel(_ item: ChecklistItem) -> String {
        guard !item.projectIds.isEmpty else { return "공통" }
        return item.projectIds.map { id in
            detail?.projects.first { $0.project.id == id }?.project.name
                ?? ((try? environment.repo.project(id: id))?.name ?? "연결 해제된 프로젝트")
        }.joined(separator: " · ")
    }

    public func isSuperseded(_ event: DomainEvent) -> Bool {
        statusEvents.contains { $0.kind == .voided && $0.supersedesEventId == event.id }
    }

    public func eventScopeLabel(_ event: DomainEvent) -> String {
        switch event.scopeType {
        case .task: return "업무 전체"
        case .taskProject:
            return detail?.projects.first { TaskProject.scopeId(taskId: event.taskId, projectId: $0.project.id) == event.scopeId }?.project.name ?? "프로젝트 적용"
        case .checklistItem:
            return ((try? environment.repo.checklistItem(id: event.scopeId))?.text).map { "체크리스트 · " + $0 } ?? "체크리스트"
        }
    }

    public func correctionConflicts(event: DomainEvent, date: WorkDate, kind: DomainEventKind,
                                   createdStatus: TaskStatus, note: String) -> [String] {
        do {
            return try environment.tasks.previewStatusCorrection(taskId: event.taskId, eventId: event.id,
                workDate: date, kind: kind, createdStatus: createdStatus, note: note).conflicts
        } catch { return [(error as? WorkLogError)?.localizedDescription ?? "이력을 확인하지 못했습니다. 다시 시도하세요."] }
    }

    @discardableResult public func correctEvent(_ event: DomainEvent, date: WorkDate, kind: DomainEventKind,
                                               createdStatus: TaskStatus, note: String) -> Bool {
        let saved = update { _ in
            _ = try environment.tasks.correctStatusEvent(taskId: event.taskId, eventId: event.id,
                workDate: date, kind: kind, createdStatus: createdStatus, note: note)
        }
        if saved { noticeMessage = "상태 이력을 정정했습니다. 영향받는 보고서 초안은 다시 생성해 확인하세요. 확정 리포트와 당시 근거는 유지됩니다." }
        return saved
    }

    // MARK: - 요약 표현·범위

    /// 진행 기록 범위 선택지. 첫 항목은 (nil, "공통"), 이어서 연결된 프로젝트 이름순.
    /// 제거된 연결은 detail.projects에 없으므로 자동으로 빠진다.
    public var activityScopeOptions: [(id: String?, label: String)] {
        var options: [(id: String?, label: String)] = [(nil, "공통")]
        let linked = (detail?.projects ?? [])
            .map { (id: $0.project.id, label: $0.project.name) }
            .sorted { $0.label < $1.label }
        for entry in linked { options.append((id: Optional(entry.id), label: entry.label)) }
        return options
    }

    /// 진행 기록의 범위 라벨. 프로젝트가 없으면 "공통", 있으면 프로젝트 이름(" · " 연결).
    public func activityScopeLabel(_ activity: Activity) -> String {
        guard !activity.projectIds.isEmpty else { return "공통" }
        let names = activity.projectIds.map { id -> String in
            if let project = detail?.projects.first(where: { $0.project.id == id })?.project {
                return project.name
            }
            if let project = try? environment.repo.project(id: id) { return project.name }
            return id
        }
        return names.joined(separator: " · ")
    }

    /// tracking 프로젝트만 "이름 상태라벨"로 요약. 없으면 nil.
    public var projectStatusSummary: String? {
        let parts = (detail?.projects ?? [])
            .filter { $0.link.trackingEnabled }
            .map { (name: $0.project.name, status: $0.status) }
            .sorted { $0.name < $1.name }
            .map { "\($0.name) \($0.status?.koreanLabel ?? "")" }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "체크리스트 2/3". 항목이 없으면 nil. 퍼센트·"완료율" 표현은 쓰지 않는다.
    public var checklistSummary: String? {
        guard let checklist = detail?.checklist, !checklist.isEmpty else { return nil }
        let done = checklist.filter { $0.done }.count
        return "체크리스트 \(done)/\(checklist.count)"
    }

    /// 오늘이 속한 주의 확정된 계획에 이 업무(Task 전체 또는 프로젝트 범위)가 포함되면 true.
    /// 계획 조회만 하며 상태·시작일을 바꾸지 않는다.
    public var isInThisWeekPlan: Bool {
        guard let taskId else { return false }
        let today = environment.calendar.workDate(of: environment.options.clock.now())
        let weekStart = environment.periods.weekStart(containing: today)
        guard let result = try? environment.plans.plan(weekStart: weekStart) else { return false }
        return result.items.contains { item in
            item.taskId == taskId && item.state == .confirmed

        }
    }

    /// 완료 확인 시트용 문구. 남은 체크리스트(최대 3개 + "그 외 n개")와
    /// 완료되지 않은 tracking 프로젝트를 보여준다. 확인 대상이 없으면 [].
    public var completionScopeLines: [String] {
        guard let check = completionCheck else { return [] }
        var lines: [String] = []
        let items = check.remainingChecklist.map(\.text)
        if !items.isEmpty {
            var text = "남은 체크리스트 \(items.count)개: " + items.prefix(3).joined(separator: ", ")
            if items.count > 3 { text += ", 그 외 \(items.count - 3)개" }
            lines.append(text)
        }
        if !check.unfinishedProjects.isEmpty {
            let names = check.unfinishedProjects.map { entry -> String in
                let name = detail?.projects.first { $0.project.id == entry.projectId }?.project.name
                    ?? entry.projectId
                return "\(name)(\(entry.status.koreanLabel))"
            }
            lines.append("적용 상태가 완료되지 않은 프로젝트: " + names.joined(separator: ", "))
        }
        return lines
    }
}
