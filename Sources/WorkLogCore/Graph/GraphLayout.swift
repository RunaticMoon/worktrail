import Foundation

/// 결정적 force-directed 그래프 레이아웃.
///
/// - 입력 배열 순서와 무관하게 `GraphNodeID.key`로 정렬한 순서를 기준으로 한다.
/// - 난수·`Hasher`·현재 시각·딕셔너리 순회 순서에 의존하지 않는다.
/// - 결과 좌표는 항상 유한하며 `[0, width] × [0, height]`로 클램프된다.
public enum GraphLayout {

    /// 그래프의 모든 노드 좌표를 계산한다.
    ///
    /// 노드가 없으면 빈 딕셔너리를 반환한다. 같은 입력에는 항상 정확히 같은
    /// 좌표를 돌려주는 순수 함수다.
    ///
    /// 알고리즘은 Fruchterman–Reingold를 고정 반복·선형 냉각으로 수행한다.
    /// 초기 배치는 정렬 순서대로 중심 기준 원형이며, 노드가 하나뿐이면 중심이다.
    public static func positions(
        for graph: GraphSnapshot,
        configuration: GraphLayoutConfiguration
    ) -> [GraphNodeID: GraphPoint] {
        let width = configuration.width
        let height = configuration.height

        // 1. 노드를 key로 안정 정렬하고 key→인덱스를 만든다.
        //    key가 같은 중복 노드는 첫 항목만 사용한다.
        let orderedNodes = graph.nodes.sorted { $0.id.key < $1.id.key }
        var indexByKey: [String: Int] = [:]
        var ids: [GraphNodeID] = []
        ids.reserveCapacity(orderedNodes.count)
        for node in orderedNodes where indexByKey[node.id.key] == nil {
            indexByKey[node.id.key] = ids.count
            ids.append(node.id)
        }
        let count = ids.count
        guard count > 0 else { return [:] }

        // 2. 초기 배치: 정렬 순서대로 중심 기준 원형. 노드 1개면 중심.
        let centerX = width / 2
        let centerY = height / 2
        var positionX = [Double](repeating: centerX, count: count)
        var positionY = [Double](repeating: centerY, count: count)
        if count > 1 {
            let radius = min(width, height) * 0.4
            let step = 2 * Double.pi / Double(count)
            for i in 0..<count {
                let angle = step * Double(i)
                positionX[i] = centerX + radius * cos(angle)
                positionY[i] = centerY + radius * sin(angle)
            }
        }

        // 3. 엣지를 key로 정렬해 인덱스 쌍으로 만든다.
        //    양끝 노드가 없는 엣지·자기 연결은 무시하고, 같은 노드 쌍을 잇는
        //    중복 엣지(병렬 관계 포함)는 한 번만 센다.
        var edgePairs: [(Int, Int)] = []
        var seenEdgePairs = Set<String>()
        let sortedEdges = graph.edges.sorted { $0.key < $1.key }
        for edge in sortedEdges {
            guard let a = indexByKey[edge.from.key],
                  let b = indexByKey[edge.to.key],
                  a != b else { continue }
            let low = min(a, b)
            let high = max(a, b)
            if seenEdgePairs.insert("\(low)|\(high)").inserted {
                edgePairs.append((low, high))
            }
        }

        // 4. Fruchterman–Reingold 반복.
        let area = max(width, 0) * max(height, 0)
        let k = (area / Double(count)).squareRoot()
        let iterations = max(configuration.iterations, 0)
        if k > 0, iterations > 0 {
            let initialTemperature = min(width, height) / 10
            var displacementX = [Double](repeating: 0, count: count)
            var displacementY = [Double](repeating: 0, count: count)

            for iteration in 0..<iterations {
                for i in 0..<count {
                    displacementX[i] = 0
                    displacementY[i] = 0
                }

                // 반발: k²/d
                if count > 1 {
                    for i in 0..<count {
                        let xi = positionX[i]
                        let yi = positionY[i]
                        for j in (i + 1)..<count {
                            var dx = xi - positionX[j]
                            var dy = yi - positionY[j]
                            var distance = (dx * dx + dy * dy).squareRoot()
                            if distance < overlapEpsilon {
                                let offset = overlapOffset(i, j)
                                dx = offset.dx
                                dy = offset.dy
                                distance = (dx * dx + dy * dy).squareRoot()
                            }
                            let force = k * k / distance
                            let ux = dx / distance
                            let uy = dy / distance
                            displacementX[i] += ux * force
                            displacementY[i] += uy * force
                            displacementX[j] -= ux * force
                            displacementY[j] -= uy * force
                        }
                    }
                }

                // 인력: d²/k
                for (a, b) in edgePairs {
                    var dx = positionX[a] - positionX[b]
                    var dy = positionY[a] - positionY[b]
                    var distance = (dx * dx + dy * dy).squareRoot()
                    if distance < overlapEpsilon {
                        let offset = overlapOffset(a, b)
                        dx = offset.dx
                        dy = offset.dy
                        distance = (dx * dx + dy * dy).squareRoot()
                    }
                    let force = distance * distance / k
                    let ux = dx / distance
                    let uy = dy / distance
                    displacementX[a] -= ux * force
                    displacementY[a] -= uy * force
                    displacementX[b] += ux * force
                    displacementY[b] += uy * force
                }

                // 선형 냉각.
                let temperature = initialTemperature * (1 - Double(iteration) / Double(iterations))
                for i in 0..<count {
                    let magnitude = (displacementX[i] * displacementX[i]
                                     + displacementY[i] * displacementY[i]).squareRoot()
                    if magnitude > 0 {
                        let limited = min(magnitude, temperature)
                        positionX[i] += displacementX[i] / magnitude * limited
                        positionY[i] += displacementY[i] / magnitude * limited
                    }
                    positionX[i] = clamp(positionX[i], lower: 0, upper: width)
                    positionY[i] = clamp(positionY[i], lower: 0, upper: height)
                }
            }
        }

        var result: [GraphNodeID: GraphPoint] = [:]
        result.reserveCapacity(count)
        for i in 0..<count {
            result[ids[i]] = GraphPoint(
                x: clamp(positionX[i], lower: 0, upper: width),
                y: clamp(positionY[i], lower: 0, upper: height)
            )
        }
        return result
    }

    /// 두 노드가 같은 위치에 겹쳤을 때 쓰는 인덱스 기반 결정적 미소 오프셋.
    private static let overlapEpsilon = 1e-9

    private static func overlapOffset(_ i: Int, _ j: Int) -> (dx: Double, dy: Double) {
        let scale = 1e-3
        return (dx: scale * (Double(i) + 1), dy: scale * (Double(j) + 1))
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        if value.isNaN { return lower }
        return min(max(value, lower), upper)
    }
}
