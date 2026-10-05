import Foundation
import Observation

/// 업무 목록 한 행. 목록에는 업무명·전체 상태·프로젝트·필요한 마감만 싣는다.
public struct TaskListRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let status: TaskStatus?
    public let projectNames: [String]
    public let dueOn: WorkDate?
    public let dueLabel: String?
    public let isOverdue: Bool
    public let isInThisWeekPlan: Bool

    public init(id: String, title: String, status: TaskStatus?, projectNames: [String],
                dueOn: WorkDate?, dueLabel: String?, isOverdue: Bool, isInThisWeekPlan: Bool) {
        self.id = id
        self.title = title
        self.status = status
        self.projectNames = projectNames
        self.dueOn = dueOn
        self.dueLabel = dueLabel
        self.isOverdue = isOverdue
        self.isInThisWeekPlan = isInThisWeekPlan
    }
}

/// 업무 목록 화면 모델. 정렬·검색·요약 라벨을 결정적으로 계산한다.
@Observable @MainActor public final class TaskListModel {
    public var query: String = ""
    public private(set) var rows: [TaskListRow] = []
    public private(set) var errorMessage: String?
    @ObservationIgnored private let environment: AppEnvironment

    public init(environment: AppEnvironment) { self.environment = environment }

    public func load() {
        do {
            let today = environment.calendar.workDate(of: environment.options.clock.now())
            let weekStart = environment.periods.weekStart(containing: today)
            let confirmed = (try? environment.plans.plan(weekStart: weekStart))?.items ?? []
            let plannedTaskIds = Set(confirmed.filter { item in
                item.state == .confirmed
                    && (item.scopeType == .wholeTask || item.scopeType == .taskProject)
            }.map(\.taskId))

            var entries: [(task: WorkTask, status: TaskStatus?)] = []
            for task in try environment.repo.tasks() {
                entries.append((task, try environment.tasks.currentStatus(taskId: task.id)))
            }
            // 미완료 먼저 → 마감 빠른 순(마감 없음 뒤) → 최근 생성 순.
            entries.sort { a, b in
                let au = Self.isUnfinished(a.status), bu = Self.isUnfinished(b.status)
                if au != bu { return au }
                switch (a.task.dueOn, b.task.dueOn) {
                case let (x?, y?): if x != y { return x < y }
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
                if a.task.createdAt != b.task.createdAt { return a.task.createdAt > b.task.createdAt }
                return a.task.id < b.task.id
            }

            rows = try entries.map { entry in
                let task = entry.task
                let unfinished = Self.isUnfinished(entry.status)
                let overdue = unfinished && (task.dueOn.map { $0 < today } ?? false)
                let dueLabel = task.dueOn.map { due -> String in
                    let label = KoreanDateLabel.monthDayWeekday(due, calendar: environment.calendar)
                    return overdue ? "마감 지남 · \(label)" : "마감 \(label)"
                }
                let projectNames = try environment.repo.taskProjects(taskId: task.id)
                    .compactMap { try environment.repo.project(id: $0.projectId)?.name }
                    .sorted()
                return TaskListRow(id: task.id, title: task.title, status: entry.status,
                                   projectNames: projectNames, dueOn: task.dueOn, dueLabel: dueLabel,
                                   isOverdue: overdue, isInThisWeekPlan: plannedTaskIds.contains(task.id))
            }
            errorMessage = nil
        } catch {
            rows = []
            errorMessage = "업무 목록을 불러오지 못했습니다. 다시 시도하세요."
        }
    }

    /// 업무명 대소문자 무시 포함 검색. 빈 검색어면 전체.
    public var filteredRows: [TaskListRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return rows }
        return rows.filter { $0.title.lowercased().contains(trimmed) }
    }

    /// 완료·취소가 아니면 미완료(상태 없음 포함).
    private static func isUnfinished(_ status: TaskStatus?) -> Bool {
        switch status {
        case .completed, .cancelled: return false
        default: return true
        }
    }
}
