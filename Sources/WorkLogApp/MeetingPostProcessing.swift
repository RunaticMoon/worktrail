#if os(macOS)
import Foundation
import WorkLogCore

protocol MeetingFileTranscribing: Sendable {
    func transcribe(samples: [Float], language: String?) async throws -> [MeetingRecognizedSpan]
    func unload() async
}
extension MeetingWhisperEngine: MeetingFileTranscribing {}
protocol MeetingFileDiarizing: Sendable {
    func diarize(samples: [Float], progress: (@Sendable (Double) -> Void)?) async throws -> MeetingDiarizationResult
    func unload() async
}
extension MeetingDiarizationEngine: MeetingFileDiarizing {}

struct MeetingRunConfiguration: Encodable {
    let preferences: MeetingAudioPreferences
    let stage: String
    let language = "ko"
    let task = "transcribe"
    let sampleRate = 16_000
    let maximumConcurrentInference = 1
    let automaticDownload = false
    let cloudFallback = false
    let llmCorrection = false
}

/// Bounded file windows; large-v3 is completely unloaded before SpeakerKit loads.
enum MeetingPostProcessing {
    static func run(recordingID: String, store: MeetingAudioStore, archive: MeetingAudioArchive,
                    models: MeetingLocalModelStore, preferences: MeetingAudioPreferences,
                    transcriber: (any MeetingFileTranscribing)? = nil, speakerEngine: (any MeetingFileDiarizing)? = nil,
                    progress: @escaping @Sendable (String) async -> Void) async throws {
        guard let recording = try store.recording(id: recordingID) else { throw WorkLogError.notFound("녹음") }
        let tracks = try store.tracks(recordingID: recordingID).filter { $0.fileState == .available }
        guard !tracks.isEmpty else { throw WorkLogError.validation("원본 음성을 찾을 수 없습니다.") }
        let descriptor = try await models.descriptor(for: .final)
        let refined = try store.createRun(meetingID: recording.meetingID, recordingID: recordingID, stage: .refined,
            engine: "WhisperKit", modelIdentifier: descriptor.modelID, modelRevision: descriptor.revision,
            settingsJSON: try StableJSON.string(MeetingRunConfiguration(preferences: preferences, stage: "refined")))
        let whisper: any MeetingFileTranscribing = transcriber ?? MeetingWhisperEngine(models: models, profile: .final)
        do {
            for track in tracks {
                try Task.checkCancellation()
                let url = try audioURL(track, archive: archive)
                let accumulator = MeetingFinalWindowAccumulator(track: track, run: refined, store: store, engine: whisper)
                try await MeetingPCMReader.readChunks(url: url, seconds: 28) { chunk in
                    try Task.checkCancellation()
                    let samples = try MeetingPCMReader.convert(chunk.buffer)
                    try await accumulator.append(samples, at: chunk.relativeStartSeconds)
                }
                try await accumulator.finish()
            }
            _ = try store.finishRun(id: refined.id)
        } catch {
            _ = try? store.finishRun(id: refined.id, status: error is CancellationError ? .cancelled : .failed)
            await whisper.unload(); throw error
        }
        await whisper.unload()
        try Task.checkCancellation()
        await progress("정밀 전사 저장됨 · 로컬 화자 분리 중…")
        let speakerDescriptor = try await models.descriptor(for: .diarization)
        let diarized = try store.createRun(meetingID: recording.meetingID, recordingID: recordingID, stage: .diarized,
            engine: "SpeakerKit + WhisperKit", modelIdentifier: descriptor.modelID + " + " + speakerDescriptor.modelID,
            modelRevision: descriptor.revision + "/" + speakerDescriptor.revision,
            settingsJSON: "{\"speakerLabels\":\"provisional\",\"chunkSeconds\":120}", sourceRunID: refined.id)
        let diarizer: any MeetingFileDiarizing = speakerEngine ?? MeetingDiarizationEngine(models: models)
        do {
            for track in tracks {
                try Task.checkCancellation()
                let source = try store.segments(runID: refined.id).filter { $0.trackID == track.id }
                let accumulator = MeetingDiarizationAccumulator(track: track, run: diarized, segments: source,
                    store: store, engine: diarizer)
                try await MeetingPCMReader.readChunks(url: audioURL(track, archive: archive), seconds: 120) { chunk in
                    try Task.checkCancellation()
                    try await accumulator.append(try MeetingPCMReader.convert(chunk.buffer), at: chunk.relativeStartSeconds)
                }
                try await accumulator.finish()
            }
            _ = try store.finishRun(id: diarized.id)
        } catch {
            // The completed refined run is independent and remains selectable on diarization failure.
            _ = try? store.finishRun(id: diarized.id, status: error is CancellationError ? .cancelled : .failed)
            await diarizer.unload(); throw error
        }
        await diarizer.unload()
    }

    static func audioURL(_ track: MeetingAudioTrack, archive: MeetingAudioArchive) throws -> URL {
        let kind: MeetingAudioTrackID = track.kind == .systemAudio ? .system : .microphone
        let url = try archive.audioURL(recordingID: track.recordingID, track: kind)
        guard url.standardizedFileURL.path == archive.root.appendingPathComponent(track.relativePath).standardizedFileURL.path else {
            throw MeetingAudioArchiveError.invalidPath
        }
        return url
    }
}

private actor MeetingFinalWindowAccumulator {
    let track: MeetingAudioTrack
    let run: MeetingTranscriptRun
    let store: MeetingAudioStore
    let engine: any MeetingFileTranscribing
    private var tail: [Float] = []
    private var merger: MeetingPreviewMerger
    init(track: MeetingAudioTrack, run: MeetingTranscriptRun, store: MeetingAudioStore, engine: any MeetingFileTranscribing) {
        self.track = track; self.run = run; self.store = store; self.engine = engine
        merger = MeetingPreviewMerger(ids: store.repo.ids)
    }
    func append(_ samples: [Float], at fileStart: Double) async throws {
        let offset = fileStart - Double(tail.count) / 16_000
        let window = tail + samples
        let spans = try await engine.transcribe(samples: window, language: "ko")
        try Task.checkCancellation()
        // Merge in file time first: discontinuities are projected only when saving the segment.
        let request = MeetingPreviewRequest(sessionID: run.id, recordingID: track.recordingID, generation: 0,
            trackID: track.id, windowStart: max(0, offset), samples: window)
        let changes = merger.merge(spans, request: request)
        try save(changes)
        tail = Array(window.suffix(32_000))
    }
    func finish() throws { try save(merger.finish()) }
    private func save(_ segments: [MeetingPreviewSegment]) throws {
        _ = try store.checkpointLiveSegments(runID: run.id, trackID: track.id, segments: segments.map {
            MeetingSegmentInput(trackID: track.id, sourceKey: $0.id,
                start: MeetingAudioTimeline.sessionTime(fileTime: $0.start, startOffset: track.startOffset, interruptions: track.interruptions),
                end: MeetingAudioTimeline.sessionTime(fileTime: $0.end, startOffset: track.startOffset, interruptions: track.interruptions),
                text: $0.text, isFinal: $0.stability == .stablePreview)
        }, activePartialKeys: merger.segments.filter { $0.stability == .partial }.map(\.id))
        for gap in merger.drainDiscardedGaps() {
            _ = try store.recordPreviewGap(runID: run.id, trackID: track.id,
                start: MeetingAudioTimeline.sessionTime(fileTime: gap.start, startOffset: track.startOffset, interruptions: track.interruptions),
                end: MeetingAudioTimeline.sessionTime(fileTime: gap.end, startOffset: track.startOffset, interruptions: track.interruptions), reason: gap.reason)
        }
    }
}

private actor MeetingDiarizationAccumulator {
    let track: MeetingAudioTrack
    let run: MeetingTranscriptRun
    let segments: [MeetingTranscriptSegment]
    let store: MeetingAudioStore
    let engine: any MeetingFileDiarizing
    private var centroids: [(key: String, vector: [Float])] = []
    private var saved = Set<String>()
    private var chunkIndex = 0
    private var buffered: [Float] = []
    private var bufferStart: Double = 0
    init(track: MeetingAudioTrack, run: MeetingTranscriptRun, segments: [MeetingTranscriptSegment],
         store: MeetingAudioStore, engine: any MeetingFileDiarizing) {
        self.track = track; self.run = run; self.segments = segments; self.store = store; self.engine = engine
    }
    func append(_ samples: [Float], at fileStart: Double) async throws {
        if buffered.isEmpty { bufferStart = fileStart }
        buffered.append(contentsOf: samples)
        if buffered.count >= 120 * 16_000 {
            let window = Array(buffered.prefix(120 * 16_000))
            buffered.removeFirst(window.count)
            let start = bufferStart; bufferStart += 120
            try await process(window, at: start)
        }
    }
    private func process(_ samples: [Float], at fileStart: Double) async throws {
        let result = try await engine.diarize(samples: samples, progress: nil)
        try Task.checkCancellation()
        var identities: [Int: String] = [:]
        var used = Set<String>()
        for localID in Set(result.turns.map(\.speakerID)).sorted() {
            var key: String?
            if let vector = result.centroids[localID] {
                let scores = centroids.filter { !used.contains($0.key) }.map { ($0.key, Self.cosine($0.vector, vector)) }.sorted { $0.1 > $1.1 }
                if let best = scores.first, best.1 >= 0.85,
                   scores.count == 1 || best.1 - scores[1].1 >= 0.05 { key = best.0 }
                if key == nil, centroids.count < 64 {
                    key = "\(track.id)-cluster-\(centroids.count + 1)"
                    centroids.append((key!, vector))
                }
            }
            let sourceKey = key ?? "\(track.id)-window-\(chunkIndex)-speaker-\(localID)"
            used.insert(sourceKey)
            let speaker = try store.upsertSpeaker(runID: run.id, sourceKey: sourceKey,
                displayName: "화자 \(centroids.firstIndex(where: { $0.key == sourceKey }).map { String($0 + 1) } ?? "미확인") · 추정")
            identities[localID] = speaker.id
        }
        let turns = result.turns.compactMap { turn -> MeetingTimedSpeaker? in
            guard let id = identities[turn.speakerID] else { return nil }
            return .init(start: sessionTime(fileStart + turn.start), end: sessionTime(fileStart + turn.end), id: id)
        }
        let start = sessionTime(fileStart), end = sessionTime(fileStart + Double(samples.count) / 16_000)
        let covered = segments.filter { !saved.contains($0.id) && $0.start >= start && $0.end <= end }
        try save(covered, turns: turns)
        chunkIndex += 1
    }
    func finish() async throws {
        if !buffered.isEmpty {
            let remainder = buffered; buffered = []
            try await process(remainder, at: bufferStart)
        }
        // Window-boundary utterances and unassigned/overlapping speech remain available with unknown speaker.
        try save(segments.filter { !saved.contains($0.id) }, turns: [])
    }
    private func save(_ covered: [MeetingTranscriptSegment], turns: [MeetingTimedSpeaker]) throws {
        guard !covered.isEmpty else { return }
        _ = try store.upsertSegments(runID: run.id, segments: covered.map {
            .init(trackID: track.id, sourceKey: $0.id, start: $0.start, end: $0.end, text: $0.originalText,
                  speakerID: MeetingSpeakerAlignment.speaker(start: $0.start, end: $0.end, turns: turns), isFinal: $0.isFinal)
        })
        saved.formUnion(covered.map(\.id))
    }
    private func sessionTime(_ file: Double) -> Double {
        MeetingAudioTimeline.sessionTime(fileTime: file, startOffset: track.startOffset, interruptions: track.interruptions)
    }
    private static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
        var dot = 0.0, a = 0.0, b = 0.0
        for (x, y) in zip(lhs, rhs) { dot += Double(x * y); a += Double(x * x); b += Double(y * y) }
        return a > 0 && b > 0 ? dot / sqrt(a * b) : -1
    }
}
#endif
