import Foundation
import Observation

@Observable @MainActor public final class TaskDetailModel {
    public private(set) var detail: TaskDetail?
    public private(set) var errorMessage: String?
    public private(set) var completionCheck: CompletionCheck?
    public private(set) var asOf: WorkDate?
    public var activityText = ""
    /// 진행 기록의 범위. nil = Task 공통 기록, 값이 있으면 그 프로젝트 기록.
    public var activityProjectId: String?
    public var checklistText = ""
    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private var taskId: String?

    public init(environment: AppEnvironment) { self.environment = environment }
    public func load(taskId: String, asOf: WorkDate? = nil) {
        // 다른 업무를 열면 이전 업무의 범위 선택이 새 업무로 새지 않게 한다.
        if self.taskId != taskId { activityProjectId = nil }
        self.taskId = taskId; self.asOf = asOf; completionCheck = nil
        do {
            detail = try environment.tasks.detail(taskId: taskId, asOf: asOf); errorMessage = nil
            // 연결이 해제된 프로젝트를 범위로 들고 있으면 공통으로 되돌린다.
            if let selected = activityProjectId,
               !(detail?.projects.contains { $0.project.id == selected } ?? false) {
                activityProjectId = nil
            }
        } catch { detail = nil; errorMessage = "업무를 불러오지 못했습니다. 다시 선택하세요." }
    }
    private func update(_ action: (String) throws -> Void) {
        guard asOf == nil, let taskId else { return }
        do { try action(taskId); load(taskId: taskId) }
        catch { errorMessage = "변경하지 못했습니다. 상태와 입력 내용을 확인하세요." }
    }
    public func changeStatus(_ kind: DomainEventKind) {
        update { try environment.tasks.changeTaskStatus(taskId: $0, kind: kind) }
    }
    public func complete(confirmRemaining: Bool = false) {
        guard asOf == nil, let taskId else { return }
        do {
            let result = try environment.tasks.completeTask(taskId: taskId, confirmRemaining: confirmRemaining)
            if result.completed { load(taskId: taskId) } else { completionCheck = result; errorMessage = nil }
        } catch { errorMessage = "완료하지 못했습니다. 업무 상태를 확인하세요." }
    }
    public func cancelCompletion() { completionCheck = nil }
    public func setChecklist(itemId: String, done: Bool) {
        update { _ in try environment.tasks.setChecklistItem(itemId: itemId, done: done) }
    }
    public func addChecklistItem() {
        update { _ = try environment.tasks.addChecklistItem(taskId: $0, text: checklistText); checklistText = "" }
    }
    public func changeProjectStatus(projectId: String, kind: DomainEventKind) {
        update { try environment.tasks.changeProjectStatus(taskId: $0, projectId: projectId, kind: kind) }
    }
    public func addActivity() {
        guard !activityText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "진행 내용을 입력하세요."; return
        }
        // activityProjectId는 저장 후에도 유지한다(같은 범위로 연속 기록 편의). 본문만 비운다.
        let scope = activityProjectId.map { [$0] } ?? []
        update { _ = try environment.tasks.addActivity(taskId: $0, body: activityText, projectIds: scope); activityText = "" }
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
                && (item.scopeType == .wholeTask || item.scopeType == .taskProject)
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
