#if os(macOS)
import AVFoundation
import Foundation
import WorkLogCore

private struct FinalizationCheckError: Error {
    let message: String
}

private actor FinalizationCallOrder {
    private(set) var steps: [String] = []
    func add(_ step: String) { steps.append(step) }
}

private actor FinalizationTranscriber: MeetingFileTranscribing {
    let order: FinalizationCallOrder
    let fails: Bool
    let cancelled: Bool
    init(_ order: FinalizationCallOrder, fails: Bool = false, cancelled: Bool = false) {
        self.order = order; self.fails = fails; self.cancelled = cancelled
    }
    func transcribe(samples: [Float], language: String?) async throws -> [MeetingRecognizedSpan] {
        await order.add("transcribe")
        if cancelled { throw CancellationError() }
        if fails {
            throw MeetingOperationFailure(phase: .modelLoading, reason: .other,
                errorDomain: .posix, errorCode: Int(ENOMEM))
        }
        return [.init(start: 0, end: Double(samples.count) / 16_000, text: "가짜 정밀 전사 보존 원문")]
    }
    func unload() async { await order.add("unload-transcriber") }
}

private actor FinalizationDiarizer: MeetingFileDiarizing {
    let order: FinalizationCallOrder
    let cancelled: Bool
    let beforeFailure: @Sendable () throws -> Void
    init(_ order: FinalizationCallOrder, cancelled: Bool = false,
         beforeFailure: @escaping @Sendable () throws -> Void = {}) {
        self.order = order; self.cancelled = cancelled; self.beforeFailure = beforeFailure
    }
    func diarize(samples: [Float], progress: (@Sendable (Double) -> Void)?) async throws -> MeetingDiarizationResult {
        await order.add("diarize")
        if cancelled { throw CancellationError() }
        try beforeFailure()
        // Deliberately private text must never become a message or diagnostic field.
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM),
            userInfo: [NSLocalizedDescriptionKey: "fake private /tmp/transcript-and-model-path"])
    }
    func unload() async { await order.add("unload-speaker") }
}

private func finalizationCheck(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw FinalizationCheckError(message: message) }
}

private func finalizationFailure(_ action: () async throws -> Void) async throws -> MeetingFinalizationFailure {
    do { try await action() }
    catch let failure as MeetingFinalizationFailure { return failure }
    throw FinalizationCheckError(message: "Expected a structured finalization failure")
}

/// Included by the native session harness. It opens only disposable accounts and
/// generated PCM; inference/model-loading/network are replaced by explicit fakes.
@MainActor func checkMeetingFinalizationFailures(at root: URL) async throws {
    let environment = try AppEnvironment.open(.init(
        paths: AppPaths(dataRoot: root.appendingPathComponent("data"), backupRoot: root.appendingPathComponent("backups")),
        keyStore: InMemoryVaultKeyStore(), authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(),
        clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_000)), ids: SequentialIDGenerator(prefix: "finalization-fixture")))
    let meetings = MeetingService(repo: environment.repo)
    let meeting = try meetings.create(title: "가짜 최종 처리 실패 회의", transcript: "이전 수동 전사", notes: "보존할 수동 메모")
    let store = MeetingAudioStore(repo: environment.repo)
    let recording = try store.createRecording(meetingID: meeting.id)
    let archive = MeetingAudioArchive(root: root.appendingPathComponent("audio"))
    let folder = archive.root.appendingPathComponent("fixture")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let audio = folder.appendingPathComponent("original.caf")
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3_200)!
    buffer.frameLength = 3_200
    for index in 0..<3_200 { buffer.floatChannelData![0][index] = sin(Float(index) * 0.05) * 0.1 }
    do {
        let file = try AVAudioFile(forWriting: audio, settings: format.settings)
        try file.write(from: buffer)
    }
    let original = try Data(contentsOf: audio)
    let track = try store.addTrack(recordingID: recording.id, kind: .imported,
        relativePath: "fixture/original.caf", sampleRate: 16_000, channels: 1)
    _ = try store.updateTrack(id: track.id, expectedRevision: track.revision, fileState: .available, duration: 0.2)
    _ = try store.updateRecordingState(id: recording.id, expectedRevision: recording.revision, state: .completed)
    let models = MeetingLocalModelStore(root: root.appendingPathComponent("models"))
    let preferences = MeetingAudioPreferences()

    let firstOrder = FinalizationCallOrder()
    let first = try await finalizationFailure {
        try await MeetingPostProcessing.run(recordingID: recording.id, store: store, archive: archive,
            models: models, preferences: preferences, transcriber: FinalizationTranscriber(firstOrder, fails: true),
            speakerEngine: FinalizationDiarizer(firstOrder), progress: { _ in })
    }
    try finalizationCheck(first.phase == .refined && first.retryRefinedRunID == nil,
        "First-stage failure must never suggest a completed refined source")
    try finalizationCheck(first.diagnostic.phase == .modelLoading && first.diagnostic.errorCode == Int(ENOMEM),
        "Finalization stage must preserve the more precise sanitized model-loading diagnostic")
    try finalizationCheck(first.message.contains("정밀 전사만") && !first.message.contains("화자 분리만 재시도")
        && !first.message.contains("완료된 정밀 전사"), "First-stage retry message must match its actual state")
    let firstSteps = await firstOrder.steps
    try finalizationCheck(firstSteps == ["transcribe", "unload-transcriber"], "Failed refined stage must unload without starting speaker inference")
    try finalizationCheck(try store.runs(meetingID: meeting.id).allSatisfy { $0.status == .failed },
        "First-stage failure must have no completed run")

    let finalDescriptor = try await models.descriptor(for: .final)
    let missingSpeakerModels = MeetingLocalModelStore(root: root.appendingPathComponent("missing-speaker"), descriptors: [finalDescriptor])
    let preparationOrder = FinalizationCallOrder()
    let preparation = try await finalizationFailure {
        try await MeetingPostProcessing.run(recordingID: recording.id, store: store, archive: archive,
            models: missingSpeakerModels, preferences: preferences, transcriber: FinalizationTranscriber(preparationOrder),
            speakerEngine: FinalizationDiarizer(preparationOrder), progress: { _ in })
    }
    guard let sourceID = preparation.retryRefinedRunID, let refined = try store.run(id: sourceID) else {
        throw FinalizationCheckError(message: "Speaker preparation failure must retain its persisted completed source")
    }
    try finalizationCheck(preparation.phase == .diarization && refined.status == .completed
        && preparation.message.contains("화자 분리만 재시도") && preparation.message.contains("모델 준비"),
        "Preparation failures after refinement must offer a valid speaker-only retry with model remedy")
    let refinedSegments = try store.segments(runID: sourceID)
    try finalizationCheck(refinedSegments.first?.originalText == "가짜 정밀 전사 보존 원문", "Persisted refined transcript must survive speaker preparation failure")

    let retryOrder = FinalizationCallOrder()
    let retry = try await finalizationFailure {
        try await MeetingPostProcessing.run(recordingID: recording.id, store: store, archive: archive,
            models: models, preferences: preferences, mode: .diarizationOnly, sourceRunID: sourceID,
            transcriber: FinalizationTranscriber(retryOrder), speakerEngine: FinalizationDiarizer(retryOrder), progress: { _ in })
    }
    let retrySteps = await retryOrder.steps
    try finalizationCheck(retry.phase == .diarization && retry.retryRefinedRunID == sourceID
        && retrySteps == ["diarize", "unload-speaker"], "Speaker-only failure must reuse its exact refined source without Whisper")
    try finalizationCheck(retry.diagnostic.errorCode == Int(ENOMEM) && !retry.message.contains("private")
        && !retry.message.contains("/tmp/"), "Speaker failure must retain safe codes without leaking private error text")

    let priorOrder = FinalizationCallOrder()
    let prior = try await finalizationFailure {
        try await MeetingPostProcessing.run(recordingID: recording.id, store: store, archive: archive,
            models: models, preferences: preferences, mode: .refinedOnly, transcriber: FinalizationTranscriber(priorOrder, fails: true),
            speakerEngine: FinalizationDiarizer(priorOrder), progress: { _ in })
    }
    try finalizationCheck(prior.phase == .refined && prior.retryRefinedRunID == nil,
        "An unrelated older completed run must not turn a new refinement failure into a speaker retry")

    var changedPreferences = preferences; changedPreferences.vadEnabled.toggle()
    let staleOrder = FinalizationCallOrder()
    let stale = try await finalizationFailure {
        try await MeetingPostProcessing.run(recordingID: recording.id, store: store, archive: archive,
            models: models, preferences: changedPreferences, mode: .diarizationOnly, sourceRunID: sourceID,
            transcriber: FinalizationTranscriber(staleOrder), speakerEngine: FinalizationDiarizer(staleOrder), progress: { _ in })
    }
    let staleSteps = await staleOrder.steps
    try finalizationCheck(stale.retryRefinedRunID == nil && staleSteps.isEmpty && stale.message.contains("정밀 전사만")
        && !stale.message.contains("화자 분리만 재시도"), "Mismatched settings must fail before inference and require new refinement")
    let staleRevision = try await MeetingPostProcessing.reusableRefinedRun(recordingID: recording.id, store: store,
        archive: archive, models: models, preferences: preferences, sourceRunID: sourceID, expectedRevision: refined.revision + 1)
    try finalizationCheck(staleRevision == nil, "Retry context must reject a different persisted revision")
    let changedDescriptor = MeetingModelDescriptor(role: .final, modelID: finalDescriptor.modelID,
        revision: "fixture-changed-model-revision", license: finalDescriptor.license,
        attribution: finalDescriptor.attribution, files: finalDescriptor.files)
    let changedModels = MeetingLocalModelStore(root: root.appendingPathComponent("changed-model"), descriptors: [changedDescriptor])
    let staleModel = try await MeetingPostProcessing.reusableRefinedRun(recordingID: recording.id, store: store,
        archive: archive, models: changedModels, preferences: preferences, sourceRunID: sourceID)
    try finalizationCheck(staleModel == nil, "Retry context must reject a different model revision")

    let changedAudioOrder = FinalizationCallOrder()
    let changedAudio = try await finalizationFailure {
        try await MeetingPostProcessing.run(recordingID: recording.id, store: store, archive: archive,
            models: models, preferences: preferences, mode: .diarizationOnly, sourceRunID: sourceID,
            transcriber: FinalizationTranscriber(changedAudioOrder),
            speakerEngine: FinalizationDiarizer(changedAudioOrder, beforeFailure: { try (original + Data([0])).write(to: audio) }),
            progress: { _ in })
    }
    try finalizationCheck(changedAudio.retryRefinedRunID == nil && !changedAudio.message.contains("화자 분리만 재시도"),
        "Source fingerprint must be revalidated after a speaker failure")
    try original.write(to: audio)

    let cancelledOrder = FinalizationCallOrder()
    do {
        try await MeetingPostProcessing.run(recordingID: recording.id, store: store, archive: archive,
            models: models, preferences: preferences, mode: .diarizationOnly, sourceRunID: sourceID,
            transcriber: FinalizationTranscriber(cancelledOrder), speakerEngine: FinalizationDiarizer(cancelledOrder, cancelled: true),
            progress: { _ in })
        throw FinalizationCheckError(message: "Expected speaker cancellation")
    } catch is CancellationError { }
    try finalizationCheck(try store.run(id: sourceID)?.status == .completed && store.runs(meetingID: meeting.id).first?.status == .cancelled,
        "Cancellation must stay cancellation and preserve the completed source")

    let cocoaCancelledOrder = FinalizationCallOrder()
    do {
        try await MeetingPostProcessing.run(recordingID: recording.id, store: store, archive: archive,
            models: models, preferences: preferences, mode: .diarizationOnly, sourceRunID: sourceID,
            transcriber: FinalizationTranscriber(cocoaCancelledOrder),
            speakerEngine: FinalizationDiarizer(cocoaCancelledOrder, beforeFailure: {
                throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.userCancelled.rawValue)
            }), progress: { _ in })
        throw FinalizationCheckError(message: "Expected Cocoa user cancellation to remain cancellation")
    } catch is CancellationError { }
    try finalizationCheck(try store.run(id: sourceID)?.status == .completed && store.runs(meetingID: meeting.id).first?.status == .cancelled,
        "SDK user-cancelled NSError must mark only the speaker stage cancelled")

    let editedOrder = FinalizationCallOrder()
    let segment = refinedSegments.first!
    let edited = try await finalizationFailure {
        try await MeetingPostProcessing.run(recordingID: recording.id, store: store, archive: archive,
            models: models, preferences: preferences, mode: .diarizationOnly, sourceRunID: sourceID,
            transcriber: FinalizationTranscriber(editedOrder),
            speakerEngine: FinalizationDiarizer(editedOrder, beforeFailure: {
                _ = try store.editSegment(id: segment.id, expectedRevision: segment.revision, text: "보존할 사용자 수정")
            }), progress: { _ in })
    }
    try finalizationCheck(edited.retryRefinedRunID == nil && !edited.message.contains("화자 분리만 재시도"),
        "Concurrent refined edits must invalidate retry advice after failure")
    try finalizationCheck(try store.segment(id: segment.id)?.text == "보존할 사용자 수정"
        && store.segment(id: segment.id)?.originalText == segment.originalText, "Failure must preserve edited text and original inference text")
    try finalizationCheck(try Data(contentsOf: audio) == original && meetings.meeting(id: meeting.id)?.notes == meeting.notes
        && meetings.meeting(id: meeting.id)?.transcript == meeting.transcript && meetings.meeting(id: meeting.id)?.activeTranscriptRunID == nil,
        "Finalization failure/cancellation must preserve PCM, notes, previous transcript and activation state")
    print("PASS: finalization failures retain precise phase; speaker-only advice requires matching persisted status/source/settings/model/revision; cancellation/original/notes/edits/previous transcript preserved")
}
#endif
