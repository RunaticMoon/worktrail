import Foundation

// ai_job 테이블(work.sqlite)의 영속화. Secret 타입은 다루지 않는다.
// 모든 값은 `?` 바인딩으로 전달한다(문자열 결합 없음).
extension WorkRepository {

    /// 새 AI 작업 행. 같은 idempotency_key가 이미 있으면 SQLite UNIQUE 제약 오류가 난다.
    public func insertAIJob(_ job: AIJob) throws {
        try db.runV("""
            INSERT INTO ai_job
                (id, type, idempotency_key, input_digest, status, attempts,
                 last_error_class, result_json, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, job.id, job.type, job.idempotencyKey, job.inputDigest, job.status.rawValue,
               job.attempts, job.lastErrorClass?.rawValue, job.resultJSON,
               job.createdAt, job.updatedAt)
    }

    /// 상태·시도 횟수·오류 분류·결과를 갱신한다. 행이 없으면 notFound.
    public func updateAIJob(_ job: AIJob) throws {
        let n = try db.runV("""
            UPDATE ai_job
               SET type = ?, idempotency_key = ?, input_digest = ?, status = ?, attempts = ?,
                   last_error_class = ?, result_json = ?, created_at = ?, updated_at = ?
             WHERE id = ?
            """, job.type, job.idempotencyKey, job.inputDigest, job.status.rawValue,
               job.attempts, job.lastErrorClass?.rawValue, job.resultJSON,
               job.createdAt, job.updatedAt, job.id)
        if n == 0 { throw WorkLogError.notFound("ai_job \(job.id)") }
    }

    public func aiJob(id: String) throws -> AIJob? {
        try db.queryOneV("SELECT * FROM ai_job WHERE id = ?", id).map { try aiJobRow($0) }
    }

    public func aiJob(idempotencyKey: String) throws -> AIJob? {
        try db.queryOneV("SELECT * FROM ai_job WHERE idempotency_key = ?", idempotencyKey)
            .map { try aiJobRow($0) }
    }

    /// created_at, id 순.
    public func aiJobs(status: AIJobStatus) throws -> [AIJob] {
        try db.queryV("""
            SELECT * FROM ai_job WHERE status = ? ORDER BY created_at ASC, id ASC
            """, status.rawValue).map { try aiJobRow($0) }
    }

    private func aiJobRow(_ row: SQLRow) throws -> AIJob {
        guard let id = row.string("id"), let type = row.string("type"),
              let key = row.string("idempotency_key"), let digest = row.string("input_digest"),
              let statusRaw = row.string("status"), let status = AIJobStatus(rawValue: statusRaw),
              let createdAt = row.date("created_at"), let updatedAt = row.date("updated_at") else {
            throw WorkLogError.storage("ai_job row 손상")
        }
        // 알 수 없는 오류 분류 문자열은 nil로 둔다(원문 보존보다 안전한 기본값).
        let lastErrorClass = row.string("last_error_class").flatMap { AIErrorClass(rawValue: $0) }
        return AIJob(id: id, type: type, idempotencyKey: key, inputDigest: digest,
                     status: status, attempts: row.int("attempts") ?? 0,
                     lastErrorClass: lastErrorClass, resultJSON: row.string("result_json"),
                     createdAt: createdAt, updatedAt: updatedAt)
    }
}
