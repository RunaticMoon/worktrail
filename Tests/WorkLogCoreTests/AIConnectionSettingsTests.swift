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
        XCTAssertEqual(reopened.launchCredentialAccount, try reopened.aiConnection.credentialAccount(),
                       "The launch check reads the saved API key account")
        var disabled = env.settings; disabled.aiEnabled = false
        try env.updateSettings(disabled)
        XCTAssertNil(SettingsModel(environment: env, credentialStore: credentials).launchCredentialAccount)
        let data = try Data(contentsOf: env.options.paths.dataRoot.appendingPathComponent(AIConnectionSettingsStore.fileName))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fake-sensitive-key"))
    }
    @MainActor func testSavingConnectionCancelsRunningProviderAndStartsNewWork() async throws {
        let root = root()
        let store = AIConnectionSettingsStore(dataRoot: root.appendingPathComponent("data"))
        let started = expectation(description: "old provider started")
        let cancelled = expectation(description: "old provider cancelled")
        let old = WaitingConnectionProvider(started: started, cancelled: cancelled)
        let next = MockAIProvider()
        let configured = ConfiguredAIProvider(selection: { AIProviderSelection(connection: try store.load()) },
            factory: { selection -> any AIProvider in
                if selection.connection.kind == .codexCLI { return old }; return next
            })
        let env = try AppEnvironment.open(AppEnvironmentOptions(
            paths: AppPaths(dataRoot: root.appendingPathComponent("data"), backupRoot: root.appendingPathComponent("backups")),
            keyStore: InMemoryVaultKeyStore(), authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(),
            aiProvider: configured, clock: FixedClock(Date(timeIntervalSince1970: 1_800_000_000)), ids: SequentialIDGenerator()))
        let runner = try XCTUnwrap(env.aiRunner)
        let first = Task { try await runner.submit(AIJobRequest(jobType: .groundedAnswer, instructions: "", payloadJSON: "old")) }
        await fulfillment(of: [started], timeout: 2)
        let model = SettingsModel(environment: env)
        model.useDeepSeekPreset()
        XCTAssertFalse(model.save(apply: { _ in throw WorkLogError.storage("fixture") }))
        let cancelledBeforeSave = await old.cancelCount
        XCTAssertEqual(cancelledBeforeSave, 0)
        XCTAssertTrue(model.save())
        await fulfillment(of: [cancelled], timeout: 2)
        let firstResult = try await first.value
        XCTAssertEqual(firstResult.job.status, .cancelled, "Old provider deliberately returns a late success")
        XCTAssertEqual(firstResult.job.attempts, 0, "Connection cancellation does not consume retry budget")
        let second = try await runner.submit(AIJobRequest(jobType: .groundedAnswer, instructions: "", payloadJSON: "new"))
        XCTAssertEqual(second.job.status, .succeeded)
        XCTAssertEqual(next.runCount, 1)
    }

    @MainActor func testCoordinatorShutdownCancelsProviderAndLeavesScheduledJobPending() async throws {
        let started = expectation(description: "provider started")
        let cancelled = expectation(description: "provider cancelled")
        let provider = WaitingConnectionProvider(started: started, cancelled: cancelled)
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let repo = try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator())
        let runner = AIJobRunner(repo: repo, provider: provider, stagingRoot: root())
        let scheduler = SchedulerRunner(repo: repo, periods: Periods(), clock: clock,
                                         settings: AppSettings(), since: WorkDate("2027-01-14")!)
        let coordinator = ScheduledReportCoordinator(catchUp: {
            _ = try await scheduler.runDue { _ in
                _ = try await runner.submit(AIJobRequest(jobType: .performanceReport, instructions: "", payloadJSON: "{}"))
            }
        }, reevaluate: { _ in XCTFail("No new work during shutdown") })
        let startup = Task { try await coordinator.runCatchUp() }
        await fulfillment(of: [started], timeout: 2)
        await coordinator.shutdown()
        await fulfillment(of: [cancelled], timeout: 2)
        do { try await startup.value; XCTFail("cancelled") } catch is CancellationError { }
        XCTAssertTrue(try repo.scheduledJobs(states: [.running]).isEmpty)
        XCTAssertFalse(try repo.scheduledJobs(states: [.pending]).isEmpty)
        XCTAssertTrue(try repo.scheduledJobs().allSatisfy { $0.attempts == 0 })
        XCTAssertEqual(try repo.aiJobs(status: .cancelled).first?.attempts, 0)
    }

    @MainActor func testCancellingQueuedWorkDoesNotWaitForUnrelatedProvider() async throws {
        let started = expectation(description: "first provider started")
        let cancelled = expectation(description: "first provider cancelled")
        let queued = expectation(description: "second submission preflight")
        let completed = expectation(description: "queued cancellation completed")
        let provider = WaitingConnectionProvider(started: started, cancelled: cancelled)
        let repo = try WorkRepository.inMemory(ids: SequentialIDGenerator())
        let runner = AIJobRunner(repo: repo, provider: provider, stagingRoot: root())
        let first = Task { try await runner.submit(AIJobRequest(jobType: .groundedAnswer, instructions: "", payloadJSON: "first")) }
        await fulfillment(of: [started], timeout: 2)
        let second = Task {
            defer { completed.fulfill() }
            do {
                _ = try await runner.submit(AIJobRequest(jobType: .groundedAnswer, instructions: "", payloadJSON: "second"),
                                             preflight: { queued.fulfill() })
                XCTFail("Queued request must be cancelled")
            } catch is CancellationError { }
        }
        await fulfillment(of: [queued], timeout: 2)
        second.cancel()
        await fulfillment(of: [completed], timeout: 2)
        let cancelCount = await provider.cancelCount
        XCTAssertEqual(cancelCount, 0, "Cancelling the waiter must not cancel the lock owner")
        first.cancel()
        _ = try? await first.value
        await fulfillment(of: [cancelled], timeout: 2)
        _ = try await second.value
        XCTAssertTrue(try repo.aiJobs(status: .running).isEmpty)
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

private actor WaitingConnectionProvider: AIProvider {
    let started: XCTestExpectation
    let cancelled: XCTestExpectation
    var gate: CheckedContinuation<Void, Never>?
    var cancelCount = 0
    init(started: XCTestExpectation, cancelled: XCTestExpectation) { self.started = started; self.cancelled = cancelled }
    func checkCapabilities() async -> AICapabilities { AICapabilities(installed: true, protocolCompatible: true) }
    func getAccountStatus() async throws -> AIAccountState { .loggedOut }
    func beginOfficialLogin() async throws -> URL? { nil }
    func listAvailableSkills() async throws -> [DiscoveredSkill] { [] }
    func run(_ input: AIJobInput) async throws -> AIJobOutput {
        await withCheckedContinuation { gate = $0; started.fulfill() }
        return AIJobOutput(rawJSON: "{}")
    }
    func cancel(jobId: String) async {
        cancelCount += 1
        gate?.resume(); gate = nil
        cancelled.fulfill()
    }
}
