import XCTest
@testable import WorkLogCore

final class AIAccountQueueTests: XCTestCase {
    func testQueuedWorkIsCancelledWhenAccountChangesBeforeLockAcquisition() async throws {
        let repo = try WorkRepository.inMemory(clock: FixedClock(Date(timeIntervalSince1970: 1_800_000_000)), ids: SequentialIDGenerator())
        let provider = QueueAccountProvider()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("worklog-account-queue-" + UUIDGenerator().make())
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = AIJobRunner(repo: repo, provider: provider, stagingRoot: root)
        let first = Task { try await runner.submit(AIJobRequest(jobType: .meetingSummary, instructions: "fake", payloadJSON: "{\"first\":true}")) }
        await provider.waitUntilFirstRun()
        let second = Task { try await runner.submit(AIJobRequest(jobType: .submissionWeekly, instructions: "fake", payloadJSON: "{\"queued\":true}")) }
        await provider.waitUntilQueuedSnapshot()
        await provider.changeAccountAndReleaseFirst()
        _ = try await first.value
        let result = try await second.value
        XCTAssertEqual(result.job.status, .cancelled)
        XCTAssertEqual(result.job.lastErrorClass, .cancelled)
        XCTAssertNil(result.output)
        XCTAssertNil(try repo.aiJob(id: result.job.id)?.resultJSON)
        let count = await provider.runCount
        XCTAssertEqual(count, 1, "The queued request must never reach the provider after account switching")
    }
}

private actor QueueAccountProvider: AIAccountGenerationProvider {
    private var generation = 0
    private var generationReads = 0
    private var firstRun: CheckedContinuation<Void, Never>?
    private var snapshotWaiter: CheckedContinuation<Void, Never>?
    private var runWaiter: CheckedContinuation<Void, Never>?
    private(set) var runCount = 0
    func accountGeneration() async -> Int {
        generationReads += 1
        let captured = generation
        if generationReads >= 3 { snapshotWaiter?.resume(); snapshotWaiter = nil }
        return captured
    }
    func waitUntilFirstRun() async {
        if firstRun != nil { return }
        await withCheckedContinuation { runWaiter = $0 }
    }
    func waitUntilQueuedSnapshot() async {
        if generationReads >= 3 { return }
        await withCheckedContinuation { snapshotWaiter = $0 }
    }
    func changeAccountAndReleaseFirst() {
        generation += 1; firstRun?.resume(); firstRun = nil
    }
    func run(_ input: AIJobInput, expectedAccountGeneration: Int) async throws -> AIJobOutput {
        guard generation == expectedAccountGeneration else { throw AIProviderError(.cancelled, "fake account changed") }
        return try await run(input)
    }
    func run(_ input: AIJobInput) async throws -> AIJobOutput {
        runCount += 1
        if runCount == 1 {
            await withCheckedContinuation { continuation in
                firstRun = continuation; runWaiter?.resume(); runWaiter = nil
            }
        }
        return AIJobOutput(rawJSON: "{}")
    }
    func checkCapabilities() async -> AICapabilities { AICapabilities(installed: true, protocolCompatible: true) }
    func getAccountStatus() async throws -> AIAccountState { .loggedOut }
    func beginOfficialLogin() async throws -> URL? { nil }
    func listAvailableSkills() async throws -> [DiscoveredSkill] { [] }
    func cancel(jobId: String) async {}
}
