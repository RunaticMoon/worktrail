import Foundation

// MARK: - 날짜 화면 읽기 모델

/// 타임라인 항목의 종류. 상태를 정하지 않는 사건(활동 추가·연결·무효화 등)은 넣지 않는다.
public enum TimelineEntryKind: String, Codable, Sendable {
    case memo, taskCreated, taskStatus, projectStatus, checklistStatus, activity
}

/// 날짜 화면 타임라인의 한 항목. 읽기 전용이며 임의의 시각·활동을 만들지 않는다.
public struct TimelineEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String              // "memo:<id>", "event:<id>", "activity:<id>"
    public var kind: TimelineEntryKind
    public var workDate: WorkDate
    /// 사용자가 지정한 실제 시각(사건 effectiveTime)만. 날짜만 알려진 기록은 nil — 임의 시각을 만들지 않는다.
    public var effectiveTime: Date?
    public var recordedAt: Date
    public var taskId: String?
    public var projectId: String?      // projectStatus일 때
    public var checklistItemId: String?
    public var eventKind: DomainEventKind?
    public var toStatus: TaskStatus?
    public var title: String           // Task 제목 또는 Memo 첫 줄(Memo.preview가 있으면 사용)
    public var detail: String?         // activity body, memo body, 사건 note

    public init(id: String, kind: TimelineEntryKind, workDate: WorkDate, effectiveTime: Date?,
                recordedAt: Date, taskId: String? = nil, projectId: String? = nil,
                checklistItemId: String? = nil, eventKind: DomainEventKind? = nil,
                toStatus: TaskStatus? = nil, title: String, detail: String? = nil) {
        self.id = id; self.kind = kind; self.workDate = workDate
        self.effectiveTime = effectiveTime; self.recordedAt = recordedAt
        self.taskId = taskId; self.projectId = projectId; self.checklistItemId = checklistItemId
        self.eventKind = eventKind; self.toStatus = toStatus; self.title = title; self.detail = detail
    }
}

/// Task 열의 한 행. 상태는 그 날짜 기준(재생)이다.
public struct DayTaskRow: Codable, Hashable, Sendable, Identifiable {
    public var id: String { taskId }
    public var taskId: String
    public var title: String
    public var status: TaskStatus      // 그 날짜 기준 상태
    public var startedOnDay: Bool      // 그 날짜에 started 사건
    public var completedOnDay: Bool    // 그 날짜에 completed 사건
    public var hasActivityOnDay: Bool
    public var dueOn: WorkDate?
    public var projectIds: [String]

    public init(taskId: String, title: String, status: TaskStatus, startedOnDay: Bool,
                completedOnDay: Bool, hasActivityOnDay: Bool, dueOn: WorkDate?,
                projectIds: [String]) {
        self.taskId = taskId; self.title = title; self.status = status
        self.startedOnDay = startedOnDay; self.completedOnDay = completedOnDay
        self.hasActivityOnDay = hasActivityOnDay; self.dueOn = dueOn; self.projectIds = projectIds
    }
}

/// 날짜 화면(DAY-01) 3열 읽기 모델. 쓰기·AI·네트워크·Secret이 없다.
public struct DayBox: Codable, Hashable, Sendable {
    public var date: WorkDate
    public var isToday: Bool
    public var isPast: Bool
    public var timeline: [TimelineEntry]
    public var tasks: [DayTaskRow]
    public var memos: [Memo]

    public init(date: WorkDate, isToday: Bool, isPast: Bool, timeline: [TimelineEntry],
                tasks: [DayTaskRow], memos: [Memo]) {
        self.date = date; self.isToday = isToday; self.isPast = isPast
        self.timeline = timeline; self.tasks = tasks; self.memos = memos
    }
}

/// 한 날짜의 Memo / Task / 타임라인을 결정적으로 구성하는 읽기 전용 서비스.
public final class DayBoxService {
    private let repo: WorkRepository

    public init(repo: WorkRepository) {
        self.repo = repo
    }

    public func dayBox(for date: WorkDate, includeHeldAndCancelled: Bool = false,
                       knownAt: Date? = nil) throws -> DayBox {
        let today = repo.calendar.workDate(of: repo.clock.now())

        let allEvents = try repo.allEvents()
        let replay = StateReplay.replay(allEvents, through: date, knownAt: knownAt)
        let effective = StateReplay.effectiveEvents(allEvents, knownAt: knownAt)
        let eventsOnDay = effective.filter { $0.effectiveDate == date }

        // 날짜에 유효한 Memo / Activity (knownAt 적용).
        let memos = try repo.memos(on: date).filter { memo in
            knownAt.map { memo.recordedAt <= $0 } ?? true
        }
        let activities = try repo.activities(on: date).filter { activity in
            knownAt.map { activity.recordedAt <= $0 } ?? true
        }

        // 삭제되지 않은 Task만 대상으로 한다.
        let tasks = try repo.tasks()
        let taskById = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

        var timeline: [TimelineEntry] = []
        var orderById: [String: Int] = [:]

        for memo in memos {
            let id = "memo:\(memo.id)"
            let title = memo.preview.isEmpty ? memo.body : memo.preview
            timeline.append(TimelineEntry(id: id, kind: .memo, workDate: date, effectiveTime: nil,
                                          recordedAt: memo.recordedAt, title: title, detail: memo.body))
            orderById[id] = 0
        }

        let activitiesByTask = Dictionary(grouping: activities, by: { $0.taskId })

        for activity in activities {
            let id = "activity:\(activity.id)"
            let title = taskById[activity.taskId]?.title ?? ""
            timeline.append(TimelineEntry(id: id, kind: .activity, workDate: date, effectiveTime: nil,
                                          recordedAt: activity.recordedAt, taskId: activity.taskId,
                                          title: title, detail: activity.body))
            orderById[id] = 0
        }

        for event in eventsOnDay {
            guard let entryKind = timelineKind(for: event.kind, scopeType: event.scopeType) else { continue }
            // 삭제된 Task(또는 없는 Task)의 사건은 타임라인에 넣지 않는다.
            guard let task = taskById[event.taskId] else { continue }
            let id = "event:\(event.id)"
            let projectId: String? = event.scopeType == .taskProject
                ? event.scopeId.split(separator: "/").last.map(String.init) : nil
            let checklistItemId: String? = event.scopeType == .checklistItem ? event.scopeId : nil
            timeline.append(TimelineEntry(id: id, kind: entryKind, workDate: date,
                                          effectiveTime: event.effectiveTime,
                                          recordedAt: event.recordedAt, taskId: event.taskId,
                                          projectId: projectId, checklistItemId: checklistItemId,
                                          eventKind: event.kind, toStatus: event.toStatus,
                                          title: task.title, detail: event.note))
            orderById[id] = event.effectiveOrder
        }

        // 정렬 기준 시각 = effectiveTime ?? recordedAt, 같으면 effectiveOrder, 그다음 id.
        timeline.sort { a, b in
            let ta = a.effectiveTime ?? a.recordedAt
            let tb = b.effectiveTime ?? b.recordedAt
            if ta != tb { return ta < tb }
            let oa = orderById[a.id] ?? 0
            let ob = orderById[b.id] ?? 0
            if oa != ob { return oa < ob }
            return a.id < b.id
        }

        // Task 열.
        var rows: [DayTaskRow] = []
        for task in tasks {
            guard let status = replay.taskStatus(task.id) else { continue } // 아직 생성되지 않음

            let dayTaskEvents = eventsOnDay.filter {
                $0.scopeType == .task && $0.scopeId == task.id && $0.kind.isStatusEvent
            }
            let hasActivityOnDay = activitiesByTask[task.id] != nil
            let hasStatusEventOnDay = !dayTaskEvents.isEmpty
            let hasDayPresence = hasStatusEventOnDay || hasActivityOnDay

            if status == .onHold || status == .cancelled {
                guard includeHeldAndCancelled else { continue }
            } else if status != .planned && status != .inProgress && !hasDayPresence {
                // 그 날짜 이전에 완료되어 그날 사건·활동이 없는 Task는 제외.
                continue
            }

            let startedOnDay = dayTaskEvents.contains {
                $0.kind == .started || ($0.kind == .created && $0.toStatus == .inProgress)
            }
            let completedOnDay = dayTaskEvents.contains {
                $0.kind == .completed || ($0.kind == .created && $0.toStatus == .completed)
            }

            let projectIds = try repo.taskProjects(taskId: task.id, includeRemoved: true)
                .filter { link in
                    link.linkedOn <= date && (link.removedOn.map { $0 > date } ?? true)
                }
                .map { $0.projectId }

            rows.append(DayTaskRow(taskId: task.id, title: task.title, status: status,
                                   startedOnDay: startedOnDay, completedOnDay: completedOnDay,
                                   hasActivityOnDay: hasActivityOnDay, dueOn: task.dueOn,
                                   projectIds: projectIds))
        }

        rows.sort { a, b in
            let ra = statusRank(a.status), rb = statusRank(b.status)
            if ra != rb { return ra < rb }
            if a.title != b.title { return a.title < b.title }
            return a.taskId < b.taskId
        }

        return DayBox(date: date, isToday: date == today, isPast: date < today,
                      timeline: timeline, tasks: rows, memos: memos)
    }

    // MARK: - 내부

    /// 상태를 정하는 사건만 타임라인 종류로 매핑한다. 그 외(활동 추가·연결·무효화 등)는 nil.
    private func timelineKind(for kind: DomainEventKind,
                              scopeType: EventScopeType) -> TimelineEntryKind? {
        guard kind.isStatusEvent else { return nil }
        switch scopeType {
        case .task:
            return kind == .created ? .taskCreated : .taskStatus
        case .taskProject:
            return .projectStatus
        case .checklistItem:
            return .checklistStatus
        }
    }

    /// Task 열 정렬: inProgress → planned → completed → onHold → cancelled.
    private func statusRank(_ status: TaskStatus) -> Int {
        switch status {
        case .inProgress: return 0
        case .planned: return 1
        case .completed: return 2
        case .onHold: return 3
        case .cancelled: return 4
        }
    }
}
