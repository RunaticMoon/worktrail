#if os(macOS)
import AVFoundation
import Foundation
import Observation
import Speech

enum MeetingSpeechError: LocalizedError {
    case busy, unavailable, koreanUnsupported, modelNotInstalled, invalidFile, emptyTranscript

    var errorDescription: String? {
        switch self {
        case .busy: return "진행 중인 음성 작업을 마치거나 취소해 주세요."
        case .unavailable: return "이 Mac은 Apple의 로컬 음성 인식을 지원하지 않습니다. 전사문을 직접 입력할 수 있습니다."
        case .koreanUnsupported: return "현재 macOS에서 한국어 로컬 음성 모델을 사용할 수 없습니다. macOS를 업데이트하거나 전사문을 직접 입력해 주세요."
        case .modelNotInstalled: return "한국어 모델이 설치되지 않았습니다. ‘한국어 모델 준비’를 먼저 실행해 주세요."
        case .invalidFile: return "읽을 수 있는 로컬 음성 파일을 선택해 주세요."
        case .emptyTranscript: return "인식한 한국어 음성이 없습니다. 음량과 파일을 확인한 뒤 다시 시도해 주세요."
        }
    }
}

/// macOS 26's SpeechTranscriber always performs recognition on this device.
/// Only the explicitly requested model installation uses the network. Audio files
/// are streamed by SpeechAnalyzer and never passed to a network or AI provider.
@Observable @MainActor final class MeetingSpeechTranscriber {
    private(set) var isPreparing = false
    private(set) var isTranscribing = false
    private(set) var isModelReady = false
    private(set) var statusMessage: String?
    private(set) var downloadProgress: Double?

    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var resultsTask: Task<String, Error>?
    @ObservationIgnored private var installationTask: Task<Void, Error>?
    @ObservationIgnored private var installationProgress: Progress?
    @ObservationIgnored private var progressObservation: NSKeyValueObservation?
    @ObservationIgnored private var cancellationRequested = false

    /// Inspect capabilities without downloading assets or requesting microphone access.
    func refreshAvailability() async {
        guard !isPreparing, !isTranscribing else { return }
        do {
            let locale = try await koreanLocale()
            let installed = await SpeechTranscriber.installedLocales.contains(locale)
            guard !isPreparing, !isTranscribing else { return }
            isModelReady = installed
            statusMessage = isModelReady ? "한국어 모델 준비됨 · 음성 인식은 이 Mac에서 실행됩니다."
                : "한국어 모델 준비가 필요합니다. 최초 다운로드에는 인터넷이 필요합니다."
        } catch {
            guard !isPreparing, !isTranscribing else { return }
            isModelReady = false
            statusMessage = error.localizedDescription
        }
    }

    /// Called only by the user's model-prepare action, separate from transcription.
    func prepareKoreanModel() async throws {
        guard !isPreparing, !isTranscribing else { throw MeetingSpeechError.busy }
        isPreparing = true
        cancellationRequested = false
        statusMessage = "한국어 모델을 확인하는 중…"
        defer {
            isPreparing = false
            installationTask = nil
            installationProgress = nil
            progressObservation = nil
            downloadProgress = nil
        }
        do {
            let locale = try await koreanLocale()
            try checkCancellation()
            let module = SpeechTranscriber(locale: locale, preset: .transcription)
            // Reserve only our chosen language. Never evict other apps' languages.
            _ = try await AssetInventory.reserve(locale: locale)
            try checkCancellation()
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try checkCancellation()
                statusMessage = "한국어 음성 모델 다운로드 중… 음성 파일은 전송하지 않습니다."
                installationProgress = request.progress
                progressObservation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor [weak self] in
                        guard self?.isPreparing == true else { return }
                        self?.downloadProgress = fraction
                    }
                }
                let task = Task { try await request.downloadAndInstall() }
                installationTask = task
                try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    request.progress.cancel()
                    task.cancel()
                }
            }
            try checkCancellation()
            isModelReady = await SpeechTranscriber.installedLocales.contains(locale)
            try checkCancellation()
            guard isModelReady else { throw MeetingSpeechError.modelNotInstalled }
            statusMessage = "한국어 모델 준비됨 · 음성 인식은 이 Mac에서 실행됩니다."
        } catch {
            statusMessage = cancellationRequested || error is CancellationError
                ? "모델 준비를 취소했습니다." : error.localizedDescription
            throw error
        }
    }

    /// Uses the framework's file input so long meetings aren't loaded as one PCM array.
    /// Missing models fail clearly; this method never initiates a download.
    func transcribe(fileURL: URL) async throws -> String {
        guard !isPreparing, !isTranscribing else { throw MeetingSpeechError.busy }
        guard fileURL.isFileURL else { throw MeetingSpeechError.invalidFile }
        isTranscribing = true
        cancellationRequested = false
        statusMessage = "이 Mac에서 한국어 음성을 인식하는 중…"
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { fileURL.stopAccessingSecurityScopedResource() }
            isTranscribing = false
            analyzer = nil
            resultsTask = nil
        }
        do {
            let locale = try await koreanLocale()
            try checkCancellation()
            isModelReady = await SpeechTranscriber.installedLocales.contains(locale)
            guard isModelReady else { throw MeetingSpeechError.modelNotInstalled }
            try checkCancellation()
            let audioFile = try AVAudioFile(forReading: fileURL)
            guard audioFile.length > 0 else { throw MeetingSpeechError.emptyTranscript }
            let module = SpeechTranscriber(locale: locale, preset: .transcription)
            let session = SpeechAnalyzer(modules: [module])
            analyzer = session
            let task = Task<String, Error> {
                var paragraphs: [String] = []
                for try await result in module.results {
                    try Task.checkCancellation()
                    if result.isFinal {
                        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { paragraphs.append(text) }
                    }
                }
                return paragraphs.joined(separator: "\n")
            }
            resultsTask = task
            let text = try await withTaskCancellationHandler {
                try await session.start(inputAudioFile: audioFile, finishAfterFile: true)
                return try await task.value
            } onCancel: {
                task.cancel()
                Task { await session.cancelAndFinishNow() }
            }
            try checkCancellation()
            guard !text.isEmpty else { throw MeetingSpeechError.emptyTranscript }
            statusMessage = "한국어 전사 완료 · 전사문을 확인하고 수정할 수 있습니다."
            return text
        } catch {
            resultsTask?.cancel()
            if let analyzer { await analyzer.cancelAndFinishNow() }
            statusMessage = cancellationRequested || error is CancellationError
                ? "음성 인식을 취소했습니다. 원본 파일은 유지됩니다." : error.localizedDescription
            throw error
        }
    }

    func cancel() {
        guard isPreparing || isTranscribing else { return }
        cancellationRequested = true
        installationProgress?.cancel()
        installationTask?.cancel()
        resultsTask?.cancel()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        statusMessage = "음성 작업을 취소하는 중…"
    }

    private func koreanLocale() async throws -> Locale {
        guard SpeechTranscriber.isAvailable else { throw MeetingSpeechError.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ko-KR")) else {
            throw MeetingSpeechError.koreanUnsupported
        }
        return locale
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancellationRequested { throw CancellationError() }
    }
}
#endif
