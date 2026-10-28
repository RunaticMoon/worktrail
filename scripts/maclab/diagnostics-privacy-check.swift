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
        diagnostics.flush()
        let exported = try await diagnostics.exportReport()
        let text = String(decoding: exported, as: UTF8.self)
        for value in fakePrivateValues { requireThat(!text.contains(value), "A private error value reached the export") }
        requireThat(!text.contains("987654321"), "Unrecognized NSError domain leaked an arbitrary numeric code")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DiagnosticReport.self, from: exported)
        requireThat(report.events.count == 6, "Expected all six safe operational failure events")
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
        print("PASS: raw NSError domain, description, userInfo, URL, path and token never reach the report")
        print("PASS: associated WorkLog/AI error messages stay private while typed failures remain present")

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
        requireThat(status?.eventCount == 106, "Status must wait for all pending writes")
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
