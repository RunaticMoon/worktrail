import Foundation

// MARK: - 주간 계획(WeekPlan / WeekPlanItem) 저장·조회
//
// 계획 포함은 착수·상태 변경이 아니다. 이 확장은 domain_event를 만들지 않고
// Task 상태·시작일을 바꾸지 않는다. 모든 SQL은 `?` 바인딩을 사용한다.
extension WorkRepository {

    // MARK: WeekPlan

    /// weekStart(월요일) 기준 계획. 없으면 nil.
    public func weekPlan(weekStart: WorkDate) throws -> WeekPlan? {
        try db.queryOneV("SELECT * FROM week_plan WHERE week_start = ?", weekStart)
            .map { try weekPlanRow($0) }
    }

    public func insertWeekPlan(_ p: WeekPlan) throws {
        try db.runV("""
            INSERT INTO week_plan (id, week_start, revision, confirmed_at)
            VALUES (?, ?, ?, ?)
            """, p.id, p.weekStart, p.revision, p.confirmedAt)
    }

    public func updateWeekPlan(_ p: WeekPlan) throws {
        let n = try db.runV("""
            UPDATE week_plan SET week_start = ?, revision = ?, confirmed_at = ?
            WHERE id = ?
            """, p.weekStart, p.revision, p.confirmedAt, p.id)
        if n == 0 { throw WorkLogError.notFound("week_plan \(p.id)") }
    }

    // MARK: WeekPlanItem

    /// 계획에 속한 항목. 삽입 순서(rowid)를 유지한다.
    public func weekPlanItems(planId: String) throws -> [WeekPlanItem] {
        try db.queryV("""
            SELECT * FROM week_plan_item WHERE week_plan_id = ?
            ORDER BY rowid ASC
            """, planId).map { try weekPlanItemRow($0) }
    }

    public func insertWeekPlanItem(_ i: WeekPlanItem) throws {
        try db.runV("""
            INSERT INTO week_plan_item
                (id, week_plan_id, task_id, scope_type, scope_id, label, state,
                 candidate_reason, confirmed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, i.id, i.weekPlanId, i.taskId, i.scopeType.rawValue, i.scopeId, i.label,
               i.state.rawValue, i.candidateReason, i.confirmedAt)
    }

    public func updateWeekPlanItem(_ i: WeekPlanItem) throws {
        let n = try db.runV("""
            UPDATE week_plan_item SET week_plan_id = ?, task_id = ?, scope_type = ?, scope_id = ?,
                label = ?, state = ?, candidate_reason = ?, confirmed_at = ?
            WHERE id = ?
            """, i.weekPlanId, i.taskId, i.scopeType.rawValue, i.scopeId, i.label,
               i.state.rawValue, i.candidateReason, i.confirmedAt, i.id)
        if n == 0 { throw WorkLogError.notFound("week_plan_item \(i.id)") }
    }

    /// 서비스 내부용 단건 조회.
    func weekPlanItem(id: String) throws -> WeekPlanItem? {
        try db.queryOneV("SELECT * FROM week_plan_item WHERE id = ?", id).map { try weekPlanItemRow($0) }
    }

    // MARK: - Row mapping

    private func weekPlanRow(_ row: SQLRow) throws -> WeekPlan {
        guard let id = row.string("id"), let weekStart = row.workDate("week_start") else {
            throw WorkLogError.storage("week_plan row 손상")
        }
        return WeekPlan(id: id, weekStart: weekStart,
                        revision: row.int("revision") ?? 1,
                        confirmedAt: row.date("confirmed_at"))
    }

    private func weekPlanItemRow(_ row: SQLRow) throws -> WeekPlanItem {
        guard let id = row.string("id"), let weekPlanId = row.string("week_plan_id"),
              let taskId = row.string("task_id"),
              let scopeRaw = row.string("scope_type"), let scopeType = PlanScopeType(rawValue: scopeRaw),
              let stateRaw = row.string("state"), let state = PlanItemState(rawValue: stateRaw) else {
            throw WorkLogError.storage("week_plan_item row 손상")
        }
        return WeekPlanItem(id: id, weekPlanId: weekPlanId, taskId: taskId, scopeType: scopeType,
                            scopeId: row.string("scope_id"), label: row.string("label"), state: state,
                            candidateReason: row.string("candidate_reason"),
                            confirmedAt: row.date("confirmed_at"))
    }
}
