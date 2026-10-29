#if os(macOS)
import CoreML
import Foundation
import WhisperKit
import WorkLogCore

/// One bounded decoder operation at a time. Instances have one fixed model role;
/// the coordinator unloads the live engine before loading the final engine.
actor MeetingWhisperEngine: MeetingPreviewEngine {
    private let models: MeetingLocalModelStore
    let profile: MeetingModelRole
    private var pipeline: MeetingOfflineWhisperKit?
    private var busy = false
    private var generation = 0
    private var unloadRequested = false

    init(models: MeetingLocalModelStore, profile: MeetingModelRole = .live) {
        self.models = models; self.profile = profile
    }

    func transcribe(_ request: MeetingPreviewRequest) async throws -> [MeetingRecognizedSpan] {
        guard request.sampleRate == 16_000 else {
            throw classified(MeetingLocalModelError.invalidAudio, phase: .inference)
        }
        return try await transcribe(samples: request.samples)
    }

    func transcribe(samples: [Float], language: String? = "ko") async throws -> [MeetingRecognizedSpan] {
        guard !busy else { throw classified(MeetingLocalModelError.busy, phase: .inference) }
        guard profile != .diarization, !samples.isEmpty, samples.count <= 30 * 16_000,
              samples.allSatisfy(\.isFinite) else {
            throw classified(MeetingLocalModelError.invalidAudio, phase: .inference)
        }
        busy = true
        let expectedGeneration = generation
        defer { busy = false }
        do {
            try Task.checkCancellation()
            let pipe = try await loadedPipeline()
            guard generation == expectedGeneration else { throw CancellationError() }
            let options = DecodingOptions(verbose: false, task: .transcribe, language: language,
                                          temperature: 0, temperatureFallbackCount: 2,
                                          detectLanguage: language == nil, skipSpecialTokens: true,
                                          withoutTimestamps: false, wordTimestamps: false,
                                          concurrentWorkerCount: 1)
            let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options, callback: { _ in
                Task.isCancelled ? false : nil
            })
            try Task.checkCancellation()
            guard generation == expectedGeneration else { throw CancellationError() }
            let duration = Double(samples.count) / 16_000
            let spans = results.flatMap(\.segments).compactMap { segment -> MeetingRecognizedSpan? in
                let start = max(0, Double(segment.start))
                let end = min(duration, Double(segment.end))
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard start.isFinite, end.isFinite, end > start, !text.isEmpty else { return nil }
                return MeetingRecognizedSpan(start: start, end: end, text: text)
            }
            await finishUnloadIfRequested()
            return spans
        } catch {
            await finishUnloadIfRequested()
            throw classified(error, phase: .inference)
        }
    }

    private func classified(_ error: Error, phase: DiagnosticState) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        let failure = MeetingFailurePresentation.failure(for: error, phase: phase)
        return failure.reason == .cancelled ? CancellationError() : failure
    }

    func unload() async {
        generation += 1
        unloadRequested = true
        if !busy { await finishUnloadIfRequested() }
    }

    private func finishUnloadIfRequested() async {
        guard unloadRequested else { return }
        unloadRequested = false
        let old = pipeline
        pipeline = nil
        await old?.unloadModels()
    }

    private func loadedPipeline() async throws -> MeetingOfflineWhisperKit {
        if let pipeline { return pipeline }
        let directory: URL
        do { directory = try await models.verifiedDirectory(for: profile) }
        catch { throw classified(error, phase: .modelValidation) }
        try Task.checkCancellation()
        let tokenizerDirectory = directory.appendingPathComponent("tokenizer", isDirectory: true)
        // The explicit local factory never falls back to Hub downloads, even for corrupt JSON.
        let localTokenizer: MeetingWhisperTokenizer
        do {
            let tokenizer = try await AutoTokenizerWrapper.from(
                modelFolder: tokenizerDirectory,
                hubApi: HubApiWrapper(downloadBase: tokenizerDirectory, hfToken: ""))
            localTokenizer = try MeetingWhisperTokenizer(tokenizer)
        } catch { throw classified(error, phase: .tokenizer) }
        try Task.checkCancellation()
        let config = WhisperKitConfig(modelFolder: directory.appendingPathComponent("model").path,
                                      tokenizerFolder: tokenizerDirectory,
                                      computeOptions: ModelComputeOptions(melCompute: .cpuAndGPU,
                                                                         audioEncoderCompute: .cpuAndNeuralEngine,
                                                                         textDecoderCompute: .cpuAndNeuralEngine),
                                      verbose: false, prewarm: false, load: false, download: false)
        let pipe: MeetingOfflineWhisperKit
        do { pipe = try await MeetingOfflineWhisperKit(config) }
        catch { throw classified(error, phase: .modelLoading) }
        pipe.tokenizer = localTokenizer
        do {
            try await pipe.loadModels()
            try Task.checkCancellation()
        } catch {
            await pipe.unloadModels()
            throw classified(error, phase: .modelLoading)
        }
        pipeline = pipe
        return pipe
    }
}

/// SDK 1.1.1's default tokenizer loader catches local parse errors then downloads.
/// Override that entry point so future lazy loads also fail closed.
final class MeetingOfflineWhisperKit: WhisperKit {
    override func loadTokenizerIfNeeded() async throws {
        // Both pinned large-v3 models use the multilingual 51,866-token vocabulary.
        guard tokenizer != nil, textDecoder.logitsSize == 51_866 else {
            throw MeetingFailurePresentation.failure(for: MeetingLocalModelError.invalidTokenizer, phase: .tokenizer)
        }
        textDecoder.isModelMultilingual = true
    }
}

/// The public SDK tokenizer wrapper initializer is internal. This small adapter uses
/// its public local factory and WhisperTokenizer protocol without the network fallback.
/// Segment timestamps are used; word timing is intentionally disabled by the engine.
private struct MeetingWhisperTokenizer: WhisperTokenizer {
    let base: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    init(_ base: TokenizerWrapper) throws {
        self.base = base
        func token(_ value: String) throws -> Int {
            guard let id = base.convertTokenToId(value) else { throw MeetingLocalModelError.invalidTokenizer }
            return id
        }
        specialTokens = try SpecialTokens(endToken: token("<|endoftext|>"), englishToken: token("<|en|>"),
                                         noSpeechToken: token("<|nospeech|>"), noTimestampsToken: token("<|notimestamps|>"),
                                         specialTokenBegin: token("<|endoftext|>"), startOfPreviousToken: token("<|startofprev|>"),
                                         startOfTranscriptToken: token("<|startoftranscript|>"), timeTokenBegin: token("<|0.00|>"),
                                         transcribeToken: token("<|transcribe|>"), translateToken: token("<|translate|>"),
                                         whitespaceToken: base.encode(text: " ", addSpecialTokens: false).first ?? 220)
        _ = try token("<|ko|>")
        allLanguageTokens = Set(Constants.languages.values.compactMap { base.convertTokenToId("<|\($0)|>") })
    }
    func encode(text: String) -> [Int] { base.encode(text: text, addSpecialTokens: false) }
    func decode(tokens: [Int]) -> String { base.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }

    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        // Keep complete Unicode sequences together. This method is not used with
        // wordTimestamps:false, but remains well-defined for the public protocol.
        var words: [String] = [], groups: [[Int]] = [], pending: [Int] = []
        for token in tokenIds {
            pending.append(token)
            let text = base.decode(tokens: pending)
            if !text.contains("\u{fffd}") { words.append(text); groups.append(pending); pending = [] }
        }
        if !pending.isEmpty { words.append(base.decode(tokens: pending)); groups.append(pending) }
        return (words, groups)
    }
}
#endif
