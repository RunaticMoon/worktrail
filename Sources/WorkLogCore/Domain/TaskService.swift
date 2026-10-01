import Foundation

// MARK: - 조회 모델

/// 전체 완료 시도 결과. 남은 범위와 실제로 완료 사건을 기록했는지 여부.
public struct CompletionCheck: Equatable, Sendable {
    /// 완료되지 않은(재생 결과 completed 아님) 삭제 안 된 항목
    public var remainingChecklist: [ChecklistItem]
    /// tracking 프로젝트 중 completed/cancelled 아닌 것
    public var unfinishedProjects: [(projectId: String, status: TaskStatus)]
    /// 실제로 완료 사건을 기록했는지
    public var completed: Bool

    public init(remainingChecklist: [ChecklistItem],
                unfinishedProjects: [(projectId: String, status: TaskStatus)],
                completed: Bool) {
        self.remainingChecklist = remainingChecklist
        self.unfinishedProjects = unfinishedProjects
        self.completed = completed
    }

    public static func == (lhs: CompletionCheck, rhs: CompletionCheck) -> Bool {
        guard lhs.completed == rhs.completed,
              lhs.remainingChecklist == rhs.remainingChecklist,
              lhs.unfinishedProjects.count == rhs.unfinishedProjects.count else { return false }
        for (l, r) in zip(lhs.unfinishedProjects, rhs.unfinishedProjects) {
            if l.projectId != r.projectId || l.status != r.status { return false }
        }
        return true
    }
}

/// Task 상세 조회 모델. 상태는 항상 이벤트 재생으로 계산한 값이다.
public struct TaskDetail: Sendable {
    public var task: WorkTask
    public var status: TaskStatus?
    /// tracking 아닌 프로젝트는 status nil
    public var projects: [(project: Project, link: TaskProject, status: TaskStatus?)]
    public var checklist: [(item: ChecklistItem, done: Bool)]
    public var activities: [Activity]
    public var links: [WorkLink]
    public var firstStartedOn: WorkDate?
    public var completionDates: [WorkDate]
    public var relations: [TaskRelation]
    public var violations: [TransitionViolation]

    public init(task: WorkTask, status: TaskStatus?,
                projects: [(project: Project, link: TaskProject, status: TaskStatus?)],
                checklist: [(item: ChecklistItem, done: Bool)], activities: [Activity],
                links: [WorkLink], firstStartedOn: WorkDate?, completionDates: [WorkDate],
                relations: [TaskRelation], violations: [TransitionViolation]) {
        self.task = task
        self.status = status
        self.projects = projects
        self.checklist = checklist
        self.activities = activities
        self.links = links
        self.firstStartedOn = firstStartedOn
        self.completionDates = completionDates
        self.relations = relations
        self.violations = violations
    }
}

// MARK: - Task 도메인 서비스

/// 입력·상태 변경 명령을 저장소에 원자적으로 기록한다.
/// 상태는 항상 이벤트 재생으로 계산하며, 허용되지 않는 전이는 저장 전에 거부한다.
public final class TaskService: @unchecked Sendable {
    private let repo: WorkRepository

    public init(repo: WorkRepository) {
        self.repo = repo
    }

    // MARK: - Memo

    /// 본문만으로 Memo를 저장한다. 프로젝트·태그는 이름으로 찾거나 만든다.
    /// 본문 URL은 work_link(ownerType memo)로 저장하며 내용을 가져오지 않는다.
    public func captureMemo(body: String, workDate: WorkDate? = nil,
                            projectNames: [String] = [], tagNames: [String] = []) throws -> Memo {
        let date = resolved(workDate)
        let now = repo.clock.now()
        return try repo.db.transaction {
            let projectIds = try projectNames.map { try repo.findOrCreateProject(name: $0).id }
            let tagIds = try tagNames.map { try repo.findOrCreateTag(name: $0).id }
            let memo = Memo(id: repo.ids.make(), body: body, workDate: date, recordedAt: now,
                            projectIds: projectIds, tagIds: tagIds)
            try repo.insertMemo(memo)
            let urls = unique(LinkExtractor.urls(in: body))
            try insertLinks(ownerType: .memo, ownerId: memo.id, urls: urls, createdAt: now)
            return memo
        }
    }

    // MARK: - Task 생성

    /// 하나의 transaction으로 Task 생성과 초기 기록을 저장한다.
    /// initialStatus == .completed 이면 started 사건을 만들지 않는다(시작일 추정 금지).
    public func createTask(title: String, initialStatus: TaskStatus = .planned,
                           workDate: WorkDate? = nil, effectiveTime: Date? = nil,
                           dueOn: WorkDate? = nil, projectNames: [String] = [],
                           trackingMode: ProjectTrackingMode = .shared, tagNames: [String] = [],
                           checklist: [String] = [], note: String? = nil,
                           links: [String] = []) throws -> WorkTask {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WorkLogError.validation("업무명이 비어 있습니다.")
        }
        let date = resolved(workDate)
        let now = repo.clock.now()
        return try repo.db.transaction {
            let tagIds = try tagNames.map { try repo.findOrCreateTag(name: $0).id }
            let task = WorkTask(id: repo.ids.make(), title: trimmed, dueOn: dueOn, createdAt: now,
                                projectTrackingMode: trackingMode, tagIds: tagIds,
                                cachedStatus: initialStatus)
            try repo.insertTask(task)

            let created = try makeEvent(taskId: task.id, scopeType: .task, scopeId: task.id,
                                        kind: .created, toStatus: initialStatus, effectiveDate: date,
                                        effectiveTime: effectiveTime, effectiveOrder: nil,
                                        recordedAt: now, note: nil, activityId: nil)
            try repo.appendEvent(created)

            for name in projectNames {
                let project = try repo.findOrCreateProject(name: name)
                try repo.linkProject(taskId: task.id, projectId: project.id,
                                     trackingEnabled: trackingMode == .perProject, linkedOn: date)
            }

            for (index, text) in checklist.enumerated() {
                let item = ChecklistItem(id: repo.ids.make(), taskId: task.id, text: text,
                                         sortOrder: index + 1)
                try repo.insertChecklistItem(item)
            }

            if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let activity = Activity(id: repo.ids.make(), taskId: task.id, body: note,
                                        workDate: date, recordedAt: now,
                                        kind: initialStatus == .completed ? .completion : .progress)
                try repo.insertActivity(activity)
            }

            try insertLinks(ownerType: .task, ownerId: task.id, urls: unique(links), createdAt: now)
            return task
        }
    }

    // MARK: - 진행 기록

    /// 진행 기록을 추가한다. projectIds가 비어 있으면 Task 공통 기록이며
    /// 어떤 프로젝트 상태 사건도 만들지 않는다.
    public func addActivity(taskId: String, body: String, workDate: WorkDate? = nil,
                            effectiveTime: Date? = nil, projectIds: [String] = [],
                            checklistItemIds: [String] = [], kind: ActivityKind = .progress,
                            links: [String] = []) throws -> Activity {
        _ = try requireTask(taskId)
        let date = resolved(workDate)
        let now = repo.clock.now()
        return try repo.db.transaction {
            let activity = Activity(id: repo.ids.make(), taskId: taskId, body: body, workDate: date,
                                    recordedAt: now, kind: kind, projectIds: projectIds,
                                    checklistItemIds: checklistItemIds)
            try repo.insertActivity(activity)

            let event = try makeEvent(taskId: taskId, scopeType: .task, scopeId: taskId,
                                      kind: .activityAdded, toStatus: nil, effectiveDate: date,
                                      effectiveTime: effectiveTime, effectiveOrder: nil,
                                      recordedAt: now, note: nil, activityId: activity.id)
            try repo.appendEvent(event)

            let urls = unique(LinkExtractor.urls(in: body) + links)
            try insertLinks(ownerType: .activity, ownerId: activity.id, urls: urls, createdAt: now)
            return activity
        }
    }

    // MARK: - 상태 변경

    /// scope task 상태 사건(started/paused/resumed/reopened/cancelled/replanned).
    /// completed는 completeTask로만 기록한다.
    public func changeTaskStatus(taskId: String, kind: DomainEventKind, workDate: WorkDate? = nil,
                                 effectiveTime: Date? = nil, effectiveOrder: Int? = nil,
                                 note: String? = nil) throws {
        _ = try requireTask(taskId)
        guard let toStatus = status(forTaskKind: kind) else {
            throw WorkLogError.invalidTransition(
                "changeTaskStatus는 \(kind.rawValue) 사건을 허용하지 않습니다. 전체 완료는 completeTask를 사용하세요.")
        }
        let date = resolved(workDate)
        let now = repo.clock.now()
        try repo.db.transaction {
            let existing = try repo.events(taskId: taskId)
            let event = try makeEvent(taskId: taskId, scopeType: .task, scopeId: taskId, kind: kind,
                                      toStatus: toStatus, effectiveDate: date,
                                      effectiveTime: effectiveTime, effectiveOrder: effectiveOrder,
                                      recordedAt: now, note: note, activityId: nil)
            try validate(event, against: existing)
            try repo.appendEvent(event)
            try refreshCachedStatus(taskId)
        }
    }

    /// 전체 완료는 사용자 확정이다. 남은 범위가 있고 confirmRemaining == false면 기록하지 않는다.
    /// confirmRemaining == true여도 남은 항목·프로젝트를 자동 완료하지 않는다.
    public func completeTask(taskId: String, workDate: WorkDate? = nil, effectiveTime: Date? = nil,
                             confirmRemaining: Bool, note: String? = nil) throws -> CompletionCheck {
        _ = try requireTask(taskId)
        let date = resolved(workDate)
        let now = repo.clock.now()

        let events = try repo.events(taskId: taskId)
        let replay = StateReplay.replay(events, through: nil, knownAt: nil)

        let remainingChecklist = try repo.checklistItems(taskId: taskId)
            .filter { replay.checklistStatus($0.id) != .completed }
        let unfinishedProjects: [(projectId: String, status: TaskStatus)] =
            try repo.taskProjects(taskId: taskId)
                .filter { $0.trackingEnabled }
                .compactMap { link in
                    let status = replay.projectStatus(taskId: taskId, projectId: link.projectId) ?? .planned
                    guard status != .completed, status != .cancelled else { return nil }
                    return (projectId: link.projectId, status: status)
                }

        let hasRemaining = !remainingChecklist.isEmpty || !unfinishedProjects.isEmpty
        if hasRemaining && !confirmRemaining {
            return CompletionCheck(remainingChecklist: remainingChecklist,
                                   unfinishedProjects: unfinishedProjects, completed: false)
        }

        try repo.db.transaction {
            let existing = try repo.events(taskId: taskId)
            let event = try makeEvent(taskId: taskId, scopeType: .task, scopeId: taskId,
                                      kind: .completed, toStatus: .completed, effectiveDate: date,
                                      effectiveTime: effectiveTime, effectiveOrder: nil,
                                      recordedAt: now, note: note, activityId: nil)
            try validate(event, against: existing)
            try repo.appendEvent(event)
            try refreshCachedStatus(taskId)
        }

        return CompletionCheck(remainingChecklist: remainingChecklist,
                               unfinishedProjects: unfinishedProjects, completed: true)
    }

    /// 특정 프로젝트에만 적용되는 상태 사건. Task 전체·다른 프로젝트는 바뀌지 않는다.
    public func changeProjectStatus(taskId: String, projectId: String, kind: DomainEventKind,
                                    workDate: WorkDate? = nil, note: String? = nil) throws {
        _ = try requireTask(taskId)
        guard let toStatus = status(forProjectKind: kind) else {
            throw WorkLogError.invalidTransition(
                "프로젝트 적용에는 \(kind.rawValue) 사건을 사용할 수 없습니다.")
        }
        let links = try repo.taskProjects(taskId: taskId)
        guard let link = links.first(where: { $0.projectId == projectId }), link.trackingEnabled else {
            throw WorkLogError.validation("프로젝트별 적용 상태를 관리하지 않는 연결입니다: \(projectId)")
        }
        let date = resolved(workDate)
        let now = repo.clock.now()
        let scopeId = TaskProject.scopeId(taskId: taskId, projectId: projectId)
        try repo.db.transaction {
            let existing = try repo.events(taskId: taskId)
            let event = try makeEvent(taskId: taskId, scopeType: .taskProject, scopeId: scopeId,
                                      kind: kind, toStatus: toStatus, effectiveDate: date,
                                      effectiveTime: nil, effectiveOrder: nil, recordedAt: now,
                                      note: note, activityId: nil)
            try validate(event, against: existing)
            try repo.appendEvent(event)
            // 프로젝트 상태는 Task 전체 상태를 바꾸지 않는다.
        }
    }

    // MARK: - 체크리스트

    /// 체크리스트 완료/해제. 프로젝트·Task 상태는 바뀌지 않는다.
    public func setChecklistItem(itemId: String, done: Bool, workDate: WorkDate? = nil) throws {
        guard let item = try repo.checklistItem(id: itemId) else {
            throw WorkLogError.notFound("checklist_item \(itemId)")
        }
        let date = resolved(workDate)
        let kind: DomainEventKind = done ? .completed : .reopened
        let toStatus: TaskStatus = done ? .completed : .planned
        let now = repo.clock.now()
        try repo.db.transaction {
            let existing = try repo.events(taskId: item.taskId)
            let event = try makeEvent(taskId: item.taskId, scopeType: .checklistItem, scopeId: itemId,
                                      kind: kind, toStatus: toStatus, effectiveDate: date,
                                      effectiveTime: nil, effectiveOrder: nil, recordedAt: now,
                                      note: nil, activityId: nil)
            try validate(event, against: existing)
            try repo.appendEvent(event)
        }
    }

    public func addChecklistItem(taskId: String, text: String,
                                 projectIds: [String] = []) throws -> ChecklistItem {
        _ = try requireTask(taskId)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WorkLogError.validation("체크리스트 항목이 비어 있습니다.")
        }
        return try repo.db.transaction {
            let existing = try repo.checklistItems(taskId: taskId, includeDeleted: true)
            let nextOrder = (existing.map { $0.sortOrder }.max() ?? 0) + 1
            let item = ChecklistItem(id: repo.ids.make(), taskId: taskId, text: trimmed,
                                     sortOrder: nextOrder, projectIds: projectIds)
            try repo.insertChecklistItem(item)
            return item
        }
    }

    // MARK: - 프로젝트 연결

    /// 프로젝트를 이름으로 찾거나 만들어 연결하고 projectLinked 사건을 기록한다.
    public func linkProjects(taskId: String, projectNames: [String], trackingEnabled: Bool,
                             workDate: WorkDate? = nil) throws -> [TaskProject] {
        _ = try requireTask(taskId)
        let date = resolved(workDate)
        let now = repo.clock.now()
        return try repo.db.transaction {
            var result: [TaskProject] = []
            for name in projectNames {
                let project = try repo.findOrCreateProject(name: name)
                let link = try repo.linkProject(taskId: taskId, projectId: project.id,
                                                trackingEnabled: trackingEnabled, linkedOn: date)
                let scopeId = TaskProject.scopeId(taskId: taskId, projectId: project.id)
                let event = try makeEvent(taskId: taskId, scopeType: .taskProject, scopeId: scopeId,
                                          kind: .projectLinked, toStatus: nil, effectiveDate: date,
                                          effectiveTime: nil, effectiveOrder: nil, recordedAt: now,
                                          note: nil, activityId: nil)
                try repo.appendEvent(event)
                result.append(link)
            }
            return result
        }
    }

    // MARK: - 후속 Task

    /// 새 범위는 관련된 새 Task다. 기존 Task의 완료 이력은 바뀌지 않는다.
    public func createFollowUpTask(from taskId: String, title: String,
                                   relation: TaskRelationType = .followUp,
                                   initialStatus: TaskStatus = .planned,
                                   workDate: WorkDate? = nil) throws -> WorkTask {
        _ = try requireTask(taskId)
        let date = resolved(workDate)
        return try repo.db.transaction {
            let task = try createTask(title: title, initialStatus: initialStatus, workDate: date)
            let taskRelation = TaskRelation(id: repo.ids.make(), fromTaskId: taskId,
                                            toTaskId: task.id, type: relation,
                                            createdAt: repo.clock.now())
            try repo.insertRelation(taskRelation)
            return task
        }
    }

    // MARK: - 조회

    public func currentStatus(taskId: String) throws -> TaskStatus? {
        _ = try requireTask(taskId)
        return try replay(taskId: taskId, asOf: nil, knownAt: nil).taskStatus(taskId)
    }

    /// asOf: 그 날짜 종료 상태(nil=현재), knownAt: 그 시각까지 기록된 정보만(nil=전부).
    public func detail(taskId: String, asOf: WorkDate? = nil, knownAt: Date? = nil) throws -> TaskDetail {
        guard let task = try repo.task(id: taskId) else {
            throw WorkLogError.notFound("task \(taskId)")
        }
        let events = try repo.events(taskId: taskId)
        let result = StateReplay.replay(events, through: asOf, knownAt: knownAt)

        let activeLinks = try repo.taskProjects(taskId: taskId).filter { link in
            if let asOf, link.linkedOn > asOf { return false }
            if let removed = link.removedOn {
                if let asOf { return removed > asOf }
                return false
            }
            return true
        }
        var projects: [(project: Project, link: TaskProject, status: TaskStatus?)] = []
        for link in activeLinks {
            guard let project = try repo.project(id: link.projectId) else { continue }
            let status: TaskStatus? = link.trackingEnabled
                ? (result.projectStatus(taskId: taskId, projectId: link.projectId) ?? .planned)
                : nil
            projects.append((project, link, status))
        }

        let checklist = try repo.checklistItems(taskId: taskId).map { item in
            (item: item, done: result.checklistStatus(item.id) == .completed)
        }

        var activities = try repo.activities(taskId: taskId)
        if let knownAt { activities = activities.filter { $0.recordedAt <= knownAt } }
        if let asOf { activities = activities.filter { $0.workDate <= asOf } }

        var links = try repo.links(ownerType: .task, ownerId: taskId)
        for activity in try repo.activities(taskId: taskId) {
            links += try repo.links(ownerType: .activity, ownerId: activity.id)
        }
        if let knownAt { links = links.filter { $0.createdAt <= knownAt } }

        let effective = effectiveEvents(events, asOf: asOf, knownAt: knownAt)
        let firstStarted = effective
            .filter { $0.scopeType == .task && $0.scopeId == taskId }
            .filter { $0.kind == .started || ($0.kind == .created && $0.toStatus == .inProgress) }
            .map { $0.effectiveDate }
            .min()

        let applied = Set(result.appliedEventIds)
        let completionDates = effective
            .filter { $0.scopeType == .task && $0.scopeId == taskId && applied.contains($0.id) }
            .filter { $0.kind == .completed || ($0.kind == .created && $0.toStatus == .completed) }
            .map { $0.effectiveDate }

        return TaskDetail(task: task, status: result.taskStatus(taskId), projects: projects,
                          checklist: checklist, activities: activities, links: links,
                          firstStartedOn: firstStarted, completionDates: completionDates,
                          relations: try repo.relations(taskId: taskId), violations: result.violations)
    }

    /// 모든 Task cachedStatus를 재계산한다 (캐시는 재생성 가능).
    public func rebuildCachedStatuses() throws {
        try repo.db.transaction {
            for task in try repo.tasks(includeDeleted: true) {
                try refreshCachedStatus(task.id)
            }
        }
    }

    // MARK: - 내부

    private func resolved(_ workDate: WorkDate?) -> WorkDate {
        workDate ?? repo.calendar.workDate(of: repo.clock.now())
    }

    private func requireTask(_ taskId: String) throws -> WorkTask {
        guard let task = try repo.task(id: taskId) else {
            throw WorkLogError.notFound("task \(taskId)")
        }
        return task
    }

    private func replay(taskId: String, asOf: WorkDate?, knownAt: Date?) throws -> ReplayResult {
        StateReplay.replay(try repo.events(taskId: taskId), through: asOf, knownAt: knownAt)
    }

    private func refreshCachedStatus(_ taskId: String) throws {
        let result = try replay(taskId: taskId, asOf: nil, knownAt: nil)
        try repo.setTaskCachedStatus(id: taskId, status: result.taskStatus(taskId))
    }

    private func effectiveEvents(_ events: [DomainEvent], asOf: WorkDate?,
                                 knownAt: Date?) -> [DomainEvent] {
        var effective = StateReplay.effectiveEvents(events, knownAt: knownAt)
        if let asOf { effective = effective.filter { $0.effectiveDate <= asOf } }
        return effective
    }

    private func status(forTaskKind kind: DomainEventKind) -> TaskStatus? {
        switch kind {
        case .started, .resumed, .reopened: return .inProgress
        case .paused: return .onHold
        case .cancelled: return .cancelled
        case .replanned: return .planned
        default: return nil
        }
    }

    private func status(forProjectKind kind: DomainEventKind) -> TaskStatus? {
        switch kind {
        case .started, .resumed, .reopened: return .inProgress
        case .paused: return .onHold
        case .cancelled: return .cancelled
        case .replanned: return .planned
        case .completed: return .completed
        default: return nil
        }
    }

    private func makeEvent(taskId: String, scopeType: EventScopeType, scopeId: String,
                           kind: DomainEventKind, toStatus: TaskStatus?, effectiveDate: WorkDate,
                           effectiveTime: Date?, effectiveOrder: Int?, recordedAt: Date,
                           note: String?, activityId: String?) throws -> DomainEvent {
        let order: Int
        if let effectiveOrder {
            order = effectiveOrder
        } else {
            order = try repo.nextEffectiveOrder(taskId: taskId, on: effectiveDate)
        }
        return DomainEvent(id: repo.ids.make(), taskId: taskId, scopeType: scopeType, scopeId: scopeId,
                           kind: kind, toStatus: toStatus, effectiveDate: effectiveDate,
                           effectiveTime: effectiveTime, effectiveOrder: order, recordedAt: recordedAt,
                           supersedesEventId: nil, note: note, activityId: activityId)
    }

    /// 새 사건을 넣었을 때 새로 생기는 전이 위반이 있으면 저장 전에 거부한다.
    private func validate(_ event: DomainEvent, against existing: [DomainEvent]) throws {
        if let first = StateReplay.validateInsertion(event, into: existing).first {
            throw WorkLogError.invalidTransition(first.reason)
        }
    }

    private func insertLinks(ownerType: LinkOwnerType, ownerId: String, urls: [String],
                             createdAt: Date) throws {
        for url in urls {
            let link = WorkLink(id: repo.ids.make(), ownerType: ownerType, ownerId: ownerId,
                                url: url, linkType: LinkType.classify(url), createdAt: createdAt)
            try repo.insertLink(link)
        }
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where seen.insert(value).inserted { result.append(value) }
        return result
    }
}
