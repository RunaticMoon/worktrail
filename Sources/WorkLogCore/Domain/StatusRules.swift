import Foundation

/// 전이 규칙 위반 사유 (한국어).
public struct StatusRuleFailure: Error, Hashable, Sendable, ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public init(stringLiteral value: String) { self.reason = value }
}

/// 상태 전이 위반. 위반 사건은 적용하지 않고 보고만 하며, 재생은 계속된다.
public struct TransitionViolation: Error, Hashable, Sendable {
    public var eventId: String
    public var scopeType: EventScopeType
    public var scopeId: String
    /// 사건 직전 상태 (nil = 아직 상태 없음)
    public var from: TaskStatus?
    public var kind: DomainEventKind
    /// 한국어 설명
    public var reason: String

    public init(eventId: String, scopeType: EventScopeType, scopeId: String,
                from: TaskStatus?, kind: DomainEventKind, reason: String) {
        self.eventId = eventId
        self.scopeType = scopeType
        self.scopeId = scopeId
        self.from = from
        self.kind = kind
        self.reason = reason
    }
}

/// 상태 전이 규칙. 결정적이며 순수하다. 위반은 throw 하지 않고 Result.failure(사유)로 돌려준다.
public enum StatusRules {

    /// `from`: 사건 직전 상태(nil = 아직 상태 없음).
    /// 반환: 결과 상태 또는 위반 사유(한국어).
    ///
    /// - 비상태 사건(`isStatusEvent == false`): 상태 불변. 단 scope task이고 from == nil이면 실패.
    /// - toStatus가 주어졌는데 규칙이 계산한 결과 상태와 다르면 실패.
    public static func apply(scopeType: EventScopeType, from: TaskStatus?, kind: DomainEventKind,
                             toStatus: TaskStatus?) -> Result<TaskStatus?, StatusRuleFailure> {
        // 상태를 정하지 않는 사건: 상태 불변.
        if !kind.isStatusEvent {
            if scopeType == .task && from == nil {
                return .failure("생성 전 사건: Task가 생성되기 전에는 \(kind.rawValue) 사건을 기록할 수 없습니다.")
            }
            return .success(from)
        }

        switch scopeType {
        case .task:
            if let current = from {
                if kind == .created {
                    return .failure("Task가 이미 생성되어 created 사건을 다시 적용할 수 없습니다.")
                }
                return transition(from: current, kind: kind, toStatus: toStatus, label: "Task")
            }
            // 아직 상태가 없다 → 첫 사건은 반드시 created.
            guard kind == .created else {
                return .failure("생성 전 사건: Task의 첫 상태 사건은 created여야 합니다.")
            }
            guard let to = toStatus else {
                return .failure("created 사건에는 상태가 필요합니다.")
            }
            return .success(to) // 완료 상태로 바로 등록 가능.

        case .taskProject:
            if kind == .created {
                guard from == nil else {
                    return .failure("이미 상태가 있는 프로젝트 적용에 created 사건을 적용할 수 없습니다.")
                }
                guard let to = toStatus else {
                    return .failure("created 사건에는 상태가 필요합니다.")
                }
                return .success(to)
            }
            // from == nil이면 암묵적 초기 상태 planned로 보고 규칙을 적용한다.
            return transition(from: from ?? .planned, kind: kind, toStatus: toStatus, label: "프로젝트 적용")

        case .checklistItem:
            // from == nil이면 암묵적 planned. 허용: planned→completed, completed→planned.
            let current = from ?? .planned
            switch kind {
            case .completed:
                guard current == .planned else {
                    return .failure("체크리스트: \(current.koreanLabel) 상태에서 completed 사건은 허용되지 않습니다.")
                }
                return completeTransition(to: .completed, given: toStatus, label: "체크리스트")
            case .reopened:
                guard current == .completed else {
                    return .failure("체크리스트: \(current.koreanLabel) 상태에서 reopened 사건은 허용되지 않습니다.")
                }
                return completeTransition(to: .planned, given: toStatus, label: "체크리스트")
            default:
                return .failure("체크리스트: \(kind.rawValue) 사건은 허용되지 않습니다.")
            }
        }
    }

    /// task / task_project 공통 상태 전이표. 허용되지 않으면 nil.
    private static func expectedStatus(from: TaskStatus, kind: DomainEventKind) -> TaskStatus? {
        switch kind {
        case .started:
            return from == .planned ? .inProgress : nil
        case .paused:
            return (from == .planned || from == .inProgress) ? .onHold : nil
        case .resumed:
            return (from == .onHold || from == .cancelled) ? .inProgress : nil
        case .completed:
            return (from == .planned || from == .inProgress || from == .onHold) ? .completed : nil
        case .reopened:
            return from == .completed ? .inProgress : nil
        case .cancelled:
            return (from == .planned || from == .inProgress || from == .onHold) ? .cancelled : nil
        case .replanned:
            return (from == .onHold || from == .cancelled) ? .planned : nil
        case .created:
            return nil // created는 위 apply에서만 처리한다.
        default:
            return nil
        }
    }

    private static func transition(from: TaskStatus, kind: DomainEventKind, toStatus: TaskStatus?,
                                   label: String) -> Result<TaskStatus?, StatusRuleFailure> {
        guard let result = expectedStatus(from: from, kind: kind) else {
            return .failure("\(label): \(from.koreanLabel) 상태에서 \(kind.rawValue) 사건은 허용되지 않습니다.")
        }
        return completeTransition(to: result, given: toStatus, label: label)
    }

    private static func completeTransition(to result: TaskStatus, given: TaskStatus?,
                                           label: String) -> Result<TaskStatus?, StatusRuleFailure> {
        if let given, given != result {
            return .failure("\(label): 기대 상태는 \(result.koreanLabel)이지만 \(given.koreanLabel)이 지정되었습니다.")
        }
        return .success(result)
    }
}
