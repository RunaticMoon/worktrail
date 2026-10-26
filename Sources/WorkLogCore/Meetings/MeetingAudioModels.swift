import Foundation

public enum MeetingRecordingState: String, Codable, Sendable, CaseIterable {
    case recording, paused, completed, interrupted, failed, discarded
}

public enum MeetingTrackKind: String, Codable, Sendable, CaseIterable {
    case microphone, systemAudio, mixed, imported
}

public enum MeetingTrackFileState: String, Codable, Sendable, CaseIterable {
    case pending, writing, available, needsRecovery, missing, deleted
}

public enum MeetingTranscriptStage: String, Codable, Sendable, CaseIterable {
    case live, refined, diarized, manual, imported
}

public enum MeetingTranscriptRunStatus: String, Codable, Sendable, CaseIterable {
    case running, completed, failed, cancelled, interrupted
}

public struct MeetingRecording: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var meetingID: String
    public var state: MeetingRecordingState
    public var revision: Int
    public var startedAt: Date
    public var endedAt: Date?
    public var updatedAt: Date
}

public struct MeetingTrackInterruption: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double?
    public var reason: String
    public init(start: Double, end: Double? = nil, reason: String) {
        self.start = start; self.end = end; self.reason = reason
    }
}

public struct MeetingAudioTrack: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var recordingID: String
    public var kind: MeetingTrackKind
    /// 앱이 소유한 녹음 루트 상대 경로. 외부 절대 경로나 ../ 경로는 저장하지 않는다.
    public var relativePath: String
    public var fileState: MeetingTrackFileState
    public var sampleRate: Double
    public var channels: Int
    public var startOffset: Double
    public var duration: Double?
    public var interruptions: [MeetingTrackInterruption]
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date
}

public struct MeetingTranscriptRun: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var meetingID: String
    public var recordingID: String?
    public var sourceRunID: String?
    public var stage: MeetingTranscriptStage
    public var engine: String
    public var modelIdentifier: String
    public var modelRevision: String?
    public var settingsJSON: String
    public var status: MeetingTranscriptRunStatus
    public var version: Int
    public var revision: Int
    /// 전체 전사문 직접 편집은 새 manual 버전으로 보존한다. 모델 원문은 이전 run에 남는다.
    public var manualText: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
}

public struct MeetingTranscriptSegment: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var runID: String
    public var trackID: String
    public var sourceKey: String
    public var start: Double
    public var end: Double
    public var originalText: String
    public var editedText: String?
    public var originalSpeakerID: String?
    public var editedSpeakerID: String?
    public var isSpeakerEdited: Bool
    public var isFinal: Bool
    public var revision: Int
    public var text: String { editedText ?? originalText }
    public var speakerID: String? { isSpeakerEdited ? editedSpeakerID : originalSpeakerID }
    public var isUserEdited: Bool { editedText != nil || isSpeakerEdited }
}

/// 모델 출력의 idempotent 저장 키. sourceKey는 동일 run 안에서 안정적으로 유지한다.
public struct MeetingSegmentInput: Codable, Hashable, Sendable {
    public var trackID: String
    public var sourceKey: String
    public var start: Double
    public var end: Double
    public var text: String
    public var speakerID: String?
    public var isFinal: Bool
    public init(trackID: String, sourceKey: String, start: Double, end: Double,
                text: String, speakerID: String? = nil, isFinal: Bool = true) {
        self.trackID = trackID; self.sourceKey = sourceKey; self.start = start; self.end = end
        self.text = text; self.speakerID = speakerID; self.isFinal = isFinal
    }
}

/// 식별자는 녹음에 소속되며 run별로 별도 생성한다. 이름이 같아도 같은 인물로 추정하지 않는다.
public struct MeetingSpeaker: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var recordingID: String
    public var runID: String
    public var sourceKey: String
    public var originalName: String
    public var displayName: String
    public var isUserEdited: Bool
    public var revision: Int
}

public struct MeetingTranscriptEdit: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var runID: String
    public var segmentID: String?
    public var speakerID: String?
    public var previousText: String
    public var replacementText: String
    public var createdAt: Date
}

/// 추론 대기·취소로 자막을 계산하지 못한 구간. 원본 녹음의 실제 누락과는 별개다.
public struct MeetingStoredPreviewGap: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var runID: String
    public var trackID: String
    public var start: Double
    public var end: Double
    public var reason: String
    public var createdAt: Date
}
