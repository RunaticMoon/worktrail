import Foundation

// MARK: - 리포트 저장소 (ReportStore)
//
// 리포트의 버전 상태 규칙과 확정본·편집본 보호를 담당한다.
// - 초안 생성(AI/composer 호출)은 하지 않는다. 이미 만들어진 GeneratedDraft를 입력으로 받는다.
// - 자동 재생성은 확정본(REP-T11)과 사용자 편집본(REP-T12)을 덮어쓰지 않는다.
// - 원본 변화가 없으면(자동 모드) 불필요한 새 버전·스냅샷을 만들지 않는다(PERF-05).
// - AI·네트워크·Secret을 다루지 않는다.

/// Composer/AI가 만든 초안(또는 결정적 렌더러 출력). 저장 계층의 입력이다.
public struct GeneratedDraft: Sendable, Hashable {
    /// 화면/복사용 본문.
    public var content: String
    /// SubmissionDraft/PerformanceDraft JSON.
    public var structuredJSON: String?
    public var warnings: [String]
    /// "deterministic" | "mock" | "codex"
    public var generator: String
    public var aiModel: String?
    public var templateVersionId: String?
    public var skillRef: String?
    /// 근거 연결.
    public var evidence: [DraftEvidence]

    public init(content: String, structuredJSON: String? = nil, warnings: [String] = [],
                generator: String, aiModel: String? = nil, templateVersionId: String? = nil,
                skillRef: String? = nil, evidence: [DraftEvidence] = []) {
        self.content = content; self.structuredJSON = structuredJSON; self.warnings = warnings
        self.generator = generator; self.aiModel = aiModel; self.templateVersionId = templateVersionId
        self.skillRef = skillRef; self.evidence = evidence
    }
}

/// 초안이 참조하는 근거 하나. sourceId 형식: "activity:<id>" 등.
public struct DraftEvidence: Sendable, Hashable {
    public var itemId: String
    public var taskId: String?
    public var sourceId: String

    public init(itemId: String, taskId: String? = nil, sourceId: String) {
        self.itemId = itemId; self.taskId = taskId; self.sourceId = sourceId
    }
}

public enum GenerationMode: Sendable {
    /// 스케줄 등 자동 생성. 원본 변화가 없으면 새 버전을 만들지 않는다.
    case automatic
    /// 사용자가 명시적으로 요청한 생성. 같은 원본이라도 새 버전을 만든다.
    case userRequested
}

public enum SaveOutcome: Equatable, Sendable {
    /// 새 버전 생성.
    case created(ReportVersion)
    /// 원본 변화 없음 → 기존 최신 버전 반환, 새 버전 없음.
    case unchanged(ReportVersion)
}

/// 리포트와 그 버전 묶음. latest는 superseded를 제외한 최고 version.
public struct ReportBundle: Sendable {
    public var report: Report
    public var versions: [ReportVersion]
    /// 가장 높은 version 중 superseded가 아닌 것.
    public var latest: ReportVersion?
    /// confirmed 중 가장 높은 version.
    public var latestConfirmed: ReportVersion?
}

public final class ReportStore {

    private let repo: WorkRepository
    private var db: SQLiteDatabase { repo.db }
    private var clock: Clock { repo.clock }
    private var ids: IDGenerator { repo.ids }

    public init(repo: WorkRepository) {
        self.repo = repo
    }

    // MARK: - 리포트 확보

    /// (family, periodType, periodKey)가 있으면 반환, 없으면 생성한다.
    public func ensureReport(family: ReportFamily, periodType: PeriodType, periodKey: String,
                             range: DateRange, planRange: DateRange? = nil,
                             evaluationPeriodId: String? = nil) throws -> Report {
        try db.transaction {
            if let existing = try repo.report(family: family, periodType: periodType, periodKey: periodKey) {
                return existing
            }
            let report = Report(id: ids.make(), family: family, periodType: periodType,
                                periodKey: periodKey, range: range, planRange: planRange,
                                evaluationPeriodId: evaluationPeriodId, createdAt: clock.now())
            try repo.insertReport(report)
            return report
        }
    }

    public func bundle(reportId: String) throws -> ReportBundle {
        guard let report = try repo.report(id: reportId) else {
            throw WorkLogError.notFound("report \(reportId)")
        }
        let versions = try repo.reportVersions(reportId: reportId)
        let latest = versions.last { $0.state != .superseded }
        let latestConfirmed = versions.last { $0.state == .confirmed }
        return ReportBundle(report: report, versions: versions, latest: latest,
                            latestConfirmed: latestConfirmed)
    }

    // MARK: - 생성 저장

    /// 스냅샷 저장 후 버전 규칙을 적용한다. 전체가 하나의 transaction이다.
    public func saveGenerated(reportId: String, facts: ReportFacts, draft: GeneratedDraft,
                              mode: GenerationMode) throws -> SaveOutcome {
        let newDigest = try ReportFactsBuilder.digest(facts)

        // 콜백은 transaction 밖에서 호출한다(롤백된 상태를 알리지 않음).
        var changedIds: [String] = []

        let outcome: SaveOutcome = try db.transaction {
            guard try repo.report(id: reportId) != nil else {
                throw WorkLogError.notFound("report \(reportId)")
            }
            let versions = try repo.reportVersions(reportId: reportId)
            let latest = versions.last { $0.state != .superseded }

            // 1. 자동 + 원본 변화 없음 → 기존 최신 버전 유지, 스냅샷도 만들지 않는다.
            if mode == .automatic, let latest,
               let snapshot = try repo.sourceSnapshot(id: latest.sourceSnapshotId),
               snapshot.digest == newDigest {
                return .unchanged(latest)
            }

            // 2. 새 스냅샷.
            let snapshot = SourceSnapshot(
                id: ids.make(), range: facts.range, stateCutoff: facts.statusCutoff,
                knownAt: facts.knownAt, frozenFactsJSON: try StableJSON.string(facts),
                digest: newDigest, createdAt: clock.now())
            try repo.insertSourceSnapshot(snapshot)

            // 3. 기존 버전 처리 + basedOn 결정.
            var basedOn: String?
            switch latest?.state {
            case nil:
                basedOn = nil
            case .some(.draft):
                // 사용자가 손대지 않은 자동 초안은 대체한다. 상태만 바꾸고 본문은 보존한다.
                var superseded = latest!
                superseded.state = .superseded
                try repo.updateReportVersion(superseded)
                changedIds.append(superseded.id)
                basedOn = nil
            case .some(.edited):
                basedOn = latest!.id
            case .some(.confirmed):
                basedOn = latest!.id
            case .some(.superseded):
                basedOn = nil
            }

            // 4. 근거 매핑 (알 수 없는 sourceId는 제외 + 경고).
            var warnings = draft.warnings
            var evidenceRows: [ReportEvidenceRow] = []
            let revisionBySource = Dictionary(uniqueKeysWithValues: facts.sources.map { ($0.id, $0.revision) })
            for evidence in draft.evidence {
                guard let revision = revisionBySource[evidence.sourceId] else {
                    warnings.append("알 수 없는 근거 제외: \(evidence.sourceId)")
                    continue
                }
                evidenceRows.append(ReportEvidenceRow(reportVersionId: "", itemId: evidence.itemId,
                                                      taskId: evidence.taskId, sourceId: evidence.sourceId,
                                                      sourceRevision: revision))
            }

            let nextVersion = (versions.map(\.version).max() ?? 0) + 1
            let versionId = ids.make()
            let version = ReportVersion(
                id: versionId, reportId: reportId, version: nextVersion, state: .draft,
                content: draft.content, structuredJSON: draft.structuredJSON,
                sourceSnapshotId: snapshot.id, templateVersionId: draft.templateVersionId,
                skillRef: draft.skillRef, aiModel: draft.aiModel, generator: draft.generator,
                warnings: warnings, basedOnVersionId: basedOn, createdAt: clock.now())
            try repo.insertReportVersion(version)

            let rows = evidenceRows.map {
                ReportEvidenceRow(reportVersionId: versionId, itemId: $0.itemId, taskId: $0.taskId,
                                  sourceId: $0.sourceId, sourceRevision: $0.sourceRevision)
            }
            try repo.insertReportEvidence(rows)
            changedIds.append(versionId)

            guard let saved = try repo.reportVersion(id: versionId) else {
                throw WorkLogError.storage("report_version \(versionId) 삽입 후 조회 실패")
            }
            return .created(saved)
        }

        for id in changedIds {
            repo.onSourceChanged?("report", id)
        }
        return outcome
    }

    // MARK: - 편집

    public func edit(versionId: String, content: String) throws -> ReportVersion {
        guard let current = try repo.reportVersion(id: versionId) else {
            throw WorkLogError.notFound("report_version \(versionId)")
        }
        switch current.state {
        case .superseded:
            throw WorkLogError.invalidTransition("superseded 버전은 편집할 수 없습니다: \(versionId)")
        case .confirmed:
            // 확정본은 불변. 같은 스냅샷·템플릿·생성기로 새 edited 버전을 만든다.
            // 콜백은 transaction 밖에서 호출한다(롤백된 상태를 알리지 않음).
            let (saved, newVersionId) = try db.transaction { () -> (ReportVersion, String) in
                let versions = try repo.reportVersions(reportId: current.reportId)
                let nextVersion = (versions.map(\.version).max() ?? 0) + 1
                let versionId = ids.make()
                var edited = current
                edited.id = versionId
                edited.version = nextVersion
                edited.state = .edited
                edited.content = content
                edited.basedOnVersionId = current.id
                edited.createdAt = clock.now()
                edited.confirmedAt = nil
                try repo.insertReportVersion(edited)
                guard let inserted = try repo.reportVersion(id: versionId) else {
                    throw WorkLogError.storage("report_version \(versionId) 삽입 후 조회 실패")
                }
                return (inserted, versionId)
            }
            repo.onSourceChanged?("report", newVersionId)
            return saved
        case .draft, .edited:
            var updated = current
            updated.content = content
            updated.state = .edited
            try repo.updateReportVersion(updated)
            guard let saved = try repo.reportVersion(id: versionId) else {
                throw WorkLogError.storage("report_version \(versionId) 갱신 후 조회 실패")
            }
            repo.onSourceChanged?("report", versionId)
            return saved
        }
    }

    // MARK: - 확정

    public func confirm(versionId: String) throws -> ReportVersion {
        guard let current = try repo.reportVersion(id: versionId) else {
            throw WorkLogError.notFound("report_version \(versionId)")
        }
        switch current.state {
        case .superseded:
            throw WorkLogError.invalidTransition("superseded 버전은 확정할 수 없습니다: \(versionId)")
        case .confirmed:
            return current
        case .draft, .edited:
            var updated = current
            updated.state = .confirmed
            updated.confirmedAt = clock.now()
            try repo.updateReportVersion(updated)
            guard let saved = try repo.reportVersion(id: versionId) else {
                throw WorkLogError.storage("report_version \(versionId) 확정 후 조회 실패")
            }
            repo.onSourceChanged?("report", versionId)
            return saved
        }
    }

    // MARK: - stale 판정

    /// 현재 facts digest가 버전의 스냅샷 digest와 다르면 true.
    public func isStale(versionId: String, currentFacts: ReportFacts) throws -> Bool {
        guard let version = try repo.reportVersion(id: versionId) else {
            throw WorkLogError.notFound("report_version \(versionId)")
        }
        guard let snapshot = try repo.sourceSnapshot(id: version.sourceSnapshotId) else {
            throw WorkLogError.storage("source_snapshot \(version.sourceSnapshotId) 없음")
        }
        return snapshot.digest != (try ReportFactsBuilder.digest(currentFacts))
    }
}
