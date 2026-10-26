#if os(macOS)
import AVFoundation
import Foundation

struct MeetingPCMFileChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    /// Relative to the source file, before adding the archive track's offset/gaps.
    let relativeStartSeconds: TimeInterval
    var duration: TimeInterval { Double(buffer.frameLength) / buffer.format.sampleRate }
}

enum MeetingPCMReader {
    /// Inference-only resampling. The archive always receives the unmodified PCM.
    /// Call from the fixed preview consumer, never from the real-time audio callback.
    static func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: buffer.format, to: target) else { throw MeetingAudioArchiveError.invalidPCM }
        let capacity = ceil(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 64
        guard capacity <= 30 * 16_000 + 64,
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(capacity)) else { throw MeetingAudioArchiveError.invalidPCM }
        // A self-contained chunk uses the converter's zero-latency normal mode.
        // `.none` adds filter delay to every chunk and changes its timestamp span.
        converter.primeMethod = .normal
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, result in
            if supplied { result.pointee = .endOfStream; return nil }
            supplied = true
            result.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        guard status != .error, let channel = output.floatChannelData?[0] else { throw MeetingAudioArchiveError.invalidPCM }
        let expected = Int((Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate).rounded())
        guard Int(output.frameLength) >= expected else { throw MeetingAudioArchiveError.invalidPCM }
        return Array(UnsafeBufferPointer(start: channel, count: expected))
    }

    /// One bounded read and one awaited consumer at a time. AVAudioFile is read-only;
    /// source files, including externally imported files, are never modified.
    static func readChunks(url: URL, seconds: Double = 30,
                           onChunk: @escaping @Sendable (MeetingPCMFileChunk) async throws -> Void) async throws {
        guard url.isFileURL, seconds.isFinite, seconds > 0 else { throw MeetingAudioArchiveError.invalidPath }
        // A detached fixed worker keeps disk reads and conversion off the main actor.
        let worker = Task.detached(priority: .utility) {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            guard format.sampleRate > 0, format.channelCount > 0 else { throw MeetingAudioArchiveError.invalidPCM }
            let frames = min(30, seconds) * format.sampleRate
            // Bound memory as well as time, including multichannel/high-rate inputs.
            let bytesPerFrame = max(1, Int(format.streamDescription.pointee.mBytesPerFrame) * (format.isInterleaved ? 1 : Int(format.channelCount)))
            let capacity = AVAudioFrameCount(min(frames, Double(8 * 1024 * 1024 / bytesPerFrame)))
            guard capacity > 0 else { throw MeetingAudioArchiveError.invalidPCM }
            while file.framePosition < file.length {
                try Task.checkCancellation()
                let start = Double(file.framePosition) / format.sampleRate
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw MeetingAudioArchiveError.invalidPCM }
                try file.read(into: buffer, frameCount: capacity)
                guard buffer.frameLength > 0 else { throw MeetingAudioArchiveError.invalidPCM }
                try await onChunk(MeetingPCMFileChunk(buffer: buffer, relativeStartSeconds: start))
            }
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
#endif
