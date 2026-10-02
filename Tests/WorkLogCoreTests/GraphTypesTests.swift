import XCTest
@testable import WorkLogCore

final class GraphTypesTests: XCTestCase {

    // MARK: 1. canonicalPair 정렬 / 자기 연결

    func testCanonicalPairOrdersByKindThenID() {
        let task = RecordReference(kind: .task, id: "a")
        let memo = RecordReference(kind: .memo, id: "z")

        // kind의 UTF-8 바이트 순("memo" < "task")이 id보다 우선한다.
        let pair = RecordReference.canonicalPair(task, memo)
        XCTAssertEqual(pair?.0, memo)
        XCTAssertEqual(pair?.1, task)
    }

    func testCanonicalPairOrdersByIDWithinSameKind() {
        let b = RecordReference(kind: .memo, id: "b")
        let a = RecordReference(kind: .memo, id: "a")

        let pair = RecordReference.canonicalPair(b, a)
        XCTAssertEqual(pair?.0, a)
        XCTAssertEqual(pair?.1, b)
    }

    func testCanonicalPairIsSymmetric() {
        let a = RecordReference(kind: .activity, id: "x9")
        let b = RecordReference(kind: .reportVersion, id: "v1")

        let forward = RecordReference.canonicalPair(a, b)
        let backward = RecordReference.canonicalPair(b, a)
        XCTAssertEqual(forward?.0, backward?.0)
        XCTAssertEqual(forward?.1, backward?.1)
        // "report_version" < "activity"? 아니다. "activity" < "report_version".
        XCTAssertEqual(forward?.0, a)
        XCTAssertEqual(forward?.1, b)
    }

    func testCanonicalPairRejectsSelfLink() {
        let a = RecordReference(kind: .task, id: "t1")
        let same = RecordReference(kind: .task, id: "t1")
        XCTAssertNil(RecordReference.canonicalPair(a, a))
        XCTAssertNil(RecordReference.canonicalPair(a, same))
    }

    func testCanonicalPairMatchesUTF8ByteOrdering() {
        let refs = [
            RecordReference(kind: .task, id: "t2"),
            RecordReference(kind: .memo, id: "m1"),
            RecordReference(kind: .reportVersion, id: "v1"),
            RecordReference(kind: .activity, id: "a1"),
            RecordReference(kind: .memo, id: "m10"),
        ]
        // (kind.rawValue, id)를 UTF-8 바이트로 비교한 기대 순서.
        let expected = refs.sorted { lhs, rhs in
            let lk = Array(lhs.kind.rawValue.utf8), rk = Array(rhs.kind.rawValue.utf8)
            if lk != rk { return lk.lexicographicallyPrecedes(rk) }
            return Array(lhs.id.utf8).lexicographicallyPrecedes(Array(rhs.id.utf8))
        }
        XCTAssertEqual(expected.map(\.id), ["a1", "m1", "m10", "v1", "t2"])

        for i in 0..<refs.count {
            for j in 0..<refs.count where refs[i] != refs[j] {
                let pair = RecordReference.canonicalPair(refs[i], refs[j])
                let lower = RecordReference.canonicalPair(refs[j], refs[i])
                XCTAssertEqual(pair?.0, lower?.0)
                XCTAssertEqual(pair?.1, lower?.1)
            }
        }
    }

    // MARK: 2. JSON 왕복과 rawValue

    func testRecordReferenceJSONRoundTripUsesSnakeCaseRawValue() throws {
        let reference = RecordReference(kind: .reportVersion, id: "rv-1")
        let data = try JSONEncoder().encode(reference)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"report_version\""), "예상하지 못한 JSON: \(json)")

        let decoded = try JSONDecoder().decode(RecordReference.self, from: data)
        XCTAssertEqual(decoded, reference)
        XCTAssertEqual(RecordReferenceKind(rawValue: "report_version"), .reportVersion)
    }

    func testGraphNodeKindRawValuesUseSnakeCase() throws {
        XCTAssertEqual(GraphNodeKind.reportVersion.rawValue, "report_version")
        XCTAssertEqual(GraphNodeKind.historicalSource.rawValue, "historical_source")

        let data = try JSONEncoder().encode(GraphNodeKind.historicalSource)
        XCTAssertEqual(try XCTUnwrap(String(data: data, encoding: .utf8)), "\"historical_source\"")
    }

    func testGraphNodeJSONRoundTrip() throws {
        let node = GraphNode(
            id: GraphNodeID(kind: .reportVersion, id: "rv-1"),
            title: "제출용 주간보고 v3",
            subtitle: "submission",
            record: RecordReference(kind: .reportVersion, id: "rv-1"),
            date: WorkDate("2026-09-28")!,
            reportFamily: "submission",
            reportVersionNumber: 3
        )
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(GraphNode.self, from: data)
        XCTAssertEqual(decoded, node)
        XCTAssertEqual(decoded.date, WorkDate("2026-09-28")!)
    }

    func testRecordLinkJSONRoundTrip() throws {
        let link = RecordLink(
            id: "l1",
            first: RecordReference(kind: .memo, id: "m1"),
            second: RecordReference(kind: .task, id: "t1"),
            relationType: "related",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(link)
        let decoded = try JSONDecoder().decode(RecordLink.self, from: data)
        XCTAssertEqual(decoded, link)
    }

    // MARK: 3. GraphNodeID.key 형식

    func testGraphNodeIDKeyFormat() {
        XCTAssertEqual(GraphNodeID(kind: .task, id: "t1").key, "task:t1")
        XCTAssertEqual(GraphNodeID(kind: .reportVersion, id: "rv-9").key, "report_version:rv-9")
        XCTAssertEqual(GraphNodeID(kind: .historicalSource, id: "h1").key, "historical_source:h1")
        XCTAssertNotEqual(GraphNodeID(kind: .memo, id: "1").key, GraphNodeID(kind: .task, id: "1").key)
    }

    // MARK: 4. 엣지 키 안정성

    func testGraphEdgeKeyIsStableAndDistinct() {
        let from = GraphNodeID(kind: .memo, id: "m1")
        let to = GraphNodeID(kind: .task, id: "t1")

        let first = GraphEdge(from: from, to: to, kind: .manualRelated,
                              sourceKey: "record_link:l1", isDirected: false)
        let second = GraphEdge(from: from, to: to, kind: .manualRelated,
                               sourceKey: "record_link:l1", isDirected: false)
        XCTAssertEqual(first.key, second.key)
        XCTAssertEqual(first.key, "memo:m1|task:t1|manualRelated|record_link:l1")

        let otherSource = GraphEdge(from: from, to: to, kind: .manualRelated,
                                    sourceKey: "record_link:l2", isDirected: false)
        XCTAssertNotEqual(first.key, otherSource.key)

        let otherKind = GraphEdge(from: from, to: to, kind: .acceptedMemoTask,
                                  sourceKey: "record_link:l1", isDirected: false)
        XCTAssertNotEqual(first.key, otherKind.key)

        // Set/딕셔너리에서 구조적 동등성과 key가 일치한다.
        XCTAssertEqual(Set([first, second]).count, 1)
        XCTAssertEqual(first, second)
    }

    func testGraphEvidenceRefRoundTrip() throws {
        let edge = GraphEdge(
            from: GraphNodeID(kind: .reportVersion, id: "rv-1"),
            to: GraphNodeID(kind: .memo, id: "m1"),
            kind: .reportEvidence,
            sourceKey: "report:rv-1",
            isDirected: true,
            evidence: GraphEvidenceRef(reportVersionId: "rv-1", sourceSnapshotId: "snap-1",
                                       sourceId: "m1", sourceRevision: 2)
        )
        let data = try JSONEncoder().encode(edge)
        let decoded = try JSONDecoder().decode(GraphEdge.self, from: data)
        XCTAssertEqual(decoded, edge)
        XCTAssertEqual(decoded.evidence?.sourceRevision, 2)
    }

    // MARK: 5. Secret 관련 kind 부재

    func testNoSecretRelatedKindsExist() {
        for kind in RecordReferenceKind.allCases {
            let raw = kind.rawValue.lowercased()
            XCTAssertFalse(raw.contains("secret") || raw.contains("vault"),
                           "Secret 관련 참조 종류가 존재하면 안 된다: \(kind.rawValue)")
        }
        for kind in GraphNodeKind.allCases {
            let raw = kind.rawValue.lowercased()
            XCTAssertFalse(raw.contains("secret") || raw.contains("vault"),
                           "Secret 관련 노드 종류가 존재하면 안 된다: \(kind.rawValue)")
        }

        XCTAssertEqual(Set(RecordReferenceKind.allCases.map(\.rawValue)),
                       ["memo", "task", "activity", "report_version"])
        XCTAssertEqual(Set(GraphNodeKind.allCases.map(\.rawValue)),
                       ["memo", "task", "activity", "report_version",
                        "project", "tag", "supplement", "historical_source"])
    }

    func testGraphEdgeKindSetIsClosed() {
        XCTAssertEqual(Set(GraphEdgeKind.allCases.map(\.rawValue)),
                       ["activityTask", "acceptedMemoTask", "taskRelated", "taskFollowUp",
                        "projectMembership", "tagMembership", "reportEvidence",
                        "supplementTask", "manualRelated"])
    }

    // MARK: 6. 조회·스냅샷·레이아웃 기본값

    func testGraphQueryDefaults() {
        let query = GraphQuery()
        XCTAssertNil(query.range)
        XCTAssertTrue(query.kinds.isEmpty)
        XCTAssertTrue(query.projectIds.isEmpty)
        XCTAssertTrue(query.tagIds.isEmpty)
        XCTAssertNil(query.focus)
        XCTAssertEqual(query.nodeLimit, 250)
    }

    func testGraphSnapshotEmpty() {
        XCTAssertTrue(GraphSnapshot.empty.nodes.isEmpty)
        XCTAssertTrue(GraphSnapshot.empty.edges.isEmpty)
        XCTAssertFalse(GraphSnapshot.empty.isTruncated)
    }

    func testLayoutConfigurationDefaults() {
        let configuration = GraphLayoutConfiguration()
        XCTAssertEqual(configuration.iterations, 300)
        XCTAssertEqual(configuration.width, 1000)
        XCTAssertEqual(configuration.height, 800)

        let point = GraphPoint(x: 1.5, y: -2.25)
        XCTAssertEqual(point.x, 1.5)
        XCTAssertEqual(point.y, -2.25)
    }
}
