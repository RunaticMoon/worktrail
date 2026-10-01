import Foundation

/// 재생 대상 scope 식별자.
public struct ScopeKey: Hashable, Sendable {
    public var scopeType: EventScopeType
    public var scopeId: String

    public init(scopeType: EventScopeType, scopeId: String) {
        self.scopeType = scopeType
        self.scopeId = scopeId
    }
}

/// 재생 결과의 scope별 상태.
public struct ScopeState: Hashable, Sendable {
    public var status: TaskStatus
    public var lastEventId: String
    public var since: WorkDate

    public init(status: TaskStatus, lastEventId: String, since: WorkDate) {
        self.status = status
        self.lastEventId = lastEventId
        self.since = since
    }
}

/// 이벤트 재생 결과. 상태·위반·적용 순서.
public struct ReplayResult: Sendable {
    public var states: [ScopeKey: ScopeState]
    public var violations: [TransitionViolation]
    /// 실제 적용된 사건 ID (적용 순서)
    public var appliedEventIds: [String]

    public init(states: [ScopeKey: ScopeState], violations: [TransitionViolation],
                appliedEventIds: [String]) {
        self.states = states
        self.violations = violations
        self.appliedEventIds = appliedEventIds
    }

    public func taskStatus(_ taskId: String) -> TaskStatus? {
        states[ScopeKey(scopeType: .task, scopeId: taskId)]?.status
    }

    /// scopeId = "\(taskId)/\(projectId)"
    public func projectStatus(taskId: String, projectId: String) -> TaskStatus? {
        states[ScopeKey(scopeType: .taskProject,
                        scopeId: TaskProject.scopeId(taskId: taskId, projectId: projectId))]?.status
    }

    public func checklistStatus(_ itemId: String) -> TaskStatus? {
        states[ScopeKey(scopeType: .checklistItem, scopeId: itemId)]?.status
    }
}

/// domain_event 목록에서 상태를 결정적으로 재생하는 순수 함수들.
public enum StateReplay {

    /// 사건 정렬 키: (effectiveDate, effectiveOrder, recordedAt, id) 오름차순
    public static func sorted(_ events: [DomainEvent]) -> [DomainEvent] {
        events.sorted { a, b in
            if a.effectiveDate != b.effectiveDate { return a.effectiveDate < b.effectiveDate }
            if a.effectiveOrder != b.effectiveOrder { return a.effectiveOrder < b.effectiveOrder }
            if a.recordedAt != b.recordedAt { return a.recordedAt < b.recordedAt }
            return a.id < b.id
        }
    }

    /// knownAt이 nil이 아니면 recordedAt <= knownAt 인 사건만 남긴다.
    /// kind == .voided 사건(자신도 recordedAt <= knownAt)이 supersedesEventId로 가리키는 사건은 제거하고,
    /// voided 사건 자체도 결과에서 제외한다. 정렬해서 반환.
    public static func effectiveEvents(_ events: [DomainEvent], knownAt: Date?) -> [DomainEvent] {
        let visible: [DomainEvent]
        if let knownAt {
            visible = events.filter { $0.recordedAt <= knownAt }
        } else {
            visible = events
        }

        var superseded = Set<String>()
        for event in visible where event.kind == .voided {
            if let target = event.supersedesEventId { superseded.insert(target) }
        }

        let remaining = visible.filter { $0.kind != .voided && !superseded.contains($0.id) }
        return sorted(remaining)
    }

    /// through가 nil이 아니면 effectiveDate <= through 인 사건만 재생.
    /// 위반 사건은 상태를 바꾸지 않고 violations에 모은 뒤 계속 재생한다 (throw 없음).
    public static func replay(_ events: [DomainEvent], through: WorkDate?, knownAt: Date?) -> ReplayResult {
        var effective = effectiveEvents(events, knownAt: knownAt)
        if let through {
            effective = effective.filter { $0.effectiveDate <= through }
        }

        var states: [ScopeKey: ScopeState] = [:]
        var violations: [TransitionViolation] = []
        var applied: [String] = []

        for event in effective {
            let key = ScopeKey(scopeType: event.scopeType, scopeId: event.scopeId)
            let from = states[key]?.status

            switch StatusRules.apply(scopeType: event.scopeType, from: from,
                                     kind: event.kind, toStatus: event.toStatus) {
            case .success(let newStatus):
                applied.append(event.id)
                if let newStatus {
                    states[key] = ScopeState(status: newStatus, lastEventId: event.id,
                                             since: event.effectiveDate)
                }
            case .failure(let reason):
                violations.append(TransitionViolation(eventId: event.id, scopeType: event.scopeType,
                                                      scopeId: event.scopeId, from: from,
                                                      kind: event.kind, reason: reason))
            }
        }

        return ReplayResult(states: states, violations: violations, appliedEventIds: applied)
    }

    /// 해당 Task(scope task)의 실제 시작일: created(toStatus=inProgress) 또는 started 사건 중
    /// 가장 이른 effectiveDate. 없으면 nil (추정 금지).
    public static func firstStartedOn(taskId: String, _ events: [DomainEvent], knownAt: Date?) -> WorkDate? {
        effectiveEvents(events, knownAt: knownAt)
            .filter { $0.scopeType == .task && $0.scopeId == taskId }
            .filter { $0.kind == .started || ($0.kind == .created && $0.toStatus == .inProgress) }
            .map { $0.effectiveDate }
            .min()
    }

    /// Task 전체 완료 사건(scope task, 적용된 completed 및 created(toStatus=completed))의 날짜 목록.
    /// 재완료 시 여러 개.
    public static func completionDates(taskId: String, _ events: [DomainEvent], knownAt: Date?) -> [WorkDate] {
        let applied = Set(replay(events, through: nil, knownAt: knownAt).appliedEventIds)
        return effectiveEvents(events, knownAt: knownAt)
            .filter { $0.scopeType == .task && $0.scopeId == taskId && applied.contains($0.id) }
            .filter { $0.kind == .completed || ($0.kind == .created && $0.toStatus == .completed) }
            .map { $0.effectiveDate }
    }

    /// 새 사건을 기존 목록에 넣었을 때 새로 생기는 위반만 반환한다.
    /// (삽입 후 전체 재생 위반 − 삽입 전 위반). 빈 배열이면 허용.
    public static func validateInsertion(_ new: DomainEvent, into existing: [DomainEvent]) -> [TransitionViolation] {
        let before = Set(replay(existing, through: nil, knownAt: nil).violations)
        let after = replay(existing + [new], through: nil, knownAt: nil).violations
        return after.filter { !before.contains($0) }
    }
}
