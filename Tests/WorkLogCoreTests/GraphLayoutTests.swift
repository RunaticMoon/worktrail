import XCTest
@testable import WorkLogCore

final class GraphLayoutTests: XCTestCase {

    // MARK: - 헬퍼

    private func node(_ kind: GraphNodeKind, _ id: String) -> GraphNode {
        GraphNode(id: GraphNodeID(kind: kind, id: id), title: "\(kind.rawValue)-\(id)")
    }

    private func nodeID(_ kind: GraphNodeKind, _ id: String) -> GraphNodeID {
        GraphNodeID(kind: kind, id: id)
    }

    private func edge(
        _ from: GraphNodeID,
        _ to: GraphNodeID,
        kind: GraphEdgeKind = .manualRelated,
        source: String = "s"
    ) -> GraphEdge {
        GraphEdge(from: from, to: to, kind: kind, sourceKey: source, isDirected: false)
    }

    private func assertWithinBounds(
        _ positions: [GraphNodeID: GraphPoint],
        _ configuration: GraphLayoutConfiguration,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (id, point) in positions {
            XCTAssertTrue(point.x.isFinite, "\(id.key) x가 유한하지 않음: \(point.x)", file: file, line: line)
            XCTAssertTrue(point.y.isFinite, "\(id.key) y가 유한하지 않음: \(point.y)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(point.x, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(point.x, configuration.width, file: file, line: line)
            XCTAssertGreaterThanOrEqual(point.y, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(point.y, configuration.height, file: file, line: line)
        }
    }

    // MARK: 1. 빈 그래프

    func testEmptyGraphReturnsNoPositions() {
        let result = GraphLayout.positions(for: .empty, configuration: GraphLayoutConfiguration())
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: 2. 단일 노드 중심

    func testSingleNodeIsPlacedAtCenter() throws {
        let configuration = GraphLayoutConfiguration(iterations: 50, width: 400, height: 300)
        let graph = GraphSnapshot(nodes: [node(.memo, "m1")], edges: [], isTruncated: false)

        let result = GraphLayout.positions(for: graph, configuration: configuration)

        XCTAssertEqual(result.count, 1)
        let point = try XCTUnwrap(result[nodeID(.memo, "m1")])
        XCTAssertEqual(point.x, 200, accuracy: 1e-9)
        XCTAssertEqual(point.y, 150, accuracy: 1e-9)
    }

    // MARK: 3. 두 연결 노드 거리 > 0

    func testTwoConnectedNodesHavePositiveDistance() {
        let a = nodeID(.memo, "m1")
        let b = nodeID(.task, "t1")
        let graph = GraphSnapshot(
            nodes: [node(.memo, "m1"), node(.task, "t1")],
            edges: [edge(a, b)],
            isTruncated: false
        )
        let configuration = GraphLayoutConfiguration()

        let result = GraphLayout.positions(for: graph, configuration: configuration)

        let pa = result[a]
        let pb = result[b]
        XCTAssertNotNil(pa)
        XCTAssertNotNil(pb)
        let dx = (pa?.x ?? 0) - (pb?.x ?? 0)
        let dy = (pa?.y ?? 0) - (pb?.y ?? 0)
        XCTAssertGreaterThan((dx * dx + dy * dy).squareRoot(), 0)
    }

    // MARK: 4. 입력 순열과 무관

    func testInputPermutationProducesIdenticalPositions() {
        let ids: [(GraphNodeKind, String)] = [
            (.memo, "m1"), (.memo, "m2"), (.task, "t1"),
            (.task, "t2"), (.activity, "a1"), (.project, "p1"),
        ]
        let nodes = ids.map { node($0.0, $0.1) }
        let edges = [
            edge(nodeID(.memo, "m1"), nodeID(.task, "t1"), source: "e1"),
            edge(nodeID(.task, "t1"), nodeID(.task, "t2"), kind: .taskRelated, source: "e2"),
            edge(nodeID(.activity, "a1"), nodeID(.task, "t1"), kind: .activityTask, source: "e3"),
            edge(nodeID(.memo, "m2"), nodeID(.project, "p1"), kind: .projectMembership, source: "e4"),
            edge(nodeID(.task, "t2"), nodeID(.project, "p1"), kind: .projectMembership, source: "e5"),
        ]
        let configuration = GraphLayoutConfiguration(iterations: 120)

        let base = GraphSnapshot(nodes: nodes, edges: edges, isTruncated: false)
        // 노드와 엣지 배열 순서를 결정적으로 뒤집은 변형.
        let permuted = GraphSnapshot(
            nodes: nodes.reversed(),
            edges: edges.reversed(),
            isTruncated: false
        )

        let baseResult = GraphLayout.positions(for: base, configuration: configuration)
        let permutedResult = GraphLayout.positions(for: permuted, configuration: configuration)

        // 정확히 같은 Double 값이어야 한다.
        XCTAssertEqual(baseResult, permutedResult)
    }

    // MARK: 5. 반복 호출 동일

    func testRepeatedCallsAreIdentical() {
        let nodes = (0..<8).map { node(.memo, "m\($0)") }
        var edges: [GraphEdge] = []
        for i in 0..<7 {
            edges.append(edge(nodeID(.memo, "m\(i)"), nodeID(.memo, "m\(i + 1)"), source: "e\(i)"))
        }
        let graph = GraphSnapshot(nodes: nodes, edges: edges, isTruncated: false)
        let configuration = GraphLayoutConfiguration(iterations: 80)

        let first = GraphLayout.positions(for: graph, configuration: configuration)
        let second = GraphLayout.positions(for: graph, configuration: configuration)

        XCTAssertEqual(first, second)
    }

    // MARK: 6. 모든 좌표 유한·범위 내

    func testAllCoordinatesAreFiniteAndWithinBounds() {
        let configuration = GraphLayoutConfiguration(iterations: 100, width: 640, height: 480)
        let nodes = (0..<12).map { node(.task, "t\($0)") }
        var edges: [GraphEdge] = []
        for i in 0..<11 {
            edges.append(edge(nodeID(.task, "t\(i)"), nodeID(.task, "t\(i + 1)"), kind: .taskRelated, source: "e\(i)"))
        }
        let graph = GraphSnapshot(nodes: nodes, edges: edges, isTruncated: false)

        let result = GraphLayout.positions(for: graph, configuration: configuration)

        XCTAssertEqual(result.count, 12)
        assertWithinBounds(result, configuration)
    }

    // MARK: 7. 비연결 그래프

    func testDisconnectedGraphStaysWithinBounds() {
        let configuration = GraphLayoutConfiguration(iterations: 100, width: 800, height: 600)
        let nodes = [
            node(.memo, "m1"), node(.memo, "m2"),
            node(.task, "t1"), node(.task, "t2"),
        ]
        let edges = [
            edge(nodeID(.memo, "m1"), nodeID(.memo, "m2"), source: "e1"),
            edge(nodeID(.task, "t1"), nodeID(.task, "t2"), kind: .taskRelated, source: "e2"),
        ]
        let graph = GraphSnapshot(nodes: nodes, edges: edges, isTruncated: false)

        let result = GraphLayout.positions(for: graph, configuration: configuration)

        XCTAssertEqual(result.count, 4)
        assertWithinBounds(result, configuration)
    }

    // MARK: 8. 끝점 누락 엣지 무시 + 중복 엣지 1회

    func testEdgeWithMissingEndpointIsIgnored() {
        let a = nodeID(.memo, "m1")
        let b = nodeID(.task, "t1")
        let missing = nodeID(.task, "t404")
        let withDangling = GraphSnapshot(
            nodes: [node(.memo, "m1"), node(.task, "t1")],
            edges: [edge(a, b, source: "e1"), edge(a, missing, source: "dangling")],
            isTruncated: false
        )
        let withoutDangling = GraphSnapshot(
            nodes: [node(.memo, "m1"), node(.task, "t1")],
            edges: [edge(a, b, source: "e1")],
            isTruncated: false
        )
        let configuration = GraphLayoutConfiguration(iterations: 60)

        let danglingResult = GraphLayout.positions(for: withDangling, configuration: configuration)
        let cleanResult = GraphLayout.positions(for: withoutDangling, configuration: configuration)

        XCTAssertEqual(danglingResult.count, 2)
        XCTAssertEqual(danglingResult, cleanResult)
    }

    func testParallelDuplicateEdgeIsCountedOnce() {
        let a = nodeID(.memo, "m1")
        let b = nodeID(.task, "t1")
        let single = GraphSnapshot(
            nodes: [node(.memo, "m1"), node(.task, "t1")],
            edges: [edge(a, b, source: "e1")],
            isTruncated: false
        )
        let duplicated = GraphSnapshot(
            nodes: [node(.memo, "m1"), node(.task, "t1")],
            edges: [
                edge(a, b, source: "e1"),
                edge(a, b, kind: .acceptedMemoTask, source: "e2"),
                edge(b, a, kind: .manualRelated, source: "e3"),
            ],
            isTruncated: false
        )
        let configuration = GraphLayoutConfiguration(iterations: 60)

        XCTAssertEqual(
            GraphLayout.positions(for: single, configuration: configuration),
            GraphLayout.positions(for: duplicated, configuration: configuration)
        )
    }

    // MARK: 9. 소규모 성능 스모크 (200노드)

    func testLargeGraphPerformanceSmoke() {
        let configuration = GraphLayoutConfiguration(iterations: 300, width: 1000, height: 800)
        let nodeCount = 200
        let nodes = (0..<nodeCount).map { node(.task, String(format: "t%03d", $0)) }

        var edges: [GraphEdge] = []
        for i in 0..<nodeCount {
            let from = nodeID(.task, String(format: "t%03d", i))
            // 각 노드에서 앞쪽 노드로 최대 3개 엣지. 총 약 600개.
            for offset in 1...3 where i - offset >= 0 {
                let to = nodeID(.task, String(format: "t%03d", i - offset))
                edges.append(edge(from, to, kind: .taskRelated, source: "e\(i)-\(offset)"))
            }
        }

        let graph = GraphSnapshot(nodes: nodes, edges: edges, isTruncated: false)
        let result = GraphLayout.positions(for: graph, configuration: configuration)

        XCTAssertEqual(result.count, nodeCount)
        assertWithinBounds(result, configuration)
    }
}
