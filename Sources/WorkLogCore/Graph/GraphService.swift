import Foundation

/// 세 소스(`GraphRecordReader`, `GraphEvidenceReader`, `RecordLinkStore`)를 병합해
/// 필터·상한을 적용한 `GraphSnapshot`을 반환하는 읽기 전용 조립 서비스.
///
/// - work.sqlite의 일반 기록만 읽는다. Secret(Vault) 테이블에는 접근하지 않는다.
/// - 노드 병합은 records → evidence 순이며 같은 id면 records 쪽(최신 제목)을 남긴다.
/// - 서로 다른 출처(예: `acceptedMemoTask`와 `manualRelated`)가 같은 두 노드를 이으면
///   의미를 합치지 않고 엣지를 각각 보존한다(`key`가 다르다).
/// - 범위 밖·삭제로 양끝 노드가 없는 수동 링크와, 필터·상한 적용 후 끝점이 사라진
///   엣지는 모두 제거한다.
/// - 정렬은 노드 `id.key`, 엣지 `key` 오름차순으로 결정적이다.
public final class GraphService {
    private let repo: WorkRepository

    public init(repo: WorkRepository) {
        self.repo = repo
    }

    /// 병합·필터·상한을 적용한 그래프 스냅샷.
    public func snapshot(query: GraphQuery) throws -> GraphSnapshot {
        let records = try GraphRecordReader(repo: repo).read(range: query.range)
        let evidence = try GraphEvidenceReader(repo: repo).read(range: query.range)
        let links = try RecordLinkStore(repo: repo).allLinks()

        // 1. 노드 병합: records 우선(제목이 최신), evidence는 없는 id만 추가.
        var nodeMap: [GraphNodeID: GraphNode] = [:]
        for node in records.nodes { nodeMap[node.id] = node }
        for node in evidence.nodes where nodeMap[node.id] == nil { nodeMap[node.id] = node }

        // 2. 엣지 병합: key 중복만 제거하고 출처가 다른 엣지는 모두 유지.
        var edgeMap: [String: GraphEdge] = [:]
        for edge in records.edges { edgeMap[edge.key] = edge }
        for edge in evidence.edges { edgeMap[edge.key] = edge }

        // 3. 수동 링크 → manualRelated 엣지. 양끝 노드가 병합 결과에 있을 때만.
        for link in links {
            let from = Self.nodeID(for: link.first)
            let to = Self.nodeID(for: link.second)
            guard nodeMap[from] != nil, nodeMap[to] != nil else { continue }
            let edge = GraphEdge(from: from, to: to, kind: .manualRelated,
                                 sourceKey: "record_link:\(link.id)", isDirected: false)
            edgeMap[edge.key] = edge
        }

        let mergedNodes = nodeMap
        let mergedEdges = Array(edgeMap.values)

        // 4a. 종류 필터: kinds가 비어 있지 않으면 해당 kind 노드만.
        //     project/tag 보조노드도 kinds에 포함될 때만 남는다.
        let kindFiltered: Set<GraphNodeID>
        if query.kinds.isEmpty {
            kindFiltered = Set(mergedNodes.keys)
        } else {
            kindFiltered = Set(mergedNodes.keys.filter { query.kinds.contains($0.kind) })
        }

        // 4b. 프로젝트/태그 필터: 선택된 project/tag 노드에 소속된 기록과 그 1-hop 이웃.
        let membershipFiltered: Set<GraphNodeID>
        if query.projectIds.isEmpty && query.tagIds.isEmpty {
            membershipFiltered = Set(mergedNodes.keys)
        } else {
            let adjacency = Self.adjacency(mergedEdges)
            let targets = Set(query.projectIds.map { GraphNodeID(kind: .project, id: $0) })
                .union(query.tagIds.map { GraphNodeID(kind: .tag, id: $0) })
            var seeds = Set<GraphNodeID>()
            for edge in mergedEdges where edge.kind == .projectMembership || edge.kind == .tagMembership {
                if targets.contains(edge.to) {
                    seeds.insert(edge.from)
                } else if targets.contains(edge.from) {
                    seeds.insert(edge.to)
                }
            }
            var expanded = seeds
            for seed in seeds { expanded.formUnion(adjacency[seed] ?? []) }
            membershipFiltered = expanded
        }

        // 4c. 중심 필터: focus 노드 기준 BFS 2-hop 이내.
        //     focus가 지정됐지만 병합 결과에 없으면 빈 스냅샷.
        var keep = kindFiltered.intersection(membershipFiltered)
        if let focus = query.focus {
            guard mergedNodes[focus] != nil else {
                return GraphSnapshot(nodes: [], edges: [], isTruncated: false)
            }
            let adjacency = Self.adjacency(mergedEdges)
            let distances = Self.bfsDistances(from: focus, adjacency: adjacency)
            let withinTwo = Set(distances.filter { $0.value <= 2 }.keys)
            keep.formIntersection(withinTwo)
        }

        // 5. 후보(필터 통과 노드·엣지)
        let candidates = mergedNodes.values.filter { keep.contains($0.id) }
        let candidateEdges = mergedEdges.filter { keep.contains($0.from) && keep.contains($0.to) }

        // 6. 상한 적용. focus가 있으면 BFS 거리 오름차순, 없으면 차수 내림차순,
        //    동률은 id.key 오름차순. 결과는 결정적이다.
        let limit = max(0, query.nodeLimit)
        let isTruncated = candidates.count > limit
        let selectedIDs: Set<GraphNodeID>
        if isTruncated {
            let ordered: [GraphNode]
            if let focus = query.focus {
                let distances = Self.bfsDistances(from: focus,
                                                  adjacency: Self.adjacency(candidateEdges))
                ordered = candidates.sorted { a, b in
                    let da = distances[a.id] ?? Int.max
                    let db = distances[b.id] ?? Int.max
                    if da != db { return da < db }
                    return a.id.key < b.id.key
                }
            } else {
                let degree = Self.degrees(edges: candidateEdges)
                ordered = candidates.sorted { a, b in
                    let da = degree[a.id] ?? 0
                    let db = degree[b.id] ?? 0
                    if da != db { return da > db }
                    return a.id.key < b.id.key
                }
            }
            selectedIDs = Set(ordered.prefix(limit).map(\.id))
        } else {
            selectedIDs = keep
        }

        // 7. 최종 노드·엣지. 끝점이 사라진 엣지(고아 엣지)는 제거하고 결정적으로 정렬한다.
        let nodes = mergedNodes.values
            .filter { selectedIDs.contains($0.id) }
            .sorted { $0.id.key < $1.id.key }
        let edges = mergedEdges
            .filter { selectedIDs.contains($0.from) && selectedIDs.contains($0.to) }
            .sorted { $0.key < $1.key }
        return GraphSnapshot(nodes: nodes, edges: edges, isTruncated: isTruncated)
    }

    // MARK: - 참조 매핑

    /// 일반 기록 참조를 그래프 노드 키로 매핑한다. `RecordReferenceKind`와
    /// `GraphNodeKind`는 memo/task/activity/reportVersion이 1:1이다.
    private static func nodeID(for reference: RecordReference) -> GraphNodeID {
        GraphNodeID(kind: nodeKind(for: reference.kind), id: reference.id)
    }

    private static func nodeKind(for kind: RecordReferenceKind) -> GraphNodeKind {
        switch kind {
        case .memo: return .memo
        case .task: return .task
        case .activity: return .activity
        case .reportVersion: return .reportVersion
        }
    }

    // MARK: - 그래프 유틸

    /// 무방향 인접 목록. 엣지 방향과 무관하게 양방향 이웃으로 본다.
    private static func adjacency(_ edges: [GraphEdge]) -> [GraphNodeID: Set<GraphNodeID>] {
        var result: [GraphNodeID: Set<GraphNodeID>] = [:]
        for edge in edges {
            result[edge.from, default: []].insert(edge.to)
            result[edge.to, default: []].insert(edge.from)
        }
        return result
    }

    /// 시작 노드에서의 BFS 거리(무방향). 시작 노드는 0.
    private static func bfsDistances(from start: GraphNodeID,
                                     adjacency: [GraphNodeID: Set<GraphNodeID>]) -> [GraphNodeID: Int] {
        var distances: [GraphNodeID: Int] = [start: 0]
        var queue: [GraphNodeID] = [start]
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            let next = distances[current]! + 1
            for neighbor in adjacency[current] ?? [] where distances[neighbor] == nil {
                distances[neighbor] = next
                queue.append(neighbor)
            }
        }
        return distances
    }

    /// 무방향 차수. 각 엣지의 양끝에 1씩 더한다.
    private static func degrees(edges: [GraphEdge]) -> [GraphNodeID: Int] {
        var result: [GraphNodeID: Int] = [:]
        for edge in edges {
            result[edge.from, default: 0] += 1
            result[edge.to, default: 0] += 1
        }
        return result
    }
}
