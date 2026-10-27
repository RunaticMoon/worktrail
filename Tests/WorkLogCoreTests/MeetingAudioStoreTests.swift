import XCTest
@testable import WorkLogCore

final class MeetingAudioStoreTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_792_972_800)

    private func fixture() throws -> (WorkRepository, MeetingService, MeetingAudioStore, Meeting, MeetingRecording, MeetingAudioTrack) {
        let repo = try WorkRepository.inMemory(clock: FixedClock(instant), ids: SequentialIDGenerator(prefix: "audio"))
        let service = MeetingService(repo: repo), store = MeetingAudioStore(repo: repo)
        let meeting = try service.create(title: "로컬 회의")
        let recording = try store.createRecording(meetingID: meeting.id)
        let track = try store.addTrack(recordingID: recording.id, kind: .microphone,
            relativePath: "recordings/\(recording.id)/mic.caf", sampleRate: 48_000, channels: 1, fileState: .writing)
        return (repo, service, store, meeting, recording, track)
    }

    private func liveRun(_ store: MeetingAudioStore, _ meeting: Meeting, _ recording: MeetingRecording) throws -> MeetingTranscriptRun {
        try store.createRun(meetingID: meeting.id, recordingID: recording.id, stage: .live,
            engine: "whisperkit", modelIdentifier: "small", modelRevision: "fixture-v1", settingsJSON: #"{"language":"ko"}"#)
    }

    func testV5MigrationPreservesLegacyTextAndDefaultsEveryMeetingToLocalOnly() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try Migrator.migrate(db, migrations: WorkSchema.migrations.filter { $0.version <= 5 })
        try db.runV("""
            INSERT INTO meeting(id,title,work_date,transcript,notes,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?)
            """, "old", "기존 회의", "2026-10-26", "보존할 전사", "보존할 메모", instant, instant)
        let repo = try WorkRepository(db: db, clock: FixedClock(instant), ids: SequentialIDGenerator())
        let service = MeetingService(repo: repo)
        let old = try XCTUnwrap(service.meeting(id: "old"))
        XCTAssertTrue(old.localOnly)
        XCTAssertNil(old.activeTranscriptRunID)
        XCTAssertEqual(old.transcript, "보존할 전사")
        XCTAssertEqual(old.notes, "보존할 메모")
        XCTAssertTrue(try service.create(title: "새 회의").localOnly)
        XCTAssertEqual(db.userVersion, WorkSchema.migrations.map(\.version).max())
        try Migrator.migrate(db, migrations: WorkSchema.migrations)
        XCTAssertEqual(try service.meetings().count, 2)
        XCTAssertTrue(try db.integrityCheck())
    }

    func testRecoveryRecordingIDIsIdempotentAndCannotMoveBetweenMeetings() throws {
        let (_, service, store, meeting, _, _) = try fixture()
        let started = instant.addingTimeInterval(-60)
        let recovered = try store.createRecording(meetingID: meeting.id, id: "manifest-recording", startedAt: started)
        XCTAssertEqual(recovered.id, "manifest-recording")
        XCTAssertEqual(recovered.startedAt, started)
        XCTAssertEqual(try store.createRecording(meetingID: meeting.id, id: recovered.id), recovered)
        let other = try service.create(title: "다른 회의")
        XCTAssertThrowsError(try store.createRecording(meetingID: other.id, id: recovered.id))
        XCTAssertTrue(try store.recordings(meetingID: other.id).isEmpty)
    }

    func testTrackFormatsPathsAndInterruptionsAreValidatedAndRevisionGuarded() throws {
        let (_, _, store, _, recording, track) = try fixture()
        for path in ["/tmp/outside.caf", "../outside.caf", "recording/../outside.caf", "a//b", "C:\\file", "", "a/./b"] {
            XCTAssertThrowsError(try store.addTrack(recordingID: recording.id, kind: .systemAudio,
                relativePath: path, sampleRate: 48_000, channels: 2))
        }
        XCTAssertThrowsError(try store.addTrack(recordingID: recording.id, kind: .systemAudio,
            relativePath: "valid/file.caf", sampleRate: .nan, channels: 2))
        let interruptions = [MeetingTrackInterruption(start: 4, end: 5, reason: "deviceChanged")]
        let updated = try store.updateTrack(id: track.id, expectedRevision: track.revision,
            fileState: .available, duration: 8, interruptions: interruptions)
        XCTAssertEqual(updated.interruptions, interruptions)
        XCTAssertEqual(updated.sampleRate, 48_000)
        XCTAssertEqual(updated.channels, 1)
        XCTAssertEqual(updated.duration, 8)
        XCTAssertThrowsError(try store.updateTrack(id: track.id, expectedRevision: track.revision, fileState: .missing))
        XCTAssertThrowsError(try store.updateTrack(id: track.id, expectedRevision: updated.revision,
            fileState: .available, interruptions: [.init(start: 5, end: 4, reason: "bad")]))
        XCTAssertEqual(try store.track(id: track.id), updated)
    }

    func testServiceBlocksDeletionWhileRecordingOrPaused() throws {
        let (_, service, store, meeting, recording, _) = try fixture()
        XCTAssertThrowsError(try service.delete(id: meeting.id, expectedRevision: meeting.revision))
        let paused = try store.updateRecordingState(id: recording.id, expectedRevision: recording.revision, state: .paused)
        XCTAssertThrowsError(try service.delete(id: meeting.id, expectedRevision: meeting.revision))
        _ = try store.updateRecordingState(id: paused.id, expectedRevision: paused.revision, state: .completed)
        try service.delete(id: meeting.id, expectedRevision: meeting.revision)
        XCTAssertNil(try service.meeting(id: meeting.id))
        XCTAssertEqual(try store.tracks(recordingID: recording.id).count, 1)
    }

    func testAuthoritativeArchiveOffsetCorrectsPreviewDropWithoutShiftingSessionSegments() throws {
        let (_, _, store, meeting, recording, _) = try fixture()
        let delayed = try store.addTrack(recordingID: recording.id, kind: .systemAudio,
            relativePath: "audio/system.caf", sampleRate: 48_000, channels: 2, startOffset: 3)
        let run = try liveRun(store, meeting, recording)
        try store.upsertSegments(runID: run.id, segments: [.init(trackID: delayed.id, sourceKey: "first-visible", start: 3, end: 4, text: "미리보기 첫 문장")])
        let corrected = try store.updateTrack(id: delayed.id, expectedRevision: delayed.revision,
            fileState: .available, duration: 8, startOffset: 0.5)
        XCTAssertEqual(corrected.startOffset, 0.5)
        XCTAssertEqual(try store.segments(runID: run.id).first?.start, 3)
        XCTAssertEqual(MeetingAudioTimeline.fileTime(sessionTime: 3, startOffset: corrected.startOffset, interruptions: []), 2.5)
        let retained = try store.updateTrack(id: corrected.id, expectedRevision: corrected.revision, fileState: .missing)
        XCTAssertEqual(retained.startOffset, 0.5)
        XCTAssertThrowsError(try store.updateTrack(id: retained.id, expectedRevision: retained.revision, fileState: .available, startOffset: -.infinity))
        XCTAssertEqual(try store.track(id: retained.id)?.startOffset, 0.5)
    }

    func testMissingAudioCanBeMarkedForDeletedMeetingWithoutRestoringIt() throws {
        let (_, service, store, meeting, recording, track) = try fixture()
        _ = try store.updateRecordingState(id: recording.id, expectedRevision: recording.revision, state: .completed)
        try service.delete(id: meeting.id, expectedRevision: meeting.revision)
        _ = try store.updateTrack(id: track.id, expectedRevision: track.revision, fileState: .missing)
        XCTAssertEqual(try store.track(id: track.id)?.fileState, .missing)
        XCTAssertNil(try service.meeting(id: meeting.id))
        XCTAssertNotNil(try service.meeting(id: meeting.id, includeDeleted: true)?.deletedAt)
    }

    func testLiveProjectionContainsFinalSegmentsAndUpdatesWithoutTouchingNotes() throws {
        let (_, service, store, meeting, recording, track) = try fixture()
        let run = try liveRun(store, meeting, recording)
        let active = try store.activateRun(meetingID: meeting.id, runID: run.id, expectedMeetingRevision: meeting.revision)
        _ = try service.update(id: active.id, expectedRevision: active.revision, title: active.title,
            workDate: active.workDate, transcript: active.transcript, notes: "사용자 메모")
        try store.upsertSegments(runID: run.id, segments: [
            .init(trackID: track.id, sourceKey: "a", start: 0, end: 1, text: "확정 문장"),
            .init(trackID: track.id, sourceKey: "b", start: 1, end: 2, text: "미확정 문", isFinal: false)
        ])
        let first = try XCTUnwrap(service.meeting(id: meeting.id))
        XCTAssertEqual(first.transcript, "확정 문장")
        XCTAssertEqual(first.notes, "사용자 메모")
        XCTAssertEqual(try store.segments(runID: run.id).count, 2)
        try store.upsertSegments(runID: run.id, segments: [.init(trackID: track.id, sourceKey: "b", start: 1, end: 2, text: "확정된 둘째 문장")])
        XCTAssertEqual(try service.meeting(id: meeting.id)?.transcript, "확정 문장\n확정된 둘째 문장")
        XCTAssertGreaterThan(try XCTUnwrap(service.meeting(id: meeting.id)).revision, first.revision)
        _ = try store.finishRun(id: run.id)
        XCTAssertThrowsError(try store.upsertSegments(runID: run.id,
            segments: [.init(trackID: track.id, sourceKey: "a", start: 0, end: 1, text: "종료 후 덮어쓰기")]))
    }

    func testMachineUpdatesPreserveEditedTextAndSpeakerNameAndOriginals() throws {
        let (_, service, store, meeting, recording, track) = try fixture()
        let run = try liveRun(store, meeting, recording)
        let speaker = try store.upsertSpeaker(runID: run.id, sourceKey: "speaker-1", displayName: "화자 1")
        try store.upsertSegments(runID: run.id, segments: [.init(trackID: track.id, sourceKey: "a", start: 0, end: 1, text: "모델 원문", speakerID: speaker.id)])
        _ = try store.activateRun(meetingID: meeting.id, runID: run.id, expectedMeetingRevision: meeting.revision)
        let segment = try XCTUnwrap(store.segments(runID: run.id).first)
        _ = try store.editSegment(id: segment.id, expectedRevision: segment.revision, text: "직접 고친 문장")
        _ = try store.renameSpeaker(id: speaker.id, expectedRevision: speaker.revision, displayName: "진행자")
        try store.upsertSegments(runID: run.id, segments: [.init(trackID: track.id, sourceKey: "a", start: 0, end: 1.5, text: "모델 갱신 원문", speakerID: speaker.id)])
        let updatedSpeaker = try store.upsertSpeaker(runID: run.id, sourceKey: "speaker-1", displayName: "모델 새 이름")
        let updated = try XCTUnwrap(store.segment(id: segment.id))
        XCTAssertEqual(updated.originalText, "모델 갱신 원문")
        XCTAssertEqual(updated.text, "직접 고친 문장")
        XCTAssertEqual(updatedSpeaker.originalName, "모델 새 이름")
        XCTAssertEqual(updatedSpeaker.displayName, "진행자")
        XCTAssertEqual(try service.meeting(id: meeting.id)?.transcript, "진행자: 직접 고친 문장")
        XCTAssertEqual(try store.edits(runID: run.id).count, 2)
        XCTAssertTrue(try store.hasUserEdits(runID: run.id))
        XCTAssertThrowsError(try store.editSegment(id: segment.id, expectedRevision: segment.revision, text: "오래된 편집"))
    }

    func testSpeakerReassignmentRetainsOriginalAndCanExplicitlyClearLabel() throws {
        let (_, _, store, meeting, recording, track) = try fixture()
        let run = try liveRun(store, meeting, recording)
        let first = try store.upsertSpeaker(runID: run.id, sourceKey: "1", displayName: "화자 1")
        let second = try store.upsertSpeaker(runID: run.id, sourceKey: "2", displayName: "화자 2")
        try store.upsertSegments(runID: run.id, segments: [.init(trackID: track.id, sourceKey: "a", start: 0, end: 1, text: "문장", speakerID: first.id)])
        let segment = try XCTUnwrap(store.segments(runID: run.id).first)
        let edited = try store.editSegment(id: segment.id, expectedRevision: segment.revision, speakerID: second.id, editSpeaker: true)
        XCTAssertEqual(edited.originalSpeakerID, first.id)
        XCTAssertEqual(edited.speakerID, second.id)
        let cleared = try store.editSegment(id: edited.id, expectedRevision: edited.revision, editSpeaker: true)
        XCTAssertNil(cleared.speakerID)
        XCTAssertEqual(cleared.originalSpeakerID, first.id)
        XCTAssertEqual(try store.edits(runID: run.id).count, 2)
    }

    func testOtherRunSpeakersAndOtherRecordingTracksCannotBeMixedAndBatchRollsBack() throws {
        let (_, _, store, meeting, recording, track) = try fixture()
        let run = try liveRun(store, meeting, recording)
        let otherRun = try liveRun(store, meeting, recording)
        let speaker = try store.upsertSpeaker(runID: otherRun.id, sourceKey: "1", displayName: "화자 1")
        XCTAssertThrowsError(try store.upsertSegments(runID: run.id, segments: [.init(trackID: track.id, sourceKey: "a", start: 0, end: 1, text: "문장", speakerID: speaker.id)]))
        let otherRecording = try store.createRecording(meetingID: meeting.id)
        let otherTrack = try store.addTrack(recordingID: otherRecording.id, kind: .systemAudio, relativePath: "other/system.caf", sampleRate: 48_000, channels: 2)
        XCTAssertThrowsError(try store.upsertSegments(runID: run.id, segments: [
            .init(trackID: track.id, sourceKey: "valid", start: 0, end: 1, text: "함께 롤백"),
            .init(trackID: otherTrack.id, sourceKey: "invalid", start: 1, end: 2, text: "다른 녹음")
        ]))
        XCTAssertTrue(try store.segments(runID: run.id).isEmpty)
        XCTAssertEqual(try store.run(id: run.id)?.revision, run.revision)
    }

    func testReplacingEditedVersionNeedsExplicitSelectionAndKeepsBothVersions() throws {
        let (_, service, store, meeting, recording, track) = try fixture()
        let live = try liveRun(store, meeting, recording)
        try store.upsertSegments(runID: live.id, segments: [.init(trackID: track.id, sourceKey: "a", start: 0, end: 1, text: "실시간 원문")])
        _ = try store.activateRun(meetingID: meeting.id, runID: live.id, expectedMeetingRevision: meeting.revision)
        let segment = try XCTUnwrap(store.segments(runID: live.id).first)
        _ = try store.editSegment(id: segment.id, expectedRevision: segment.revision, text: "사용자 수정")
        let refined = try store.createRun(meetingID: meeting.id, recordingID: recording.id, stage: .refined,
            engine: "whisperkit", modelIdentifier: "large-v3", sourceRunID: live.id)
        try store.upsertSegments(runID: refined.id, segments: [.init(trackID: track.id, sourceKey: "a", start: 0, end: 1, text: "정밀 원문")])
        _ = try store.finishRun(id: refined.id)
        let current = try XCTUnwrap(service.meeting(id: meeting.id))
        XCTAssertThrowsError(try store.activateRun(meetingID: meeting.id, runID: refined.id, expectedMeetingRevision: current.revision))
        XCTAssertEqual(try service.meeting(id: meeting.id)?.transcript, "사용자 수정")
        let selected = try store.activateRun(meetingID: meeting.id, runID: refined.id, expectedMeetingRevision: current.revision, allowReplacingUserEdits: true)
        XCTAssertEqual(selected.transcript, "정밀 원문")
        XCTAssertEqual(try store.segments(runID: live.id).first?.originalText, "실시간 원문")
        XCTAssertEqual(try store.segments(runID: live.id).first?.text, "사용자 수정")
        XCTAssertEqual(try store.runs(meetingID: meeting.id).map(\.version), [2, 1])
    }

    func testWholeTranscriptEditsBecomeManualVersionsAndRetainMachineSource() throws {
        let (_, service, store, meeting, recording, track) = try fixture()
        let run = try liveRun(store, meeting, recording)
        try store.upsertSegments(runID: run.id, segments: [.init(trackID: track.id, sourceKey: "a", start: 0, end: 1, text: "모델 원문")])
        let active = try store.activateRun(meetingID: meeting.id, runID: run.id, expectedMeetingRevision: meeting.revision)
        let edited = try service.update(id: active.id, expectedRevision: active.revision, title: active.title,
            workDate: active.workDate, transcript: "직접 편집한 전체 본문", notes: "메모")
        let manual = try XCTUnwrap(store.run(id: XCTUnwrap(edited.activeTranscriptRunID)))
        XCTAssertEqual(manual.stage, .manual)
        XCTAssertEqual(manual.status, .completed)
        XCTAssertEqual(manual.sourceRunID, run.id)
        XCTAssertEqual(manual.manualText, edited.transcript)
        try store.upsertSegments(runID: run.id, segments: [.init(trackID: track.id, sourceKey: "a", start: 0, end: 2, text: "이후 모델 갱신")])
        XCTAssertEqual(try service.meeting(id: meeting.id)?.transcript, "직접 편집한 전체 본문")
        XCTAssertEqual(try store.segments(runID: run.id).first?.originalText, "이후 모델 갱신")
    }

    func testLegacyRawTranscriptIsPreservedBeforeFirstReplacement() throws {
        let (repo, service, store, _, _, _) = try fixture()
        let meeting = try service.create(title: "이전 회의", transcript: "이전 원문")
        let recording = try store.createRecording(meetingID: meeting.id)
        let run = try liveRun(store, meeting, recording)
        XCTAssertThrowsError(try store.activateRun(meetingID: meeting.id, runID: run.id, expectedMeetingRevision: meeting.revision))
        _ = try store.activateRun(meetingID: meeting.id, runID: run.id, expectedMeetingRevision: meeting.revision, allowReplacingUserEdits: true)
        XCTAssertEqual(try store.runs(meetingID: meeting.id).first(where: { $0.stage == .manual })?.manualText, "이전 원문")
        XCTAssertEqual(try repo.db.scalarIntV("SELECT COUNT(*) FROM meeting_transcript_run WHERE meeting_id = ?", meeting.id), 2)
    }

    func testTranscriptRemainsEditableAfterOriginalAudioIsDiscarded() throws {
        let (_, service, store, meeting, recording, track) = try fixture()
        let run = try liveRun(store, meeting, recording)
        try store.upsertSegments(runID: run.id, segments: [.init(trackID: track.id, sourceKey: "a", start: 0, end: 1, text: "보존된 전사")])
        let active = try store.activateRun(meetingID: meeting.id, runID: run.id, expectedMeetingRevision: meeting.revision)
        _ = try store.finishRun(id: run.id)
        _ = try store.updateTrack(id: track.id, expectedRevision: track.revision, fileState: .deleted)
        _ = try store.updateRecordingState(id: recording.id, expectedRevision: recording.revision, state: .discarded)
        let edited = try service.update(id: active.id, expectedRevision: active.revision, title: active.title,
            workDate: active.workDate, transcript: "음성 삭제 뒤에도 직접 수정", notes: "")
        XCTAssertEqual(edited.transcript, "음성 삭제 뒤에도 직접 수정")
        XCTAssertEqual(try store.segments(runID: run.id).first?.originalText, "보존된 전사")
        XCTAssertThrowsError(try store.createRun(meetingID: meeting.id, recordingID: recording.id, stage: .refined,
            engine: "fixture", modelIdentifier: "large-v3"))
    }

    func testInterruptedRecoveryRetainsReferencesAndMarksRunningVersionsWithoutDeletingText() throws {
        let (_, _, store, meeting, recording, track) = try fixture()
        let run = try liveRun(store, meeting, recording)
        try store.upsertSegments(runID: run.id, segments: [.init(trackID: track.id, sourceKey: "a", start: 0, end: 1, text: "종료 전 확정")])
        let recovered = try store.recoverInterrupted()
        XCTAssertEqual(recovered.map(\.id), [recording.id])
        XCTAssertEqual(recovered.first?.state, .interrupted)
        let pending = try XCTUnwrap(store.track(id: track.id))
        XCTAssertEqual(pending.fileState, .needsRecovery)
        XCTAssertEqual(pending.relativePath, track.relativePath)
        XCTAssertEqual(try store.run(id: run.id)?.status, .interrupted)
        XCTAssertEqual(try store.segments(runID: run.id).first?.text, "종료 전 확정")
        XCTAssertEqual(try store.recoverableRecordings().map(\.id), [recording.id])
        XCTAssertTrue(try store.recoverInterrupted().isEmpty)
        let missing = try store.updateTrack(id: pending.id, expectedRevision: pending.revision, fileState: .missing)
        XCTAssertEqual(missing.relativePath, track.relativePath)
        XCTAssertEqual(missing.fileState, .missing)
    }

    func testFailedCaptureCanBeReconciledAsInterruptedAndThenCompleted() throws {
        let (_, _, store, _, recording, _) = try fixture()
        let failed = try store.updateRecordingState(id: recording.id, expectedRevision: recording.revision, state: .failed)
        let recovered = try store.updateRecordingState(id: failed.id, expectedRevision: failed.revision, state: .interrupted)
        XCTAssertEqual(recovered.state, .interrupted)
        XCTAssertNil(recovered.endedAt)
        let complete = try store.updateRecordingState(id: recovered.id, expectedRevision: recovered.revision, state: .completed)
        XCTAssertEqual(complete.state, .completed)
        XCTAssertEqual(complete.endedAt, instant)
        XCTAssertThrowsError(try store.updateRecordingState(id: complete.id, expectedRevision: complete.revision, state: .recording))
    }

    func testOversizedInterimSegmentsRollbackInsteadOfAccumulatingUnboundedData() throws {
        let (_, _, store, meeting, recording, track) = try fixture()
        let run = try liveRun(store, meeting, recording)
        let inputs = (0..<16).map { index in
            MeetingSegmentInput(trackID: track.id, sourceKey: String(index), start: Double(index), end: Double(index + 1),
                text: String(repeating: "x", count: MeetingLimits.notesBytes), isFinal: false)
        }
        XCTAssertThrowsError(try store.upsertSegments(runID: run.id, segments: inputs))
        XCTAssertTrue(try store.segments(runID: run.id).isEmpty)
    }

    func testSQLiteBackupIncludesMetadataOriginalsEditsAndActiveVersion() throws {
        let (repo, service, store, meeting, recording, track) = try fixture()
        let run = try liveRun(store, meeting, recording)
        try store.upsertSegments(runID: run.id, segments: [.init(trackID: track.id, sourceKey: "a", start: 0, end: 1, text: "백업 원문")])
        _ = try store.activateRun(meetingID: meeting.id, runID: run.id, expectedMeetingRevision: meeting.revision)
        let segment = try XCTUnwrap(store.segments(runID: run.id).first)
        _ = try store.editSegment(id: segment.id, expectedRevision: segment.revision, text: "백업 수정")
        let previewGap = try store.recordPreviewGap(runID: run.id, trackID: track.id, start: 2, end: 3, reason: "preview-error")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-audio-backup-" + UUIDGenerator().make())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("work.sqlite").path
        try repo.db.backup(to: path)
        let copy = try WorkRepository(db: SQLiteDatabase(path: path), clock: FixedClock(instant))
        let restored = try XCTUnwrap(MeetingService(repo: copy).meeting(id: meeting.id))
        let restoredStore = MeetingAudioStore(repo: copy)
        XCTAssertEqual(restored, try service.meeting(id: meeting.id))
        XCTAssertTrue(restored.localOnly)
        XCTAssertEqual(restored.activeTranscriptRunID, run.id)
        XCTAssertEqual(try restoredStore.tracks(recordingID: recording.id), [track])
        XCTAssertEqual(try restoredStore.segments(runID: run.id).first?.originalText, "백업 원문")
        XCTAssertEqual(try restoredStore.segments(runID: run.id).first?.text, "백업 수정")
        XCTAssertEqual(try restoredStore.edits(runID: run.id).count, 1)
        XCTAssertEqual(try restoredStore.previewGaps(runID: run.id), [previewGap])
        XCTAssertTrue(try copy.db.integrityCheck())
    }
}
