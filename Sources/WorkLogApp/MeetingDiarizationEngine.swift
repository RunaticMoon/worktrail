#if os(macOS)
import Foundation
import SpeakerKit

struct MeetingSpeakerTurn: Sendable, Equatable {
    let start: Double
    let end: Double
    /// IDs are local to this one window, never a person's real identity.
    let speakerID: Int
}

struct MeetingDiarizationResult: Sendable {
    let turns: [MeetingSpeakerTurn]
    /// Caller may use cosine similarity to propose links between windows.
    /// The SDK does not guarantee a universal same-speaker threshold.
    let centroids: [Int: [Float]]
}

actor MeetingDiarizationEngine {
    private let models: MeetingLocalModelStore
    private var pipeline: SpeakerKit?
    private var busy = false
    private var generation = 0
    private var unloadRequested = false
    init(models: MeetingLocalModelStore) { self.models = models }

    func diarize(samples: [Float], progress: (@Sendable (Double) -> Void)? = nil) async throws -> MeetingDiarizationResult {
        guard !busy else { throw MeetingLocalModelError.busy }
        guard !samples.isEmpty, samples.count <= 120 * 16_000, samples.allSatisfy(\.isFinite) else {
            throw MeetingLocalModelError.invalidAudio
        }
        busy = true
        let expectedGeneration = generation
        defer { busy = false }
        do {
            try Task.checkCancellation()
            let speakerKit = try await loadedPipeline()
            guard generation == expectedGeneration else { throw CancellationError() }
            let result = try await speakerKit.diarize(
                audioArray: samples,
                options: PyannoteDiarizationOptions(useExclusiveReconciliation: false, centroidSource: .trainableOnly)
            ) { value in progress?(value.fractionCompleted) }
            try Task.checkCancellation()
            guard generation == expectedGeneration else { throw CancellationError() }
            let duration = Double(samples.count) / 16_000
            let turns = result.segments.flatMap { segment -> [MeetingSpeakerTurn] in
                let start = max(0, Double(segment.startTime)), end = min(duration, Double(segment.endTime))
                guard start.isFinite, end.isFinite, end > start else { return [] }
                return segment.speaker.speakerIds.map { MeetingSpeakerTurn(start: start, end: end, speakerID: $0) }
            }
            let centroids = result.speakerCentroidEmbeddings.filter { !$0.value.isEmpty && $0.value.allSatisfy(\.isFinite) }
            await finishUnloadIfRequested()
            return .init(turns: turns, centroids: centroids)
        } catch {
            await finishUnloadIfRequested()
            throw error
        }
    }

    func unload() async {
        generation += 1
        unloadRequested = true
        if !busy { await finishUnloadIfRequested() }
    }

    private func finishUnloadIfRequested() async {
        guard unloadRequested else { return }
        unloadRequested = false
        let old = pipeline; pipeline = nil
        await old?.unloadModels()
    }

    private func loadedPipeline() async throws -> SpeakerKit {
        if let pipeline { return pipeline }
        let directory = try await models.verifiedDirectory(for: .diarization)
        try Task.checkCancellation()
        let config = PyannoteConfig(modelToken: "", modelFolder: directory.appendingPathComponent("model").path,
                                   download: false, downloadRevision: "556fc52a13327837688f02289457cded017802e9",
                                   load: true, verbose: false, concurrentSegmenterWorkers: 1,
                                   concurrentEmbedderWorkers: 1)
        let speakerKit = try await SpeakerKit(config)
        do { try Task.checkCancellation() } catch { await speakerKit.unloadModels(); throw error }
        pipeline = speakerKit
        return speakerKit
    }
}
#endif
