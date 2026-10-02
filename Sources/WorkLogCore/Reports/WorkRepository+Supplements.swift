import Foundation

// MARK: - 성과 보충 답변(EvidenceSupplement) / 전역 Memo↔Task 링크 조회
//
// 리포트 사실 생성기가 쓰는 읽기 경로. Secret 자료형을 다루지 않는다.
// 모든 SQL은 `?` 바인딩을 사용한다.
extension WorkRepository {

    // MARK: EvidenceSupplement

    public func insertSupplement(_ s: EvidenceSupplement) throws {
        try db.runV("""
            INSERT INTO evidence_supplement
                (id, task_id, topic_key, question, answer, outcome,
                 applies_start, applies_end_exclusive, source_digest, recorded_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, s.id, s.taskId, s.topicKey, s.question, s.answer, s.outcome.rawValue,
               s.applies.start, s.applies.endExclusive, s.sourceDigest, s.recordedAt)
        onSourceChanged?("supplement", s.id)
    }

    public func supplements(taskId: String) throws -> [EvidenceSupplement] {
        try db.queryV("""
            SELECT * FROM evidence_supplement WHERE task_id = ?
            ORDER BY recorded_at ASC, id ASC
            """, taskId).map { try supplementRow($0) }
    }

    /// applies 구간이 range와 겹치는 것. [start, endExclusive) 기준.
    public func supplements(overlapping range: DateRange) throws -> [EvidenceSupplement] {
        try db.queryV("""
            SELECT * FROM evidence_supplement
            WHERE applies_start < ? AND applies_end_exclusive > ?
            ORDER BY applies_start ASC, recorded_at ASC, id ASC
            """, range.endExclusive, range.start).map { try supplementRow($0) }
    }

    // MARK: MemoTaskLink (전역 status 조회)

    public func memoTaskLinks(status: MemoTaskLinkStatus) throws -> [MemoTaskLink] {
        try db.queryV("""
            SELECT * FROM memo_task_link WHERE status = ?
            ORDER BY created_at ASC, id ASC
            """, status.rawValue).map { try statusMemoTaskLinkRow($0) }
    }

    // MARK: - Row mapping

    private func supplementRow(_ row: SQLRow) throws -> EvidenceSupplement {
        guard let id = row.string("id"), let taskId = row.string("task_id"),
              let topicKey = row.string("topic_key"), let question = row.string("question"),
              let outcomeRaw = row.string("outcome"), let outcome = SupplementOutcome(rawValue: outcomeRaw),
              let appliesStart = row.workDate("applies_start"),
              let appliesEnd = row.workDate("applies_end_exclusive"),
              let sourceDigest = row.string("source_digest"),
              let recordedAt = row.date("recorded_at") else {
            throw WorkLogError.storage("evidence_supplement row 손상")
        }
        return EvidenceSupplement(id: id, taskId: taskId, topicKey: topicKey, question: question,
                                  answer: row.string("answer"), outcome: outcome,
                                  applies: DateRange(start: appliesStart, endExclusive: appliesEnd),
                                  sourceDigest: sourceDigest, recordedAt: recordedAt)
    }

    private func statusMemoTaskLinkRow(_ row: SQLRow) throws -> MemoTaskLink {
        guard let id = row.string("id"), let memoId = row.string("memo_id"),
              let taskId = row.string("task_id"),
              let statusRaw = row.string("status"), let status = MemoTaskLinkStatus(rawValue: statusRaw) else {
            throw WorkLogError.storage("memo_task_link row 손상")
        }
        return MemoTaskLink(id: id, memoId: memoId, taskId: taskId, status: status,
                            reason: row.string("reason") ?? "",
                            sourceRevision: row.int("source_revision") ?? 1,
                            createdAt: row.date("created_at") ?? Date(timeIntervalSince1970: 0),
                            decidedAt: row.date("decided_at"))
    }
}
