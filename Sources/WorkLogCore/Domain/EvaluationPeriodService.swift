import Foundation

// MARK: - 평가 기간 영속화 (evaluation_period)
//
// 평가 기간 ID와 확정 리포트 버전 ID를 분리해 저장한다. 같은 기간의 새 버전을
// 다시 확정해도 기간 range는 변하지 않는다(REP-T07). 모든 SQL은 `?` 바인딩을 쓴다.
extension WorkRepository {

    public func insertEvaluationPeriod(_ p: EvaluationPeriod) throws {
        try db.runV("""
            INSERT INTO evaluation_period
                (id, start, end_exclusive, previous_period_id, confirmed_report_version_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, p.id, p.range.start, p.range.endExclusive, p.previousPeriodId,
               p.confirmedReportVersionId, p.createdAt)
    }

    /// start 오름차순, created_at, id 순.
    public func evaluationPeriods() throws -> [EvaluationPeriod] {
        try db.queryV("""
            SELECT * FROM evaluation_period
            ORDER BY start ASC, created_at ASC, id ASC
            """).map { try evaluationPeriodRow($0) }
    }

    public func evaluationPeriod(id: String) throws -> EvaluationPeriod? {
        try db.queryOneV("SELECT * FROM evaluation_period WHERE id = ?", id)
            .map { try evaluationPeriodRow($0) }
    }

    /// 확정 리포트 버전 연결. 존재하지 않는 id면 notFound.
    public func setEvaluationPeriodConfirmed(id: String, reportVersionId: String) throws {
        let n = try db.runV("""
            UPDATE evaluation_period SET confirmed_report_version_id = ? WHERE id = ?
            """, reportVersionId, id)
        if n == 0 { throw WorkLogError.notFound("evaluation_period \(id)") }
    }

    // MARK: - Row mapping

    private func evaluationPeriodRow(_ row: SQLRow) throws -> EvaluationPeriod {
        guard let id = row.string("id"),
              let start = row.workDate("start"),
              let endExclusive = row.workDate("end_exclusive"),
              start <= endExclusive else {
            throw WorkLogError.storage("evaluation_period row 손상")
        }
        return EvaluationPeriod(
            id: id,
            range: DateRange(start: start, endExclusive: endExclusive),
            previousPeriodId: row.string("previous_period_id"),
            confirmedReportVersionId: row.string("confirmed_report_version_id"),
            createdAt: row.date("created_at") ?? Date(timeIntervalSince1970: 0))
    }
}

/// 새 평가 기간 제안. 저장 전 미리보기이며 경고를 포함한다.
public struct EvaluationPeriodProposal: Sendable, Hashable {
    public var range: DateRange
    public var previousPeriodId: String?
    public var warnings: [String]

    public init(range: DateRange, previousPeriodId: String? = nil, warnings: [String] = []) {
        self.range = range
        self.previousPeriodId = previousPeriodId
        self.warnings = warnings
    }
}

/// PERF-03: 연간 평가 기간을 제안·저장하고 확정 리포트 버전을 연결한다.
/// 보고서 생성일(clock now)과 집계 종료일(endInclusive)은 별개다(REP-T08).
public final class EvaluationPeriodService {

    private let repo: WorkRepository

    public init(repo: WorkRepository) {
        self.repo = repo
    }

    /// start가 nil이면 직전 확정 기간의 종료 다음 날을 시작일로 파생한다(EvaluationPeriods.propose).
    /// 첫 평가는 start가 필수다. previousPeriodId는 확정 기간 중 endExclusive가 가장 늦은 기간이다.
    public func propose(start: WorkDate?, endInclusive: WorkDate) throws -> EvaluationPeriodProposal {
        let existing = try repo.evaluationPeriods()
        let range = try EvaluationPeriods.propose(start: start, endInclusive: endInclusive,
                                                  existing: existing, calendar: repo.calendar)
        let previousPeriodId = existing
            .filter { $0.confirmedReportVersionId != nil }
            .max(by: { $0.range.endExclusive < $1.range.endExclusive })?
            .id
        let warnings = EvaluationPeriods.boundaryWarnings(range, periodId: nil, existing: existing)
        return EvaluationPeriodProposal(range: range, previousPeriodId: previousPeriodId,
                                        warnings: warnings)
    }

    /// 제안 후 저장한다. id는 주입된 IDGenerator, createdAt은 주입된 Clock을 쓴다.
    @discardableResult
    public func create(start: WorkDate?, endInclusive: WorkDate) throws -> (EvaluationPeriod, [String]) {
        let proposal = try propose(start: start, endInclusive: endInclusive)
        let period = EvaluationPeriod(id: repo.ids.make(),
                                      range: proposal.range,
                                      previousPeriodId: proposal.previousPeriodId,
                                      confirmedReportVersionId: nil,
                                      createdAt: repo.clock.now())
        try repo.insertEvaluationPeriod(period)
        return (period, proposal.warnings)
    }

    /// 확정 리포트 버전을 기간에 연결한다. 기간 range는 바뀌지 않는다.
    public func markConfirmed(periodId: String, reportVersionId: String) throws {
        guard try repo.evaluationPeriod(id: periodId) != nil else {
            throw WorkLogError.notFound("evaluation_period \(periodId)")
        }
        try repo.setEvaluationPeriodConfirmed(id: periodId, reportVersionId: reportVersionId)
    }
}
