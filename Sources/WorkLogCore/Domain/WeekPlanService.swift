import Foundation

// MARK: - 주간 계획 서비스 (PLAN-01 / PLAN-02 / PLAN-03)
//
// 후보 제안 → 사용자 확정 → 정규화. 이 서비스는 domain_event를 만들지 않고
// Task 상태·시작일을 바꾸지 않는다. 후보는 확정 전까지 `confirmedFacts`(보고서 ‘예정’ 입력)에
// 들어가지 않는다.
public final class WeekPlanService: @unchecked Sendable {
    private let repo: WorkRepository
    private let periods: Periods

    public init(repo: WorkRepository, periods: Periods) {
        self.repo = repo
        self.periods = periods
    }

    // MARK: 조회

    /// weekStart는 월요일이어야 한다(아니면 validation). 계획이 없으면 nil.
    public func plan(weekStart: WorkDate) throws -> (plan: WeekPlan, items: [WeekPlanItem])? {
        try requireMonday(weekStart)
        guard let plan = try repo.weekPlan(weekStart: weekStart) else { return nil }
        return (plan, try repo.weekPlanItems(planId: plan.id))
    }

    // MARK: 후보 생성

    /// 계획이 없으면 만들고 후보(state .candidate)를 추가해 전체 항목을 반환한다.
    ///
    /// 후보 규칙:
    ///  - 지난주 종료 상태가 planned 또는 in_progress인 Task → wholeTask 후보, "지난주 미완료"
    ///  - dueOn이 이번 주 `[weekStart, weekStart+7)` 안이고 현재 상태가 completed/cancelled가 아닌
    ///    Task → wholeTask 후보, "이번 주 마감"
    ///  - 위 후보 Task 중 perProject 추적 프로젝트 가운데 현재 상태가 completed/cancelled가 아닌 것
    ///    → taskProject 후보, label "<프로젝트명> 적용"
    ///  - 위 후보 Task의 미완료 체크리스트 → checklistItem 후보, label = 체크리스트 text
    ///  - on_hold/cancelled Task는 자동 후보로 만들지 않는다(사용자가 addItem으로 직접 추가 가능).
    ///
    /// 기존 항목(같은 taskId+scopeType+scopeId)은 중복 추가하지 않고, confirmed/excluded 항목은
    /// 건드리지 않는다. 이미 후보면 사유를 덮어쓰지 않는다.
    public func generateCandidates(weekStart: WorkDate) throws -> [WeekPlanItem] {
        try requireMonday(weekStart)
        let plan = try ensurePlan(weekStart: weekStart)

        let now = repo.clock.now()
        let priorThrough = periods.calendar.adding(days: -1, to: weekStart)
        let weekEnd = periods.calendar.adding(days: 7, to: weekStart)
        let events = try repo.allEvents()

        // 지난주 종료 상태 = weekStart 전날까지의 재생.
        let prior = StateReplay.replay(events, through: priorThrough, knownAt: now)
        // 현재 상태 = 지금까지 알려진 전체 재생.
        let current = StateReplay.replay(events, through: nil, knownAt: now)

        var existing = try repo.weekPlanItems(planId: plan.id)
        var existingKeys = Set(existing.map { scopeKey($0) })

        for task in try repo.tasks() {
            let currentStatus = current.taskStatus(task.id)
            // 보류·취소 Task는 자동 후보로 되살리지 않는다.
            if currentStatus == .onHold || currentStatus == .cancelled { continue }

            let priorStatus = prior.taskStatus(task.id)
            let wasIncomplete = (priorStatus == .planned || priorStatus == .inProgress)
            let isDueThisWeek = task.dueOn.map { $0 >= weekStart && $0 < weekEnd } ?? false
            let isDueCandidate = isDueThisWeek && currentStatus != .completed && currentStatus != .cancelled
            guard wasIncomplete || isDueCandidate else { continue }

            let reason = wasIncomplete ? "지난주 미완료" : "이번 주 마감"

            // 1) Task 전체
            try appendCandidate(plan: plan, taskId: task.id, scopeType: .wholeTask, scopeId: nil,
                                label: nil, reason: reason, existing: &existing, keys: &existingKeys)

            // 2) 프로젝트별 적용 (perProject 추적만, 현재 상태가 완료/취소가 아닌 것)
            if task.projectTrackingMode == .perProject {
                for link in try repo.taskProjects(taskId: task.id) where link.trackingEnabled {
                    let status = current.projectStatus(taskId: task.id, projectId: link.projectId)
                    if status == .completed || status == .cancelled { continue }
                    let scopeId = TaskProject.scopeId(taskId: task.id, projectId: link.projectId)
                    let name = (try repo.project(id: link.projectId))?.name ?? link.projectId
                    try appendCandidate(plan: plan, taskId: task.id, scopeType: .taskProject,
                                        scopeId: scopeId, label: "\(name) 적용", reason: reason,
                                        existing: &existing, keys: &existingKeys)
                }
            }

            // 3) 미완료 체크리스트
            for checklist in try repo.checklistItems(taskId: task.id) {
                let status = current.checklistStatus(checklist.id)
                if status == .completed || status == .cancelled { continue }
                try appendCandidate(plan: plan, taskId: task.id, scopeType: .checklistItem,
                                    scopeId: checklist.id, label: checklist.text, reason: reason,
                                    existing: &existing, keys: &existingKeys)
            }
        }

        return try repo.weekPlanItems(planId: plan.id)
    }

    // MARK: 사용자 편집

    /// 사용자가 직접 항목 추가(보류 Task 포함 가능). state .candidate.
    public func addItem(weekStart: WorkDate, taskId: String, scopeType: PlanScopeType,
                        scopeId: String?, label: String?) throws -> WeekPlanItem {
        try requireMonday(weekStart)
        let plan = try ensurePlan(weekStart: weekStart)
        let item = WeekPlanItem(id: repo.ids.make(), weekPlanId: plan.id, taskId: taskId,
                                scopeType: scopeType, scopeId: scopeId, label: label, state: .candidate)
        try repo.insertWeekPlanItem(item)
        return item
    }

    public func setLabel(itemId: String, label: String?) throws {
        guard var item = try repo.weekPlanItem(id: itemId) else {
            throw WorkLogError.notFound("week_plan_item \(itemId)")
        }
        item.label = label
        try repo.updateWeekPlanItem(item)
    }

    /// itemIds를 confirmed(confirmedAt = now)로. 나머지 후보는 candidate 유지.
    /// plan.revision += 1, plan.confirmedAt = now. 반환: 갱신된 항목 전체.
    public func confirm(weekStart: WorkDate, itemIds: [String]) throws -> [WeekPlanItem] {
        try requireMonday(weekStart)
        guard var plan = try repo.weekPlan(weekStart: weekStart) else {
            throw WorkLogError.notFound("week_plan \(weekStart.iso)")
        }
        let target = Set(itemIds)
        let now = repo.clock.now()
        let items = try repo.weekPlanItems(planId: plan.id)
        for var item in items where target.contains(item.id) {
            item.state = .confirmed
            item.confirmedAt = now
            try repo.updateWeekPlanItem(item)
        }
        plan.revision += 1
        plan.confirmedAt = now
        try repo.updateWeekPlan(plan)
        return try repo.weekPlanItems(planId: plan.id)
    }

    /// confirmed → candidate.
    public func unconfirm(itemId: String) throws {
        guard var item = try repo.weekPlanItem(id: itemId) else {
            throw WorkLogError.notFound("week_plan_item \(itemId)")
        }
        guard item.state == .confirmed else {
            throw WorkLogError.validation("확정 항목이 아닙니다: \(itemId)")
        }
        item.state = .candidate
        item.confirmedAt = nil
        try repo.updateWeekPlanItem(item)
    }

    /// → excluded.
    public func exclude(itemId: String) throws {
        guard var item = try repo.weekPlanItem(id: itemId) else {
            throw WorkLogError.notFound("week_plan_item \(itemId)")
        }
        item.state = .excluded
        item.confirmedAt = nil
        try repo.updateWeekPlanItem(item)
    }

    // MARK: 보고서용

    /// 보고서용: 확정 항목만 정규화한다. 각 항목 label이 nil이면 표시용 label을 채운 뒤 normalize
    /// (wholeTask: nil 유지, taskProject: "<프로젝트명> 적용", checklistItem: 체크리스트 text).
    /// 기존 시그니처 — knownAt 필터 없이 모든 확정 항목을 포함한다.
    public func confirmedFacts(weekStart: WorkDate) throws -> [FactPlanItem] {
        try confirmedFacts(weekStart: weekStart, knownAt: nil)
    }

    /// 보고서용: 확정 항목만 정규화한다. knownAt이 주어지면 `confirmedAt > knownAt`인 항목을
    /// 제외해, 그 시점 이후에 확정한 계획이 과거 스냅샷에 섞이지 않게 한다.
    /// `confirmedAt`이 기록되지 않은(nil) 항목은 확정 시각을 알 수 없으므로 포함한다.
    public func confirmedFacts(weekStart: WorkDate, knownAt: Date?) throws -> [FactPlanItem] {
        try requireMonday(weekStart)
        guard let plan = try repo.weekPlan(weekStart: weekStart) else { return [] }
        var confirmed = try repo.weekPlanItems(planId: plan.id).filter { $0.state == .confirmed }
        if let knownAt {
            confirmed = confirmed.filter { item in
                guard let confirmedAt = item.confirmedAt else { return true }
                return confirmedAt <= knownAt
            }
        }

        var filled: [WeekPlanItem] = []
        filled.reserveCapacity(confirmed.count)
        for var item in confirmed {
            if item.label == nil {
                item.label = try displayLabel(for: item)
            }
            filled.append(item)
        }
        return PlanNormalizer.normalize(filled)
    }

    // MARK: - 내부

    private func ensurePlan(weekStart: WorkDate) throws -> WeekPlan {
        if let plan = try repo.weekPlan(weekStart: weekStart) { return plan }
        let plan = WeekPlan(id: repo.ids.make(), weekStart: weekStart)
        try repo.insertWeekPlan(plan)
        return plan
    }

    private func requireMonday(_ weekStart: WorkDate) throws {
        guard periods.calendar.isoWeekday(weekStart) == 1 else {
            throw WorkLogError.validation("weekStart는 월요일이어야 합니다: \(weekStart.iso)")
        }
    }

    private func scopeKey(taskId: String, scopeType: PlanScopeType, scopeId: String?) -> String {
        "\(taskId)|\(scopeType.rawValue)|\(scopeId ?? "")"
    }

    private func scopeKey(_ item: WeekPlanItem) -> String {
        scopeKey(taskId: item.taskId, scopeType: item.scopeType, scopeId: item.scopeId)
    }

    private func appendCandidate(plan: WeekPlan, taskId: String, scopeType: PlanScopeType,
                                 scopeId: String?, label: String?, reason: String,
                                 existing: inout [WeekPlanItem],
                                 keys: inout Set<String>) throws {
        let key = scopeKey(taskId: taskId, scopeType: scopeType, scopeId: scopeId)
        if keys.contains(key) { return }
        let item = WeekPlanItem(id: repo.ids.make(), weekPlanId: plan.id, taskId: taskId,
                                scopeType: scopeType, scopeId: scopeId, label: label,
                                state: .candidate, candidateReason: reason)
        try repo.insertWeekPlanItem(item)
        existing.append(item)
        keys.insert(key)
    }

    /// label이 nil인 확정 항목의 표시용 문구.
    private func displayLabel(for item: WeekPlanItem) throws -> String? {
        switch item.scopeType {
        case .wholeTask:
            return nil
        case .taskProject:
            guard let scopeId = item.scopeId, let projectId = Self.projectId(fromScopeId: scopeId) else {
                return nil
            }
            let name = (try repo.project(id: projectId))?.name ?? projectId
            return "\(name) 적용"
        case .checklistItem:
            guard let scopeId = item.scopeId, let checklist = try repo.checklistItem(id: scopeId) else {
                return nil
            }
            return checklist.text
        }
    }

    /// scopeId = "taskId/projectId" 에서 projectId 추출.
    static func projectId(fromScopeId scopeId: String) -> String? {
        guard let index = scopeId.lastIndex(of: "/") else { return nil }
        let projectId = String(scopeId[scopeId.index(after: index)...])
        return projectId.isEmpty ? nil : projectId
    }
}
