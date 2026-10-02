import Foundation

// MARK: - 예약 작업 영속화 (scheduled_job)
//
// (type, period_key)가 유일하다. 이미 처리한 기간을 다시 넣지 않도록 INSERT OR IGNORE를 쓴다.
extension WorkRepository {

    public func scheduledJob(type: ScheduledJobType, periodKey: String) throws -> ScheduledJob? {
        try db.queryOneV("SELECT * FROM scheduled_job WHERE type = ? AND period_key = ?",
                         type.rawValue, periodKey).map { try scheduledJobRow($0) }
    }

    /// UNIQUE(type, period_key) — 이미 있으면 false, 새로 넣으면 true.
    @discardableResult
    public func insertScheduledJobIfAbsent(_ job: ScheduledJob) throws -> Bool {
        let inserted = try db.runV("""
            INSERT OR IGNORE INTO scheduled_job
                (id, type, period_key, scheduled_for, state, attempts,
                 last_attempt_at, recovered_late, last_error)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, job.id, job.type.rawValue, job.periodKey, job.scheduledFor, job.state.rawValue,
               job.attempts, job.lastAttemptAt, job.recoveredLate, job.lastError)
        return inserted > 0
    }

    public func updateScheduledJob(_ job: ScheduledJob) throws {
        let updated = try db.runV("""
            UPDATE scheduled_job
            SET type = ?, period_key = ?, scheduled_for = ?, state = ?, attempts = ?,
                last_attempt_at = ?, recovered_late = ?, last_error = ?
            WHERE id = ?
            """, job.type.rawValue, job.periodKey, job.scheduledFor, job.state.rawValue,
               job.attempts, job.lastAttemptAt, job.recoveredLate, job.lastError, job.id)
        if updated == 0 { throw WorkLogError.notFound("scheduled_job \(job.id)") }
    }

    /// scheduledFor 오름차순. states가 nil이면 전체.
    public func scheduledJobs(states: [ScheduledJobState]? = nil) throws -> [ScheduledJob] {
        let base = "SELECT * FROM scheduled_job"
        let order = "ORDER BY scheduled_for ASC, type ASC, id ASC"
        let rows: [SQLRow]
        if let states, !states.isEmpty {
            let placeholders = Array(repeating: "?", count: states.count).joined(separator: ", ")
            rows = try db.query("\(base) WHERE state IN (\(placeholders)) \(order)",
                                states.map { $0.rawValue as SQLBindable })
        } else {
            rows = try db.query("\(base) \(order)")
        }
        return try rows.map { try scheduledJobRow($0) }
    }

    /// "type|periodKey" 집합. 처리 여부와 무관하게 존재하는 모든 행을 담는다.
    public func scheduledJobKeys() throws -> Set<String> {
        let rows = try db.queryV("SELECT type, period_key FROM scheduled_job")
        return Set(rows.compactMap { row in
            guard let type = row.string("type"), let periodKey = row.string("period_key") else { return nil }
            return "\(type)|\(periodKey)"
        })
    }

    /// 앱이 죽어 running으로 남은 작업을 pending으로 되돌린다. 바뀐 개수 반환.
    @discardableResult
    public func resetStaleRunningJobs() throws -> Int {
        try db.runV("UPDATE scheduled_job SET state = ? WHERE state = ?",
                    ScheduledJobState.pending.rawValue, ScheduledJobState.running.rawValue)
    }

    // MARK: - Row mapping

    private func scheduledJobRow(_ row: SQLRow) throws -> ScheduledJob {
        guard let id = row.string("id"),
              let typeRaw = row.string("type"), let type = ScheduledJobType(rawValue: typeRaw),
              let periodKey = row.string("period_key"),
              let scheduledFor = row.date("scheduled_for"),
              let stateRaw = row.string("state"), let state = ScheduledJobState(rawValue: stateRaw) else {
            throw WorkLogError.storage("scheduled_job row 손상")
        }
        return ScheduledJob(id: id, type: type, periodKey: periodKey, scheduledFor: scheduledFor,
                            state: state, attempts: row.int("attempts") ?? 0,
                            lastAttemptAt: row.date("last_attempt_at"),
                            recoveredLate: row.bool("recovered_late"),
                            lastError: row.string("last_error"))
    }
}
