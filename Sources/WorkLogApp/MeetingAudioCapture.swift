#if os(macOS)
import AppKit
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import ScreenCaptureKit
import WorkLogCore

struct MeetingMicrophoneDevice: Identifiable, Sendable {
    let id: String
    let name: String
    var isBuiltIn = false

    /// Device names are localized and Continuity microphones may sort first.
    /// Without a built-in input, let the user explicitly choose another device.
    static func preferredID(in devices: [Self]) -> String? { devices.first(where: \.isBuiltIn)?.id }
}
struct MeetingOnlineApplication: Identifiable, Sendable { let id: Int32; let name: String }
enum MeetingCaptureMode: Sendable {
    case microphone(deviceID: String)
    case online(applicationPID: Int32, microphoneDeviceID: String)
}
enum MeetingCaptureEvent: Sendable {
    case started
    case level(track: MeetingAudioTrackID, rms: Float)
    case failed(String)
    case stopped(MeetingAudioArchiveSnapshot)
}

enum MeetingAudioCaptureError: LocalizedError {
    case busy, missingUsageDescription, microphonePermission, screenPermission, missingDevice, missingApplication, invalidFormat
    var errorDescription: String? {
        switch self {
        case .busy: return "이미 녹음을 시작했거나 종료하고 있습니다."
        case .missingUsageDescription: return "마이크 권한 설명이 포함된 WorkLog 앱에서 녹음을 시작해 주세요."
        case .microphonePermission: return "마이크 접근이 허용되지 않았습니다. 시스템 설정의 마이크 권한을 확인해 주세요."
        case .screenPermission: return "선택한 앱의 소리를 녹음하려면 시스템 설정에서 화면 및 시스템 오디오 녹음 권한을 허용해 주세요."
        case .missingDevice: return "선택한 마이크를 찾을 수 없습니다. 다른 장치로 자동 전환하지 않았습니다. 마이크를 다시 선택해 주세요."
        case .missingApplication: return "선택한 온라인 회의 앱이 종료되었거나 캡처 대상에서 사라졌습니다. 앱을 다시 선택해 주세요."
        case .invalidFormat: return "선택한 장치의 PCM 형식을 확인하지 못했습니다. 녹음을 시작하지 않았습니다."
        }
    }
}

/// Owns the session independently of a SwiftUI screen. Permission prompts and device
/// activation happen only in start(), which is called by an explicit user action.
@MainActor final class MeetingAudioCapture {
    private let clock: any MeetingMonotonicClock
    private let wallClock: any Clock
    private var engine: AVAudioEngine?
    private var microphoneTapInstalled = false
    private var stream: SCStream?
    private var streamStartTask: Task<Void, Error>?
    private var sink: MeetingCaptureSink?
    private var writer: MeetingAudioArchiveWriter?
    private var notificationObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var deviceObservers: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var sessionTimer: Timer?
    private var microphoneConfiguration: MeetingMicrophoneConfigurationPolicy?
    private var captureGeneration = 0
    private var starting = false
    private var stopRequested = false
    private var stopping: Task<MeetingAudioArchiveSnapshot?, Never>?
    private var onEvent: (@Sendable (MeetingCaptureEvent) -> Void)?

    init(clock: any MeetingMonotonicClock = SystemMeetingMonotonicClock(), wallClock: any Clock = SystemClock()) {
        self.clock = clock; self.wallClock = wallClock
    }

    static func microphoneDevices() -> [MeetingMicrophoneDevice] {
        MeetingAudioDeviceCatalog.devices().compactMap { device in
            guard MeetingAudioDeviceCatalog.hasInput(device), let uid = MeetingAudioDeviceCatalog.string(device, selector: kAudioDevicePropertyDeviceUID) else { return nil }
            return MeetingMicrophoneDevice(id: uid, name: MeetingAudioDeviceCatalog.string(device, selector: kAudioObjectPropertyName) ?? uid,
                isBuiltIn: MeetingAudioDeviceCatalog.uint32(device, selector: kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn)
        }.sorted {
            if $0.isBuiltIn != $1.isBuiltIn { return $0.isBuiltIn }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Invoked when the user opens the application chooser. ScreenCaptureKit may
    /// request permission to enumerate shareable applications; it starts no stream.
    static func onlineApplications() async throws -> [MeetingOnlineApplication] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return content.applications.filter { $0.processID != ProcessInfo.processInfo.processIdentifier }
            .map { MeetingOnlineApplication(id: $0.processID, name: $0.applicationName) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func start(recordingID: String, meetingID: String, mode: MeetingCaptureMode, archiveRoot: URL,
               onPCM: @escaping @Sendable (MeetingCapturedPCM) -> Void,
               onEvent: @escaping @Sendable (MeetingCaptureEvent) -> Void) async throws {
        guard !starting, writer == nil, engine == nil, stream == nil else { throw MeetingAudioCaptureError.busy }
        starting = true; stopRequested = false; stopping = nil
        captureGeneration += 1
        let generation = captureGeneration
        AppDiagnostics.shared.record(.operationStarted, category: .recording, fields: [.phase: .state(.starting)])
        defer { starting = false }
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") is String else { throw MeetingAudioCaptureError.missingUsageDescription }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AppDiagnostics.shared.record(.permissionRequested, category: .recording)
            let permission = MeetingCaptureAuthorizationWait()
            let allowed = try await permission.wait { reply in AVCaptureDevice.requestAccess(for: .audio, completionHandler: reply) }
            AppDiagnostics.shared.record(.permissionResult, category: .recording, fields: [.permissionGranted: .flag(allowed)])
            guard allowed else {
                throw MeetingAudioCaptureError.microphonePermission
            }
        default:
            AppDiagnostics.shared.record(.permissionResult, category: .recording, level: .warning,
                fields: [.permissionGranted: .flag(false)])
            throw MeetingAudioCaptureError.microphonePermission
        }
        try checkStart()
        let microphoneUID: String
        switch mode {
        case .microphone(let deviceID): microphoneUID = deviceID
        case .online(_, let deviceID): microphoneUID = deviceID
        }
        guard let device = MeetingAudioDeviceCatalog.devices().first(where: {
            MeetingAudioDeviceCatalog.hasInput($0) && MeetingAudioDeviceCatalog.string($0, selector: kAudioDevicePropertyDeviceUID) == microphoneUID
        }) else { throw MeetingAudioCaptureError.missingDevice }

        var filter: SCContentFilter?
        if case .online(let pid, _) = mode {
            guard pid != ProcessInfo.processInfo.processIdentifier else { throw MeetingAudioCaptureError.missingApplication }
            guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { throw MeetingAudioCaptureError.screenPermission }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            try checkStart()
            guard let application = content.applications.first(where: { $0.processID == pid }), let display = content.displays.first else {
                throw MeetingAudioCaptureError.missingApplication
            }
            // Only the chosen application is included. No display-wide audio fallback.
            filter = SCContentFilter(display: display, including: [application], exceptingWindows: [])
        }
        try checkStart()
        self.onEvent = onEvent
        let originalWriter = try MeetingAudioArchiveWriter(archive: MeetingAudioArchive(root: archiveRoot),
            recordingID: recordingID, meetingID: meetingID, clock: wallClock, onPCM: onPCM,
            onLevel: { track, rms in onEvent(.level(track: track, rms: rms)) },
            onFailure: { [weak self] error in Task { @MainActor in
                guard let self, self.captureGeneration == generation else { return }
                await self.fail(error)
            } })
        writer = originalWriter
        let receiver = MeetingCaptureSink(writer: originalWriter, clock: clock,
            onFailure: { [weak self] error in Task { @MainActor in
                guard let self, self.captureGeneration == generation else { return }
                await self.fail(error)
            } })
        sink = receiver
        do {
            var tapFormat: AVAudioFormat?
            if let filter {
                let configuration = SCStreamConfiguration()
                configuration.width = 2; configuration.height = 2
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                configuration.queueDepth = 3
                configuration.capturesAudio = true
                configuration.sampleRate = 48_000; configuration.channelCount = 2
                configuration.excludesCurrentProcessAudio = true
                configuration.captureMicrophone = true
                configuration.microphoneCaptureDeviceID = microphoneUID
                let capture = SCStream(filter: filter, configuration: configuration, delegate: receiver)
                try capture.addStreamOutput(receiver, type: .audio, sampleHandlerQueue: receiver.callbackQueue)
                try capture.addStreamOutput(receiver, type: .microphone, sampleHandlerQueue: receiver.callbackQueue)
                stream = capture
                let startup = Task { try await capture.startCapture() }
                streamStartTask = startup
                try await startup.value
                streamStartTask = nil
            } else {
                let capture = AVAudioEngine()
                engine = capture
                observe(NotificationCenter.default, name: .AVAudioEngineConfigurationChange, object: capture) { [weak self, weak capture] in
                    guard let self, let capture, self.engine === capture, self.captureGeneration == generation else { return }
                    await self.checkMicrophoneConfiguration(device: device)
                }
                try capture.inputNode.auAudioUnit.setDeviceID(device)
                guard capture.inputNode.auAudioUnit.deviceID == device else { throw MeetingAudioCaptureError.missingDevice }
                let format = capture.inputNode.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { throw MeetingAudioCaptureError.invalidFormat }
                tapFormat = format
                capture.inputNode.installTap(onBus: 0, bufferSize: 8_192, format: format, block: MeetingMicrophoneTap.make { buffer, time in
                    receiver.receiveMicrophone(buffer, at: time)
                })
                microphoneTapInstalled = true
                capture.prepare()
                try capture.start()
            }
            try checkStart()
            // Selecting/starting a device can itself change its stream format.
            // Observe external changes only after that startup has completed.
            guard let hardware = MeetingAudioDeviceCatalog.configuration(device) else { throw MeetingAudioCaptureError.missingDevice }
            microphoneConfiguration = MeetingMicrophoneConfigurationPolicy(expected: .init(deviceID: device,
                hardware: hardware, format: tapFormat))
            installObservers(device: device)
            installSessionMonitor(mode: mode, deviceID: device, receiver: receiver)
            AppDiagnostics.shared.record(.recordingStarted, category: .recording, fields: [
                .inputSampleRate: .decimal(hardware.sampleRate),
                .inputChannelCount: .integer(hardware.channelCounts.reduce(0) { $0 + Int($1) }),
                .engineRunning: .flag(engine?.isRunning ?? true)])
            onEvent(.started)
        } catch {
            AppDiagnostics.shared.recordFailure(error, category: .recording)
            _ = await stop(reason: error.localizedDescription)
            throw error
        }
    }

    /// Concurrent/repeated callers share one finalization task. The capture sink is
    /// closed first, then devices stop, queued original PCM drains, and CAF closes.
    func stop(reason: String? = nil) async -> MeetingAudioArchiveSnapshot? {
        stopRequested = true
        if let stopping { return await stopping.value }
        sink?.close()
        let captureEngine = engine; engine = nil
        let hadMicrophoneTap = microphoneTapInstalled; microphoneTapInstalled = false
        let captureStream = stream; stream = nil
        let startup = streamStartTask
        let originalWriter = writer
        microphoneConfiguration = nil
        removeObservers()
        let event = onEvent
        let task = Task { @MainActor () -> MeetingAudioArchiveSnapshot? in
            if hadMicrophoneTap { captureEngine?.inputNode.removeTap(onBus: 0) }
            captureEngine?.stop()
            var failure = reason
            if let captureStream {
                // A stop during SCK's asynchronous startup must wait until startup
                // settles; otherwise startCapture could win after stopCapture.
                if let startup { _ = try? await startup.value }
                do { try await captureStream.stopCapture() }
                catch { if failure == nil { failure = "오디오 캡처 종료 오류: " + error.localizedDescription } }
            }
            guard let originalWriter else { return nil }
            let result = await originalWriter.finish(reason: failure)
            AppDiagnostics.shared.record(.recordingStopped, category: .recording,
                level: result.error == nil ? .info : .error,
                fields: [.reason: .state(result.error == nil ? .stopped : .failed), .itemCount: .integer(result.tracks.count)])
            event?(.stopped(result))
            return result
        }
        stopping = task
        let result = await task.value
        writer = nil; sink = nil; onEvent = nil; streamStartTask = nil
        return result
    }

    private func checkStart() throws {
        try Task.checkCancellation()
        guard !stopRequested else { throw CancellationError() }
    }

    private func fail(_ message: String, reason: DiagnosticState = .failed) async {
        guard writer != nil, stopping == nil else { return }
        AppDiagnostics.shared.record(.operationFailed, category: .recording, level: .error,
            fields: [.phase: .state(.running), .reason: .state(reason)])
        onEvent?(.failed(message))
        _ = await stop(reason: message)
    }

    private func observe(_ center: NotificationCenter, name: Notification.Name, object: AnyObject? = nil,
                         action: @escaping @MainActor () async -> Void) {
        let generation = captureGeneration
        let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.captureGeneration == generation, self.writer != nil, self.stopping == nil else { return }
                await action()
            }
        }
        notificationObservers.append((center, token))
    }

    /// The engine notification covers output changes too, and can arrive after
    /// our own startup. Only changes to the selected input invalidate this archive.
    private func checkMicrophoneConfiguration(device: AudioObjectID) async {
        guard writer != nil, stopping == nil, var policy = microphoneConfiguration else { return }
        let current = MeetingAudioDeviceCatalog.configuration(device).map {
            MeetingMicrophoneConfigurationPolicy.Configuration(deviceID: engine?.inputNode.auAudioUnit.deviceID ?? device,
                hardware: $0, format: engine?.inputNode.outputFormat(forBus: 0))
        }
        let action = policy.action(current: current, engineRunning: engine?.isRunning,
            microphoneBuffers: sink?.microphoneBufferCount ?? 0)
        microphoneConfiguration = policy
        var fields: [DiagnosticField: DiagnosticValue] = [
            .inputDeviceMatches: .flag(current?.deviceID == policy.expected.deviceID),
            .engineRunning: .flag(engine?.isRunning ?? true),
            .bufferCount: .integer(Int(clamping: sink?.microphoneBufferCount ?? 0))]
        if let current {
            fields[.inputSampleRate] = .decimal(current.hardware.sampleRate)
            fields[.inputChannelCount] = .integer(current.hardware.channelCounts.reduce(0) { $0 + Int($1) })
            if let format = current.format {
                fields[.engineSampleRate] = .decimal(format.sampleRate)
                fields[.engineChannelCount] = .integer(Int(format.channelCount))
            }
        }
        AppDiagnostics.shared.record(.audioConfigurationObserved, category: .recording, fields: fields)
        switch action {
        case .continueRecording:
            AppDiagnostics.shared.record(.audioConfigurationIgnored, category: .recording, fields: [.reason: .state(.unchanged)])
            return
        case .deviceUnavailable:
            AppDiagnostics.shared.record(.deviceUnavailable, category: .recording, level: .error)
            await fail(MeetingAudioCaptureError.missingDevice.localizedDescription, reason: .missing)
        case .inputChanged:
            AppDiagnostics.shared.record(.audioConfigurationChanged, category: .recording, level: .error, fields: fields)
            await fail("녹음 중 마이크 구성이 변경되었습니다. 자동 장치 전환 없이 원본을 보존하고 중단했습니다.", reason: .changed)
        case .restartExhausted:
            AppDiagnostics.shared.record(.operationFailed, category: .recording, level: .error,
                fields: [.reason: .state(.unavailable), .recovered: .flag(false)])
            await fail("마이크 엔진이 반복해서 중단되었습니다. 다른 장치로 전환하지 않고 저장된 원본을 보존했습니다.", reason: .unavailable)
        case .restartSameInput:
            guard let engine else { return }
            do {
                // Nodes and the tap remain attached after configuration changes.
                // Do not select another device or alter the archive's PCM format.
                engine.prepare()
                try engine.start()
                await checkMicrophoneConfiguration(device: device)
                if self.engine === engine, engine.isRunning {
                    AppDiagnostics.shared.record(.operationSucceeded, category: .recording,
                        fields: [.recovered: .flag(true), .reason: .state(.unchanged)])
                }
            } catch {
                AppDiagnostics.shared.recordFailure(error, category: .recording)
                await fail("선택한 마이크의 녹음을 재개하지 못했습니다. 저장된 원본을 보존하고 중단했습니다.", reason: .unavailable)
            }
        }
    }

    private func installObservers(device: AudioObjectID) {
        let generation = captureGeneration
        observe(NSWorkspace.shared.notificationCenter, name: NSWorkspace.willSleepNotification) { [weak self] in
            await self?.fail("Mac이 잠자기에 들어가 녹음을 종료했습니다. 저장된 원본은 보존했습니다.", reason: .stopped)
        }
        for selector in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyStreamConfiguration] {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                mScope: selector == kAudioDevicePropertyStreamConfiguration ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in
                    guard let self, self.captureGeneration == generation else { return }
                    await self.checkMicrophoneConfiguration(device: device)
                }
            }
            if AudioObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr { deviceObservers.append((device, address, block)) }
        }
    }

    private func installSessionMonitor(mode: MeetingCaptureMode, deviceID: AudioObjectID, receiver: MeetingCaptureSink) {
        let generation = captureGeneration
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak receiver] _ in
            Task { @MainActor in
                guard let self, self.captureGeneration == generation, self.writer != nil, self.stopping == nil else { return }
                if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                    await self.fail(MeetingAudioCaptureError.microphonePermission.localizedDescription, reason: .denied)
                } else if !MeetingAudioDeviceCatalog.devices().contains(deviceID)
                            || (self.engine != nil && self.engine?.inputNode.auAudioUnit.deviceID != deviceID) {
                    await self.fail(MeetingAudioCaptureError.missingDevice.localizedDescription, reason: .missing)
                } else if case .online(let pid, _) = mode, NSRunningApplication(processIdentifier: pid)?.isTerminated != false {
                    await self.fail(MeetingAudioCaptureError.missingApplication.localizedDescription, reason: .notFound)
                } else if receiver?.microphoneStalled == true {
                    await self.fail("선택한 마이크에서 8초 동안 PCM을 받지 못했습니다. 장치나 권한을 확인해 주세요. 저장한 원본을 보존하고 중단했습니다.", reason: .timeout)
                }
            }
        }
    }

    private func removeObservers() {
        for (center, token) in notificationObservers { center.removeObserver(token) }
        notificationObservers.removeAll()
        for (device, original, block) in deviceObservers {
            var address = original
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, block)
        }
        deviceObservers.removeAll()
        sessionTimer?.invalidate(); sessionTimer = nil
    }
}

/// Notifications are hints to inspect the input, not proof that it changed.
/// One same-input restart is allowed until another microphone buffer arrives;
/// a stopped engine cannot enter an endless notification/restart loop.
struct MeetingMicrophoneConfigurationPolicy {
    struct Hardware: Equatable {
        let sampleRate: Double
        let channelCounts: [UInt32]
    }
    struct Configuration {
        let deviceID: AudioObjectID
        let hardware: Hardware
        let format: AVAudioFormat?

        func hasSameInput(as other: Self) -> Bool {
            guard hardware == other.hardware else { return false }
            switch (format, other.format) {
            case (nil, nil): return true
            case (let left?, let right?): return left.isEqual(right)
            default: return false
            }
        }
    }
    enum Action: Equatable { case continueRecording, restartSameInput, deviceUnavailable, inputChanged, restartExhausted }
    let expected: Configuration
    private var restartedAfterBufferCount: UInt64?

    init(expected: Configuration) { self.expected = expected }

    mutating func action(current: Configuration?, engineRunning: Bool?, microphoneBuffers: UInt64) -> Action {
        guard let current, current.deviceID == expected.deviceID else { return .deviceUnavailable }
        guard current.hasSameInput(as: expected) else { return .inputChanged }
        guard engineRunning == false else { return .continueRecording }
        guard restartedAfterBufferCount != microphoneBuffers else { return .restartExhausted }
        restartedAfterBufferCount = microphoneBuffers
        return .restartSameInput
    }
}

/// AVAudioNodeTapBlock is non-Sendable in Apple's SDK and runs on an audio
/// callback queue. Construct it outside MainActor so it cannot inherit the
/// caller's actor isolation and trap when the first microphone buffer arrives.
enum MeetingMicrophoneTap {
    static func make(_ receive: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) -> AVAudioNodeTapBlock {
        { buffer, time in receive(buffer, time) }
    }
}

/// Cancelling capture cannot dismiss the system permission dialog, but it must
/// release shutdown immediately and ignore the eventual answer to that dialog.
/// The injected request closure also permits testing without asking for access.
final class MeetingCaptureAuthorizationWait: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var continuation: CheckedContinuation<Bool, Error>?

    func wait(request: (@escaping @Sendable (Bool) -> Void) -> Void) async throws -> Bool {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                lock.lock()
                if cancelled || Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                lock.unlock()
                request { [weak self] allowed in self?.resolve(allowed) }
            }
        } onCancel: { self.cancel() }
    }

    private func resolve(_ allowed: Bool) {
        lock.lock()
        let pending = continuation; continuation = nil
        lock.unlock()
        pending?.resume(returning: allowed)
    }
    private func cancel() {
        lock.lock()
        cancelled = true
        let pending = continuation; continuation = nil
        lock.unlock()
        pending?.resume(throwing: CancellationError())
    }
}

/// No file operations, inference, UI updates or per-buffer Tasks on capture queues.
/// CMSampleBuffer storage is copied before the SCK callback returns.
private final class MeetingCaptureSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let callbackQueue = DispatchQueue(label: "WorkLog.meeting.capture-callback", qos: .userInteractive)
    private let writer: MeetingAudioArchiveWriter
    private let clock: any MeetingMonotonicClock
    private let origin: Double
    private let hostOrigin: Double
    private let lock = NSLock()
    private var closed = false
    private var reportedFailure = false
    private var lastMicrophoneTime: Double?
    private var microphoneBuffers: UInt64 = 0
    private let onFailure: @Sendable (String) -> Void

    init(writer: MeetingAudioArchiveWriter, clock: any MeetingMonotonicClock,
         onFailure: @escaping @Sendable (String) -> Void) {
        self.writer = writer; self.clock = clock; self.onFailure = onFailure
        origin = clock.seconds()
        hostOrigin = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
    }
    func close() { lock.lock(); closed = true; lock.unlock() }
    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    var microphoneStalled: Bool {
        lock.lock(); let last = lastMicrophoneTime ?? origin; lock.unlock()
        return clock.seconds() - last > 8
    }
    var microphoneBufferCount: UInt64 { lock.lock(); defer { lock.unlock() }; return microphoneBuffers }

    func receiveMicrophone(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard !isClosed else { return }
        guard time.isHostTimeValid else { fail(MeetingAudioArchiveError.invalidPCM); return }
        let start = AVAudioTime.seconds(forHostTime: time.hostTime) - hostOrigin
        receive(buffer: buffer, track: .microphone, start: start)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !isClosed, type == .audio || type == .microphone else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              basic.pointee.mFormatID == kAudioFormatLinearPCM,
              let format = AVAudioFormat(streamDescription: basic) else { fail(MeetingAudioArchiveError.invalidPCM); return }
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        let channels = Int(format.channelCount), bytesPerFrame = Int(basic.pointee.mBytesPerFrame)
        guard count > 0, count <= 262_144, channels > 0, channels <= 128,
              bytesPerFrame > 0, bytesPerFrame <= 1_024,
              count * bytesPerFrame * (format.isInterleaved ? 1 : channels) <= 8 * 1024 * 1024,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { fail(MeetingAudioArchiveError.invalidPCM); return }
        buffer.frameLength = AVAudioFrameCount(count)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList)
        guard status == noErr else { fail(MeetingAudioArchiveError.invalidPCM); return }
        // CoreMedia host clock and AVAudioTime.hostTime share mach_absolute_time.
        // Keep the original presentation timestamp; arrival jitter is not audio time.
        let start = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) - hostOrigin
        receive(buffer: buffer, track: type == .audio ? .system : .microphone, start: start, alreadyOwned: true)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) { fail(error) }

    private func receive(buffer: AVAudioPCMBuffer, track: MeetingAudioTrackID, start: Double, alreadyOwned: Bool = false) {
        do {
            let duration = Double(buffer.frameLength) / buffer.format.sampleRate
            // Reject incompatible clock domains instead of silently resynchronizing.
            guard start.isFinite, start >= -duration, start <= clock.seconds() - origin + 1 else { throw MeetingAudioArchiveError.invalidPCM }
            let packet = try alreadyOwned
                ? MeetingCapturedPCM(track: track, buffer: buffer, relativeStartSeconds: max(0, start))
                : MeetingCapturedPCM.copy(track: track, buffer: buffer, relativeStartSeconds: max(0, start))
            if track == .microphone {
                lock.lock(); lastMicrophoneTime = clock.seconds(); microphoneBuffers &+= 1; lock.unlock()
            }
            _ = writer.enqueue(packet)
        } catch { fail(error) }
    }

    private func fail(_ error: any Error) {
        lock.lock()
        guard !closed, !reportedFailure else { lock.unlock(); return }
        reportedFailure = true; closed = true
        lock.unlock()
        let message = error.localizedDescription
        DispatchQueue.global(qos: .userInitiated).async { self.onFailure(message) }
    }
}

private enum MeetingAudioDeviceCatalog {
    static func configuration(_ device: AudioObjectID) -> MeetingMicrophoneConfigurationPolicy.Hardware? {
        guard uint32(device, selector: kAudioDevicePropertyDeviceIsAlive) == 1,
              let channels = inputChannelCounts(device), channels.contains(where: { $0 > 0 }) else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr,
              rate.isFinite, rate > 0 else { return nil }
        return .init(sampleRate: rate, channelCounts: channels)
    }
    static func uint32(_ device: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
    static func devices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &result) == noErr else { return [] }
        return result
    }
    static func string(_ device: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let value = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
        value.initialize(to: nil)
        defer { value.deinitialize(count: 1); value.deallocate() }
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, value) == noErr,
              let returned = value.pointee else { return nil }
        // CoreAudio's property contract transfers this CFString to the caller.
        return returned.takeRetainedValue() as String
    }
    static func hasInput(_ device: AudioObjectID) -> Bool {
        inputChannelCounts(device)?.contains { $0 > 0 } == true
    }
    private static func inputChannelCounts(_ device: AudioObjectID) -> [UInt32]? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size >= MemoryLayout<AudioBufferList>.size else { return nil }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, memory) == noErr else { return nil }
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self)).map(\.mNumberChannels)
    }
}
#endif
