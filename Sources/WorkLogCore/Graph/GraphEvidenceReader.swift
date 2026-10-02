import Foundation

/// `report_version`과 그 근거(`report_evidence`)·스냅샷을 그래프 DTO로 변환하는 읽기 전용 리더.
///
/// - work.sqlite의 일반 테이블만 읽는다. Secret(Vault) 테이블에는 접근하지 않는다.
/// - 근거의 `source_id`는 `FactSource` 형식(`"memo:<id>"`, `"task:<id>"`,
///   `"activity:<id>"`, `"supplement:<id>"`, `"report:<versionId>"`)이다. 접두사
///   `report:`의 접미사는 **리포트 ID가 아니라 리포트 버전 ID**다. 근거: `ReportTypes.swift`.
/// - 원본이 삭제됐거나 조회 불가면 `historicalSource` 노드로 보존한다.
/// - 알 수 없는 source 종류는 건너뛴다(throw 하지 않는다).
/// - 모든 SQL은 저장소의 `?` 바인딩 조회 메서드를 통해서만 수행한다.
public struct GraphEvidenceReader {
    private let repo: WorkRepository

    public init(repo: WorkRepository) {
        self.repo = repo
    }

    /// 리포트 버전과 그 근거를 노드·엣지로 읽는다.
    ///
    /// `range`가 있으면 리포트 기간이 겹치거나 그 기간에 생성된 버전만 루트로 읽는다.
    /// nil이면 전체 버전을 읽는다. 근거 대상 노드는 범위와 무관하게 원본 id로 조회한다.
    /// 결과는 노드를 `id.key`, 엣지를 `key`로 정렬해 반환한다.
    public func read(range: DateRange?) throws -> (nodes: [GraphNode], edges: [GraphEdge]) {
        var nodeMap: [GraphNodeID: GraphNode] = [:]
        var edgeMap: [String: GraphEdge] = [:]

        for (version, report) in try selectedVersions(range: range) {
            let from = GraphNodeID(kind: .reportVersion, id: version.id)
            if nodeMap[from] == nil {
                nodeMap[from] = reportVersionNode(version: version, report: report)
            }

            let evidence = try repo.reportEvidence(versionId: version.id)
            guard !evidence.isEmpty else { continue }
            let snapshotText = try snapshotSourceText(version: version)

            for row in evidence {
                guard let to = try resolveTarget(sourceId: row.sourceId, revision: row.sourceRevision,
                                                 snapshotText: snapshotText, nodeMap: &nodeMap) else {
                    continue
                }
                let edge = GraphEdge(
                    from: from,
                    to: to,
                    kind: .reportEvidence,
                    sourceKey: "report_evidence:\(version.id):\(row.itemId):\(row.sourceId)",
                    isDirected: true,
                    evidence: GraphEvidenceRef(reportVersionId: version.id,
                                               sourceSnapshotId: version.sourceSnapshotId,
                                               sourceId: row.sourceId,
                                               sourceRevision: row.sourceRevision))
                edgeMap[edge.key] = edge
            }
        }

        let nodeKeys = Set(nodeMap.keys)
        let nodes = nodeMap.values.sorted { $0.id.key < $1.id.key }
        let edges = edgeMap.values
            .filter { nodeKeys.contains($0.from) && nodeKeys.contains($0.to) }
            .sorted { $0.key < $1.key }
        return (nodes, edges)
    }

    // MARK: - 버전 선택

    /// 기간이 겹치거나 그 기간에 생성된 리포트 버전.
    /// 결정적 순서: 리포트 start 내림차순 → 리포트 id 오름차순 → version 오름차순 → version id 오름차순.
    private func selectedVersions(range: DateRange?) throws -> [(ReportVersion, Report)] {
        var result: [(ReportVersion, Report)] = []
        for report in try repo.reports() {
            for version in try repo.reportVersions(reportId: report.id) {
                if let range, !isIncluded(version: version, report: report, range: range) { continue }
                result.append((version, report))
            }
        }
        result.sort { lhs, rhs in
            if lhs.1.range.start != rhs.1.range.start { return lhs.1.range.start > rhs.1.range.start }
            if lhs.1.id != rhs.1.id { return lhs.1.id < rhs.1.id }
            if lhs.0.version != rhs.0.version { return lhs.0.version < rhs.0.version }
            return lhs.0.id < rhs.0.id
        }
        return result
    }

    private func isIncluded(version: ReportVersion, report: Report, range: DateRange) -> Bool {
        if report.range.intersection(range) != nil { return true }
        return range.contains(repo.calendar.workDate(of: version.createdAt))
    }

    // MARK: - 근거 대상 해석

    /// `source_id`를 노드로 해석한다. 삭제·조회 불가면 스냅샷 `historicalSource` 노드.
    /// 알 수 없는 접두사는 nil(건너뜀)을 반환한다.
    private func resolveTarget(sourceId: String, revision: Int, snapshotText: [String: String],
                               nodeMap: inout [GraphNodeID: GraphNode]) throws -> GraphNodeID? {
        guard let parsed = Self.parse(sourceId) else { return nil }

        switch parsed.kind {
        case "memo":
            if let memo = try repo.memo(id: parsed.rawId) {
                return insertNode(GraphNodeID(kind: .memo, id: memo.id),
                                  GraphNode(id: GraphNodeID(kind: .memo, id: memo.id),
                                            title: Self.title(from: memo.body),
                                            record: RecordReference(kind: .memo, id: memo.id),
                                            date: memo.workDate),
                                  into: &nodeMap)
            }
        case "task":
            if let task = try repo.task(id: parsed.rawId) {
                let id = GraphNodeID(kind: .task, id: task.id)
                return insertNode(id,
                                  GraphNode(id: id, title: task.title,
                                            record: RecordReference(kind: .task, id: task.id),
                                            date: repo.calendar.workDate(of: task.createdAt)),
                                  into: &nodeMap)
            }
        case "activity":
            if let activity = try repo.activity(id: parsed.rawId), activity.deletedAt == nil {
                let id = GraphNodeID(kind: .activity, id: activity.id)
                return insertNode(id,
                                  GraphNode(id: id, title: Self.title(from: activity.body),
                                            record: RecordReference(kind: .activity, id: activity.id),
                                            date: activity.workDate),
                                  into: &nodeMap)
            }
        case "supplement":
            // 보충 노드 id·필드는 GraphRecordReader의 supplement 노드와 동일해야 엣지가 붙는다.
            if let supplement = try repo.supplement(id: parsed.rawId) {
                let id = GraphNodeID(kind: .supplement, id: supplement.id)
                return insertNode(id,
                                  GraphNode(id: id, title: Self.title(from: supplement.question),
                                            subtitle: supplement.answer, record: nil,
                                            date: supplement.applies.start),
                                  into: &nodeMap)
            }
        case "report":
            // 접미사는 리포트 ID가 아니라 버전 ID다.
            if let version = try repo.reportVersion(id: parsed.rawId),
               let report = try repo.report(id: version.reportId) {
                let id = GraphNodeID(kind: .reportVersion, id: version.id)
                return insertNode(id, reportVersionNode(version: version, report: report), into: &nodeMap)
            }
        default:
            // 알 수 없는 source 종류는 조용히 건너뛴다.
            return nil
        }

        // 원본이 삭제됐거나 조회 불가 → 스냅샷 역사 노드.
        return insertHistoricalNode(parsed: parsed, sourceId: sourceId, revision: revision,
                                    snapshotText: snapshotText, nodeMap: &nodeMap)
    }

    @discardableResult
    private func insertNode(_ id: GraphNodeID, _ node: GraphNode,
                            into nodeMap: inout [GraphNodeID: GraphNode]) -> GraphNodeID {
        if nodeMap[id] == nil { nodeMap[id] = node }
        return id
    }

    private func insertHistoricalNode(parsed: ParsedSourceID, sourceId: String, revision: Int,
                                      snapshotText: [String: String],
                                      nodeMap: inout [GraphNodeID: GraphNode]) -> GraphNodeID {
        let id = GraphNodeID(kind: .historicalSource, id: "\(parsed.kind):\(parsed.rawId)@\(revision)")
        if nodeMap[id] == nil {
            let title = snapshotText[sourceId].map { Self.snapshotPreview($0) } ?? sourceId
            nodeMap[id] = GraphNode(id: id, title: title, record: nil)
        }
        return id
    }

    // MARK: - 스냅샷

    /// 버전의 스냅샷 `frozen_facts_json`에서 `source_id` → 원문 텍스트 사전을 만든다.
    /// 해석 실패는 치명적이지 않으므로 빈 사전으로 둔다.
    private func snapshotSourceText(version: ReportVersion) throws -> [String: String] {
        guard let snapshot = try repo.sourceSnapshot(id: version.sourceSnapshotId),
              let facts = try? StableJSON.decode(ReportFacts.self, from: snapshot.frozenFactsJSON) else {
            return [:]
        }
        var text: [String: String] = [:]
        for source in facts.sources { text[source.id] = source.text }
        return text
    }

    // MARK: - 노드 생성

    private func reportVersionNode(version: ReportVersion, report: Report) -> GraphNode {
        let endInclusive = repo.calendar.adding(days: -1, to: report.range.endExclusive)
        let period = "\(report.range.start.iso)~\(endInclusive.iso)"
        return GraphNode(id: GraphNodeID(kind: .reportVersion, id: version.id),
                         title: "\(Self.familyDisplayName(report.family)) \(period) v\(version.version)",
                         record: RecordReference(kind: .reportVersion, id: version.id),
                         reportFamily: report.family.rawValue,
                         reportVersionNumber: version.version)
    }

    // MARK: - 문자열

    private static func familyDisplayName(_ family: ReportFamily) -> String {
        switch family {
        case .submission: return "제출용 주간보고"
        case .performance: return "상세 성과 리포트"
        }
    }

    /// 본문 첫 번째 비어 있지 않은 줄의 앞 `maxLength`자. 없으면 빈 문자열.
    private static func title(from body: String, maxLength: Int = 40) -> String {
        let line = body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return line.count > maxLength ? String(line.prefix(maxLength)) : line
    }

    /// 스냅샷 텍스트의 공백을 하나로 접고 앞 `maxLength`자.
    private static func snapshotPreview(_ text: String, maxLength: Int = 40) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.count > maxLength ? String(collapsed.prefix(maxLength)) : collapsed
    }

    // MARK: - source_id 파싱

    private struct ParsedSourceID {
        let kind: String
        let rawId: String
    }

    /// `"<kind>:<id>"` 형식을 나눈다. 콜론이나 한쪽이 비면 nil.
    private static func parse(_ sourceId: String) -> ParsedSourceID? {
        guard let colon = sourceId.firstIndex(of: ":") else { return nil }
        let kind = String(sourceId[sourceId.startIndex..<colon])
        let rawId = String(sourceId[sourceId.index(after: colon)...])
        guard !kind.isEmpty, !rawId.isEmpty else { return nil }
        return ParsedSourceID(kind: kind, rawId: rawId)
    }
}
