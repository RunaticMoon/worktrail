import Foundation
import Observation

/// 그래프 화면용 Presentation 모델.
///
/// - `GraphService`로 조회한 순수 DTO(`GraphSnapshot`)만 받아 `GraphLayout`에 좌표를 맡긴다.
/// - 실제 그래프 조회·병합·필터는 `GraphService`, 좌표 계산은 `GraphLayout`이 담당한다.
///   이 모델은 화면 상태(로딩·빈·오류·필터·선택·잘림)와 사용자 상호작용만 관리한다.
/// - Secret(Vault)에는 접근하지 않는다. `AppEnvironment`의 일반 저장소만 쓴다.
/// - 레이아웃은 250노드 수준에서 동기로 계산해도 충분하다. 다만 오래된 결과를 버릴 수
///   있도록 `generation` 카운터를 두어, 나중에 계산을 비동기로 옮겨도 안전하게 한다.
@Observable @MainActor public final class GraphModel {

    /// 화면 로딩 상태.
    public enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case empty
        case failed(String)
    }

    /// 조회 기간 프리셋. 오늘 업무일을 기준으로 최근 며칠을 볼지 정한다.
    public enum RangePreset: String, CaseIterable, Sendable {
        case week
        case month
        case quarter
        case all

        /// 접근성·필터 UI에 쓰는 한국어 표시 문자열.
        public var label: String {
            switch self {
            case .week: return "최근 7일"
            case .month: return "최근 30일"
            case .quarter: return "최근 90일"
            case .all: return "전체"
            }
        }
    }

    // MARK: - 상태

    public private(set) var phase: Phase = .idle
    public private(set) var snapshot: GraphSnapshot = .empty
    public private(set) var positions: [GraphNodeID: GraphPoint] = [:]

    /// 변경 시 뷰가 `reload()`를 호출해야 한다(자동 호출 아님).
    public var rangePreset: RangePreset = .month

    /// 표시할 노드 종류. 기본은 일반 기록과 그 소속 노드다.
    public var visibleKinds: Set<GraphNodeKind> = GraphModel.defaultVisibleKinds

    /// 노드 제목 필터(접근성 목록 전용). 그래프 스냅샷 자체는 바꾸지 않는다.
    public var searchText: String = ""

    public private(set) var selectedNodeID: GraphNodeID?

    /// 주변 보기(2-hop) 중심 노드. 설정 후 `reload()`가 필요하다.
    public var focus: GraphNodeID?

    public var layoutConfiguration = GraphLayoutConfiguration()

    /// 그래프 화면 기본 표시 종류. 성과 보충·역사 노드는 기본에서 뺀다.
    public static let defaultVisibleKinds: Set<GraphNodeKind> = [
        .memo, .task, .activity, .reportVersion, .project, .tag,
    ]

    /// 한 번에 표시하는 노드 상한.
    public static let nodeLimit = 250

    @ObservationIgnored private var environment: AppEnvironment?
    @ObservationIgnored private var service: GraphService?
    /// `reload()`마다 증가한다. 느린(미래의 비동기) 계산 결과를 버리기 위한 카운터.
    @ObservationIgnored private var generation = 0

    public init(environment: AppEnvironment) {
        self.environment = environment
        self.service = GraphService(repo: environment.repo)
    }

    // MARK: - 조회

    /// 현재 조건으로 스냅샷과 좌표를 다시 계산한다.
    ///
    /// 실패하면 원문 오류를 노출하지 않고 고정된 한국어 문구만 남긴다.
    public func reload() {
        guard let environment, let service else { return }
        generation &+= 1
        let current = generation
        phase = .loading
        do {
            let today = environment.calendar.workDate(of: environment.options.clock.now())
            let query = GraphQuery(
                range: Self.range(for: rangePreset, calendar: environment.calendar, today: today),
                kinds: visibleKinds,
                focus: focus,
                nodeLimit: Self.nodeLimit
            )
            let newSnapshot = try service.snapshot(query: query)
            // 동기 호출이라 항상 최신이지만, 비동기 전환 시 오래된 결과를 버리는 계약을 지킨다.
            guard current == generation else { return }
            apply(newSnapshot)
        } catch {
            guard current == generation else { return }
            phase = .failed("그래프를 불러오지 못했습니다.")
        }
    }

    private func apply(_ newSnapshot: GraphSnapshot) {
        snapshot = newSnapshot
        positions = GraphLayout.positions(for: newSnapshot, configuration: layoutConfiguration)
        // 새 스냅샷에 없는 선택은 지운다.
        if let selected = selectedNodeID,
           !newSnapshot.nodes.contains(where: { $0.id == selected }) {
            selectedNodeID = nil
        }
        phase = newSnapshot.nodes.isEmpty ? .empty : .loaded
    }

    // MARK: - 선택·주변 보기

    public func select(_ id: GraphNodeID?) {
        selectedNodeID = id
    }

    /// 현재 선택을 중심으로 2-hop 주변 보기를 켠다.
    public func focusOnSelection() {
        focus = selectedNodeID
        reload()
    }

    /// 주변 보기를 끄고 전체 범위로 돌아간다.
    public func clearFocus() {
        focus = nil
        reload()
    }

    public var selectedNode: GraphNode? {
        guard let selectedNodeID else { return nil }
        return snapshot.nodes.first { $0.id == selectedNodeID }
    }

    /// inspector용: 해당 노드에 닿는 엣지와 반대편 노드. 엣지 `key` 오름차순.
    public func neighbors(of id: GraphNodeID) -> [(edge: GraphEdge, node: GraphNode)] {
        let nodeByID = Dictionary(
            snapshot.nodes.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result: [(edge: GraphEdge, node: GraphNode)] = []
        for edge in snapshot.edges {
            if edge.from == id, let node = nodeByID[edge.to] {
                result.append((edge, node))
            } else if edge.to == id, let node = nodeByID[edge.from] {
                result.append((edge, node))
            }
        }
        return result.sorted { $0.edge.key < $1.edge.key }
    }

    // MARK: - 접근성 목록

    /// 접근성을 위한 노드 목록. `searchText`로 제목을 거르고 kind→title 순으로 정렬한다.
    public var listedNodes: [GraphNode] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = snapshot.nodes.filter { node in
            guard !query.isEmpty else { return true }
            return node.title.localizedCaseInsensitiveContains(query)
        }
        return filtered.sorted { lhs, rhs in
            let lr = Self.sortRank(lhs.id.kind)
            let rr = Self.sortRank(rhs.id.kind)
            if lr != rr { return lr < rr }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.id.id < rhs.id.id
        }
    }

    public var isTruncated: Bool { snapshot.isTruncated }

    /// 앱 종료·백업 복원 시 DB를 붙잡지 않도록 참조를 놓는다. 이후 `reload()`는 무해하다.
    public func detach() {
        environment = nil
        service = nil
    }

    // MARK: - 기간 계산

    /// 프리셋별 조회 기간. `all`은 nil(전체).
    ///
    /// 오늘을 포함해 week=7일, month=30일, quarter=90일이다. 예: week는
    /// `[today-6, today+1)`이며 `contains(today)`가 참이다.
    public static func range(
        for preset: RangePreset,
        calendar: WorkCalendar,
        today: WorkDate
    ) -> DateRange? {
        switch preset {
        case .all:
            return nil
        case .week:
            return DateRange(start: calendar.adding(days: -6, to: today),
                             endExclusive: calendar.adding(days: 1, to: today))
        case .month:
            return DateRange(start: calendar.adding(days: -29, to: today),
                             endExclusive: calendar.adding(days: 1, to: today))
        case .quarter:
            return DateRange(start: calendar.adding(days: -89, to: today),
                             endExclusive: calendar.adding(days: 1, to: today))
        }
    }

    // MARK: - 라벨·심볼 헬퍼

    /// 엣지 종류의 한국어 라벨.
    public static func label(for kind: GraphEdgeKind) -> String {
        switch kind {
        case .activityTask: return "진행기록"
        case .acceptedMemoTask: return "승인된 메모 연결"
        case .manualRelated: return "직접 연결"
        case .reportEvidence: return "리포트 근거"
        case .projectMembership: return "프로젝트"
        case .tagMembership: return "태그"
        case .taskRelated: return "관련 업무"
        case .taskFollowUp: return "후속 업무"
        case .supplementTask: return "성과 보충"
        }
    }

    /// 노드 종류의 한국어 라벨.
    public static func nodeLabel(for kind: GraphNodeKind) -> String {
        switch kind {
        case .memo: return "메모"
        case .task: return "업무"
        case .activity: return "진행기록"
        case .reportVersion: return "리포트"
        case .project: return "프로젝트"
        case .tag: return "태그"
        case .supplement: return "성과 보충"
        case .historicalSource: return "과거 근거"
        }
    }

    /// 노드 종류의 SF Symbol 이름.
    public static func symbol(for kind: GraphNodeKind) -> String {
        switch kind {
        case .memo: return "note.text"
        case .task: return "checklist"
        case .activity: return "clock.arrow.circlepath"
        case .reportVersion: return "doc.text"
        case .project: return "folder"
        case .tag: return "number"
        case .supplement: return "star"
        case .historicalSource: return "clock.badge.questionmark"
        }
    }

    // MARK: - 정렬 순위

    /// 목록 정렬용 kind 순위. 선언 순서(memo→task→activity→reportVersion→project→tag→
    /// supplement→historicalSource)를 쓴다.
    private static let kindOrder: [GraphNodeKind: Int] = {
        var order: [GraphNodeKind: Int] = [:]
        for (index, kind) in GraphNodeKind.allCases.enumerated() { order[kind] = index }
        return order
    }()

    private static func sortRank(_ kind: GraphNodeKind) -> Int {
        kindOrder[kind] ?? Int.max
    }
}
