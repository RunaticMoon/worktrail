import Foundation

/// 일반 회의 기록. Secret 자료는 이 모델이나 연결 메모 선택에 포함하지 않는다.
public struct Meeting: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var workDate: WorkDate
    public var transcript: String
    public var notes: String
    public var memoSnapshots: [MeetingMemoSnapshot]
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var summary: MeetingSummary?
    /// 모든 신규·이전 회의의 기본값. true이면 네트워크 AI 입력으로 사용할 수 없다.
    public var localOnly: Bool = true
    public var activeTranscriptRunID: String? = nil
    public var metadata: MeetingMetadata? = nil

    public var isSummaryStale: Bool { summary.map { $0.sourceRevision != revision } ?? false }
}

/// 선택 당시의 일반 메모 원문. 원본 메모 변경·삭제로 회의 근거가 조용히 달라지지 않는다.
public struct MeetingMemoSnapshot: Codable, Hashable, Sendable, Identifiable {
    public var memoID: String
    public var revision: Int
    public var body: String
    public var workDate: WorkDate
    public var capturedAt: Date
    public var id: String { memoID }
}

/// AI가 만든 요약은 언제나 검토·편집 가능한 초안이다. 원문과 별도 테이블에 저장한다.
public struct MeetingSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var meetingID: String
    public var version: Int
    public var revision: Int
    public var sourceRevision: Int
    public var content: String
    public var structuredOutput: MeetingSummaryOutput
    public var sources: [MeetingSummarySource]
    public var isUserEdited: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var origin: String? = nil
    public var isManual: Bool { origin == "manual" }
}

public enum MeetingSourceKind: String, Codable, Hashable, Sendable {
    case transcript
    case meetingNotes
    case linkedMemo

    public var label: String {
        switch self {
        case .transcript: return "전사"
        case .meetingNotes: return "회의 메모"
        case .linkedMemo: return "연결 메모"
        }
    }
}

public struct MeetingSummarySource: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: MeetingSourceKind
    public var text: String
    public var sourceRevision: Int
}

public struct MeetingCitation: Codable, Hashable, Sendable {
    public var sourceID: String
    /// 해당 원문의 정확한 부분 문자열. 공백·구두점도 원문 그대로 보존한다.
    public var quote: String
    public init(sourceID: String, quote: String) { self.sourceID = sourceID; self.quote = quote }
}

public struct MeetingSummaryItem: Codable, Hashable, Sendable {
    public var text: String
    public var citations: [MeetingCitation]
    public init(text: String, citations: [MeetingCitation]) { self.text = text; self.citations = citations }
}

/// 모든 서술은 실제 입력 근거를 가져야 한다. 없는 결정·담당자·기한은 생성하지 않는다.
public struct MeetingSummaryOutput: Codable, Hashable, Sendable {
    public var summary: [MeetingSummaryItem]
    public var decisions: [MeetingSummaryItem]
    public var actionItems: [MeetingSummaryItem]
    public var openQuestions: [MeetingSummaryItem]

    public init(summary: [MeetingSummaryItem], decisions: [MeetingSummaryItem] = [],
                actionItems: [MeetingSummaryItem] = [], openQuestions: [MeetingSummaryItem] = []) {
        self.summary = summary; self.decisions = decisions
        self.actionItems = actionItems; self.openQuestions = openQuestions
    }
}

public enum MeetingLimits {
    public static let titleBytes = 1_000
    public static let transcriptBytes = 2_000_000
    public static let notesBytes = 256_000
    public static let linkedMemoCount = 30
    public static let linkedMemoBytes = 256_000
    public static let summaryInputBytes = 240_000
    public static let summaryOutputBytes = 64_000
}

/// Optional metadata is independent of the work date and recording timestamps.
public struct MeetingMetadata: Codable, Hashable, Sendable {
    public var projectIDs: [String] = []
    public var tagIDs: [String] = []
    public var participants: [String] = []
    public var agenda: String = ""
    public var occurredAt: Date? = nil
    public init(projectIDs: [String] = [], tagIDs: [String] = [], participants: [String] = [], agenda: String = "", occurredAt: Date? = nil) {
        self.projectIDs = projectIDs; self.tagIDs = tagIDs; self.participants = participants
        self.agenda = agenda; self.occurredAt = occurredAt
    }
}
