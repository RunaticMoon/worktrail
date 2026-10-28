import XCTest
import Crypto
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

    func testSummaryHistoryMetadataAndExternalPolicyRoundTrip() throws {
        let (root, repo, initial, archiveService) = try fixture()
        let service = MeetingService(repo: repo)
        let metadata = MeetingMetadata(projectIDs: [], tagIDs: [], participants: ["가짜 참석자"], agenda: "검증", occurredAt: repo.clock.now())
        let meeting = try service.updateMetadata(meetingID: initial.id, expectedRevision: initial.revision, metadata: metadata)
        let first = try service.saveManualSummary(meetingID: meeting.id, expectedMeetingRevision: meeting.revision,
            expectedSummaryRevision: nil, output: .init(summary: [.init(text: "수동 요약", citations: [])]))
        _ = try service.saveManualSummary(meetingID: meeting.id, expectedMeetingRevision: meeting.revision,
            expectedSummaryRevision: first.revision, output: .init(summary: [.init(text: "수동 두 번째 요약", citations: [])]))
        _ = try service.setLocalOnly(id: meeting.id, expectedRevision: meeting.revision, localOnly: false)
        let archive = root.appendingPathComponent("history.worklogmeeting")
        try archiveService.export(meetingID: meeting.id, includeAudio: false, to: archive)
        let destination = try WorkRepository.inMemory(ids: SequentialIDGenerator(prefix: "history"))
        let id = try MeetingArchiveService(repo: destination, audioRoot: root.appendingPathComponent("history-audio")).restore(archive, duplicatePolicy: .newCopy)
        let restored = try XCTUnwrap(MeetingService(repo: destination).meeting(id: id))
        XCTAssertEqual(restored.metadata, metadata)
        XCTAssertTrue(restored.localOnly)
        XCTAssertTrue(try MeetingService(repo: destination).summaryHistory(meetingID: id).allSatisfy(\.isManual))
        XCTAssertEqual(try MeetingService(repo: destination).summaryHistory(meetingID: id).count, 2)
    }

    func testDatabaseConflictRollsBackAllRowsAndNewAudio() throws {
        let (root, repo, meeting, service) = try fixture()
        let archive = root.appendingPathComponent("rollback.worklogmeeting")
        try service.export(meetingID: meeting.id, includeAudio: true, to: archive)
        let recordingID = try XCTUnwrap(MeetingAudioStore(repo: repo).recordings(meetingID: meeting.id).first?.id)
        let destination = try WorkRepository.inMemory(ids: SequentialIDGenerator(prefix: "unrelated"))
        let existing = try MeetingService(repo: destination).create(title: "기존 회의 보존")
        _ = try MeetingAudioStore(repo: destination).createRecording(meetingID: existing.id, id: recordingID)
        let audioRoot = root.appendingPathComponent("rollback-audio")
        let importer = MeetingArchiveService(repo: destination, audioRoot: audioRoot)
        XCTAssertThrowsError(try importer.restore(archive, duplicatePolicy: .reject))
        XCTAssertNil(try MeetingService(repo: destination).meeting(id: meeting.id))
        XCTAssertEqual(try MeetingService(repo: destination).meeting(id: existing.id)?.title, "기존 회의 보존")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: audioRoot.path).isEmpty)
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
    private func setMetadata(_ metadata: MeetingMetadata, for meeting: Meeting, repo: WorkRepository) throws {
        _ = try MeetingService(repo: repo).updateMetadata(meetingID: meeting.id, expectedRevision: meeting.revision, metadata: metadata)
    }

    private func rewritePayload(_ archive: URL, transform: (inout [String: Any]) throws -> Void) throws {
        let recordsURL = archive.appendingPathComponent("records.json")
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordsURL)) as? [String: Any])
        try transform(&records)
        let data = try JSONSerialization.data(withJSONObject: records)
        try data.write(to: recordsURL)
        let manifestURL = archive.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        let index = try XCTUnwrap(entries.firstIndex { $0["path"] as? String == "records.json" })
        entries[index]["size"] = data.count
        entries[index]["sha256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        manifest["entries"] = entries
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    }

    func testMissingAudioManifestMustExactlyMatchPayloadTracks() throws {
        let (root, repo, meeting, service) = try fixture()
        let archive = root.appendingPathComponent("missing-list.worklogmeeting")
        try service.export(meetingID: meeting.id, includeAudio: false, to: archive)
        let url = archive.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let missing = try XCTUnwrap(manifest["missingTrackIDs"] as? [String])
        XCTAssertEqual(missing.count, 1)
        for invalid in [[], ["unknown-track"], missing + missing] {
            manifest["missingTrackIDs"] = invalid
            try JSONSerialization.data(withJSONObject: manifest).write(to: url)
            XCTAssertThrowsError(try service.inspect(archive))
            XCTAssertThrowsError(try service.restore(archive, duplicatePolicy: .newCopy))
            XCTAssertEqual(try repo.db.scalarInt("SELECT COUNT(*) FROM meeting"), 1)
        }
    }

    func testSelectedClassificationsRoundTripIntoEmptyRepository() throws {
        let (root, repo, meeting, service) = try fixture()
        let project = try repo.createProject(name: "선택한 보관 프로젝트")
        let tag = try repo.findOrCreateTag(name: "선택한 태그")
        _ = try repo.createProject(name: "내보내면 안 되는 무관한 프로젝트")
        _ = try repo.findOrCreateTag(name: "내보내면 안 되는 무관한 태그")
        let archivedAt = repo.clock.now()
        try repo.db.run("UPDATE project SET archived_at = ? WHERE id = ?", [archivedAt, project.id])
        try setMetadata(.init(projectIDs: [project.id], tagIDs: [tag.id], participants: ["가짜 참석자"], agenda: "의제"), for: meeting, repo: repo)
        let archive = root.appendingPathComponent("classifications.worklogmeeting")
        try service.export(meetingID: meeting.id, includeAudio: false, to: archive)
        let payloadText = try String(contentsOf: archive.appendingPathComponent("records.json"), encoding: .utf8)
        XCTAssertFalse(payloadText.contains("내보내면 안 되는"))
        let destination = try WorkRepository.inMemory(ids: SequentialIDGenerator(prefix: "classifications"))
        let importer = MeetingArchiveService(repo: destination, audioRoot: root.appendingPathComponent("classification-audio"))
        let id = try importer.restore(archive, duplicatePolicy: .newCopy)
        let metadata = try XCTUnwrap(MeetingService(repo: destination).meeting(id: id)?.metadata)
        XCTAssertEqual(metadata.participants, ["가짜 참석자"])
        XCTAssertEqual(metadata.agenda, "의제")
        let restoredProject = try XCTUnwrap(destination.project(id: try XCTUnwrap(metadata.projectIDs.first)))
        XCTAssertEqual(restoredProject.name, project.name)
        XCTAssertEqual(restoredProject.archivedAt, archivedAt)
        XCTAssertEqual(try destination.tags().map(\.name), [tag.name])
        XCTAssertEqual(try destination.projects(includeArchived: true).count, 1)
        XCTAssertEqual(metadata.tagIDs, try destination.tags().map(\.id))
    }

    func testClassificationIDAndNameConflictsReuseOrCreateWithoutModifyingExistingData() throws {
        let (root, repo, meeting, service) = try fixture()
        let first = try repo.createProject(name: "이름으로 재사용")
        let second = try repo.createProject(name: "새로 만들어야 하는 이름")
        let third = try repo.createProject(name: "같은 ID와 이름")
        let tag = try repo.findOrCreateTag(name: "태그 이름 재사용")
        try setMetadata(.init(projectIDs: [first.id, second.id, third.id], tagIDs: [tag.id]), for: meeting, repo: repo)
        let archive = root.appendingPathComponent("conflicts.worklogmeeting")
        try service.export(meetingID: meeting.id, includeAudio: false, to: archive)
        let destination = try WorkRepository.inMemory(ids: SequentialIDGenerator(prefix: "classification-conflict"))
        try destination.db.run("INSERT INTO project (id, name, archived_at) VALUES (?, ?, ?)", [first.id, "첫 ID의 다른 이름", SQLValue.null])
        try destination.db.run("INSERT INTO project (id, name, archived_at) VALUES (?, ?, ?)", [second.id, "둘째 ID의 다른 이름", SQLValue.null])
        let archivedAt = repo.clock.now()
        try destination.db.run("INSERT INTO project (id, name, archived_at) VALUES (?, ?, ?)", [third.id, third.name, archivedAt])
        let sameName = try destination.createProject(name: first.name)
        try destination.db.run("INSERT INTO tag (id, name) VALUES (?, ?)", [tag.id, "태그 ID의 다른 이름"])
        let sameTag = try destination.findOrCreateTag(name: tag.name)
        let importer = MeetingArchiveService(repo: destination, audioRoot: root.appendingPathComponent("conflict-audio"))
        let id = try importer.restore(archive, duplicatePolicy: .newCopy)
        let metadata = try XCTUnwrap(MeetingService(repo: destination).meeting(id: id)?.metadata)
        XCTAssertEqual(metadata.projectIDs[0], sameName.id)
        XCTAssertNotEqual(metadata.projectIDs[1], second.id)
        XCTAssertEqual(try destination.project(id: metadata.projectIDs[1])?.name, second.name)
        XCTAssertEqual(metadata.projectIDs[2], third.id)
        XCTAssertEqual(try destination.project(id: third.id)?.archivedAt, archivedAt)
        XCTAssertEqual(try destination.project(id: first.id)?.name, "첫 ID의 다른 이름")
        XCTAssertEqual(try destination.project(id: second.id)?.name, "둘째 ID의 다른 이름")
        XCTAssertEqual(metadata.tagIDs, [sameTag.id])
        XCTAssertEqual(try destination.db.queryOne("SELECT name FROM tag WHERE id = ?", [tag.id])?.string("name"), "태그 ID의 다른 이름")
    }

    func testClassificationRowsRollBackWithMeetingImportFailure() throws {
        let (root, repo, meeting, service) = try fixture()
        let project = try repo.createProject(name: "롤백 프로젝트")
        let tag = try repo.findOrCreateTag(name: "롤백 태그")
        try setMetadata(.init(projectIDs: [project.id], tagIDs: [tag.id]), for: meeting, repo: repo)
        let archive = root.appendingPathComponent("classification-rollback.worklogmeeting")
        try service.export(meetingID: meeting.id, includeAudio: true, to: archive)
        let destination = try WorkRepository.inMemory(ids: SequentialIDGenerator(prefix: "rollback-classification"))
        let existing = try destination.createProject(name: "기존 프로젝트")
        try destination.db.execute("CREATE TRIGGER fail_archive_meeting BEFORE INSERT ON meeting BEGIN SELECT RAISE(ABORT, 'injected import failure'); END;")
        let audioRoot = root.appendingPathComponent("classification-rollback-audio")
        let importer = MeetingArchiveService(repo: destination, audioRoot: audioRoot)
        XCTAssertThrowsError(try importer.restore(archive, duplicatePolicy: .newCopy))
        XCTAssertEqual(try destination.projects(includeArchived: true), [existing])
        XCTAssertTrue(try destination.tags().isEmpty)
        XCTAssertEqual(try destination.db.scalarInt("SELECT COUNT(*) FROM meeting"), 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: audioRoot.path).isEmpty)
    }

    func testUnavailableClassificationIDsNeverAttachToUnrelatedDestinationRows() throws {
        let (root, repo, meeting, service) = try fixture()
        let project = try repo.createProject(name: "원본에서 없어진 프로젝트")
        let tag = try repo.findOrCreateTag(name: "원본에서 없어진 태그")
        try setMetadata(.init(projectIDs: [project.id], tagIDs: [tag.id]), for: meeting, repo: repo)
        try repo.db.run("DELETE FROM project WHERE id = ?", [project.id])
        try repo.db.run("DELETE FROM tag WHERE id = ?", [tag.id])
        let archive = root.appendingPathComponent("unknown-classifications.worklogmeeting")
        try service.export(meetingID: meeting.id, includeAudio: false, to: archive)
        let destination = try WorkRepository.inMemory(ids: SequentialIDGenerator(prefix: "missing-classifications"))
        try destination.db.run("INSERT INTO project (id, name) VALUES (?, ?)", [project.id, "무관한 프로젝트"])
        try destination.db.run("INSERT INTO tag (id, name) VALUES (?, ?)", [tag.id, "무관한 태그"])
        let importer = MeetingArchiveService(repo: destination, audioRoot: root.appendingPathComponent("unknown-classifications-audio"))
        let id = try importer.restore(archive, duplicatePolicy: .newCopy)
        let metadata = try XCTUnwrap(MeetingService(repo: destination).meeting(id: id)?.metadata)
        XCTAssertNotEqual(metadata.projectIDs, [project.id]); XCTAssertNotEqual(metadata.tagIDs, [tag.id])
        XCTAssertNil(try destination.project(id: metadata.projectIDs[0]))
        XCTAssertNil(try destination.db.queryOne("SELECT id FROM tag WHERE id = ?", [metadata.tagIDs[0]]))
        XCTAssertEqual(try destination.projects().map(\.name), ["무관한 프로젝트"])
        XCTAssertEqual(try destination.tags().map(\.name), ["무관한 태그"])
    }

    func testLegacyMetadataStaysUnavailableAndUnselectedClassificationsAreRejected() throws {
        let (root, repo, meeting, service) = try fixture()
        let project = try repo.createProject(name: "기존 형식 프로젝트")
        try setMetadata(.init(projectIDs: [project.id]), for: meeting, repo: repo)
        let archive = root.appendingPathComponent("legacy-classifications.worklogmeeting")
        try service.export(meetingID: meeting.id, includeAudio: false, to: archive)
        try rewritePayload(archive) { $0.removeValue(forKey: "projects"); $0.removeValue(forKey: "tags") }
        let destination = try WorkRepository.inMemory(ids: SequentialIDGenerator(prefix: "legacy-classifications"))
        let importer = MeetingArchiveService(repo: destination, audioRoot: root.appendingPathComponent("legacy-classifications-audio"))
        let id = try importer.restore(archive, duplicatePolicy: .newCopy)
        let metadata = try XCTUnwrap(MeetingService(repo: destination).meeting(id: id)?.metadata)
        XCTAssertEqual(metadata.projectIDs, [project.id])
        XCTAssertNil(try destination.project(id: project.id))
        try rewritePayload(archive) { $0["projects"] = [["id": "unselected", "name": "허용되지 않는 분류"]] }
        XCTAssertThrowsError(try importer.inspect(archive))
        XCTAssertThrowsError(try importer.restore(archive, duplicatePolicy: .newCopy))
        XCTAssertEqual(try destination.db.scalarInt("SELECT COUNT(*) FROM meeting"), 1)
        XCTAssertTrue(try destination.projects(includeArchived: true).isEmpty)
    }

    func testSourceValidationErrorsAreNotSilentlyReportedAsMissingAndPreviewChangesAbort() throws {
        let (root, _, meeting, service) = try fixture()
        let preview = try service.preview(meetingID: meeting.id, includeAudio: true)
        let source = root.appendingPathComponent("original.wav")
        try FileManager.default.removeItem(at: source)
        let archive = root.appendingPathComponent("changed-source.worklogmeeting")
        XCTAssertThrowsError(try service.export(meetingID: meeting.id, includeAudio: true, to: archive, expectedPreview: preview))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        let missing = try service.preview(meetingID: meeting.id, includeAudio: true)
        XCTAssertEqual(missing.audioFileCount, 0); XCTAssertEqual(missing.missingTrackCount, 1)
        try service.export(meetingID: meeting.id, includeAudio: true, to: archive, expectedPreview: missing)
        XCTAssertEqual(try service.inspect(archive).missingTrackCount, 1)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        XCTAssertThrowsError(try service.preview(meetingID: meeting.id, includeAudio: true))
        XCTAssertThrowsError(try service.export(meetingID: meeting.id, includeAudio: true,
            to: root.appendingPathComponent("invalid-source.worklogmeeting")))
    }

    func testExistingTemporaryDirectoriesAreNeverReusedOrDeleted() throws {
        struct CollisionIDs: IDGenerator { func make() -> String { "collision" } }
        let (root, source, meeting, service) = try fixture()
        let fixed = try WorkRepository(db: source.db, clock: source.clock, ids: CollisionIDs())
        let fixedExporter = MeetingArchiveService(repo: fixed, audioRoot: root)
        let temporary = root.appendingPathComponent(".meeting-incomplete-collision")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let sentinel = temporary.appendingPathComponent("existing.txt")
        try Data("existing export file".utf8).write(to: sentinel)
        XCTAssertThrowsError(try fixedExporter.export(meetingID: meeting.id, includeAudio: false,
            to: root.appendingPathComponent("collision.worklogmeeting")))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("existing export file".utf8))

        let archive = root.appendingPathComponent("valid-import.worklogmeeting")
        try service.export(meetingID: meeting.id, includeAudio: false, to: archive)
        let destination = try WorkRepository.inMemory(ids: CollisionIDs())
        let audioRoot = root.appendingPathComponent("collision-import-audio")
        let staging = audioRoot.appendingPathComponent(".incomplete-import-collision")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let importSentinel = staging.appendingPathComponent("existing.txt")
        try Data("existing import file".utf8).write(to: importSentinel)
        let importer = MeetingArchiveService(repo: destination, audioRoot: audioRoot)
        XCTAssertThrowsError(try importer.restore(archive, duplicatePolicy: .reject))
        XCTAssertEqual(try Data(contentsOf: importSentinel), Data("existing import file".utf8))
        XCTAssertEqual(try destination.db.scalarInt("SELECT COUNT(*) FROM meeting"), 0)
    }

}
