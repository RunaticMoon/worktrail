import Foundation
import Observation

@Observable @MainActor public final class TaskDetailModel {
    public private(set) var detail: TaskDetail?
    public private(set) var errorMessage: String?
    public private(set) var completionCheck: CompletionCheck?
    public private(set) var asOf: WorkDate?
    public var activityText = ""
    public var checklistText = ""
    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private var taskId: String?

    public init(environment: AppEnvironment) { self.environment = environment }
    public func load(taskId: String, asOf: WorkDate? = nil) {
        self.taskId = taskId; self.asOf = asOf; completionCheck = nil
        do { detail = try environment.tasks.detail(taskId: taskId, asOf: asOf); errorMessage = nil }
        catch { detail = nil; errorMessage = "업무를 불러오지 못했습니다. 다시 선택하세요." }
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
        update { _ = try environment.tasks.addActivity(taskId: $0, body: activityText); activityText = "" }
    }
}
