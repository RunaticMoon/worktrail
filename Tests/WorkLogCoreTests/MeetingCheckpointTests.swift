import XCTest
@testable import WorkLogCore

final class MeetingCheckpointTests: XCTestCase {
    private func fixture(stage: MeetingTranscriptStage = .live) throws -> (WorkRepository, MeetingAudioStore, Meeting, MeetingRecording, MeetingAudioTrack, MeetingTranscriptRun) {
        let repo = try WorkRepository.inMemory(clock: FixedClock(Date(timeIntervalSince1970: 1_792_972_800)), ids: SequentialIDGenerator(prefix: "checkpoint"))
        let meeting = try MeetingService(repo: repo).create(title: "체크포인트")
        let store = MeetingAudioStore(repo: repo), recording = try store.createRecording(meetingID: meeting.id)
        let track = try store.addTrack(recordingID: recording.id, kind: .microphone, relativePath: "audio/mic.caf", sampleRate: 48_000, channels: 1)
        let run = try store.createRun(meetingID: meeting.id, recordingID: recording.id, stage: stage, engine: "fixture", modelIdentifier: "small")
        return (repo, store, meeting, recording, track, run)
    }

    func testRollingCheckpointRemovesVanishedPartialButKeepsStableAndUserEditedSegments() throws {
        let (_, store, _, _, track, run) = try fixture()
        let initial: [MeetingSegmentInput] = [
            .init(trackID: track.id, sourceKey: "stable", start: 0, end: 1, text: "확정 내용"),
            .init(trackID: track.id, sourceKey: "vanished", start: 1, end: 2, text: "사라질 가설", isFinal: false),
            .init(trackID: track.id, sourceKey: "edited", start: 2, end: 3, text: "모델 가설", isFinal: false)
        ]
        try store.upsertSegments(runID: run.id, segments: initial)
        let edited = try XCTUnwrap(store.segments(runID: run.id).first { $0.sourceKey == "edited" })
        _ = try store.editSegment(id: edited.id, expectedRevision: edited.revision, text: "직접 수정한 가설")
        try store.checkpointLiveSegments(runID: run.id, trackID: track.id, segments: [
            .init(trackID: track.id, sourceKey: "stable", start: 0, end: 1, text: "늦은 덮어쓰기", isFinal: false),
            .init(trackID: track.id, sourceKey: "new", start: 3, end: 4, text: "현재 가설", isFinal: false)
        ], activePartialKeys: ["new", "stable"])
        let saved = try store.segments(runID: run.id)
        XCTAssertEqual(saved.map(\.sourceKey), ["stable", "edited", "new"])
        XCTAssertEqual(saved.first?.text, "확정 내용")
        XCTAssertEqual(saved.first?.isFinal, true)
        XCTAssertEqual(saved.first(where: { $0.sourceKey == "edited" })?.text, "직접 수정한 가설")
        XCTAssertEqual(try store.edits(runID: run.id).count, 1)
        // Empty recognizer output must still evict stale partials.
        try store.checkpointLiveSegments(runID: run.id, trackID: track.id, segments: [], activePartialKeys: [])
        XCTAssertEqual(try store.segments(runID: run.id).map(\.sourceKey), ["stable", "edited"])
    }

    func testCheckpointPromotesExistingPartialWithoutChangingIDAndLeavesOtherTrackAlone() throws {
        let (_, store, _, recording, track, run) = try fixture()
        let otherTrack = try store.addTrack(recordingID: recording.id, kind: .systemAudio, relativePath: "audio/system.caf", sampleRate: 48_000, channels: 2)
        try store.upsertSegments(runID: run.id, segments: [
            .init(trackID: track.id, sourceKey: "mic", start: 0, end: 1, text: "임시", isFinal: false),
            .init(trackID: otherTrack.id, sourceKey: "system", start: 0, end: 1, text: "다른 트랙 가설", isFinal: false)
        ])
        let original = try XCTUnwrap(store.segments(runID: run.id).first { $0.sourceKey == "mic" })
        try store.checkpointLiveSegments(runID: run.id, trackID: track.id,
            segments: [.init(trackID: track.id, sourceKey: "mic", start: 0, end: 1, text: "확정")], activePartialKeys: [])
        let saved = try store.segments(runID: run.id)
        XCTAssertEqual(saved.first(where: { $0.sourceKey == "mic" })?.id, original.id)
        XCTAssertEqual(saved.first(where: { $0.sourceKey == "mic" })?.isFinal, true)
        XCTAssertEqual(saved.first(where: { $0.sourceKey == "system" })?.text, "다른 트랙 가설")
    }

    func testRefinedRollingCheckpointAlsoRemovesStalePartialAndRejectsFinishedRun() throws {
        let (_, store, _, _, track, run) = try fixture(stage: .refined)
        try store.checkpointLiveSegments(runID: run.id, trackID: track.id,
            segments: [.init(trackID: track.id, sourceKey: "partial", start: 0, end: 1, text: "임시", isFinal: false)], activePartialKeys: ["partial"])
        try store.checkpointLiveSegments(runID: run.id, trackID: track.id, segments: [], activePartialKeys: [])
        XCTAssertTrue(try store.segments(runID: run.id).isEmpty)
        _ = try store.finishRun(id: run.id)
        XCTAssertThrowsError(try store.checkpointLiveSegments(runID: run.id, trackID: track.id, segments: [], activePartialKeys: []))
    }

    func testExplicitReviewMakesAmbiguousPartialPartOfActiveTranscriptAndSurvivesCheckpoint() throws {
        let (repo, store, meeting, _, track, run) = try fixture()
        try store.upsertSegments(runID: run.id, segments: [.init(trackID: track.id, sourceKey: "ambiguous", start: 0, end: 1, text: "확인이 필요한 해석", isFinal: false)])
        _ = try store.activateRun(meetingID: meeting.id, runID: run.id, expectedMeetingRevision: meeting.revision)
        let service = MeetingService(repo: repo)
        XCTAssertEqual(try service.meeting(id: meeting.id)?.transcript, "")
        let partial = try XCTUnwrap(store.segments(runID: run.id).first)
        _ = try store.editSegment(id: partial.id, expectedRevision: partial.revision, text: "사용자가 확인한 문장")
        XCTAssertEqual(try service.meeting(id: meeting.id)?.transcript, "사용자가 확인한 문장")
        try store.checkpointLiveSegments(runID: run.id, trackID: track.id, segments: [], activePartialKeys: [])
        XCTAssertEqual(try service.meeting(id: meeting.id)?.transcript, "사용자가 확인한 문장")
        XCTAssertEqual(try store.segments(runID: run.id).first?.originalText, "확인이 필요한 해석")
        XCTAssertEqual(try store.segments(runID: run.id).first?.isFinal, false)
    }

    func testFailedCheckpointRollsBackPartialDeletionTogetherWithInvalidInsert() throws {
        let (_, store, _, _, track, run) = try fixture()
        try store.upsertSegments(runID: run.id, segments: [.init(trackID: track.id, sourceKey: "old", start: 0, end: 1, text: "유지할 가설", isFinal: false)])
        let before = try store.segments(runID: run.id)
        XCTAssertThrowsError(try store.checkpointLiveSegments(runID: run.id, trackID: track.id,
            segments: [.init(trackID: track.id, sourceKey: "invalid", start: 3, end: 2, text: "유효하지 않은 시간")], activePartialKeys: []))
        XCTAssertEqual(try store.segments(runID: run.id), before)
    }

    func testPreviewGapsArePersistentIdempotentAndSeparateFromOriginalInterruptions() throws {
        let (repo, store, _, recording, track, run) = try fixture()
        let originalGaps = [MeetingTrackInterruption(start: 5, end: 6, reason: "device-change")]
        _ = try store.updateTrack(id: track.id, expectedRevision: track.revision, fileState: .available, interruptions: originalGaps)
        let gap = try store.recordPreviewGap(runID: run.id, trackID: track.id, start: 10, end: 20, reason: "superseded-preview")
        XCTAssertEqual(try store.recordPreviewGap(runID: run.id, trackID: track.id, start: 10, end: 20, reason: "superseded-preview"), gap)
        XCTAssertEqual(try store.previewGaps(runID: run.id), [gap])
        XCTAssertEqual(try store.previewGaps(recordingID: recording.id), [gap])
        XCTAssertEqual(try store.track(id: track.id)?.interruptions, originalGaps)
        let reopenedStore = MeetingAudioStore(repo: repo)
        XCTAssertEqual(try reopenedStore.previewGaps(runID: run.id), [gap])
        XCTAssertThrowsError(try store.recordPreviewGap(runID: run.id, trackID: track.id, start: 20, end: 10, reason: "bad"))
        let other = try store.createRecording(meetingID: recording.meetingID)
        let otherTrack = try store.addTrack(recordingID: other.id, kind: .microphone, relativePath: "other/mic.caf", sampleRate: 48_000, channels: 1)
        XCTAssertThrowsError(try store.recordPreviewGap(runID: run.id, trackID: otherTrack.id, start: 0, end: 1, reason: "wrong-recording"))
        XCTAssertEqual(try store.previewGaps(runID: run.id).count, 1)
    }
}
