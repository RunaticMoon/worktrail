import XCTest
@testable import WorkLogCore

/// GraphEvidenceReader: 리포트 버전과 근거·스냅샷을 그래프 DTO로 읽는 계약 검증.
///
/// - 근거 엣지 종류·방향·`GraphEvidenceRef` 값·`sourceKey`.
/// - `report:<versionId>`가 리포트 ID가 아니라 버전 ID로 연결되는지.
/// - 삭제·조회 불가 원본 → 스냅샷 `historicalSource` 보존.
/// - 범위 필터, 결정적 정렬, 모든 엣지 끝점 존재, 알 수 없는 source 종류 건너뜀.
final class GraphEvidenceReaderTests: XCTestCase {

    private var repo: WorkRepository!
    private var reader: GraphEvidenceReader!

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let week1 = DateRange(start: WorkDate("2026-09-28")!, endExclusive: WorkDate("2026-10-05")!)
    private let week2 = DateRange(start: WorkDate("2026-10-05")!, endExclusive: WorkDate("2026-10-12")!)

    override func setUpWithError() throws {
        try super.setUpWithError()
        repo = try WorkRepository.inMemory(clock: FixedClock(now),
                                           ids: SequentialIDGenerator(prefix: "r"))
        reader = GraphEvidenceReader(repo: repo)
    }

    // MARK: - 픽스처

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    @discardableResult
    private func insertReport(id: String, family: ReportFamily, periodType: PeriodType = .weekly,
                              periodKey: String, range: DateRange) throws -> Report {
        let report = Report(id: id, family: family, periodType: periodType, periodKey: periodKey,
                            range: range, createdAt: now)
        try repo.insertReport(report)
        return report
    }

    @discardableResult
    private func insertVersion(reportId: String, versionId: String, family: ReportFamily,
                               periodType: PeriodType = .weekly, range: DateRange, version: Int,
                               state: ReportVersionState = .draft, createdAt: Date,
                               sources: [FactSource] = [],
                               evidence: [(itemId: String, sourceId: String, revision: Int)] = []) throws -> ReportVersion {
        let facts = ReportFacts(family: family, periodType: periodType, timezone: "Asia/Seoul",
                                generatedAt: createdAt, range: range, statusCutoff: createdAt,
                                knownAt: createdAt, projects: [], tasks: [], sources: sources,
                                metrics: ReportMetrics())
        let snapshot = SourceSnapshot(id: "snap-\(versionId)", range: range, stateCutoff: createdAt,
                                      knownAt: createdAt,
                                      frozenFactsJSON: try StableJSON.string(facts),
                                      digest: "digest-\(versionId)", createdAt: createdAt)
        try repo.insertSourceSnapshot(snapshot)
        let saved = ReportVersion(id: versionId, reportId: reportId, version: version, state: state,
                                  content: "content-\(versionId)", sourceSnapshotId: snapshot.id,
                                  generator: "deterministic", createdAt: createdAt)
        try repo.insertReportVersion(saved)
        if !evidence.isEmpty {
            try repo.insertReportEvidence(evidence.map {
                ReportEvidenceRow(reportVersionId: versionId, itemId: $0.itemId, taskId: nil,
                                  sourceId: $0.sourceId, sourceRevision: $0.revision)
            })
        }
        return saved
    }

    private func factSource(_ id: String, _ kind: FactSourceKind, revision: Int = 1,
                            text: String) -> FactSource {
        FactSource(id: id, kind: kind, revision: revision, recordedAt: now, workDate: nil,
                   taskId: nil, projectIds: [], text: text)
    }

    @discardableResult
    private func insertSupplement(id: String, taskId: String, question: String = "보충 질문",
                                  answer: String? = "보충 답변", applies: DateRange) throws -> EvidenceSupplement {
        let supplement = EvidenceSupplement(id: id, taskId: taskId, topicKey: "topic-\(id)",
                                            question: question, answer: answer, outcome: .answered,
                                            applies: applies, sourceDigest: "digest-\(id)", recordedAt: now)
        try repo.insertSupplement(supplement)
        return supplement
    }

    private func assertEndpointsExist(_ nodes: [GraphNode], _ edges: [GraphEdge],
                                      file: StaticString = #filePath, line: UInt = #line) {
        let keys = Set(nodes.map(\.id))
        for edge in edges {
            XCTAssertTrue(keys.contains(edge.from), "엣지 from 끝점 누락: \(edge.from.key)", file: file, line: line)
            XCTAssertTrue(keys.contains(edge.to), "엣지 to 끝점 누락: \(edge.to.key)", file: file, line: line)
        }
    }

    // MARK: 1 — 근거 엣지와 노드 필드

    func testEvidenceEdgesLinkVersionToExistingRecords() throws {
        let report = try insertReport(id: "rep-1", family: .submission, periodKey: "2026-10-05",
                                      range: week1)
        try repo.insertMemo(Memo(id: "m1", body: "메모 첫 줄\n둘째 줄", workDate: week1.start,
                                 recordedAt: now))
        try repo.insertTask(WorkTask(id: "t1", title: "업무 제목", createdAt: now))
        try repo.insertActivity(Activity(id: "a1", taskId: "t1", body: "활동 본문",
                                         workDate: week1.start, recordedAt: now))

        try insertVersion(reportId: report.id, versionId: "v1", family: .submission, range: week1,
                          version: 1, createdAt: date("2026-09-29T09:00:00+09:00"),
                          sources: [factSource("memo:m1", .memo, revision: 3, text: "스냅샷 메모"),
                                    factSource("activity:a1", .activity, text: "스냅샷 활동")],
                          evidence: [("i1", "memo:m1", 3), ("i2", "task:t1", 1), ("i3", "activity:a1", 2)])

        let (nodes, edges) = try reader.read(range: nil)

        let versionID = GraphNodeID(kind: .reportVersion, id: "v1")
        let versionNode = try XCTUnwrap(nodes.first { $0.id == versionID })
        XCTAssertEqual(versionNode.reportFamily, "submission")
        XCTAssertEqual(versionNode.reportVersionNumber, 1)
        XCTAssertEqual(versionNode.record, RecordReference(kind: .reportVersion, id: "v1"))
        XCTAssertTrue(versionNode.title.contains("제출용 주간보고"), versionNode.title)
        XCTAssertTrue(versionNode.title.contains("v1"), versionNode.title)

        XCTAssertEqual(edges.count, 3)
        for edge in edges {
            XCTAssertEqual(edge.kind, .reportEvidence)
            XCTAssertTrue(edge.isDirected)
            XCTAssertEqual(edge.from, versionID)
        }

        let memoEdge = try XCTUnwrap(edges.first { $0.to == GraphNodeID(kind: .memo, id: "m1") })
        XCTAssertEqual(memoEdge.evidence,
                       GraphEvidenceRef(reportVersionId: "v1", sourceSnapshotId: "snap-v1",
                                        sourceId: "memo:m1", sourceRevision: 3))
        XCTAssertEqual(memoEdge.sourceKey, "report_evidence:v1:i1:memo:m1")

        XCTAssertEqual(nodes.first { $0.id == GraphNodeID(kind: .memo, id: "m1") }?.record,
                       RecordReference(kind: .memo, id: "m1"))
        XCTAssertEqual(nodes.first { $0.id == GraphNodeID(kind: .task, id: "t1") }?.title, "업무 제목")
        XCTAssertEqual(nodes.first { $0.id == GraphNodeID(kind: .activity, id: "a1") }?.record,
                       RecordReference(kind: .activity, id: "a1"))
        assertEndpointsExist(nodes, edges)
    }

    // MARK: 2 — report:<versionId>는 버전 ID (리포트 ID 아님)

    func testReportSourceLinksToPreviousVersionNotReportId() throws {
        let report = try insertReport(id: "rep-1", family: .performance, periodType: .weekly,
                                      periodKey: "2026-W40", range: week1)
        try insertVersion(reportId: report.id, versionId: "v1", family: .performance, range: week1,
                          version: 1, createdAt: date("2026-09-28T09:00:00+09:00"))
        try insertVersion(reportId: report.id, versionId: "v2", family: .performance, range: week1,
                          version: 2, createdAt: date("2026-09-29T09:00:00+09:00"),
                          sources: [factSource("report:v1", .report, text: "이전 리포트 본문")],
                          evidence: [("i1", "report:v1", 1)])

        let (nodes, edges) = try reader.read(range: nil)

        let edge = try XCTUnwrap(edges.first { $0.kind == .reportEvidence })
        XCTAssertEqual(edge.from, GraphNodeID(kind: .reportVersion, id: "v2"))
        XCTAssertEqual(edge.to, GraphNodeID(kind: .reportVersion, id: "v1"),
                       "접미사는 리포트 버전 ID여야 한다")
        XCTAssertEqual(edge.evidence?.sourceId, "report:v1")
        XCTAssertNil(nodes.first { $0.id == GraphNodeID(kind: .reportVersion, id: report.id) },
                     "리포트 ID를 버전 노드로 오해하면 안 된다")
        XCTAssertNotNil(nodes.first { $0.id == GraphNodeID(kind: .reportVersion, id: "v1") })
        assertEndpointsExist(nodes, edges)
    }

    // MARK: 3 — 삭제된 원본 → 스냅샷 historicalSource

    func testDeletedSourceBecomesHistoricalSourceNode() throws {
        let report = try insertReport(id: "rep-1", family: .submission, periodKey: "2026-10-05",
                                      range: week1)
        try repo.insertMemo(Memo(id: "m1", body: "삭제될 메모", workDate: week1.start, recordedAt: now))
        try insertVersion(reportId: report.id, versionId: "v1", family: .submission, range: week1,
                          version: 1, createdAt: date("2026-09-29T09:00:00+09:00"),
                          sources: [factSource("memo:m1", .memo, revision: 2, text: "스냅샷 원문 텍스트입니다")],
                          evidence: [("i1", "memo:m1", 2)])
        try repo.softDeleteMemo(id: "m1")

        let (nodes, edges) = try reader.read(range: nil)

        XCTAssertNil(nodes.first { $0.id == GraphNodeID(kind: .memo, id: "m1") },
                     "삭제된 메모는 일반 노드가 되면 안 된다")
        let historyID = GraphNodeID(kind: .historicalSource, id: "memo:m1@2")
        let history = try XCTUnwrap(nodes.first { $0.id == historyID })
        XCTAssertNil(history.record)
        XCTAssertEqual(history.title, "스냅샷 원문 텍스트입니다")
        XCTAssertEqual(edges.first?.to, historyID)
        assertEndpointsExist(nodes, edges)
    }

    // MARK: 3b — supplement 근거는 보충 노드로 연결, 삭제·부재 시 historicalSource

    func testSupplementSourceLinksToSupplementNode() throws {
        let report = try insertReport(id: "rep-1", family: .performance, periodType: .weekly,
                                      periodKey: "2026-W40", range: week1)
        try repo.insertTask(WorkTask(id: "t1", title: "업무", createdAt: now))
        try insertSupplement(id: "s1", taskId: "t1", question: "성과 보충 질문",
                             answer: "성과 보충 답변", applies: week1)
        try insertVersion(reportId: report.id, versionId: "v1", family: .performance, range: week1,
                          version: 1, createdAt: date("2026-09-29T09:00:00+09:00"),
                          sources: [factSource("supplement:s1", .supplement, text: "Q: 성과 보충 질문\nA: 성과 보충 답변")],
                          evidence: [("i1", "supplement:s1", 1)])

        let (nodes, edges) = try reader.read(range: nil)

        let supplementID = GraphNodeID(kind: .supplement, id: "s1")
        let node = try XCTUnwrap(nodes.first { $0.id == supplementID },
                                 "보충 근거가 supplement 노드로 연결되어야 한다")
        XCTAssertEqual(node.title, "성과 보충 질문")
        XCTAssertEqual(node.subtitle, "성과 보충 답변")
        XCTAssertNil(node.record)
        XCTAssertEqual(node.date, week1.start)
        XCTAssertEqual(edges.count, 1)
        let edge = try XCTUnwrap(edges.first)
        XCTAssertEqual(edge.kind, .reportEvidence)
        XCTAssertEqual(edge.from, GraphNodeID(kind: .reportVersion, id: "v1"))
        XCTAssertEqual(edge.to, supplementID)
        XCTAssertEqual(edge.evidence?.sourceId, "supplement:s1")
        assertEndpointsExist(nodes, edges)
    }

    func testDeletedSupplementBecomesHistoricalSourceNode() throws {
        let report = try insertReport(id: "rep-1", family: .performance, periodType: .weekly,
                                      periodKey: "2026-W40", range: week1)
        try repo.insertTask(WorkTask(id: "t1", title: "업무", createdAt: now))
        try insertSupplement(id: "s1", taskId: "t1", applies: week1)
        try insertVersion(reportId: report.id, versionId: "v1", family: .performance, range: week1,
                          version: 1, createdAt: date("2026-09-29T09:00:00+09:00"),
                          sources: [factSource("supplement:s1", .supplement, revision: 4,
                                               text: "스냅샷 보충 원문 텍스트입니다")],
                          evidence: [("i1", "supplement:s1", 4)])
        // 삭제된 보충을 재현한다(조회 실패).
        try repo.db.run("DELETE FROM evidence_supplement WHERE id = ?", ["s1"])

        let (nodes, edges) = try reader.read(range: nil)

        XCTAssertNil(nodes.first { $0.id == GraphNodeID(kind: .supplement, id: "s1") },
                     "삭제된 보충은 supplement 노드가 되면 안 된다")
        let historyID = GraphNodeID(kind: .historicalSource, id: "supplement:s1@4")
        let history = try XCTUnwrap(nodes.first { $0.id == historyID })
        XCTAssertNil(history.record)
        XCTAssertEqual(history.title, "스냅샷 보충 원문 텍스트입니다")
        XCTAssertEqual(edges.first?.to, historyID)
        assertEndpointsExist(nodes, edges)
    }

    // MARK: 4 — 알 수 없는 source 종류는 건너뛴다

    func testUnknownSourceKindIsSkippedWithoutThrowing() throws {
        let report = try insertReport(id: "rep-1", family: .submission, periodKey: "2026-10-05",
                                      range: week1)
        try insertVersion(reportId: report.id, versionId: "v1", family: .submission, range: week1,
                          version: 1, createdAt: date("2026-09-29T09:00:00+09:00"),
                          sources: [factSource("secret:canary", .memo, text: "가짜 시크릿"),
                                    factSource("weird:1", .memo, text: "알 수 없음")],
                          evidence: [("i1", "secret:canary", 1), ("i2", "weird:1", 1)])

        let (nodes, edges) = try reader.read(range: nil)

        XCTAssertTrue(edges.isEmpty)
        XCTAssertEqual(nodes.map(\.id), [GraphNodeID(kind: .reportVersion, id: "v1")])
    }

    // MARK: 5 — 범위 필터

    func testRangeFilterSelectsOverlappingReportsOnly() throws {
        let submission = try insertReport(id: "rep-1", family: .submission, periodKey: "2026-10-05",
                                          range: week1)
        try insertVersion(reportId: submission.id, versionId: "v1", family: .submission, range: week1,
                          version: 1, createdAt: date("2026-09-29T09:00:00+09:00"))
        let performance = try insertReport(id: "rep-2", family: .performance, periodType: .weekly,
                                           periodKey: "2026-W41", range: week2)
        try insertVersion(reportId: performance.id, versionId: "v2", family: .performance, range: week2,
                          version: 1, createdAt: date("2026-10-06T09:00:00+09:00"))

        let (filtered, _) = try reader.read(range: week1)
        XCTAssertEqual(filtered.map(\.id), [GraphNodeID(kind: .reportVersion, id: "v1")])

        let (all, _) = try reader.read(range: nil)
        XCTAssertEqual(Set(all.map(\.id)),
                       [GraphNodeID(kind: .reportVersion, id: "v1"),
                        GraphNodeID(kind: .reportVersion, id: "v2")])
    }

    func testVersionCreatedInRangeIncludedEvenIfReportRangeDisjoint() throws {
        let report = try insertReport(id: "rep-1", family: .performance, periodType: .weekly,
                                      periodKey: "2026-W41", range: week2)
        try insertVersion(reportId: report.id, versionId: "vx", family: .performance, range: week2,
                          version: 1, createdAt: date("2026-09-29T09:00:00+09:00")) // week1 안에서 생성

        let (nodes, _) = try reader.read(range: week1)
        XCTAssertEqual(nodes.map(\.id), [GraphNodeID(kind: .reportVersion, id: "vx")])
    }

    // MARK: 6 — 같은 근거를 여러 item이 참조하면 별개 엣지

    func testSameSourceDifferentItemsProduceSeparateEdges() throws {
        let report = try insertReport(id: "rep-1", family: .submission, periodKey: "2026-10-05",
                                      range: week1)
        try repo.insertMemo(Memo(id: "m1", body: "공유 근거", workDate: week1.start, recordedAt: now))
        try insertVersion(reportId: report.id, versionId: "v1", family: .submission, range: week1,
                          version: 1, createdAt: date("2026-09-29T09:00:00+09:00"),
                          sources: [factSource("memo:m1", .memo, text: "공유 근거")],
                          evidence: [("i1", "memo:m1", 1), ("i2", "memo:m1", 1)])

        let (_, edges) = try reader.read(range: nil)
        XCTAssertEqual(edges.count, 2)
        XCTAssertEqual(Set(edges.map(\.sourceKey)).count, 2)
    }

    // MARK: 7 — 결정적 정렬·중복 없음·끝점 존재

    func testDeterministicOrderingAndUniqueNodes() throws {
        let report = try insertReport(id: "rep-1", family: .submission, periodKey: "2026-10-05",
                                      range: week1)
        try repo.insertMemo(Memo(id: "m-b", body: "메모 B", workDate: week1.start, recordedAt: now))
        try repo.insertMemo(Memo(id: "m-a", body: "메모 A", workDate: week1.start, recordedAt: now))
        try insertVersion(reportId: report.id, versionId: "v2", family: .submission, range: week1,
                          version: 2, createdAt: date("2026-09-30T09:00:00+09:00"),
                          sources: [factSource("memo:m-a", .memo, text: "메모 A"),
                                    factSource("memo:m-b", .memo, text: "메모 B")],
                          evidence: [("i2", "memo:m-b", 1), ("i1", "memo:m-a", 1)])
        try insertVersion(reportId: report.id, versionId: "v1", family: .submission, range: week1,
                          version: 1, createdAt: date("2026-09-29T09:00:00+09:00"),
                          sources: [factSource("memo:m-a", .memo, text: "메모 A")],
                          evidence: [("i1", "memo:m-a", 1)])

        let first = try reader.read(range: nil)
        let second = try reader.read(range: nil)
        XCTAssertEqual(first.nodes, second.nodes)
        XCTAssertEqual(first.edges, second.edges)

        XCTAssertEqual(first.nodes.map(\.id.key), first.nodes.map(\.id.key).sorted())
        XCTAssertEqual(first.edges.map(\.key), first.edges.map(\.key).sorted())
        XCTAssertEqual(Set(first.nodes.map(\.id)).count, first.nodes.count, "같은 id 노드는 하나만")
        assertEndpointsExist(first.nodes, first.edges)
    }
}
