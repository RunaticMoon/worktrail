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
    public let planScopeSummary: String?

    public init(id: String, title: String, status: TaskStatus?, projectNames: [String],
                dueOn: WorkDate?, dueLabel: String?, isOverdue: Bool, isInThisWeekPlan: Bool, planScopeSummary: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.projectNames = projectNames
        self.dueOn = dueOn
        self.dueLabel = dueLabel
        self.isOverdue = isOverdue
        self.isInThisWeekPlan = isInThisWeekPlan
        self.planScopeSummary = planScopeSummary
    }
}

/// 업무 목록 화면 모델. 정렬·검색·요약 라벨을 결정적으로 계산한다.
@Observable @MainActor public final class TaskListModel {
    public var query: String = ""
    public var isClosedExpanded = false
    public var executionFilter: TaskExecutionFilter = .all
    public var stateFilter: TaskStateFilter = .all
    public var today: WorkDate { environment.calendar.workDate(of: environment.options.clock.now()) }
    public private(set) var rows: [TaskListRow] = []
    public private(set) var errorMessage: String?
    @ObservationIgnored private let environment: AppEnvironment

    public init(environment: AppEnvironment) { self.environment = environment }

    public func load() {
        do {
            let today = environment.calendar.workDate(of: environment.options.clock.now())
            let weekStart = environment.periods.weekStart(containing: today)
            let confirmed = (try? environment.plans.plan(weekStart: weekStart))?.items ?? []
            let plansByTask = Dictionary(grouping: confirmed.filter { $0.state == .confirmed }, by: \.taskId)


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
                                   isOverdue: overdue, isInThisWeekPlan: plansByTask[task.id] != nil,
                                   planScopeSummary: Self.planSummary(plansByTask[task.id] ?? []))
            }
            errorMessage = nil
        } catch {
            rows = []
            errorMessage = "업무 목록을 불러오지 못했습니다. 다시 시도하세요."
        }
    }

    /// 업무명 대소문자 무시 포함 검색. 빈 검색어면 전체.
    public var filteredRows: [TaskListRow] {
        matchingRows(execution: executionFilter, state: stateFilter)
    }

    public func matchingRows(execution: TaskExecutionFilter, state: TaskStateFilter) -> [TaskListRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rows.filter { row in
            (trimmed.isEmpty || row.title.lowercased().contains(trimmed))
                && state.includes(row.status)
                && (execution == .all || state != .all || Self.isUnfinished(row.status))
                && execution.includes(row, today: today)
        }
    }

    public var hasExecutionFilters: Bool { executionFilter != .all || stateFilter != .all }
    public func clearFilters() { query = ""; executionFilter = .all; stateFilter = .all }

    private static func planSummary(_ items: [WeekPlanItem]) -> String? {
        guard !items.isEmpty else { return nil }
        if items.contains(where: { $0.scopeType == .wholeTask }) { return "이번 주 계획 · 업무 전체" }
        let projects = items.filter { $0.scopeType == .taskProject }.count
        let checklist = items.filter { $0.scopeType == .checklistItem }.count
        var parts: [String] = []
        if projects > 0 { parts.append("프로젝트 \(projects)개") }
        if checklist > 0 { parts.append("체크리스트 \(checklist)개") }
        return "이번 주 계획 · 일부 범위 (" + parts.joined(separator: ", ") + ")"
    }

    public var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var openRows: [TaskListRow] {
        filteredRows.filter { Self.isUnfinished($0.status) }
    }

    public var closedRows: [TaskListRow] {
        filteredRows.filter { !Self.isUnfinished($0.status) }
    }

    /// 종료 업무는 기본으로 접되, 검색에서는 과거 기록도 바로 찾을 수 있다.
    public var showsClosedRows: Bool { isSearching || hasExecutionFilters || isClosedExpanded }

    /// 화면과 키보드 이동이 같은 행 순서를 사용한다.
    public var visibleRows: [TaskListRow] {
        openRows + (showsClosedRows ? closedRows : [])
    }

    /// 완료·취소가 아니면 미완료(상태 없음 포함).
    private static func isUnfinished(_ status: TaskStatus?) -> Bool {
        switch status {
        case .completed, .cancelled: return false
        default: return true
        }
    }
}

public enum TaskExecutionFilter: String, CaseIterable, Sendable {
    case all = "전체", dueToday = "오늘 마감", overdue = "마감 지남", thisWeek = "이번 주 계획", noDueDate = "마감 없음"
    public func includes(_ row: TaskListRow, today: WorkDate) -> Bool {
        switch self {
        case .all: return true
        case .dueToday: return row.dueOn == today
        case .overdue: return row.dueOn.map { $0 < today } ?? false
        case .thisWeek: return row.isInThisWeekPlan
        case .noDueDate: return row.dueOn == nil
        }
    }
}

public enum TaskStateFilter: String, CaseIterable, Sendable {
    case all = "모든 상태", active = "예정·진행", planned = "예정", inProgress = "진행 중", onHold = "보류", completed = "완료", cancelled = "취소"
    public func includes(_ status: TaskStatus?) -> Bool {
        switch self {
        case .all: return true
        case .active: return status == .planned || status == .inProgress
        case .planned: return status == .planned
        case .inProgress: return status == .inProgress
        case .onHold: return status == .onHold
        case .completed: return status == .completed
        case .cancelled: return status == .cancelled
        }
    }
}
