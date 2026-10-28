#if os(macOS)
import Foundation
import WorkLogCore

@MainActor private final class FailedStartupCapture: MeetingAudioCapturing {
    let error: Error
    init(_ error: Error) { self.error = error }
    func start(recordingID: String, meetingID: String, mode: MeetingCaptureMode, archiveRoot: URL,
               onPCM: @escaping @Sendable (MeetingCapturedPCM) -> Void,
               onEvent: @escaping @Sendable (MeetingCaptureEvent) -> Void) async throws { throw error }
    func stop(reason: String?) async -> MeetingAudioArchiveSnapshot? { nil }
}

@MainActor func checkMeetingErrorSessions(at root: URL) async throws {
    let cases: [(Error, String)] = [
        (MeetingAudioCaptureError.busy, "진행 중인 작업"),
        (MeetingAudioCaptureError.missingUsageDescription, "권한 설명"),
        (MeetingAudioCaptureError.microphonePermission, "시스템 설정의 마이크"),
        (MeetingAudioCaptureError.screenPermission, "화면 및 시스템 오디오"),
        (MeetingAudioCaptureError.missingDevice, "입력 장치를 다시 선택"),
        (MeetingAudioCaptureError.missingApplication, "앱을 다시 선택"),
        (MeetingAudioCaptureError.invalidFormat, "입력 장치 설정"),
        (CancellationError(), "취소"),
        (URLError(.cancelled), "취소")
    ]
    for (index, item) in cases.enumerated() {
        let environment = try MeetingSessionCheck.fixtureEnvironment(at: root.appendingPathComponent("start-\(index)"))
        let service = MeetingService(repo: environment.repo)
        let meeting = try service.create(title: "시작 오류 가짜 회의")
        let session = MeetingRecordingSession(environment: environment, capture: FailedStartupCapture(item.0))
        session.microphoneID = "fixture-device-never-opened"
        session.preferences.automaticFinalization = false
        try await MeetingSessionCheck.waitUntil("startup fixture recovery", { !session.isRecovering })
        session.start(meeting: meeting, recordOnly: true)
        try await MeetingSessionCheck.waitUntil("startup failure cleanup", { session.phase == .idle && session.captureMessage != nil })
        try MeetingSessionCheck.check(session.captureMessage?.contains(item.1) == true,
            "Startup failure must retain its actionable message after stop cleanup")
        try MeetingSessionCheck.check(session.captureIssue == (MeetingFailurePresentation.failure(for: item.0, phase: .recordingStart).reason != .cancelled),
            "Cancellation must not present a capture failure")
        let closed = await session.shutdown()
        try MeetingSessionCheck.check(closed, "Failed startup must remain safely closeable")
    }
    print("PASS: 7 actual session startup failure paths and 2 cancellation forms retain specific recovery guidance after cleanup")

    var status = MeetingPreviewStatus()
    let error = MeetingOperationFailure(phase: .modelLoading, reason: .failed, errorDomain: .coreML, errorCode: 17)
    try MeetingSessionCheck.check(status.receive(.failed(trackID: "microphone", failure: error)) == error,
        "First preview failure must be available for diagnostics")
    let failedMessage = status.message
    try MeetingSessionCheck.check(failedMessage?.contains("모델 준비") == true,
        "Model loading failure must identify the model remedy")
    _ = status.receive(.skipped(.init(trackID: "microphone", start: 0, end: 2, reason: "preview-error")))
    _ = status.receive(.load(interval: 2, inferenceSeconds: 1, queued: 0))
    _ = status.receive(.updated(visible: [], changed: []))
    _ = status.receive(.succeeded(trackID: "system"))
    try MeetingSessionCheck.check(status.message == failedMessage,
        "Gap, load, finish updates and another track's success must not erase the failing track's message")
    try MeetingSessionCheck.check(status.receive(.failed(trackID: "microphone", failure: error)) == nil,
        "Repeated identical failures must not flood the bounded diagnostic log")
    _ = status.receive(.succeeded(trackID: "microphone"))
    _ = status.receive(.load(interval: 2, inferenceSeconds: 1, queued: 0))
    try MeetingSessionCheck.check(status.failures.isEmpty && status.message?.contains("최근 추론") == true,
        "Successful inference on the failing track must restore performance status")
    try MeetingSessionCheck.check(status.receive(.failed(trackID: "microphone", failure: error)) == error,
        "A new failure after recovery must create a new diagnostic episode")
    print("PASS: actual preview presentation preserves failure across performance/gap events and clears only the recovered track")
}
#endif
