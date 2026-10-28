import Foundation
import XCTest
@testable import WorkLogCore

final class AIConnectionSettingsTests: XCTestCase {
    private var roots: [URL] = []
    private func root() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIConnectionSettingsTests-\(UUID().uuidString)")
        roots.append(root); return root
    }
    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown()
    }
    func testMissingSettingsDefaultsToCLIAndSaveRollsBackIfAppSaveFails() throws {
        let root = root(), store = AIConnectionSettingsStore(dataRoot: root)
        XCTAssertEqual(try store.load().kind, .codexCLI)
        let old = AIConnectionSettings()
        try store.save(old)
        let changed = AIConnectionSettings(kind: .openAICompatible)
        XCTAssertThrowsError(try store.save(changed, applying: { throw WorkLogError.validation("fixture") }))
        XCTAssertEqual(try store.load(), old)
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(AIConnectionSettingsStore.fileName).path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
    func testInvalidURLsRejectedBeforeCredentialAccess() throws {
        for url in ["http://api.example.invalid", "https://user:pass@example.invalid", "https://example.invalid?token=fake", "file:///tmp/x", "https://example.invalid/#key"] {
            XCTAssertThrowsError(try AIConnectionSettings(kind: .openAICompatible, baseURL: url).validate())
        }
        XCTAssertNoThrow(try AIConnectionSettings(kind: .openAICompatible, baseURL: "https://intranet.example.invalid:8443/v1").validate())
    }
    @MainActor func testSettingsSavePersistsEndpointAndKeepsKeyOutsideSettings() async throws {
        let root = root()
        let credentials = FakeServiceCredentials()
        let env = try AppEnvironment.open(AppEnvironmentOptions(
            paths: AppPaths(dataRoot: root.appendingPathComponent("data"), backupRoot: root.appendingPathComponent("backups")),
            keyStore: InMemoryVaultKeyStore(), authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(),
            aiProvider: MockAIProvider(), clock: FixedClock(Date(timeIntervalSince1970: 1_800_000_000)), ids: SequentialIDGenerator()))
        let model = SettingsModel(environment: env, credentialStore: credentials)
        XCTAssertEqual(credentials.reads, 0, "Initialization must not access credentials")
        model.useDeepSeekPreset()
        XCTAssertTrue(model.hasChanges)
        XCTAssertTrue(model.hasUnsavedAIConnection)
        let saved = await model.saveAPIKey("fake-sensitive-key")
        XCTAssertTrue(saved)
        XCTAssertTrue(model.save())
        XCTAssertFalse(model.hasUnsavedAIConnection)
        let reopened = SettingsModel(environment: env, credentialStore: credentials)
        XCTAssertEqual(reopened.aiConnection.kind, .openAICompatible)
        XCTAssertEqual(try credentials.read(account: reopened.aiConnection.credentialAccount()), "fake-sensitive-key")
        let data = try Data(contentsOf: env.options.paths.dataRoot.appendingPathComponent(AIConnectionSettingsStore.fileName))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fake-sensitive-key"))
    }
    func testChangedConnectionRejectsAlreadyQueuedWork() async throws {
        let selection = MutableFixtureSelection()
        let provider = ConfiguredAIProvider(selection: { selection.read() }, factory: { _ in MockAIProvider() })
        let generation = await provider.accountGeneration()
        selection.change()
        do {
            _ = try await provider.run(AIJobInput(jobId: "queued", jobType: .queryPlan, instructions: "", payloadJSON: "{}"),
                                       expectedAccountGeneration: generation)
            XCTFail("Queued request must not be sent to a newly selected endpoint")
        } catch let error as AIProviderError { XCTAssertEqual(error.errorClass, .cancelled) }
    }
    func testReplacingCredentialsInvalidatesQueuedWork() async throws {
        let provider = ConfiguredAIProvider(selection: { AIProviderSelection(connection: AIConnectionSettings()) }, factory: { _ in MockAIProvider() })
        let generation = await provider.accountGeneration()
        await provider.invalidateConnection()
        do {
            _ = try await provider.run(AIJobInput(jobId: "queued", jobType: .queryPlan, instructions: "", payloadJSON: "{}"),
                                       expectedAccountGeneration: generation)
            XCTFail("Queue must stay bound to previous credential")
        } catch let error as AIProviderError { XCTAssertEqual(error.errorClass, .cancelled) }
    }
}

private final class MutableFixtureSelection: @unchecked Sendable {
    private let lock = NSLock()
    private var selection = AIProviderSelection(connection: AIConnectionSettings())
    func read() -> AIProviderSelection { lock.lock(); defer { lock.unlock() }; return selection }
    func change() { lock.lock(); defer { lock.unlock() }; selection.connection.kind = .openAICompatible }
}
