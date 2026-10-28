import XCTest
@testable import WorkLogCore

final class MeetingArchiveTests: XCTestCase {
    private func fixture() throws -> (URL, WorkRepository, Meeting, MeetingArchiveService) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repo = try WorkRepository.inMemory(clock: FixedClock(Date(timeIntervalSince1970: 1_792_972_800)), ids: SequentialIDGenerator(prefix: "archive"))
        let meeting = try MeetingService(repo: repo).create(title: "가짜 회의", transcript: "이전 전사", notes: "가짜 메모")
        let store = MeetingAudioStore(repo: repo)
        let recording = try store.createRecording(meetingID: meeting.id)
        let track = try store.addTrack(recordingID: recording.id, kind: .imported, relativePath: "original.wav",
            sampleRate: 16_000, channels: 1, fileState: .available)
        try Data("fake local audio bytes".utf8).write(to: root.appendingPathComponent("original.wav"))
        let run = try store.createRun(meetingID: meeting.id, recordingID: recording.id, stage: .refined,
            engine: "fixture", modelIdentifier: "fake")
        let speaker = try store.upsertSpeaker(runID: run.id, sourceKey: "S1", displayName: "화자 1")
        _ = try store.upsertSegments(runID: run.id, segments: [.init(trackID: track.id, sourceKey: "one", start: 1, end: 3, text: "원문", speakerID: speaker.id)])
        _ = try store.finishRun(id: run.id)
        let segment = try XCTUnwrap(store.segments(runID: run.id).first)
        _ = try store.editSegment(id: segment.id, expectedRevision: segment.revision, text: "수정한 원문")
        _ = try store.updateRecordingState(id: recording.id, expectedRevision: recording.revision, state: .completed)
        _ = try store.activateRun(meetingID: meeting.id, runID: run.id, expectedMeetingRevision: meeting.revision, allowReplacingUserEdits: true)
        return (root, repo, try XCTUnwrap(MeetingService(repo: repo).meeting(id: meeting.id)), MeetingArchiveService(repo: repo, audioRoot: root))
    }

    func testRoundTripPreservesVersionsEditsSpeakersOffsetsAndProtection() throws {
        let (root, source, meeting, service) = try fixture()
        let archive = root.appendingPathComponent("roundtrip.worklogmeeting")
        try service.export(meetingID: meeting.id, includeAudio: true, to: archive)
        let preview = try service.inspect(archive)
        XCTAssertEqual(preview.audioFileCount, 1)
        XCTAssertEqual(preview.missingTrackCount, 0)
        let destination = try WorkRepository.inMemory(ids: SequentialIDGenerator(prefix: "restore"))
        let audioRoot = root.appendingPathComponent("destination")
        let restoredID = try MeetingArchiveService(repo: destination, audioRoot: audioRoot).restore(archive, duplicatePolicy: .reject)
        let restored = try XCTUnwrap(MeetingService(repo: destination).meeting(id: restoredID))
        XCTAssertTrue(restored.localOnly)
        XCTAssertEqual(restored.transcript, meeting.transcript)
        XCTAssertEqual(restored.notes, meeting.notes)
        XCTAssertEqual(restored.activeTranscriptRunID, meeting.activeTranscriptRunID)
        let store = MeetingAudioStore(repo: destination)
        XCTAssertEqual(try store.edits(runID: restored.activeTranscriptRunID!).count, 1)
        XCTAssertEqual(try store.speakers(runID: restored.activeTranscriptRunID!).first?.displayName, "화자 1")
        let segment = try XCTUnwrap(store.segments(runID: restored.activeTranscriptRunID!).first)
        XCTAssertEqual(segment.start, 1)
        XCTAssertEqual(segment.text, "수정한 원문")
        let track = try XCTUnwrap(store.track(id: segment.trackID))
        XCTAssertEqual(try Data(contentsOf: audioRoot.appendingPathComponent(track.relativePath)), Data("fake local audio bytes".utf8))
        XCTAssertEqual(try source.db.scalarInt("SELECT COUNT(*) FROM meeting"), 1)
    }

    func testTextOnlyMissingAudioAndExplicitDuplicateCopy() throws {
        let (root, repo, meeting, service) = try fixture()
        let archive = root.appendingPathComponent("text.worklogmeeting")
        try service.export(meetingID: meeting.id, includeAudio: false, to: archive)
        XCTAssertFalse(try service.inspect(archive).includesAudio)
        XCTAssertEqual(try service.inspect(archive).missingTrackCount, 1)
        XCTAssertThrowsError(try service.restore(archive, duplicatePolicy: .reject))
        let newID = try service.restore(archive, duplicatePolicy: .newCopy)
        XCTAssertNotEqual(newID, meeting.id)
        let copy = try XCTUnwrap(MeetingService(repo: repo).meeting(id: newID))
        XCTAssertNotEqual(copy.activeTranscriptRunID, meeting.activeTranscriptRunID)
        let store = MeetingAudioStore(repo: repo)
        let recording = try XCTUnwrap(store.recordings(meetingID: newID).first)
        XCTAssertEqual(try store.tracks(recordingID: recording.id).first?.fileState, .missing)
        XCTAssertEqual(try store.edits(runID: copy.activeTranscriptRunID!).count, 1)
    }

    func testCorruptionAndPathEscapeFailWithoutChangingData() throws {
        let (root, repo, meeting, service) = try fixture()
        let archive = root.appendingPathComponent("corrupt.worklogmeeting")
        try service.export(meetingID: meeting.id, includeAudio: true, to: archive)
        try Data("tampered".utf8).write(to: archive.appendingPathComponent("audio/track-0.wav"))
        XCTAssertThrowsError(try service.restore(archive, duplicatePolicy: .newCopy))
        XCTAssertEqual(try repo.db.scalarInt("SELECT COUNT(*) FROM meeting"), 1)
        let manifestURL = archive.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        entries[0]["path"] = "../original.wav"; manifest["entries"] = entries
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        XCTAssertThrowsError(try service.restore(archive, duplicatePolicy: .newCopy))
        XCTAssertEqual(try repo.db.scalarInt("SELECT COUNT(*) FROM meeting"), 1)
    }

    func testDiskFullCancellationAndSymlinkLeaveExistingDataIntact() throws {
        let (root, repo, meeting, service) = try fixture()
        let archive = root.appendingPathComponent("full.worklogmeeting")
        let full = MeetingArchiveService(repo: repo, audioRoot: root, availableBytes: { _ in 0 })
        XCTAssertThrowsError(try full.export(meetingID: meeting.id, includeAudio: true, to: archive))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertThrowsError(try service.export(meetingID: meeting.id, includeAudio: true, to: archive, checkCancellation: { throw CancellationError() }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        try service.export(meetingID: meeting.id, includeAudio: true, to: archive)
        XCTAssertThrowsError(try full.restore(archive, duplicatePolicy: .newCopy))
        XCTAssertThrowsError(try service.restore(archive, duplicatePolicy: .newCopy, checkCancellation: { throw CancellationError() }))
        let audio = archive.appendingPathComponent("audio/track-0.wav")
        try FileManager.default.removeItem(at: audio)
        try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: root.appendingPathComponent("original.wav"))
        XCTAssertThrowsError(try service.inspect(archive))
        XCTAssertEqual(try repo.db.scalarInt("SELECT COUNT(*) FROM meeting"), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("original.wav").path))
    }
}
