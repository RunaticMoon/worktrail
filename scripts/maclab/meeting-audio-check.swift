#if os(macOS)
import AVFoundation
import Foundation
import WorkLogCore

private struct CheckError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}
private final class Counter: @unchecked Sendable {
    let lock = NSLock()
    private var count = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
private final class ChunkLog: @unchecked Sendable {
    let lock = NSLock()
    private var offsets: [Double] = []
    func record(_ value: Double) { lock.lock(); offsets.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return offsets }
}
private final class FakePermission: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: (@Sendable (Bool) -> Void)?
    func request(_ callback: @escaping @Sendable (Bool) -> Void) { lock.lock(); reply = callback; lock.unlock() }
    var requested: Bool { lock.lock(); defer { lock.unlock() }; return reply != nil }
    func grant() { lock.lock(); let callback = reply; lock.unlock(); callback?(true) }
}

@main struct MeetingAudioCheck {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CheckError(message) }
    }
    static func pcm(rate: Double = 48_000, channels: AVAudioChannelCount = 1, frames: AVAudioFrameCount = 4_800, value: Float = 0.25) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for index in 0..<Int(frames) { buffer.floatChannelData![channel][index] = value + Float(channel) * 0.1 }
        }
        return buffer
    }
    static func packet(_ time: Double, track: MeetingAudioTrackID = .microphone, channels: AVAudioChannelCount = 1) throws -> MeetingCapturedPCM {
        try .copy(track: track, buffer: pcm(channels: channels), relativeStartSeconds: time)
    }
    static func writer(_ archive: MeetingAudioArchive, id: String, onPCM: @escaping @Sendable (MeetingCapturedPCM) -> Void = { _ in }) throws -> MeetingAudioArchiveWriter {
        try MeetingAudioArchiveWriter(archive: archive, recordingID: id, meetingID: "fake-meeting", clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_000)),
                                      onPCM: onPCM, onLevel: { _, _ in }, onFailure: { _ in })
    }
    static func mustThrow(_ body: () throws -> Void, _ message: String) throws {
        do { try body() } catch { return }
        throw CheckError(message)
    }

    static func main() async throws {
        setbuf(stdout, nil)
        let testRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent("archives", isDirectory: true)
        let archive = MeetingAudioArchive(root: testRoot)
        let delivered = Counter()
        let normal = try writer(archive, id: "two-tracks", onPCM: { _ in _ = delivered.increment() })
        let source = pcm()
        let copied = try MeetingCapturedPCM.copy(track: .microphone, buffer: source, relativeStartSeconds: 0.2)
        source.floatChannelData![0][0] = 99 // owned copy must preserve the original sample
        try await normal.appendForImport(copied)
        try await normal.appendForImport(packet(0.5)) // a 0.2 s source discontinuity
        try await normal.appendForImport(packet(0.1, track: .system, channels: 2))
        async let firstStop = normal.finish()
        async let secondStop = normal.finish()
        let (first, second) = await (firstStop, secondStop)
        try check(first.status == .archived && second.status == .archived, "finish must be idempotent")
        try check(first.recordingID == second.recordingID && delivered.value == 3, "all original writes precede preview callbacks")
        let microphone = first.tracks.first { $0.id == .microphone }!
        try check(microphone.frameCount == 9_600 && microphone.startOffset == 0.2 && microphone.gaps.count == 1,
                  "track frame counts/offsets/gaps")
        try check(abs(microphone.gaps[0].duration - 0.2) < 0.00001, "gap duration")
        let micURL = try archive.audioURL(recordingID: first.recordingID, track: .microphone)
        let input = try AVAudioFile(forReading: micURL)
        let original = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 9_600)!
        try input.read(into: original)
        try check(original.floatChannelData![0][0] == 0.25 && input.length == 9_600, "original PCM retained without callback-lifetime aliasing")
        try check((try FileManager.default.attributesOfItem(atPath: micURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "audio permissions must be 0600")
        print("PASS: separate lossless PCM tracks, lifetime-safe copy, offsets/gaps, write-before-preview and idempotent stop")

        let recovered = try archive.recover(recordingID: "two-tracks")
        try check(recovered.tracks.count == 2 && recovered.status == .archived, "normal recovery")
        let unclosed = try writer(archive, id: "unclosed-crash")
        try await unclosed.appendForImport(packet(0))
        let unclosedRecovery = try archive.recover(recordingID: "unclosed-crash")
        try check(unclosedRecovery.tracks.first?.frameCount == 4_800, "CAF must expose saved frames before normal close")
        _ = await unclosed.finish()
        let manifestURL = testRoot.appendingPathComponent("two-tracks/manifest.json")
        var journal = try JSONDecoder().decode(MeetingAudioArchiveSnapshot.self, from: Data(contentsOf: manifestURL))
        journal.status = .pending
        for index in journal.tracks.indices { journal.tracks[index].frameCount = 0 }
        try JSONEncoder().encode(journal).write(to: manifestURL)
        let crash = try archive.recover(recordingID: "two-tracks")
        try check(crash.status == .interrupted && crash.tracks.first { $0.id == .microphone }!.frameCount == 9_600,
                  "recovery must use actual CAF frames after interrupted journal")
        try check(try JSONDecoder().decode(MeetingAudioArchiveSnapshot.self, from: Data(contentsOf: manifestURL)).status == .pending, "recovery must be read-only")
        _ = try archive.acknowledgeRecovery(recordingID: "two-tracks")
        let exported = testRoot.deletingLastPathComponent().appendingPathComponent("exported")
        try archive.export(recordingID: "two-tracks", to: exported)
        try check(try Data(contentsOf: micURL) == Data(contentsOf: exported.appendingPathComponent("microphone.caf")), "export byte identity")
        let broken = testRoot.appendingPathComponent("broken-journal", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: false)
        let brokenManifest = broken.appendingPathComponent("manifest.json")
        try Data("corrupt fixture".utf8).write(to: brokenManifest)
        let isolated = try archive.recoverAvailable()
        try check(isolated.unavailableCount == 1 && isolated.snapshots.contains { $0.recordingID == "two-tracks" },
                  "one corrupt journal must not block unrelated archive recovery")
        try check(try Data(contentsOf: brokenManifest) == Data("corrupt fixture".utf8), "corrupt archive must stay unchanged")
        print("PASS: crash recovery uses actual CAF length, preserves original and exports exact bytes")

        try mustThrow({ _ = try writer(archive, id: "two-tracks") }, "duplicate must not overwrite")
        try mustThrow({ _ = try writer(archive, id: "../outside") }, "path traversal must fail")
        let foreign = testRoot.appendingPathComponent("two-tracks/unrelated.wav")
        try Data("unrelated".utf8).write(to: foreign)
        try mustThrow({ try archive.delete(recordingID: "two-tracks") }, "unknown sibling must block delete")
        try check(FileManager.default.fileExists(atPath: micURL.path), "failed delete must preserve original")
        try FileManager.default.removeItem(at: foreign)
        let symlink = testRoot.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: exported)
        try mustThrow({ _ = try archive.recover(recordingID: "linked") }, "symlink must be rejected")
        try FileManager.default.removeItem(at: symlink)
        try archive.delete(recordingID: "two-tracks")
        try check(FileManager.default.fileExists(atPath: exported.appendingPathComponent("microphone.caf").path), "delete must not touch export")
        print("PASS: duplicate/path/symlink rejection and explicit exact archive deletion")

        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let writes = Counter(), failures = Counter()
        let overflow = try MeetingAudioArchiveWriter(archive: archive, recordingID: "overflow", meetingID: "fake-meeting",
            maximumQueuedPackets: 1, onPCM: { _ in }, onLevel: { _, _ in }, onFailure: { _ in _ = failures.increment() }, writeHook: {
                if writes.increment() == 1 { entered.signal(); _ = release.wait(timeout: .now() + 5) }
            })
        try check(overflow.enqueue(try packet(0)), "first enqueue")
        try check(entered.wait(timeout: .now() + 5) == .success, "fake stalled writer must start")
        try check(overflow.enqueue(try packet(0.1)), "bounded queued packet")
        try check(!overflow.enqueue(try packet(0.2)), "overflow must refuse additional original audio")
        release.signal()
        let overflowResult = await overflow.finish()
        try check(overflowResult.status == .interrupted && overflowResult.error != nil && overflowResult.tracks.first?.frameCount == 9_600,
                  "overflow must drain existing original data and report interruption")
        print("PASS: bounded writer overflow stops explicitly and drains already queued original PCM")

        let ioCount = Counter()
        let disk = try MeetingAudioArchiveWriter(archive: archive, recordingID: "disk-error", meetingID: "fake-meeting",
            onPCM: { _ in }, onLevel: { _, _ in }, onFailure: { _ in }, writeHook: {
                if ioCount.increment() == 2 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
            })
        try await disk.appendForImport(packet(0))
        do { try await disk.appendForImport(packet(0.1)); throw CheckError("injected disk failure should throw") }
        catch is CheckError { throw CheckError("injected disk failure should throw") }
        catch { }
        let diskResult = await disk.finish()
        try check(diskResult.status == .interrupted && diskResult.tracks.first?.frameCount == 4_800, "disk failure preserves saved PCM")
        let format = try writer(archive, id: "format-change")
        try await format.appendForImport(packet(0))
        do { try await format.appendForImport(packet(0.1, channels: 2)); throw CheckError("format change must throw") }
        catch is CheckError { throw CheckError("format change must throw") }
        catch { }
        let formatResult = await format.finish()
        try check(formatResult.status == .interrupted && formatResult.tracks.first?.frameCount == 4_800, "format change preserves original and interrupts")
        print("PASS: disk-full and input-format-change failures preserve already saved PCM")

        let file = exported.appendingPathComponent("microphone.caf")
        let before = try Data(contentsOf: file)
        let chunks = ChunkLog()
        try await MeetingPCMReader.readChunks(url: file, seconds: 0.05) { chunk in
            chunks.record(chunk.relativeStartSeconds)
            let samples = try MeetingPCMReader.convert(chunk.buffer)
            try check(abs(samples.count - 800) < 3, "resampled output should retain duration: \(samples.count)")
            try check(samples.dropFirst(32).dropLast(32).allSatisfy { abs($0 - 0.25) < 0.01 }, "resampling fake constant signal away from filter boundaries")
        }
        try check(chunks.values.count == 4 && abs(chunks.values.last! - 0.15) < 0.00001, "file chunks retain source frame timestamps")
        try check(try Data(contentsOf: file) == before, "read/convert must never change external source")
        let stereo = try MeetingPCMReader.convert(pcm(channels: 2))
        try check(abs(stereo.count - 1_600) < 3 && stereo.allSatisfy(\.isFinite), "stereo to mono resampling")
        print("PASS: bounded file reader, source timestamps, 16 kHz mono conversion and source immutability")

        let emptyCapture = MeetingAudioCapture()
        let emptyFirst = await emptyCapture.stop()
        let emptySecond = await emptyCapture.stop()
        try check(emptyFirst == nil && emptySecond == nil, "stop before start must be harmless and idempotent")
        print("PASS: capture owner repeated stop before activation; no device or permission request")

        let permission = FakePermission()
        let authorization = MeetingCaptureAuthorizationWait()
        let permissionTask = Task { try await authorization.wait(request: permission.request) }
        for _ in 0..<1_000 {
            if permission.requested { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try check(permission.requested, "fake permission callback must be pending")
        permissionTask.cancel()
        do { _ = try await permissionTask.value; throw CheckError("Pending authorization cancellation must throw") }
        catch is CancellationError { }
        permission.grant() // a late system answer must not resume the completed continuation
        print("PASS: pending authorization cancellation returns before a response and ignores a late grant")
        try await checkConfigurationChanges(archive: archive)
        print("9 fake PCM suites passed. No microphone/system capture, account, model or network was used.")
    }

    static func checkConfigurationChanges(archive: MeetingAudioArchive) async throws {
        typealias Policy = MeetingMicrophoneConfigurationPolicy
        let baseline = Policy.Configuration(deviceID: 42, hardware: .init(sampleRate: 48_000, channelCounts: [1]), format: pcm().format)
        var policy = Policy(expected: baseline)
        let original = try writer(archive, id: "configuration-notifications")
        // The delayed notification from selecting/starting the device must not
        // kill recording, even when it arrives before the first PCM callback.
        for _ in 0..<3 {
            try check(policy.action(current: baseline, engineRunning: true, microphoneBuffers: 0) == .continueRecording,
                      "unchanged startup notifications must leave recording active")
        }
        try await original.appendForImport(packet(0))
        try check(policy.action(current: baseline, engineRunning: false, microphoneBuffers: 1) == .restartSameInput,
                  "output-only engine stop may restart the same unchanged microphone")
        try check(policy.action(current: baseline, engineRunning: true, microphoneBuffers: 1) == .continueRecording,
                  "notification after successful restart must not stop the engine")
        try check(policy.action(current: baseline, engineRunning: false, microphoneBuffers: 1) == .restartExhausted,
                  "without new PCM a repeated stop must fail instead of looping")
        try await original.appendForImport(packet(0.2))
        try check(policy.action(current: baseline, engineRunning: false, microphoneBuffers: 2) == .restartSameInput,
                  "PCM progress permits another same-input recovery")
        let preserved = await original.finish()
        try check(preserved.status == .archived && preserved.tracks.first?.frameCount == 9_600 && preserved.tracks.first?.gaps.count == 1,
                  "notification recovery preserves original frames and real interruption timing")

        let otherDevice = Policy.Configuration(deviceID: 43, hardware: baseline.hardware, format: baseline.format)
        try check(policy.action(current: otherDevice, engineRunning: true, microphoneBuffers: 3) == .deviceUnavailable,
                  "an automatic device switch must never be accepted")
        try check(policy.action(current: nil, engineRunning: false, microphoneBuffers: 3) == .deviceUnavailable,
                  "missing or disconnected devices must stop capture")
        for changed in [
            Policy.Configuration(deviceID: 42, hardware: .init(sampleRate: 44_100, channelCounts: [1]), format: baseline.format),
            Policy.Configuration(deviceID: 42, hardware: .init(sampleRate: 48_000, channelCounts: [2]), format: baseline.format),
            Policy.Configuration(deviceID: 42, hardware: baseline.hardware, format: pcm(rate: 44_100).format),
            Policy.Configuration(deviceID: 42, hardware: baseline.hardware, format: pcm(channels: 2).format),
        ] {
            try check(policy.action(current: changed, engineRunning: true, microphoneBuffers: 3) == .inputChanged,
                      "actual hardware or tapped PCM format changes must preserve and stop")
        }
        let online = Policy.Configuration(deviceID: 42, hardware: baseline.hardware, format: nil)
        var onlinePolicy = Policy(expected: online)
        try check(onlinePolicy.action(current: online, engineRunning: nil, microphoneBuffers: 0) == .continueRecording,
                  "unchanged CoreAudio notifications must also be harmless in online capture")
        let changedOnline = Policy.Configuration(deviceID: 42, hardware: .init(sampleRate: 44_100, channelCounts: [1]), format: nil)
        try check(onlinePolicy.action(current: changedOnline, engineRunning: nil, microphoneBuffers: 0) == .inputChanged,
                  "online capture must still stop for an actual microphone format change")
        print("PASS: delayed/duplicate startup notifications, same-input bounded restart, PCM preservation, device/format-change rejection")
    }
}
#endif
