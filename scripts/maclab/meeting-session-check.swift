#if os(macOS)
import AVFoundation
import Foundation
import WorkLogCore

// This CLI fixture has no text editor or IME session. All meeting model logic is
// compiled from the actual application source; only this UI-global is stubbed.
@MainActor var worklogHasMarkedText: Bool { false }

private struct SessionCheckError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private actor FakeInferenceOrder {
    private(set) var steps: [String] = []
    func add(_ step: String) { steps.append(step) }
}
private actor FakeFileTranscriber: MeetingFileTranscribing {
    let order: FakeInferenceOrder
    init(_ order: FakeInferenceOrder) { self.order = order }
    func transcribe(samples: [Float], language: String?) async throws -> [MeetingRecognizedSpan] {
        guard language == "ko", !samples.isEmpty, samples.count <= 30 * 16_000 else { throw SessionCheckError("Invalid inference window") }
        await order.add("transcribe")
        return [.init(start: 0, end: Double(samples.count) / 16_000, text: "가짜 정밀 전사 원문")]
    }
    func unload() async { await order.add("unload-transcriber") }
}
private actor FakeFileDiarizer: MeetingFileDiarizing {
    let order: FakeInferenceOrder
    let fails: Bool
    init(_ order: FakeInferenceOrder, fails: Bool) { self.order = order; self.fails = fails }
    func diarize(samples: [Float], progress: (@Sendable (Double) -> Void)?) async throws -> MeetingDiarizationResult {
        guard await order.steps.last == "unload-transcriber" else { throw SessionCheckError("Diarizer started before transcriber unload") }
        await order.add("diarize")
        if fails { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM)) }
        return .init(turns: [.init(start: 0, end: Double(samples.count) / 16_000, speakerID: 1)], centroids: [1: [1, 0, 0]])
    }
    func unload() async { await order.add("unload-speaker") }
}

/// Uses the production archive writer, but every sample originates in this fixture.
/// It never creates AVAudioEngine, SCStream or a microphone permission request.
@MainActor private final class FakeMeetingCapture: MeetingAudioCapturing {
    private var writer: MeetingAudioArchiveWriter?
    private var last: MeetingAudioArchiveSnapshot?
    private var events: [@Sendable (MeetingCaptureEvent) -> Void] = []
    private var consumers: [@Sendable (MeetingCapturedPCM) -> Void] = []
    private(set) var starts: [(recording: String, meeting: String)] = []
    private(set) var stops = 0

    func start(recordingID: String, meetingID: String, mode: MeetingCaptureMode, archiveRoot: URL,
               onPCM: @escaping @Sendable (MeetingCapturedPCM) -> Void,
               onEvent: @escaping @Sendable (MeetingCaptureEvent) -> Void) async throws {
        starts.append((recordingID, meetingID)); events.append(onEvent); consumers.append(onPCM)
        last = nil
        writer = try MeetingAudioArchiveWriter(archive: MeetingAudioArchive(root: archiveRoot), recordingID: recordingID,
            meetingID: meetingID, clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_000)),
            onPCM: onPCM, onLevel: { track, value in onEvent(.level(track: track, rms: value)) },
            onFailure: { onEvent(.failed($0)) })
        try await writer!.appendForImport(Self.packet(at: 0))
        try await writer!.appendForImport(Self.packet(at: 0.1))
        onEvent(.started)
    }

    func stop(reason: String?) async -> MeetingAudioArchiveSnapshot? {
        stops += 1
        try? await Task.sleep(nanoseconds: 20_000_000)
        if let writer {
            last = await writer.finish(reason: reason)
            self.writer = nil
            if let last { events.last?(.stopped(last)) }
        }
        return last
    }

    func sendLateEvents(from index: Int) throws {
        events[index](.failed("fake old session failure"))
        events[index](.level(track: .system, rms: 99))
        consumers[index](try Self.packet(at: 100))
    }

    private static func packet(at time: Double) throws -> MeetingCapturedPCM {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        for index in 0..<4_800 { buffer.floatChannelData![0][index] = sin(Float(index) * 0.05) * 0.1 }
        return try .copy(track: .microphone, buffer: buffer, relativeStartSeconds: time)
    }
}

@main struct MeetingSessionCheck {
    @MainActor static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw SessionCheckError(message) }
    }
    @MainActor static func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw SessionCheckError("Timed out: " + message)
    }

    @MainActor static func fixtureEnvironment(at root: URL) throws -> AppEnvironment {
        try AppEnvironment.open(.init(
            paths: AppPaths(dataRoot: root.appendingPathComponent("data"), backupRoot: root.appendingPathComponent("backups")),
            keyStore: InMemoryVaultKeyStore(), authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(),
            clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_000)), ids: SequentialIDGenerator(prefix: "save-fixture")))
    }

    @MainActor static func checkDatabaseSaveRetry(at root: URL) async throws {
        let environment = try fixtureEnvironment(at: root)
        let meeting = try MeetingService(repo: environment.repo).create(title: "가짜 DB 저장 실패 회의")
        let capture = FakeMeetingCapture()
        let session = MeetingRecordingSession(environment: environment, capture: capture)
        session.microphoneID = "fixture-device-never-opened"
        session.preferences.automaticFinalization = false
        session.start(meeting: meeting, recordOnly: true)
        try await waitUntil("DB failure capture", { session.phase == .recording })
        let recordingID = session.recordingID!
        let original = try session.archive.audioURL(recordingID: recordingID, track: .microphone)
        try environment.repo.db.run("""
            CREATE TRIGGER fixture_fail_recording_update BEFORE UPDATE ON meeting_recording
            BEGIN SELECT RAISE(ABORT, 'fixture recording update failure'); END
            """)
        session.stop()
        try await waitUntil("DB failure stop", { session.phase == .idle })
        let preserved = try Data(contentsOf: original)
        try check(session.isSavePending, "Failed recording reconciliation must retain an unsaved snapshot")
        let refused = await session.shutdown()
        try check(!refused && session.isSavePending, "DB failure must prevent termination")
        session.start(meeting: meeting, recordOnly: true)
        try check(session.phase == .idle && capture.starts.count == 1, "Pending save must block replacing the recording with a new capture")
        try environment.repo.db.run("DROP TRIGGER fixture_fail_recording_update")
        try check(session.retrySaving() && !session.isSavePending, "Removing the DB fault must permit an explicit save retry")
        let allowed = await session.shutdown()
        try check(allowed, "Successful DB save retry must permit termination")
        try check(try session.store.recording(id: recordingID)?.state == .completed, "Retried DB state must reflect the completed original")
        try check(try Data(contentsOf: original) == preserved && AVAudioFile(forReading: original).length == 9_600,
                  "DB save failure and retry must preserve original PCM bytes")
        print("PASS: DB reconciliation failure blocks shutdown/new capture until retry succeeds, preserving original PCM bytes")
    }

    @MainActor static func checkJournalSaveRetry(at root: URL) async throws {
        let environment = try fixtureEnvironment(at: root)
        let meeting = try MeetingService(repo: environment.repo).create(title: "가짜 저널 저장 실패 회의")
        let capture = FakeMeetingCapture()
        let session = MeetingRecordingSession(environment: environment, capture: capture)
        session.microphoneID = "fixture-device-never-opened"
        session.preferences.automaticFinalization = false
        session.start(meeting: meeting, recordOnly: true)
        try await waitUntil("journal failure capture", { session.phase == .recording })
        let recordingID = session.recordingID!
        let original = try session.archive.audioURL(recordingID: recordingID, track: .microphone)
        let journal = original.deletingLastPathComponent().appendingPathComponent("manifest.json")
        let heldJournal = root.appendingPathComponent("held-fixture-manifest.json")
        // Only replace this disposable fixture's manifest. Keep its prior contents
        // outside the archive so failure cannot destroy recovery evidence.
        try FileManager.default.moveItem(at: journal, to: heldJournal)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        session.stop()
        try await waitUntil("journal failure stop", { session.phase == .idle })
        let preserved = try Data(contentsOf: original)
        try check(session.isSavePending, "Final journal write failure must retain the unsaved snapshot")
        let refused = await session.shutdown()
        try check(!refused && session.isSavePending, "Journal failure must prevent termination")
        try check(!session.retrySaving(), "A still-broken journal must not falsely report save success")
        try check(try FileManager.default.contentsOfDirectory(atPath: journal.path).isEmpty, "Fixture obstruction must still be an empty directory")
        try FileManager.default.removeItem(at: journal)
        try FileManager.default.moveItem(at: heldJournal, to: journal)
        try check(session.retrySaving() && !session.isSavePending, "Restoring the journal path must allow save retry")
        let repaired = try session.archive.recover(recordingID: recordingID)
        try check(repaired.journalNeedsRetry == false && repaired.tracks.first?.frameCount == 9_600,
                  "Retried journal must persist the final frame count and clear its retry marker")
        let allowed = await session.shutdown()
        try check(allowed, "Successful journal repair must permit termination")
        try check(try Data(contentsOf: original) == preserved && AVAudioFile(forReading: original).length == 9_600,
                  "Journal failure and retry must preserve original PCM bytes")
        print("PASS: final journal failure blocks shutdown until repair/retry, preserving original PCM bytes and final metadata")
    }

    @MainActor static func main() async throws {
        let microphones = [
            MeetingMicrophoneDevice(id: "continuity", name: "A iPhone"),
            MeetingMicrophoneDevice(id: "usb", name: "USB microphone"),
            MeetingMicrophoneDevice(id: "built-in", name: "Mac microphone", isBuiltIn: true)
        ]
        try check(MeetingMicrophoneDevice.preferredID(in: microphones) == "built-in", "Prefer the Mac input even when iPhone sorts first")
        try check(MeetingMicrophoneDevice.preferredID(in: Array(microphones.prefix(2))) == nil, "Without a built-in input require explicit selection")
        let callbackWasBackground = await withCheckedContinuation { continuation in
            // Construct from MainActor, then invoke exactly the production tap
            // wrapper on a background queue. Synthetic PCM never opens a device.
            let tap = MeetingMicrophoneTap.make { _, _ in continuation.resume(returning: !Thread.isMainThread) }
            DispatchQueue.global(qos: .userInitiated).async {
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
                buffer.frameLength = 1; buffer.floatChannelData![0][0] = 0
                tap(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
            }
        }
        try check(callbackWasBackground, "The microphone tap must accept background audio callbacks without MainActor isolation")
        let availableMicrophones = MeetingAudioCapture.microphoneDevices()
        if availableMicrophones.contains(where: \.isBuiltIn) {
            try check(availableMicrophones.first?.isBuiltIn == true, "CoreAudio enumerates the built-in input first")
        }
        print("PASS: Mac input preference and background tap callback; device metadata enumeration only, no recording")
        setbuf(stdout, nil)
        guard CommandLine.arguments.count == 2 else { throw SessionCheckError("Disposable fixture root required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let environment = try AppEnvironment.open(.init(
            paths: AppPaths(dataRoot: root.appendingPathComponent("data"), backupRoot: root.appendingPathComponent("backups")),
            keyStore: InMemoryVaultKeyStore(), authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(),
            clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_000)), ids: SequentialIDGenerator(prefix: "fixture")))
        let meetings = MeetingService(repo: environment.repo)
        let first = try meetings.create(title: "가짜 첫 번째 회의")
        let second = try meetings.create(title: "가짜 두 번째 회의")
        let capture = FakeMeetingCapture()
        let session = MeetingRecordingSession(environment: environment, capture: capture)
        let model = MeetingsModel(environment: environment, audio: session)
        session.microphoneID = "fixture-device-never-opened"
        try await waitUntil("initial archive recovery", { !session.isRecovering })
        model.select(first.id)
        model.startRecording(recordOnly: true)
        try await waitUntil("first capture", { session.phase == .recording })
        let firstRecording = session.recordingID!
        model.notes = "녹음 중 첫 회의에 작성한 메모"
        model.select(second.id)
        try check(model.selected?.id == second.id && session.meetingID == first.id && session.phase == .recording,
                  "Selecting another meeting must retain the original capture owner")
        try check(try meetings.meeting(id: first.id)?.notes == "녹음 중 첫 회의에 작성한 메모",
                  "Changing selection must save the first meeting's notes")
        model.notes = "두 번째 회의의 화면 이탈 메모"
        try check(model.leaveScreen(), "Leaving the meeting screen must save notes")
        try check(session.meetingID == first.id && session.phase == .recording && capture.stops == 0,
                  "Leaving the screen must not stop or rebind recording")
        try check(try meetings.meeting(id: second.id)?.notes == "두 번째 회의의 화면 이탈 메모",
                  "Screen exit must preserve the selected meeting's notes")
        model.notes = "새 회의를 만들기 직전 두 번째 회의 메모"
        model.create()
        let createdMeetingID = model.selected!.id
        try check(createdMeetingID != first.id && createdMeetingID != second.id && session.meetingID == first.id && session.phase == .recording,
                  "Creating a meeting must change only selection, not active capture ownership")
        try check(try meetings.meeting(id: second.id)?.notes == "새 회의를 만들기 직전 두 번째 회의 메모",
                  "Creating a meeting must save the preceding draft")
        model.notes = "새 회의의 독립 메모"
        try check(model.leaveScreen(), "New meeting notes must be saved on exit")
        model.select(first.id)
        try check(model.notes == "녹음 중 첫 회의에 작성한 메모" && session.recordingID == firstRecording && session.phase == .recording,
                  "Returning to the recording's meeting must preserve notes and capture identity")
        try check(try meetings.meeting(id: createdMeetingID)?.notes == "새 회의의 독립 메모", "New meeting must retain its own notes")
        print("PASS: actual MeetingsModel selection/create/leaveScreen keep recording alive and preserve each meeting's notes")
        session.start(meeting: second, recordOnly: true) // selection changes cannot rebind an active session
        try check(session.meetingID == first.id && session.recordingID == firstRecording && session.meetingTitle == first.title,
                  "Active recording must stay attached to its original meeting")
        try check(capture.starts.count == 1 && capture.starts.first?.meeting == first.id, "Only one capture may start")
        session.stop(); session.stop()
        let firstShutdown = await session.shutdown()
        let secondShutdown = await session.shutdown()
        try check(firstShutdown, "Shutdown must drain the original recording")
        try check(secondShutdown, "Repeated shutdown must be idempotent")
        try check(capture.stops == 1, "Duplicate stop/shutdown must share one capture stop")
        try check(try session.store.recordings(meetingID: second.id).isEmpty, "Second meeting must not receive the first meeting's recording")
        let firstTracks = try session.store.tracks(recordingID: firstRecording)
        try check(firstTracks.count == 1 && firstTracks[0].fileState == .available, "Stopped source track must be available in DB")
        let firstURL = try session.archive.audioURL(recordingID: firstRecording, track: .microphone)
        try check(try AVAudioFile(forReading: firstURL).length == 9_600, "Record-only mode must persist all fixture PCM")
        print("PASS: fixed meeting ownership, record-only PCM persistence and idempotent stop/shutdown")

        model.select(second.id)
        model.startRecording(recordOnly: true)
        try await waitUntil("second capture", { session.phase == .recording })
        let secondRecording = session.recordingID!
        try capture.sendLateEvents(from: 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        try check(session.phase == .recording && session.meetingID == second.id && session.recordingID == secondRecording,
                  "Late old-session errors must not stop or rebind the new recording")
        try check(session.levels[MeetingAudioTrackID.system.rawValue] != 99 && session.elapsed < 1,
                  "Late old-session meters/PCM must not mutate the new session")
        try check(session.captureMessage != "fake old session failure", "Old error must not reach current session")
        session.stop()
        try await waitUntil("second stop", { session.phase == .idle })
        try await waitUntil("missing model finalization", { !session.isFinalizing })
        try check(session.finalMessage?.contains("모델") == true, "Missing final models must be visible and leave source audio retryable")
        let secondURL = try session.archive.audioURL(recordingID: secondRecording, track: .microphone)
        try check(try AVAudioFile(forReading: secondURL).length == 9_600, "Missing models must not discard source PCM")
        try check(try session.store.recordings(meetingID: first.id).count == 1 && session.store.recordings(meetingID: second.id).count == 1,
                  "Each stopped recording must remain attached to its own meeting")
        print("PASS: obsolete callback rejection and model-free original preservation with retry message")

        let reopened = MeetingRecordingSession(environment: environment, capture: FakeMeetingCapture())
        try await waitUntil("journal recovery", { reopened.contentRevision > 0 })
        try check(reopened.phase == .idle && reopened.recordingID == nil, "Recovery must never resume capture")
        try check(try reopened.store.tracks(recordingID: firstRecording).allSatisfy { $0.fileState == .available }, "Relaunch should reconcile archived audio")
        try check(try Data(contentsOf: firstURL).count > 0 && Data(contentsOf: secondURL).count > 0, "Recovery must preserve both originals")
        print("PASS: relaunch reconciliation preserves separate archives without activating capture")

        let sourceBytes = try Data(contentsOf: secondURL)
        let failedOrder = FakeInferenceOrder()
        do {
            try await MeetingPostProcessing.run(recordingID: secondRecording, store: session.store, archive: session.archive,
                models: session.modelStore, preferences: session.preferences,
                transcriber: FakeFileTranscriber(failedOrder), speakerEngine: FakeFileDiarizer(failedOrder, fails: true), progress: { _ in })
            throw SessionCheckError("Injected diarization failure must escape")
        } catch is SessionCheckError { throw SessionCheckError("Post-processing did not follow the injected failure/unload contract") }
        catch { }
        let failedSteps = await failedOrder.steps
        try check(failedSteps == ["transcribe", "unload-transcriber", "diarize", "unload-speaker"], "Large model must unload before diarization even on failure")
        let runs = try session.store.runs(meetingID: second.id)
        let refined = runs.first { $0.stage == .refined && $0.status == .completed }!
        try check(runs.contains { $0.stage == .diarized && $0.status == .failed }, "Diarization failure must retain a failed, independent version")
        let originalSegment = try session.store.segments(runID: refined.id).first!
        try check(originalSegment.isFinal && originalSegment.originalText == "가짜 정밀 전사 원문", "Completed refined text must survive speaker failure")
        let edited = try session.store.editSegment(id: originalSegment.id, expectedRevision: originalSegment.revision, text: "사용자 검토 수정")
        let successfulOrder = FakeInferenceOrder()
        try await MeetingPostProcessing.run(recordingID: secondRecording, store: session.store, archive: session.archive,
            models: session.modelStore, preferences: session.preferences,
            transcriber: FakeFileTranscriber(successfulOrder), speakerEngine: FakeFileDiarizer(successfulOrder, fails: false), progress: { _ in })
        let afterRuns = try session.store.runs(meetingID: second.id)
        try check(afterRuns.filter { $0.stage == .refined && $0.status == .completed }.count == 2, "Retry must create a new refined version")
        let diarized = afterRuns.first { $0.stage == .diarized && $0.status == .completed }!
        try check(try session.store.segments(runID: diarized.id).first?.speakerID != nil, "Successful fake speaker stage must preserve the attribution")
        try check(try session.store.segment(id: edited.id)?.text == "사용자 검토 수정", "Retry must preserve edits in the older refined version")
        try check(try Data(contentsOf: secondURL) == sourceBytes, "Post-processing must never alter original PCM")
        print("PASS: sequential inference unload, refined result retained on diarization failure and retry preserves user edits/original bytes")

        let cancelledCapture = FakeMeetingCapture()
        let cancelledSession = MeetingRecordingSession(environment: environment, capture: cancelledCapture)
        cancelledSession.microphoneID = "fixture-device-never-opened"
        cancelledSession.start(meeting: first, recordOnly: true)
        cancelledSession.stop()
        let cancelledShutdown = await cancelledSession.shutdown()
        try check(cancelledShutdown && cancelledSession.phase == .idle && cancelledCapture.starts.isEmpty,
                  "Immediate cancellation must not activate capture after asynchronous initialization")
        print("PASS: startup cancellation drains without late capture activation")
        _ = await reopened.shutdown()
        _ = await session.shutdown()
        try await checkDatabaseSaveRetry(at: root.appendingPathComponent("db-save-failure"))
        try await checkJournalSaveRetry(at: root.appendingPathComponent("journal-save-failure"))
        print("9 native session suites passed using the actual meeting model, synthetic PCM and fake inference/temporary accounts; no real capture, inference, download or network.")
    }
}
#endif
