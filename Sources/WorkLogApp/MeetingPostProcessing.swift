#if os(macOS)
import Foundation
import CryptoKit
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
    var sourceFingerprint: String = ""
    let language = "ko"
    let task = "transcribe"
    let sampleRate = 16_000
    let maximumConcurrentInference = 1
    let automaticDownload = false
    let cloudFallback = false
    let llmCorrection = false
}

enum MeetingProcessingMode { case refinedOnly, refinedAndDiarized, diarizationOnly }

/// Bounded file windows; large-v3 is completely unloaded before SpeakerKit loads.
enum MeetingPostProcessing {
    static func run(recordingID: String, store: MeetingAudioStore, archive: MeetingAudioArchive,
                    models: MeetingLocalModelStore, preferences: MeetingAudioPreferences,
                    mode: MeetingProcessingMode = .refinedAndDiarized, sourceRunID: String? = nil,
                    transcriber: (any MeetingFileTranscribing)? = nil, speakerEngine: (any MeetingFileDiarizing)? = nil,
                    progress: @escaping @Sendable (String) async -> Void) async throws {
        guard let recording = try store.recording(id: recordingID) else { throw WorkLogError.notFound("녹음") }
        let allTracks = try store.tracks(recordingID: recordingID)
        guard !allTracks.isEmpty, allTracks.allSatisfy({ $0.fileState == .available }) else {
            throw WorkLogError.validation("일부 원본 음성이 없거나 준비되지 않았습니다. 원본을 확인한 뒤 재시도하세요.")
        }
        let tracks = allTracks
        let descriptor = try await models.descriptor(for: .final)
        let fingerprint = try sourceFingerprint(tracks, archive: archive)
        let settings = try StableJSON.string(MeetingRunConfiguration(preferences: preferences, stage: "refined", sourceFingerprint: fingerprint))
        let existing = try store.runs(meetingID: recording.meetingID)
        let reusable = try existing.first { run in
            if let sourceRunID, run.id != sourceRunID { return false }
            return MeetingProcessingReuse.isReusable(run, recordingID: recordingID, modelIdentifier: descriptor.modelID,
                modelRevision: descriptor.revision, settingsJSON: settings,
                hasUserEdits: try store.segments(runID: run.id).contains(where: \.isUserEdited))
        }
        let refined: MeetingTranscriptRun
        let total = tracks.reduce(0) { $0 + ($1.duration ?? 0) }
        if mode != .refinedOnly, let reusable {
            refined = reusable
            await progress("완료된 정밀 전사 v\(reusable.version) 재사용 · 원본 해시·모델·설정 검증됨")
        } else {
            guard mode != .diarizationOnly else {
                throw WorkLogError.conflict("저장된 정밀 전사의 원본·모델·설정 또는 수정 상태가 달라 재사용할 수 없습니다. 정밀 전사를 새로 실행해 주세요.")
            }
            if !existing.isEmpty { await progress("일치하는 완료 결과가 없어 정밀 전사를 새 버전으로 실행합니다.") }
            let created = try store.createRun(meetingID: recording.meetingID, recordingID: recordingID, stage: .refined,
                engine: "WhisperKit", modelIdentifier: descriptor.modelID, modelRevision: descriptor.revision, settingsJSON: settings)
            let whisper: any MeetingFileTranscribing = transcriber ?? MeetingWhisperEngine(models: models, profile: .final)
            do {
                for (index, track) in tracks.enumerated() {
                    try Task.checkCancellation()
                    let preceding = tracks.prefix(index).reduce(0) { $0 + ($1.duration ?? 0) }
                    let accumulator = MeetingFinalWindowAccumulator(track: track, run: created, store: store, engine: whisper)
                    try await MeetingPCMReader.readChunks(url: audioURL(track, archive: archive), seconds: 28) { chunk in
                        try Task.checkCancellation()
                        let samples = try MeetingPCMReader.convert(chunk.buffer)
                        try await accumulator.append(samples, at: chunk.relativeStartSeconds)
                        await progress(progressText("정밀 전사", done: preceding + chunk.relativeStartSeconds + Double(samples.count) / 16_000, total: total))
                    }
                    try await accumulator.finish()
                }
                guard try sourceFingerprint(store.tracks(recordingID: recordingID), archive: archive) == fingerprint else {
                    throw WorkLogError.conflict("정밀 전사 도중 원본이 변경되었습니다. 기존 결과와 합치지 않고 원본을 다시 확인해 주세요.")
                }
                refined = try store.finishRun(id: created.id)
            } catch {
                _ = try? store.finishRun(id: created.id, status: error is CancellationError ? .cancelled : .failed)
                await whisper.unload(); throw error
            }
            await whisper.unload()
        }
        guard mode != .refinedOnly else { return }
        try Task.checkCancellation()
        await progress("정밀 전사 저장됨 · 로컬 화자 분리 중…")
        let speakerDescriptor = try await models.descriptor(for: .diarization)
        let diarizationSettings = try StableJSON.string(DiarizationConfiguration(sourceRevision: refined.revision, sourceFingerprint: fingerprint))
        let diarized = try store.createRun(meetingID: recording.meetingID, recordingID: recordingID, stage: .diarized,
            engine: "SpeakerKit + WhisperKit", modelIdentifier: descriptor.modelID + " + " + speakerDescriptor.modelID,
            modelRevision: descriptor.revision + "/" + speakerDescriptor.revision,
            settingsJSON: diarizationSettings, sourceRunID: refined.id)
        let diarizer: any MeetingFileDiarizing = speakerEngine ?? MeetingDiarizationEngine(models: models)
        do {
            for (index, track) in tracks.enumerated() {
                try Task.checkCancellation()
                guard try store.run(id: refined.id)?.revision == refined.revision else {
                    throw WorkLogError.conflict("처리 중 정밀 전사가 수정되었습니다. 새 수정본을 확인해 주세요.")
                }
                let source = try store.segments(runID: refined.id).filter { $0.trackID == track.id }
                let preceding = tracks.prefix(index).reduce(0) { $0 + ($1.duration ?? 0) }
                let accumulator = MeetingDiarizationAccumulator(track: track, run: diarized, segments: source, store: store, engine: diarizer)
                try await MeetingPCMReader.readChunks(url: audioURL(track, archive: archive), seconds: 120) { chunk in
                    try Task.checkCancellation()
                    let samples = try MeetingPCMReader.convert(chunk.buffer)
                    try await accumulator.append(samples, at: chunk.relativeStartSeconds)
                    await progress(progressText("화자 분리", done: preceding + chunk.relativeStartSeconds + Double(samples.count) / 16_000, total: total))
                }
                try await accumulator.finish()
            }
            guard try store.run(id: refined.id)?.revision == refined.revision,
                  try sourceFingerprint(store.tracks(recordingID: recordingID), archive: archive) == fingerprint else {
                throw WorkLogError.conflict("처리 중 원본 또는 전사가 변경되어 결과를 활성화할 수 없습니다.")
            }
            _ = try store.finishRun(id: diarized.id)
        } catch {
            _ = try? store.finishRun(id: diarized.id, status: error is CancellationError ? .cancelled : .failed)
            await diarizer.unload(); throw error
        }
        await diarizer.unload()
    }
    private struct DiarizationConfiguration: Encodable {
        let sourceRevision: Int
        let sourceFingerprint: String
        let speakerLabels = "provisional"
        let chunkSeconds = 120
    }
    private struct SourceIdentity: Encodable {
        let id: String
        let hash: String
        let startOffset: Double
        let duration: Double?
        let interruptions: [MeetingTrackInterruption]
    }
    private static func sourceFingerprint(_ tracks: [MeetingAudioTrack], archive: MeetingAudioArchive) throws -> String {
        let sources = try tracks.map { track -> SourceIdentity in
            let handle = try FileHandle(forReadingFrom: audioURL(track, archive: archive))
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation(); hash.update(data: data)
            }
            return .init(id: track.id, hash: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                startOffset: track.startOffset, duration: track.duration, interruptions: track.interruptions)
        }
        return SHA256.hash(data: Data(try StableJSON.string(sources).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func progressText(_ stage: String, done: Double, total: Double) -> String {
        return total > 0 ? String(format: "%@ · %.0f / %.0f초 · %.0f%% · 취소 가능", stage, min(done, total), total, min(100, done / total * 100))
            : String(format: "%@ · %.0f초 처리 · 전체 길이 확인 중 · 취소 가능", stage, done)
    }

    static func audioURL(_ track: MeetingAudioTrack, archive: MeetingAudioArchive) throws -> URL {
        try archive.resolveTrackURL(relativePath: track.relativePath)
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
