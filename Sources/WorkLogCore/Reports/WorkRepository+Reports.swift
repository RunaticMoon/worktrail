import Foundation

// MARK: - 리포트 저장 (Report / SourceSnapshot / ReportVersion / ReportEvidence)
//
// 리포트 계약 타입(Models.swift, ReportTypes.swift)의 단순 CRUD만 담당한다.
// 버전 상태 전이 규칙·확정본 보호·stale 판정은 ReportStore가 담당한다.
// 모든 SQL은 `?` 바인딩을 사용한다. Secret 자료형은 여기에 들어오지 않는다.

/// report_evidence 한 행. 근거 원문의 revision을 함께 고정한다.
public struct ReportEvidenceRow: Codable, Hashable, Sendable {
    public var reportVersionId: String
    public var itemId: String
    public var taskId: String?
    public var sourceId: String
    public var sourceRevision: Int

    public init(reportVersionId: String, itemId: String, taskId: String? = nil,
                sourceId: String, sourceRevision: Int) {
        self.reportVersionId = reportVersionId; self.itemId = itemId; self.taskId = taskId
        self.sourceId = sourceId; self.sourceRevision = sourceRevision
    }
}

extension WorkRepository {

    // MARK: Report

    public func insertReport(_ r: Report) throws {
        try db.runV("""
            INSERT INTO report
                (id, family, period_type, period_key, start, end_exclusive,
                 plan_start, plan_end_exclusive, evaluation_period_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, r.id, r.family.rawValue, r.periodType.rawValue, r.periodKey,
               r.range.start, r.range.endExclusive,
               r.planRange?.start, r.planRange?.endExclusive,
               r.evaluationPeriodId, r.createdAt)
    }

    public func report(id: String) throws -> Report? {
        try db.queryOneV("SELECT * FROM report WHERE id = ?", id).map { try reportRow($0) }
    }

    public func report(family: ReportFamily, periodType: PeriodType, periodKey: String) throws -> Report? {
        try db.queryOneV("""
            SELECT * FROM report WHERE family = ? AND period_type = ? AND period_key = ?
            """, family.rawValue, periodType.rawValue, periodKey).map { try reportRow($0) }
    }

    /// 기간 시작 내림차순, id 오름차순. family가 주어지면 그 family만.
    public func reports(family: ReportFamily? = nil) throws -> [Report] {
        if let family {
            return try db.queryV("""
                SELECT * FROM report WHERE family = ? ORDER BY start DESC, id ASC
                """, family.rawValue).map { try reportRow($0) }
        }
        return try db.queryV("SELECT * FROM report ORDER BY start DESC, id ASC").map { try reportRow($0) }
    }

    // MARK: SourceSnapshot

    public func insertSourceSnapshot(_ s: SourceSnapshot) throws {
        try db.runV("""
            INSERT INTO source_snapshot
                (id, start, end_exclusive, state_cutoff, known_at, frozen_facts_json, digest, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, s.id, s.range.start, s.range.endExclusive, s.stateCutoff, s.knownAt,
               s.frozenFactsJSON, s.digest, s.createdAt)
    }

    public func sourceSnapshot(id: String) throws -> SourceSnapshot? {
        try db.queryOneV("SELECT * FROM source_snapshot WHERE id = ?", id).map { try sourceSnapshotRow($0) }
    }

    // MARK: ReportVersion

    /// warnings는 JSON 배열로 저장한다.
    public func insertReportVersion(_ v: ReportVersion) throws {
        try db.runV("""
            INSERT INTO report_version
                (id, report_id, version, state, content, structured_json, source_snapshot_id,
                 template_version_id, skill_ref, ai_model, generator, warnings_json,
                 based_on_version_id, created_at, confirmed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, v.id, v.reportId, v.version, v.state.rawValue, v.content, v.structuredJSON,
               v.sourceSnapshotId, v.templateVersionId, v.skillRef, v.aiModel, v.generator,
               try StableJSON.string(v.warnings), v.basedOnVersionId, v.createdAt, v.confirmedAt)
    }

    /// 확정본의 보호 컬럼(content/state/structured_json/source_snapshot_id) 변경은
    /// DB 트리거가 거부한다. 오류는 그대로 전파된다.
    public func updateReportVersion(_ v: ReportVersion) throws {
        let n = try db.runV("""
            UPDATE report_version SET report_id = ?, version = ?, state = ?, content = ?,
                structured_json = ?, source_snapshot_id = ?, template_version_id = ?, skill_ref = ?,
                ai_model = ?, generator = ?, warnings_json = ?, based_on_version_id = ?,
                created_at = ?, confirmed_at = ?
            WHERE id = ?
            """, v.reportId, v.version, v.state.rawValue, v.content, v.structuredJSON,
               v.sourceSnapshotId, v.templateVersionId, v.skillRef, v.aiModel, v.generator,
               try StableJSON.string(v.warnings), v.basedOnVersionId, v.createdAt, v.confirmedAt, v.id)
        if n == 0 { throw WorkLogError.notFound("report_version \(v.id)") }
    }

    public func reportVersion(id: String) throws -> ReportVersion? {
        try db.queryOneV("SELECT * FROM report_version WHERE id = ?", id).map { try reportVersionRow($0) }
    }

    /// version 오름차순.
    public func reportVersions(reportId: String) throws -> [ReportVersion] {
        try db.queryV("""
            SELECT * FROM report_version WHERE report_id = ? ORDER BY version ASC
            """, reportId).map { try reportVersionRow($0) }
    }

    // MARK: ReportEvidence

    public func insertReportEvidence(_ rows: [ReportEvidenceRow]) throws {
        guard !rows.isEmpty else { return }
        try db.transaction {
            for row in rows {
                try db.runV("""
                    INSERT OR IGNORE INTO report_evidence
                        (report_version_id, item_id, task_id, source_id, source_revision)
                    VALUES (?, ?, ?, ?, ?)
                    """, row.reportVersionId, row.itemId, row.taskId, row.sourceId, row.sourceRevision)
            }
        }
    }

    public func reportEvidence(versionId: String) throws -> [ReportEvidenceRow] {
        try db.queryV("""
            SELECT * FROM report_evidence WHERE report_version_id = ?
            ORDER BY item_id ASC, source_id ASC
            """, versionId).map { row in
            ReportEvidenceRow(reportVersionId: row.string("report_version_id") ?? versionId,
                              itemId: row.string("item_id") ?? "",
                              taskId: row.string("task_id"),
                              sourceId: row.string("source_id") ?? "",
                              sourceRevision: row.int("source_revision") ?? 1)
        }
    }

    // MARK: - Row mapping

    private func reportRow(_ row: SQLRow) throws -> Report {
        guard let id = row.string("id"),
              let familyRaw = row.string("family"), let family = ReportFamily(rawValue: familyRaw),
              let periodRaw = row.string("period_type"), let periodType = PeriodType(rawValue: periodRaw),
              let periodKey = row.string("period_key"),
              let start = row.workDate("start"), let end = row.workDate("end_exclusive") else {
            throw WorkLogError.storage("report row 손상")
        }
        let planRange: DateRange?
        if let planStart = row.workDate("plan_start"), let planEnd = row.workDate("plan_end_exclusive") {
            planRange = DateRange(start: planStart, endExclusive: planEnd)
        } else {
            planRange = nil
        }
        return Report(id: id, family: family, periodType: periodType, periodKey: periodKey,
                      range: DateRange(start: start, endExclusive: end), planRange: planRange,
                      evaluationPeriodId: row.string("evaluation_period_id"),
                      createdAt: row.date("created_at") ?? Date(timeIntervalSince1970: 0))
    }

    private func sourceSnapshotRow(_ row: SQLRow) throws -> SourceSnapshot {
        guard let id = row.string("id"),
              let start = row.workDate("start"), let end = row.workDate("end_exclusive"),
              let frozen = row.string("frozen_facts_json"), let digest = row.string("digest") else {
            throw WorkLogError.storage("source_snapshot row 손상")
        }
        return SourceSnapshot(id: id, range: DateRange(start: start, endExclusive: end),
                              stateCutoff: row.date("state_cutoff") ?? Date(timeIntervalSince1970: 0),
                              knownAt: row.date("known_at") ?? Date(timeIntervalSince1970: 0),
                              frozenFactsJSON: frozen, digest: digest,
                              createdAt: row.date("created_at") ?? Date(timeIntervalSince1970: 0))
    }

    private func reportVersionRow(_ row: SQLRow) throws -> ReportVersion {
        guard let id = row.string("id"), let reportId = row.string("report_id"),
              let version = row.int("version"),
              let stateRaw = row.string("state"), let state = ReportVersionState(rawValue: stateRaw),
              let content = row.string("content"), let generator = row.string("generator"),
              let snapshotId = row.string("source_snapshot_id") else {
            throw WorkLogError.storage("report_version row 손상")
        }
        let warnings = (try? StableJSON.decode([String].self, from: row.string("warnings_json") ?? "[]")) ?? []
        return ReportVersion(id: id, reportId: reportId, version: version, state: state, content: content,
                             structuredJSON: row.string("structured_json"), sourceSnapshotId: snapshotId,
                             templateVersionId: row.string("template_version_id"),
                             skillRef: row.string("skill_ref"), aiModel: row.string("ai_model"),
                             generator: generator, warnings: warnings,
                             basedOnVersionId: row.string("based_on_version_id"),
                             createdAt: row.date("created_at") ?? Date(timeIntervalSince1970: 0),
                             confirmedAt: row.date("confirmed_at"))
    }
}
