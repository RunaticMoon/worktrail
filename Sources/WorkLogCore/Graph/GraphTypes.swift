import Foundation

// MARK: - 일반 기록 참조

/// 수동 연결·그래프가 참조할 수 있는 일반 기록 종류.
///
/// Secret(Vault) 관련 종류는 의도적으로 존재하지 않는다. Secret 데이터는
/// work.sqlite·일반 검색·그래프·AI 입력에 절대 들어가지 않는다.
public enum RecordReferenceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case memo
    case task
    case activity
    case reportVersion = "report_version"
}

/// 일반 기록 하나를 가리키는 다형 참조.
public struct RecordReference: Hashable, Codable, Sendable {
    public let kind: RecordReferenceKind
    public let id: String

    public init(kind: RecordReferenceKind, id: String) {
        self.kind = kind
        self.id = id
    }

    /// 무방향 연결의 정규 순서쌍.
    ///
    /// `(kind.rawValue, id)`를 UTF-8 바이트 순으로 비교해 작은 쪽을 first로 둔다.
    /// SQL의 `VARCHAR BINARY` 순서(`from_kind < to_kind OR (from_kind = to_kind AND from_id < to_id)`)와
    /// 같은 결과가 되도록 Swift `String`의 스칼라 순서가 아니라 UTF-8 바이트 순서를 사용한다.
    /// 자기 연결(a == b)은 연결할 수 없으므로 nil을 반환한다.
    public static func canonicalPair(
        _ a: RecordReference,
        _ b: RecordReference
    ) -> (RecordReference, RecordReference)? {
        if a == b { return nil }
        return isOrderedBefore(a, b) ? (a, b) : (b, a)
    }

    /// (kind.rawValue, id)를 UTF-8 바이트 순으로 비교한다.
    private static func isOrderedBefore(_ a: RecordReference, _ b: RecordReference) -> Bool {
        let aKind = Array(a.kind.rawValue.utf8)
        let bKind = Array(b.kind.rawValue.utf8)
        if aKind != bKind {
            return aKind.lexicographicallyPrecedes(bKind)
        }
        return Array(a.id.utf8).lexicographicallyPrecedes(Array(b.id.utf8))
    }
}

/// 저장된 무방향 수동 관련 연결.
///
/// `first`/`second`는 항상 `RecordReference.canonicalPair`의 정규 순서다.
public struct RecordLink: Hashable, Codable, Sendable {
    public let id: String
    public let first: RecordReference
    public let second: RecordReference
    public let relationType: String
    public let createdAt: Date

    public init(
        id: String,
        first: RecordReference,
        second: RecordReference,
        relationType: String = "related",
        createdAt: Date
    ) {
        self.id = id
        self.first = first
        self.second = second
        self.relationType = relationType
        self.createdAt = createdAt
    }
}

/// 수동 연결 후보 검색 결과의 한 항목.
public struct RelatedRecordCandidate: Hashable, Codable, Sendable {
    public let reference: RecordReference
    public let title: String
    public let subtitle: String?

    public init(reference: RecordReference, title: String, subtitle: String? = nil) {
        self.reference = reference
        self.title = title
        self.subtitle = subtitle
    }
}

// MARK: - 그래프 노드

/// 그래프 노드의 종류.
///
/// `historicalSource`는 리포트 스냅샷 근거 등 읽기 전용 역사 노드를 나타내며
/// 수동 연결 대상으로 선택할 수 없다.
public enum GraphNodeKind: String, Codable, CaseIterable, Hashable, Sendable {
    case memo
    case task
    case activity
    case reportVersion = "report_version"
    case project
    case tag
    case supplement
    case historicalSource = "historical_source"
}

/// 그래프 노드를 안정적으로 식별하는 키.
public struct GraphNodeID: Hashable, Codable, Sendable {
    public let kind: GraphNodeKind
    public let id: String

    public init(kind: GraphNodeKind, id: String) {
        self.kind = kind
        self.id = id
    }

    /// 안정 정렬·딕셔너리 키로 쓰는 문자열. `"<kind>:<id>"`.
    public var key: String { "\(kind.rawValue):\(id)" }
}

/// 그래프의 한 노드.
public struct GraphNode: Hashable, Codable, Sendable {
    public let id: GraphNodeID
    public let title: String
    public let subtitle: String?
    /// 일반 기록 노드면 그 참조. 프로젝트·태그·성과 보충 등 보조 노드는 nil.
    public let record: RecordReference?
    /// 기록이 속한 대표 업무일.
    public let date: WorkDate?
    /// 리포트 버전 노드의 family 표시 문자열.
    public let reportFamily: String?
    /// 리포트 버전 노드의 버전 번호.
    public let reportVersionNumber: Int?

    public init(
        id: GraphNodeID,
        title: String,
        subtitle: String? = nil,
        record: RecordReference? = nil,
        date: WorkDate? = nil,
        reportFamily: String? = nil,
        reportVersionNumber: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.record = record
        self.date = date
        self.reportFamily = reportFamily
        self.reportVersionNumber = reportVersionNumber
    }
}

// MARK: - 그래프 엣지

/// 그래프 엣지의 의미. 기존 관계를 그대로 보존한다.
public enum GraphEdgeKind: String, Codable, CaseIterable, Hashable, Sendable {
    /// activity → task 직접 관계.
    case activityTask
    /// memo → task 승인 연결(`accepted`만).
    case acceptedMemoTask
    /// task → task `related`.
    case taskRelated
    /// task → task `followUp`.
    case taskFollowUp
    /// 기록 → project 소속.
    case projectMembership
    /// 기록 → tag 소속.
    case tagMembership
    /// report version → 근거 원문.
    case reportEvidence
    /// supplement → task.
    case supplementTask
    /// 수동 관련 연결. 보고서 근거 승인과 다른 의미.
    case manualRelated
}

/// 리포트 근거 엣지가 참조하는 스냅샷·원문 정보.
public struct GraphEvidenceRef: Hashable, Codable, Sendable {
    public let reportVersionId: String
    public let sourceSnapshotId: String?
    public let sourceId: String
    public let sourceRevision: Int?

    public init(
        reportVersionId: String,
        sourceSnapshotId: String? = nil,
        sourceId: String,
        sourceRevision: Int? = nil
    ) {
        self.reportVersionId = reportVersionId
        self.sourceSnapshotId = sourceSnapshotId
        self.sourceId = sourceId
        self.sourceRevision = sourceRevision
    }
}

/// 그래프의 한 엣지.
public struct GraphEdge: Hashable, Codable, Sendable {
    public let from: GraphNodeID
    public let to: GraphNodeID
    public let kind: GraphEdgeKind
    /// 이 엣지의 출처 식별자. 같은 두 노드를 잇는 여러 관계를 구분·보존한다.
    public let sourceKey: String
    public let isDirected: Bool
    public let evidence: GraphEvidenceRef?

    public init(
        from: GraphNodeID,
        to: GraphNodeID,
        kind: GraphEdgeKind,
        sourceKey: String,
        isDirected: Bool,
        evidence: GraphEvidenceRef? = nil
    ) {
        self.from = from
        self.to = to
        self.kind = kind
        self.sourceKey = sourceKey
        self.isDirected = isDirected
        self.evidence = evidence
    }

    /// 안정 정렬·중복 제거용 키. `"<from.key>|<to.key>|<kind.rawValue>|<sourceKey>"`.
    public var key: String {
        "\(from.key)|\(to.key)|\(kind.rawValue)|\(sourceKey)"
    }
}

// MARK: - 조회·스냅샷

/// 그래프 조회 조건.
public struct GraphQuery: Hashable, Codable, Sendable {
    public let range: DateRange?
    public let kinds: Set<GraphNodeKind>
    public let projectIds: Set<String>
    public let tagIds: Set<String>
    public let focus: GraphNodeID?
    public let nodeLimit: Int

    public init(
        range: DateRange? = nil,
        kinds: Set<GraphNodeKind> = [],
        projectIds: Set<String> = [],
        tagIds: Set<String> = [],
        focus: GraphNodeID? = nil,
        nodeLimit: Int = 250
    ) {
        self.range = range
        self.kinds = kinds
        self.projectIds = projectIds
        self.tagIds = tagIds
        self.focus = focus
        self.nodeLimit = nodeLimit
    }
}

/// 그래프 조회 결과.
public struct GraphSnapshot: Hashable, Codable, Sendable {
    public let nodes: [GraphNode]
    public let edges: [GraphEdge]
    public let isTruncated: Bool

    public init(nodes: [GraphNode], edges: [GraphEdge], isTruncated: Bool) {
        self.nodes = nodes
        self.edges = edges
        self.isTruncated = isTruncated
    }

    public static let empty = GraphSnapshot(nodes: [], edges: [], isTruncated: false)
}

// MARK: - 레이아웃

/// 평면 좌표.
public struct GraphPoint: Hashable, Codable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// 결정적 레이아웃 계산 설정. 난수·현재 시각을 사용하지 않는다.
public struct GraphLayoutConfiguration: Hashable, Codable, Sendable {
    public let iterations: Int
    public let width: Double
    public let height: Double

    public init(iterations: Int = 300, width: Double = 1000, height: Double = 800) {
        self.iterations = iterations
        self.width = width
        self.height = height
    }
}
