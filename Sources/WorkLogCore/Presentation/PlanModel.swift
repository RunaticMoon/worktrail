import Foundation
import Observation

@Observable @MainActor public final class PlanModel {
    public var weekStart: WorkDate
    public var checkedIds: Set<String> = []
    public var labels: [String: String] = [:]
    public private(set) var plan: WeekPlan?
    public private(set) var items: [WeekPlanItem] = []
    public private(set) var tasks: [WorkTask] = []
    public private(set) var errorMessage: String?
    public private(set) var noticeMessage: String?
    public private(set) var isLoading = false
    public var range: DateRange { environment.periods.range(.weekly, containing: weekStart) }
    public var candidates: [WeekPlanItem] { items.filter { $0.state == .candidate } }
    public var confirmed: [WeekPlanItem] { items.filter { $0.state == .confirmed } }
    public var excluded: [WeekPlanItem] { items.filter { $0.state == .excluded } }
    @ObservationIgnored private let environment: AppEnvironment
    public init(environment: AppEnvironment) {
        self.environment = environment
        weekStart = environment.periods.weekStart(containing: environment.calendar.workDate(of: environment.options.clock.now()))
    }
    public func load() {
        isLoading = true
        defer { isLoading = false }
        do {
            weekStart = environment.periods.weekStart(containing: weekStart)
            let result = try environment.plans.plan(weekStart: weekStart)
            plan = result?.plan; items = result?.items ?? []
            tasks = try environment.repo.tasks()
            checkedIds.formIntersection(Set(candidates.map(\.id)))
            labels = Dictionary(uniqueKeysWithValues: items.map { ($0.id, labels[$0.id] ?? $0.label ?? "") })
            errorMessage = nil
        } catch {
            plan = nil; items = []; tasks = []; checkedIds = []; labels = [:]
            errorMessage = "계획을 불러오지 못했습니다. 다시 시도하세요."
        }
    }
    public func selectWeek(_ date: WorkDate) { weekStart = date; checkedIds = []; labels = [:]; load() }
    public func generateCandidates() { perform { _ = try environment.plans.generateCandidates(weekStart: weekStart) } }
    public func check(_ id: String, selected: Bool) {
        guard candidates.contains(where: { $0.id == id }) else { return }
        if selected { checkedIds.insert(id) } else { checkedIds.remove(id) }
    }
    public func confirmChecked() {
        let selected = candidates.filter { checkedIds.contains($0.id) }.map(\.id)
        guard !selected.isEmpty else { return }
        perform { _ = try environment.plans.confirm(weekStart: weekStart, itemIds: selected) }
    }
    public func saveLabel(_ id: String) {
        guard let text = labels[id] else { return }
        perform { try environment.plans.setLabel(itemId: id, label: text.isEmpty ? nil : text) }
    }
    public func unconfirm(_ id: String) { perform { try environment.plans.unconfirm(itemId: id) } }
    public func exclude(_ id: String) { perform { try environment.plans.exclude(itemId: id) } }
    public func restore(_ id: String) {
        perform { try environment.plans.restore(itemId: id) }
        if errorMessage == nil { noticeMessage = "후보로 되돌렸습니다. 계획에 포함하려면 다시 확정하세요." }
    }
    public func addTask(_ taskId: String) {
        let existing = items.first { $0.taskId == taskId && $0.scopeType == .wholeTask }
        perform { _ = try environment.plans.addItem(weekStart: weekStart, taskId: taskId, scopeType: .wholeTask, scopeId: nil, label: nil) }
        guard errorMessage == nil else { return }
        if existing?.state == .excluded { noticeMessage = "제외했던 항목을 후보로 되돌렸습니다. 다시 확정하세요." }
        else if existing != nil { noticeMessage = "이미 계획에 포함된 항목입니다." }
        else { noticeMessage = "후보에 추가했습니다. 계획에 포함하려면 확정하세요." }
    }
    public func title(for item: WeekPlanItem) -> String { tasks.first { $0.id == item.taskId }?.title ?? "업무를 찾을 수 없음" }
    private func perform(_ action: () throws -> Void) {
        noticeMessage = nil
        do { try action(); load() }
        catch { errorMessage = "계획 변경을 저장하지 못했습니다. 다시 시도하세요." }
    }
}
