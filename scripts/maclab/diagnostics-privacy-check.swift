import CoreML
import Foundation
import WorkLogCore

@main struct DiagnosticsPrivacyCheck {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fail("Expected a disposable test directory") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let directory = root.appendingPathComponent("diagnostics", isDirectory: true)
        let diagnostics = AppDiagnostics(directory: directory, clock: FixedClock(Date(timeIntervalSince1970: 1_800_000_000)))
        let fakePrivateValues = [
            "FAKE_PRIVATE_ERROR_DESCRIPTION", "FAKE_PRIVATE_ERROR_DOMAIN", "FAKE_BEARER_TOKEN",
            "https://fake.invalid/account?secret=FAKE_URL_TOKEN", "/fake/private/home/FAKE_ACCOUNT"
        ]
        let privateMessage = fakePrivateValues.joined(separator: " ")
        let userInfo: [String: Any] = [
            NSLocalizedDescriptionKey: privateMessage,
            NSFilePathErrorKey: fakePrivateValues[4],
            NSURLErrorFailingURLErrorKey: URL(string: fakePrivateValues[3])!,
            "Authorization": fakePrivateValues[2]
        ]
        diagnostics.recordFailure(NSError(domain: fakePrivateValues[1], code: 987_654_321, userInfo: userInfo), category: .storage)
        diagnostics.recordFailure(NSError(domain: NSOSStatusErrorDomain, code: -25308, userInfo: userInfo), category: .keychain)
        diagnostics.recordFailure(NSError(domain: NSURLErrorDomain, code: -1009, userInfo: userInfo), category: .update)
        diagnostics.recordFailure(WorkLogError.validation(privateMessage), category: .storage)
        diagnostics.recordFailure(AIProviderError(.rateLimited, privateMessage), category: .ai)
        diagnostics.recordFailure(CancellationError(), category: .recording)
        let captureCases: [(MeetingAudioCaptureError, DiagnosticState, String)] = [
            (.busy, .captureBusy, "작업을 마친"),
            (.missingUsageDescription, .missingUsageDescription, "권한 설명"),
            (.microphonePermission, .microphonePermission, "마이크 권한"),
            (.screenPermission, .screenPermission, "화면 및 시스템 오디오 녹음 권한"),
            (.missingDevice, .missingDevice, "입력 장치를 다시 선택"),
            (.missingApplication, .missingApplication, "회의 앱을 실행"),
            (.invalidFormat, .invalidFormat, "입력 장치 설정")
        ]
        for (error, reason, action) in captureCases {
            let failure = MeetingFailurePresentation.failure(for: error, phase: .recordingStart)
            requireThat(failure.reason == reason && failure.phase == .recordingStart,
                        "A capture preflight failure lost its specific reason or phase")
            requireThat(MeetingFailurePresentation.startupMessage(for: failure).contains(action),
                        "A capture preflight failure lost its actionable remedy")
            diagnostics.recordFailure(failure, category: .recording)
        }
        let modelCases: [(MeetingLocalModelError, DiagnosticState)] = [
            (.missing(.live), .modelMissing), (.invalidFile(privateMessage), .modelInvalid),
            (.busy, .conflict), (.invalidAudio, .invalidAudio),
            (.downloadFailed(987_654_321), .network), (.invalidTokenizer, .tokenizerInvalid)
        ]
        for (error, reason) in modelCases {
            let failure = MeetingFailurePresentation.failure(for: error, phase: .modelValidation)
            requireThat(failure.reason == reason && failure.phase == .modelValidation,
                        "A model failure lost its reviewed reason or phase")
            for value in fakePrivateValues {
                requireThat(!MeetingFailurePresentation.startupMessage(for: failure).contains(value),
                            "A model path reached the startup message")
                requireThat(!MeetingFailurePresentation.previewMessage(for: failure).contains(value),
                            "A model path reached the preview message")
            }
            diagnostics.recordFailure(failure, category: .transcription)
        }
        let loadingFailure = MeetingOperationFailure.sanitized(
            NSError(domain: NSCocoaErrorDomain, code: 260, userInfo: userInfo), phase: .modelLoading)
        let preserved = MeetingFailurePresentation.failure(for: loadingFailure, phase: .preview)
        requireThat(preserved == loadingFailure, "An outer layer replaced the failing model-loading phase")
        requireThat(MeetingFailurePresentation.previewMessage(for: preserved).contains("모델 준비"),
                    "A loading failure must explain model preparation")
        requireThat(MeetingFailurePresentation.previewMessage(for: .init(phase: .inference, reason: .failed))
            .contains("정밀 전사"), "An inference failure must explain the saved-audio retry path")
        diagnostics.recordFailure(preserved, category: .transcription)
        diagnostics.recordFailure(MeetingOperationFailure.sanitized(CancellationError(), phase: .preview), category: .transcription)
        diagnostics.recordFailure(MeetingFailurePresentation.failure(
            for: NSError(domain: fakePrivateValues[1], code: 987_654_321, userInfo: userInfo), phase: .inference),
            category: .transcription)
        let coreMLFailure = MeetingFailurePresentation.failure(
            for: NSError(domain: MLModelErrorDomain, code: 17, userInfo: userInfo), phase: .modelLoading)
        requireThat(coreMLFailure.errorDomain == .coreML && coreMLFailure.errorCode == 17,
                    "Core ML failures must retain their reviewed domain and numeric code")
        diagnostics.recordFailure(coreMLFailure, category: .transcription, stage: .preview)
        let expectedFailureCount = 6 + captureCases.count + modelCases.count + 4
        diagnostics.flush()
        let exported = try await diagnostics.exportReport()
        let text = String(decoding: exported, as: UTF8.self)
        for value in fakePrivateValues { requireThat(!text.contains(value), "A private error value reached the export") }
        requireThat(!text.contains("987654321"), "Unrecognized NSError domain leaked an arbitrary numeric code")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DiagnosticReport.self, from: exported)
        requireThat(report.events.count == expectedFailureCount, "Expected all safe operational failure events")
        requireThat(report.events.first(where: { $0.category == .keychain })?.fields["errorCode"] == .integer(-25308),
                    "OSStatus must retain its actionable numeric code")
        requireThat(report.events.first(where: { $0.category == .update })?.fields["errorCode"] == .integer(-1009),
                    "Known URL errors must retain only their safe numeric code")
        requireThat(report.events.contains(where: { $0.fields["reason"] == .state(.validation) }),
                    "WorkLog failures must preserve their reviewed error class")
        requireThat(report.events.first(where: { $0.category == .ai })?.fields["reason"] == .state(.rateLimit),
                    "AI failures must preserve their reviewed error class")
        requireThat(report.events.allSatisfy { $0.fields["osMajor"] != nil },
                    "Events must include numeric OS provenance")
        for (_, reason, _) in captureCases {
            requireThat(report.events.contains { $0.fields["phase"] == .state(.recordingStart)
                && $0.fields["reason"] == .state(reason) }, "A capture classification was not exported")
        }
        requireThat(report.events.contains { $0.fields["phase"] == .state(.modelLoading)
            && $0.fields["errorDomain"] == .state(.cocoa) && $0.fields["errorCode"] == .integer(260) },
            "Model-loading failures must retain the phase and safe underlying error code")
        requireThat(report.events.contains { $0.fields["phase"] == .state(.modelLoading)
            && $0.fields["stage"] == .state(.preview)
            && $0.fields["errorDomain"] == .state(.coreML) && $0.fields["errorCode"] == .integer(17) },
            "Core ML model-loading failures must export the safe numeric code without userInfo")
        requireThat(report.events.contains { $0.fields["phase"] == .state(.preview)
            && $0.fields["reason"] == .state(.cancelled) && $0.level == .info },
            "Cancellation must remain informational after safe classification")
        print("PASS: raw NSError domain, description, userInfo, URL, path and token never reach the report")
        print("PASS: associated WorkLog/AI error messages stay private while typed failures remain present")
        print("PASS: production capture/model errors retain actionable reasons and phases without model paths")

        let stored = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in stored {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for value in fakePrivateValues { requireThat(!contents.contains(value), "A private error value reached disk") }
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            requireThat(permissions?.intValue == 0o600, "Diagnostic files must use private permissions")
        }
        print("PASS: JSONL storage contains only reviewed fields and has 0600 permissions")

        for attempt in 0..<100 {
            diagnostics.record(.operationStarted, category: .recording, fields: [.attempt: .integer(attempt)])
        }
        let status = await diagnostics.status()
        requireThat(status?.eventCount == 100 + expectedFailureCount, "Status must wait for all pending writes")
        try await diagnostics.deleteAll()
        let afterDelete = try decoder.decode(DiagnosticReport.self, from: await diagnostics.exportReport())
        requireThat(afterDelete.events.isEmpty, "Delete must remove stored diagnostics")
        diagnostics.record(.appReady, category: .application)
        let afterResume = await diagnostics.status()
        requireThat(afterResume?.eventCount == 1, "Logging must resume after deletion")
        print("PASS: async status/export/delete preserve queue ordering and logging resumes after deletion")
    }

    private static func requireThat(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}
