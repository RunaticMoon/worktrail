#if os(macOS)
import AVFoundation
import Foundation
import Observation
import WorkLogCore

enum MeetingCapturePhase: String { case idle, starting, recording, stopping }

@MainActor protocol MeetingAudioCapturing: AnyObject {
    func start(recordingID: String, meetingID: String, mode: MeetingCaptureMode, archiveRoot: URL,
               onPCM: @escaping @Sendable (MeetingCapturedPCM) -> Void,
               onEvent: @escaping @Sendable (MeetingCaptureEvent) -> Void) async throws
    func stop(reason: String?) async -> MeetingAudioArchiveSnapshot?
}
extension MeetingAudioCapture: MeetingAudioCapturing {}

/// Owned by MeetingsModel/AppController, never by the lifetime or selection of a screen.
@Observable @MainActor final class MeetingRecordingSession {
    let store: MeetingAudioStore
    let models: MeetingLocalModels
    let modelStore: MeetingLocalModelStore
    let archive: MeetingAudioArchive
    private let capture: any MeetingAudioCapturing
    private let ids: any IDGenerator
    private let clock: any WorkLogCore.Clock
    private let preferencesURL: URL
    var preferences = MeetingAudioPreferences()
    private(set) var phase: MeetingCapturePhase = .idle
    private(set) var recordingID: String?
    private(set) var meetingID: String?
    private(set) var meetingTitle = ""
    private(set) var elapsed: Double = 0
    private(set) var levels: [String: Float] = [:]
    private(set) var visible: [MeetingPreviewSegment] = []
    private(set) var previewMessage: String?
    private(set) var captureMessage: String?
    private(set) var captureIssue = false
    private(set) var finalMessage: String?
    private(set) var finalRecordingID: String?
    private(set) var contentRevision = 0
    private(set) var isRecovering = true
    private(set) var isSavePending = false
    private var pendingSnapshot: MeetingAudioArchiveSnapshot?
    var microphones: [MeetingMicrophoneDevice] = []
    var applications: [MeetingOnlineApplication] = []
    var microphoneID = ""
    var applicationPID: Int32 = 0
    var online = false
    var isCapturing: Bool { phase != .idle }
    var isFinalizing: Bool { finalTask != nil }
    private var generation = 0
    private var scheduler: MeetingPreviewScheduler?
    private var liveEngine: MeetingWhisperEngine?
    private var previewTask: Task<Void, Never>?
    private var previewPreparationTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var finalTask: Task<Void, Never>?
    private var finalGeneration = 0
    private var stopTask: Task<Void, Never>?
    private var continuation: AsyncStream<MeetingCapturedPCM>.Continuation?
    private var liveRunID: String?
    private var trackIDs: [String: String] = [:]
    private var changedSegments: [String: MeetingSegmentInput] = [:]
    private var checkpointDirty = false
    private var previewGaps: [MeetingPreviewGap] = []
    private var lastCheckpoint: Double = 0
    private var player: AVAudioPlayer?
    private var playbackTask: Task<Void, Never>?
    private var playbackTrack: MeetingAudioTrack?
    private var playbackEnd: Double?
    private var playbackStart: Double = 0
    private(set) var playingSegmentID: String?
    private(set) var isPlaying = false
    private(set) var playbackPosition: Double = 0
    private(set) var playbackDuration: Double = 0
    private(set) var playbackMessage: String?
    var playbackRate: Float = 1 { didSet { player?.rate = playbackRate } }
    private var recoveryTask: Task<Void, Never>?
    private let monotonic: any MeetingMonotonicClock

    init(environment: AppEnvironment, monotonic: any MeetingMonotonicClock = SystemMeetingMonotonicClock(),
         capture: (any MeetingAudioCapturing)? = nil) {
        store = MeetingAudioStore(repo: environment.repo)
        ids = environment.options.ids; clock = environment.options.clock; self.monotonic = monotonic
        self.capture = capture ?? MeetingAudioCapture(clock: monotonic, wallClock: environment.options.clock)
        archive = MeetingAudioArchive(root: environment.options.paths.dataRoot.appendingPathComponent("meeting-recordings"))
        modelStore = MeetingLocalModelStore(root: environment.options.paths.dataRoot.appendingPathComponent("meeting-models"), clock: environment.options.clock)
        models = MeetingLocalModels(store: modelStore)
        preferencesURL = environment.options.paths.dataRoot.appendingPathComponent("meeting-audio-settings.json")
        if let data = try? Data(contentsOf: preferencesURL), let saved = try? JSONDecoder().decode(MeetingAudioPreferences.self, from: data) { preferences = saved }
        refreshMicrophones()
        recoveryTask = Task { [weak self] in await self?.recover() }
    }

    func savePreferences() {
        do { try JSONEncoder().encode(preferences).write(to: preferencesURL, options: .atomic) }
        catch { captureMessage = "음성 설정을 저장하지 못했습니다." }
    }
    func refreshMicrophones() {
        microphones = MeetingAudioCapture.microphoneDevices()
        // Initial selection is visible to the user; never switch a running capture's device.
        if microphoneID.isEmpty { microphoneID = MeetingMicrophoneDevice.preferredID(in: microphones) ?? "" }
    }
    func refreshApplications() async {
        do { applications = try await MeetingAudioCapture.onlineApplications() }
        catch { captureMessage = "회의 앱 목록을 열지 못했습니다. 화면 및 시스템 오디오 권한을 확인하세요." }
    }
    func prepare(_ role: MeetingModelRole) {
        guard !isRecovering, !isSavePending, !models.isPreparing, !isCapturing, !isFinalizing else { return }
        Task { do { try await models.prepare(role) } catch { /* authored model message is shown by the model manager */ } }
    }

    func start(meeting: Meeting, recordOnly: Bool = false) {
        guard !isSavePending else { captureMessage = "이전 녹음 저장을 재시도한 뒤 새 녹음을 시작하세요."; return }
        guard !isCapturing, !models.isPreparing, meeting.deletedAt == nil else { return }
        guard !microphoneID.isEmpty, !online || applicationPID != 0 else {
            captureMessage = "마이크와 녹음할 회의 앱을 먼저 선택하세요."; return
        }
        // Capture starts first. A previous offline job is cancelled and drained before live inference begins.
        finalTask?.cancel()
        let oldFinal = finalTask
        generation += 1; let expected = generation
        phase = .starting; visible = []; levels = [:]; elapsed = 0
        changedSegments = [:]; previewGaps = []; trackIDs = [:]; liveRunID = nil
        checkpointDirty = false; lastCheckpoint = monotonic.seconds()
        captureMessage = nil; captureIssue = false; previewMessage = nil; meetingTitle = meeting.title
        recordingID = nil; meetingID = meeting.id
        startupTask = Task { [weak self] in
            guard let self else { return }
            defer { startupTask = nil }
            do {
                await recoveryTask?.value
                let recording = try store.createRecording(meetingID: meeting.id)
                recordingID = recording.id; meetingID = meeting.id
                let wantsPreview = preferences.liveEnabled && !recordOnly
                // Never wait behind a cancelled final model's multi-GB integrity check
                // before starting capture. The engine still verifies assets before inference.
                let available = models.readyRoles.contains(.live)
                try Task.checkCancellation()
                if wantsPreview && available {
                    do {
                        guard let descriptor = MeetingModelRegistry.models.first(where: { $0.role == .live }) else {
                            throw MeetingLocalModelError.missing(.live)
                        }
                        liveRunID = try store.createRun(meetingID: recording.meetingID, recordingID: recording.id, stage: .live,
                            engine: "WhisperKit", modelIdentifier: descriptor.modelID, modelRevision: descriptor.revision,
                            settingsJSON: try StableJSON.string(MeetingRunConfiguration(preferences: preferences, stage: "live"))).id
                    } catch { previewMessage = "미리보기 저장을 준비하지 못했습니다. 원본만 녹음합니다." }
                }
                let stream = AsyncStream<MeetingCapturedPCM>(bufferingPolicy: .bufferingNewest(4)) { self.continuation = $0 }
                let sink = continuation!
                let drops = MeetingPreviewDropCounter()
                let mode: MeetingCaptureMode = online
                    ? .online(applicationPID: applicationPID, microphoneDeviceID: microphoneID)
                    : .microphone(deviceID: microphoneID)
                previewPreparationTask = Task { [weak self] in
                    guard let self else { return }
                    await oldFinal?.value
                    guard expected == generation, !Task.isCancelled, phase == .starting || phase == .recording else { return }
                    if wantsPreview && available {
                        await preparePreview(recording: recording, expected: expected)
                    } else { previewMessage = wantsPreview ? "실시간 모델 없음 · 원본만 녹음합니다." : "녹음만 진행합니다." }
                }
                previewTask = Task { [weak self] in
                    guard let self else { return }
                    var windows: [String: MeetingRollingAudio] = [:]
                    for await packet in stream {
                        guard expected == generation else { break }
                        do {
                            try ensureTrack(packet, recordingID: recording.id)
                            let packetEnd = packet.relativeStartSeconds + Double(packet.buffer.frameLength) / packet.buffer.format.sampleRate
                            elapsed = max(elapsed, packetEnd)
                            if let scheduler, preferences.liveEnabled, wantsPreview {
                                let converted = try await Task.detached { try MeetingPCMReader.convert(packet.buffer) }.value
                                let key = packet.track.rawValue
                                var window = windows[key] ?? MeetingRollingAudio(settings: preferences)
                                window.append(converted, at: packet.relativeStartSeconds)
                                if let request = window.window(sessionID: recording.id, recordingID: recording.id,
                                    generation: expected, trackID: key, interval: await scheduler.interval) { await scheduler.submit(request) }
                                windows[key] = window
                            } else if wantsPreview && liveRunID != nil {
                                previewEvent(.skipped(.init(trackID: packet.track.rawValue,
                                    start: packet.relativeStartSeconds, end: packetEnd, reason: "preview-unavailable")), expected: expected)
                            }
                            for gap in drops.drain() { previewEvent(.skipped(gap), expected: expected) }
                            checkpointIfNeeded()
                        } catch { previewMessage = "미리보기를 처리하지 못했습니다. 원본 녹음은 계속 보관합니다." }
                    }
                    for gap in drops.drain() { previewEvent(.skipped(gap), expected: expected) }
                    if let scheduler, expected == generation {
                        for key in windows.keys.sorted() {
                            if let request = windows[key]?.window(sessionID: recording.id, recordingID: recording.id,
                                generation: expected, trackID: key, interval: 2, final: true) { await scheduler.submit(request) }
                        }
                        await scheduler.finish(graceSeconds: 8)
                    }
                }
                try await capture.start(recordingID: recording.id, meetingID: recording.meetingID, mode: mode,
                    archiveRoot: archive.root, onPCM: { packet in
                        if case .dropped(let dropped) = sink.yield(packet) { drops.record(dropped) }
                    }, onEvent: { [weak self] event in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == expected else { return }
                            switch event {
                            case .started: break
                            case .level(let track, let rms): self.levels[track.rawValue] = rms
                            case .failed(let message): self.captureMessage = message; self.captureIssue = true; self.stop()
                            case .stopped: if self.phase == .recording { self.stop() }
                            }
                        }
                    })
                guard expected == generation, !Task.isCancelled else { stop(); return }
                phase = .recording
            } catch {
                continuation?.finish(); continuation = nil
                captureIssue = !(error is CancellationError)
                captureMessage = error is CancellationError ? "녹음 시작을 취소했습니다. 저장된 원본은 유지됩니다."
                    : "녹음을 시작하지 못했습니다. 입력 장치·권한·저장 공간을 확인하세요. 저장된 원본은 유지됩니다."
                if let recordingID, let record = try? store.recording(id: recordingID) {
                    _ = try? store.updateRecordingState(id: record.id, expectedRevision: record.revision, state: .failed)
                }
                stop()
            }
        }
    }

    private func preparePreview(recording: MeetingRecording, expected: Int) async {
            guard expected == generation, liveRunID != nil, !Task.isCancelled,
                  phase == .starting || phase == .recording else { return }
            let engine = MeetingWhisperEngine(models: modelStore, profile: .live)
            liveEngine = engine
            scheduler = MeetingPreviewScheduler(sessionID: recording.id, recordingID: recording.id, generation: expected,
                tracks: [MeetingAudioTrackID.microphone.rawValue, MeetingAudioTrackID.system.rawValue], engine: engine,
                ids: ids, clock: monotonic, overlap: preferences.overlap) { [weak self] event in
                    await self?.previewEvent(event, expected: expected)
                }
            previewMessage = "음성을 기다리는 중 · 첫 요청에서 모델을 로딩합니다."
    }

    private func ensureTrack(_ packet: MeetingCapturedPCM, recordingID: String) throws {
        guard trackIDs[packet.track.rawValue] == nil else { return }
        let track = try store.addTrack(recordingID: recordingID,
            kind: packet.track == .microphone ? .microphone : .systemAudio,
            relativePath: recordingID + "/" + packet.track.rawValue + ".caf",
            sampleRate: packet.buffer.format.sampleRate, channels: Int(packet.buffer.format.channelCount),
            startOffset: packet.relativeStartSeconds, fileState: .writing)
        trackIDs[packet.track.rawValue] = track.id
    }
    private func previewEvent(_ event: MeetingPreviewEvent, expected: Int) {
        guard expected == generation else { return }
        switch event {
        case .updated(let current, let changes):
            visible = current
            checkpointDirty = true
            for segment in changes {
                guard let trackID = trackIDs[segment.trackID] else { continue }
                changedSegments[segment.id] = MeetingSegmentInput(trackID: trackID, sourceKey: segment.id,
                    start: segment.start, end: segment.end, text: segment.text, isFinal: segment.stability == .stablePreview)
            }
            checkpointIfNeeded()
        case .skipped(let gap):
            if let previous = previewGaps.last, previous.trackID == gap.trackID,
               previous.reason == gap.reason, gap.start <= previous.end + 0.15 {
                previewGaps[previewGaps.count - 1].end = max(previous.end, gap.end)
            } else { previewGaps.append(gap) }
            checkpointDirty = true
            checkpointIfNeeded(force: previewGaps.count >= 256)
            previewMessage = "미리보기 일부 구간을 건너뛰었습니다. 종료 후 원본에서 다시 전사합니다."
        case .failed: previewMessage = "미리보기 오류 · 원본 녹음은 계속됩니다."
        case .load(let interval, let duration, _):
            previewMessage = "최근 추론 \(String(format: "%.1f", duration))초 · 갱신 시도 \(String(format: "%.1f", interval))초 간격"
        }
    }
    private func checkpointIfNeeded(force: Bool = false) {
        guard let liveRunID, checkpointDirty,
              force || monotonic.seconds() - lastCheckpoint >= 3 else { return }
        do {
            for (key, id) in trackIDs {
                _ = try store.checkpointLiveSegments(runID: liveRunID, trackID: id,
                    segments: changedSegments.values.filter { $0.trackID == id },
                    activePartialKeys: visible.filter { $0.trackID == key && $0.stability == .partial }.map(\.id))
            }
            for gap in previewGaps {
                if let id = trackIDs[gap.trackID] {
                    _ = try store.recordPreviewGap(runID: liveRunID, trackID: id, start: gap.start, end: gap.end, reason: gap.reason)
                }
            }
            changedSegments = [:]; previewGaps = []; checkpointDirty = false; lastCheckpoint = monotonic.seconds()
        } catch { previewMessage = "자막 체크포인트를 저장하지 못했습니다. 원본은 별도로 보관됩니다." }
        // A prolonged DB failure cannot grow the preview mailbox indefinitely.
        if previewGaps.count > 256 {
            var combined: [String: MeetingPreviewGap] = [:]
            for gap in previewGaps {
                let old = combined[gap.trackID]
                combined[gap.trackID] = .init(trackID: gap.trackID, start: min(old?.start ?? gap.start, gap.start),
                    end: max(old?.end ?? gap.end, gap.end), reason: "checkpoint-unavailable")
            }
            previewGaps = Array(combined.values)
        }
        if changedSegments.count > 512 {
            changedSegments = Dictionary(uniqueKeysWithValues: changedSegments.values.sorted { $0.end > $1.end }.prefix(512).map { ($0.sourceKey, $0) })
            previewMessage = "자막 저장 지연 · 오래된 미리보기는 원본 정밀 전사로 복구해야 합니다."
        }
    }

    func stop() {
        guard phase != .idle, stopTask == nil else { return }
        phase = .stopping; startupTask?.cancel()
        previewPreparationTask?.cancel(); previewPreparationTask = nil
        stopTask = Task { [weak self] in
            guard let self else { return }
            // Permission resolution cannot restart capture after cancellation.
            await startupTask?.value
            let snapshot = await capture.stop(reason: nil)
            continuation?.finish(); continuation = nil
            await previewTask?.value; previewTask = nil
            pendingSnapshot = snapshot
            if let error = snapshot?.error { captureMessage = error; captureIssue = true }
            _ = persistStoppedRecording()
            phase = .idle; contentRevision += 1; stopTask = nil
            let oldScheduler = scheduler, oldEngine = liveEngine
            let previousFinal = finalTask
            finalGeneration += 1; let job = finalGeneration
            scheduler = nil; liveEngine = nil
            // A timeout only ends the UI wait. Do not unload while the SDK still executes.
            finalTask = Task { [weak self] in
                await previousFinal?.value
                await oldScheduler?.waitUntilIdle(); await oldEngine?.unload()
                guard let self else { return }
                if let snapshot, !isSavePending, preferences.automaticFinalization, !Task.isCancelled {
                    await finalize(snapshot.recordingID)
                }
                if finalGeneration == job { finalTask = nil }
            }
        }
    }
    func shutdown() async -> Bool {
        stopPlayback()
        await recoveryTask?.value
        models.cancel(); startupTask?.cancel()
        if isCapturing { stop() }
        await stopTask?.value
        finalTask?.cancel() // Original and DB checkpoint already closed; interrupted run recovers at next launch.
        return phase == .idle && persistStoppedRecording()
    }
    @discardableResult func retrySaving() -> Bool {
        guard phase == .idle, !isRecovering else { return false }
        let saved = persistStoppedRecording()
        if saved { captureMessage = "녹음 복구 정보와 전사를 저장했습니다."; captureIssue = false; contentRevision += 1 }
        return saved
    }
    private func persistStoppedRecording() -> Bool {
        do {
            if var snapshot = pendingSnapshot {
                if snapshot.journalNeedsRetry == true {
                    snapshot = try archive.retryClosedJournal(snapshot)
                    pendingSnapshot = snapshot
                }
                try reconcile(snapshot)
            }
            checkpointIfNeeded(force: true)
            guard !checkpointDirty || liveRunID == nil else { throw WorkLogError.storage("자막 저장 대기") }
            if let liveRunID, let run = try store.run(id: liveRunID), run.status == .running {
                _ = try store.finishRun(id: liveRunID)
            }
            pendingSnapshot = nil; isSavePending = false
            return true
        } catch {
            isSavePending = true; captureIssue = true
            captureMessage = "녹음 저장이 완료되지 않아 종료와 새 녹음을 보류합니다. 저장 공간·폴더 권한을 확인하고 ‘저장 재시도’를 누르세요. 원본은 삭제하지 않았습니다."
            return false
        }
    }
    func dismissCaptureIssue() { if !isSavePending { captureIssue = false } }
    func cancelFinalization() { finalTask?.cancel(); finalMessage = "정밀 전사 중지 요청 · 원본과 저장된 구간을 보존합니다." }
    func retryFinalization(_ id: String, mode: MeetingProcessingMode = .refinedAndDiarized, sourceRunID: String? = nil) {
        guard !isRecovering, !isSavePending, !isCapturing, finalTask == nil, !models.isPreparing else { return }
        finalGeneration += 1; let job = finalGeneration
        finalTask = Task { [weak self] in
            guard let self else { return }; await finalize(id, mode: mode, sourceRunID: sourceRunID)
            if finalGeneration == job { finalTask = nil }
        }
    }

    private func finalize(_ id: String, mode: MeetingProcessingMode = .refinedAndDiarized, sourceRunID: String? = nil) async {
        finalRecordingID = id
        defer { finalRecordingID = nil; contentRevision += 1 }
        if mode != .diarizationOnly, !(await modelStore.isInstalled(.final)) {
            finalMessage = "정밀 전사 대기 · large-v3 모델을 준비해 주세요."; return
        }
        if mode != .refinedOnly, !(await modelStore.isInstalled(.diarization)) {
            finalMessage = "화자 분리 모델을 준비하거나 ‘정밀 전사만’ 실행하세요."; return
        }
        do {
            finalMessage = "원본으로 정밀 전사 중…"
            try await MeetingPostProcessing.run(recordingID: id, store: store, archive: archive, models: modelStore,
                preferences: preferences, mode: mode, sourceRunID: sourceRunID) { [weak self] message in await self?.setFinalMessage(message) }
            finalMessage = "정밀 전사 버전을 저장했습니다. 검토 후 활성 전사본으로 선택하세요."
        } catch is CancellationError { finalMessage = "정밀 전사 대기 · 원본과 완료된 구간을 보존했습니다. 재시도할 수 있습니다." }
        catch let error as WorkLogError { finalMessage = error.localizedDescription + " 원본과 완료된 전사는 보존했습니다." }
        catch { finalMessage = "처리 단계 실패 · 원본과 완료된 정밀 전사는 보존했습니다. 화자 분리만 재시도할 수 있습니다." }
    }
    private func setFinalMessage(_ message: String) { finalMessage = message }

    private func recover() async {
        defer { isRecovering = false }
        do {
            _ = try store.recoverInterrupted()
            let report = try await Task.detached { [archive] in try archive.recoverAvailable() }.value
            let recovered = report.snapshots
            if report.unavailableCount > 0 { captureMessage = "일부 원본 파일이 없거나 복구 정보를 읽지 못했습니다. 정상 원본은 따로 복구하며 어떤 파일도 삭제하지 않습니다." }
            for snapshot in recovered {
                guard let meeting = try MeetingService(repo: store.repo).meeting(id: snapshot.meetingID, includeDeleted: true),
                      meeting.deletedAt == nil else { continue }
                do {
                    let persisted = try archive.acknowledgeRecovery(recordingID: snapshot.recordingID)
                    try reconcile(persisted)
                } catch { captureMessage = "일부 원본의 DB 연결을 복구하지 못했습니다. 원본 파일은 유지됩니다." }
            }
            // Backups deliberately exclude audio. A restored reference must visibly become missing.
            for meeting in try MeetingService(repo: store.repo).meetings(includeDeleted: true) {
                for recording in try store.recordings(meetingID: meeting.id) {
                    for track in try store.tracks(recordingID: recording.id) where track.fileState != .deleted {
                        let url = archive.root.appendingPathComponent(track.relativePath)
                        if !FileManager.default.fileExists(atPath: url.path) {
                            _ = try store.updateTrack(id: track.id, expectedRevision: track.revision, fileState: .missing)
                        }
                    }
                }
            }
            if recovered.contains(where: { $0.status == .interrupted }) { captureMessage = "중단된 원본을 복구했습니다. 녹음을 자동 재개하지 않습니다." }
        } catch { captureMessage = "일부 녹음 복구 정보를 확인하지 못했습니다. 원본은 삭제하지 않았습니다." }
        contentRevision += 1
        await models.refreshAvailability()
    }
    private func reconcile(_ snapshot: MeetingAudioArchiveSnapshot) throws {
        let recording = try store.createRecording(meetingID: snapshot.meetingID, id: snapshot.recordingID, startedAt: snapshot.startedAt)
        guard recording.state != .discarded else { return }
        for item in snapshot.tracks {
            let existing = try store.tracks(recordingID: recording.id).first { $0.relativePath == item.relativePath }
            let track = try existing ?? store.addTrack(recordingID: recording.id,
                kind: item.id == .microphone ? .microphone : .systemAudio, relativePath: item.relativePath,
                sampleRate: item.sampleRate, channels: Int(item.channelCount), startOffset: item.startOffset)
            guard track.fileState != .deleted else { continue }
            let gaps = item.gaps.map { MeetingTrackInterruption(start: $0.startOffset, end: $0.startOffset + $0.duration, reason: $0.reason) }
            _ = try store.updateTrack(id: track.id, expectedRevision: track.revision, fileState: .available,
                                     duration: item.duration, interruptions: gaps, startOffset: item.startOffset)
        }
        if recording.state != .completed {
            _ = try store.updateRecordingState(id: recording.id, expectedRevision: recording.revision,
                                               state: snapshot.status == .archived ? .completed : .interrupted)
        }
    }

    func play(_ segment: MeetingTranscriptSegment) {
        do {
            guard let track = try store.track(id: segment.trackID), track.fileState == .available else {
                playbackMessage = "원본이 없거나 삭제되어 재생할 수 없습니다. 전사 읽기·수정은 가능합니다."; return
            }
            let url = try archive.resolveTrackURL(relativePath: track.relativePath)
            stopPlayback()
            let next = try AVAudioPlayer(contentsOf: url)
            next.enableRate = true; next.rate = playbackRate
            next.currentTime = MeetingAudioTimeline.fileTime(sessionTime: segment.start, startOffset: track.startOffset, interruptions: track.interruptions)
            playbackStart = next.currentTime
            playbackEnd = min(next.duration, MeetingAudioTimeline.fileTime(sessionTime: segment.end, startOffset: track.startOffset, interruptions: track.interruptions))
            player = next; playbackTrack = track; playingSegmentID = segment.id
            playbackDuration = MeetingAudioTimeline.sessionTime(fileTime: next.duration, startOffset: track.startOffset, interruptions: track.interruptions)
            playbackPosition = segment.start; playbackMessage = nil; isPlaying = next.play()
            playbackTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard let self, let player = self.player, let track = self.playbackTrack else { return }
                    if let end = self.playbackEnd, player.currentTime >= end { player.pause(); player.currentTime = end }
                    self.isPlaying = player.isPlaying
                    self.playbackPosition = MeetingAudioTimeline.sessionTime(fileTime: player.currentTime,
                        startOffset: track.startOffset, interruptions: track.interruptions)
                }
            }
        } catch { playbackMessage = "원본을 재생하지 못했습니다. 원본 파일과 보관 폴더를 확인하세요. 전사는 계속 편집할 수 있습니다." }
    }
    func togglePlayback() {
        guard let player else { return }
        if player.isPlaying { player.pause(); isPlaying = false }
        else {
            if let end = playbackEnd, player.currentTime >= end { player.currentTime = playbackStart }
            isPlaying = player.play()
        }
    }
    func seekPlayback(to sessionTime: Double) {
        guard let player, let track = playbackTrack else { return }
        player.currentTime = min(player.duration, max(0, MeetingAudioTimeline.fileTime(sessionTime: sessionTime,
            startOffset: track.startOffset, interruptions: track.interruptions)))
        playbackPosition = MeetingAudioTimeline.sessionTime(fileTime: player.currentTime, startOffset: track.startOffset, interruptions: track.interruptions)
    }
    func skipPlayback(_ seconds: Double) { seekPlayback(to: playbackPosition + seconds) }
    func stopPlayback() {
        playbackTask?.cancel(); playbackTask = nil; player?.stop(); player = nil
        playbackTrack = nil; playingSegmentID = nil; isPlaying = false; playbackEnd = nil
        playbackPosition = 0; playbackDuration = 0
    }
    func isPastRetention(_ recording: MeetingRecording) -> Bool {
        preferences.retentionDays > 0 &&
        clock.now().timeIntervalSince(recording.endedAt ?? recording.startedAt) >= Double(preferences.retentionDays) * 86_400
    }
    func deleteOriginal(_ id: String) {
        guard !isRecovering, !isSavePending else { return }
        guard id != recordingID || !isCapturing, id != finalRecordingID else { return }
        do {
            let tracks = try store.tracks(recordingID: id)
            if tracks.contains(where: MeetingImportedAudioArchive.owns) {
                try MeetingImportedAudioArchive(archive: archive, ids: ids).delete(recordingID: id, tracks: tracks)
            } else {
                _ = try archive.acknowledgeRecovery(recordingID: id)
                try archive.delete(recordingID: id)
            }
            for track in tracks {
                _ = try store.updateTrack(id: track.id, expectedRevision: track.revision, fileState: .deleted)
            }
            if let recording = try store.recording(id: id) {
                _ = try store.updateRecordingState(id: id, expectedRevision: recording.revision, state: .discarded)
            }
            contentRevision += 1
        } catch { captureMessage = "원본 삭제를 완료하지 못했습니다. 파일과 복구 정보를 확인하세요." }
    }
    func exportOriginal(_ id: String, to url: URL) {
        guard !isRecovering else { return }
        do {
            let tracks = try store.tracks(recordingID: id)
            if tracks.contains(where: MeetingImportedAudioArchive.owns) {
                guard let recording = try store.recording(id: id) else { throw WorkLogError.notFound("녹음") }
                let localOnly = try MeetingService(repo: store.repo).meeting(id: recording.meetingID, includeDeleted: true)?.localOnly ?? true
                try MeetingImportedAudioArchive(archive: archive, ids: ids).export(recording: recording, tracks: tracks, localOnly: localOnly, to: url)
            } else {
                _ = try archive.acknowledgeRecovery(recordingID: id)
                try archive.export(recordingID: id, to: url)
            }
        } catch { captureMessage = "원본 내보내기를 완료하지 못했습니다. 대상 폴더와 권한을 확인하세요." }
    }
    func importAudio(_ url: URL, meetingID: String) async throws {
        guard !isRecovering, !isSavePending, !isCapturing, !isFinalizing else { throw MeetingLocalModelError.busy }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let recording = try store.createRecording(meetingID: meetingID)
        let writer = try MeetingAudioArchiveWriter(archive: archive, recordingID: recording.id, meetingID: meetingID,
            clock: clock, onPCM: { _ in }, onLevel: { _, _ in }, onFailure: { _ in })
        do {
            try await MeetingPCMReader.readChunks(url: url, seconds: 1) { chunk in
                let packet = try MeetingCapturedPCM.copy(track: .microphone, buffer: chunk.buffer, relativeStartSeconds: chunk.relativeStartSeconds)
                try await writer.appendForImport(packet)
            }
            let snapshot = await writer.finish(); pendingSnapshot = snapshot
            guard persistStoppedRecording() else { throw WorkLogError.storage("가져온 원본의 저장 마무리가 필요합니다.") }
            contentRevision += 1
            if preferences.automaticFinalization { retryFinalization(recording.id) }
        } catch {
            let snapshot = await writer.finish(reason: "파일 가져오기 중단")
            pendingSnapshot = snapshot
            _ = persistStoppedRecording(); contentRevision += 1; throw error
        }
    }
}

/// A fixed-size mailbox for dropped preview buffers; the original has already been written.
private final class MeetingPreviewDropCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var gaps: [String: MeetingPreviewGap] = [:]
    func record(_ packet: MeetingCapturedPCM) {
        lock.lock(); defer { lock.unlock() }
        let id = packet.track.rawValue, end = packet.relativeStartSeconds + Double(packet.buffer.frameLength) / packet.buffer.format.sampleRate
        let previous = gaps[id]
        gaps[id] = .init(trackID: id, start: min(previous?.start ?? packet.relativeStartSeconds, packet.relativeStartSeconds),
                         end: max(previous?.end ?? end, end), reason: "preview-consumer-overload")
    }
    func drain() -> [MeetingPreviewGap] { lock.lock(); defer { lock.unlock() }; let result = Array(gaps.values); gaps = [:]; return result }
}
#endif
