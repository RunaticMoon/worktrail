import Foundation
import XCTest
@testable import WorkLogCore

// AIJobRunner: 영속 AI 작업 실행기·중복 방지·호출 전 차단 검증.
// 실제 codex 실행·네트워크는 없다. provider는 MockAIProvider 또는 테스트 내부 가짜 클래스만 사용한다.
final class AIJobRunnerTests: XCTestCase {

    private let baseDate = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - Helpers

    private func makeRepo() throws -> WorkRepository {
        try WorkRepository.inMemory(clock: FixedClock(baseDate), ids: SequentialIDGenerator())
    }

    private func makeTempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wlog-aijob-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRequest(jobType: AIJobType = .groundedAnswer,
                             payload: String = #"{"query":"오늘 한 일"}"#,
                             instructions: String = "P-00 지침",
                             templateVersionId: String? = "tmpl-v1",
                             skill: SkillRef? = nil,
                             nonce: String? = nil) -> AIJobRequest {
        AIJobRequest(jobType: jobType,
                     periodStart: WorkDate("2026-09-28"),
                     periodEndExclusive: WorkDate("2026-10-05"),
                     instructions: instructions,
                     payloadJSON: payload,
                     templateVersionId: templateVersionId,
                     skill: skill,
                     regenerationNonce: nonce)
    }

    // MARK: 1. 성공 실행

    func testSuccessRunStoresSucceededOutput() async throws {
        let repo = try makeRepo()
        let mock = MockAIProvider(responses: [.groundedAnswer: #"{"answer":"ok"}"#])
        let runner = AIJobRunner(repo: repo, provider: mock, stagingRoot: makeTempRoot())

        let result = try await runner.submit(makeRequest())

        XCTAssertEqual(result.job.status, .succeeded)
        XCTAssertEqual(result.job.attempts, 1)
        XCTAssertFalse(result.reusedExisting)
        XCTAssertNil(result.job.lastErrorClass)
        XCTAssertEqual(result.output?.rawJSON, #"{"answer":"ok"}"#)
        XCTAssertEqual(mock.runCount, 1)

        // result_json에서 output 복원
        let stored = try XCTUnwrap(try repo.aiJob(id: result.job.id))
        XCTAssertEqual(stored.status, .succeeded)
        let restored = try StableJSON.decode(AIJobOutput.self, from: try XCTUnwrap(stored.resultJSON))
        XCTAssertEqual(restored, result.output)

        // provider에 전달된 jobId 일치
        XCTAssertEqual(mock.receivedInputs.first?.jobId, result.job.id)
        XCTAssertEqual(mock.receivedInputs.first?.jobType, .groundedAnswer)
    }

    // MARK: 2. 같은 요청 재제출 → 재사용, 행 1개, 호출 증가 없음 (PERF-05)

    func testResubmitSameRequestReusesSucceededRow() async throws {
        let repo = try makeRepo()
        let mock = MockAIProvider(responses: [.groundedAnswer: #"{"answer":"ok"}"#])
        let runner = AIJobRunner(repo: repo, provider: mock, stagingRoot: makeTempRoot())

        let request = makeRequest()
        let first = try await runner.submit(request)
        let second = try await runner.submit(request)

        XCTAssertTrue(second.reusedExisting)
        XCTAssertEqual(second.job.id, first.job.id)
        XCTAssertEqual(second.output?.rawJSON, #"{"answer":"ok"}"#)
        XCTAssertEqual(mock.runCount, 1)
        XCTAssertEqual(try repo.db.scalarInt("SELECT COUNT(*) FROM ai_job"), 1)
    }

    // MARK: 3. regenerationNonce가 다르면 새 행·새 호출

    func testDifferentRegenerationNonceCreatesNewRow() async throws {
        let repo = try makeRepo()
        let mock = MockAIProvider(responses: [.groundedAnswer: "{}"])
        let runner = AIJobRunner(repo: repo, provider: mock, stagingRoot: makeTempRoot())

        let a = try await runner.submit(makeRequest(nonce: "n-1"))
        let b = try await runner.submit(makeRequest(nonce: "n-2"))

        XCTAssertNotEqual(a.job.id, b.job.id)
        XCTAssertNotEqual(a.job.idempotencyKey, b.job.idempotencyKey)
        XCTAssertEqual(mock.runCount, 2)
        XCTAssertEqual(try repo.db.scalarInt("SELECT COUNT(*) FROM ai_job"), 2)
    }

    // MARK: 4. digest·key 민감도

    func testDigestAndKeyChangeWithInputs() {
        let base = makeRequest()

        var changed = base
        changed.payloadJSON += " "
        XCTAssertNotEqual(AIJobRunner.inputDigest(base), AIJobRunner.inputDigest(changed))
        XCTAssertNotEqual(AIJobRunner.idempotencyKey(base), AIJobRunner.idempotencyKey(changed))

        var template = base
        template.templateVersionId = "tmpl-v2"
        XCTAssertEqual(AIJobRunner.inputDigest(base), AIJobRunner.inputDigest(template))
        XCTAssertNotEqual(AIJobRunner.idempotencyKey(base), AIJobRunner.idempotencyKey(template))

        var skillA = base
        skillA.skill = SkillRef(name: "weekly", contentHash: "hash-a")
        var skillB = base
        skillB.skill = SkillRef(name: "weekly", contentHash: "hash-b")
        XCTAssertNotEqual(AIJobRunner.idempotencyKey(skillA), AIJobRunner.idempotencyKey(skillB))
        XCTAssertNotEqual(AIJobRunner.idempotencyKey(base), AIJobRunner.idempotencyKey(skillA))
    }

    // MARK: 5. 오류 분류

    func testErrorClassificationMapsProviderErrors() async throws {
        let cases: [(AIErrorClass, AIJobStatus)] = [
            (.notLoggedIn, .blockedAuth),
            (.authExpired, .blockedAuth),
            (.policyRestricted, .blockedPolicy),
            (.cancelled, .cancelled),
            (.rateLimited, .failed),
        ]
        for (errorClass, expectedStatus) in cases {
            let repo = try makeRepo()
            let mock = MockAIProvider()
            mock.failure = AIProviderError(errorClass, "boom")
            let runner = AIJobRunner(repo: repo, provider: mock, stagingRoot: makeTempRoot())

            let result = try await runner.submit(makeRequest(payload: #"{"i":"\#(errorClass.rawValue)"}"#))

            XCTAssertEqual(result.job.status, expectedStatus, "\(errorClass)")
            XCTAssertEqual(result.job.lastErrorClass, errorClass, "\(errorClass)")
            XCTAssertNil(result.output, "\(errorClass)")
        }
    }

    func testGenericErrorBecomesFailedUnknown() async throws {
        let repo = try makeRepo()
        let provider = GenericErrorProvider()
        let runner = AIJobRunner(repo: repo, provider: provider, stagingRoot: makeTempRoot())

        let result = try await runner.submit(makeRequest())

        XCTAssertEqual(result.job.status, .failed)
        XCTAssertEqual(result.job.lastErrorClass, .unknown)
        XCTAssertNil(result.output)
    }

    // MARK: 6. 실패 후 재시도, maxAttempts 도달 시 호출 중단

    func testRetryReusesRowUntilSuccess() async throws {
        let repo = try makeRepo()
        let mock = MockAIProvider(responses: [.groundedAnswer: "{}"])
        mock.failure = AIProviderError(.network, "down")
        let runner = AIJobRunner(repo: repo, provider: mock, stagingRoot: makeTempRoot())
        let request = makeRequest()

        let first = try await runner.submit(request)
        XCTAssertEqual(first.job.status, .failed)
        XCTAssertEqual(first.job.attempts, 1)
        XCTAssertEqual(first.job.lastErrorClass, .network)
        XCTAssertFalse(first.reusedExisting)

        mock.failure = nil   // 이제 성공
        let second = try await runner.submit(request)
        XCTAssertEqual(second.job.id, first.job.id)      // 같은 행 재사용
        XCTAssertEqual(second.job.status, .succeeded)
        XCTAssertEqual(second.job.attempts, 2)
        XCTAssertEqual(mock.runCount, 2)
    }

    func testMaxAttemptsStopsProviderCalls() async throws {
        let repo = try makeRepo()
        let mock = MockAIProvider()
        mock.failure = AIProviderError(.rateLimited, "quota")
        let runner = AIJobRunner(repo: repo, provider: mock, stagingRoot: makeTempRoot(),
                                 maxAttempts: 2)
        let request = makeRequest()

        _ = try await runner.submit(request)   // attempts 1
        _ = try await runner.submit(request)   // attempts 2
        let third = try await runner.submit(request)   // 한도 도달 → 호출 안 함

        XCTAssertEqual(third.job.attempts, 2)
        XCTAssertEqual(third.job.status, .failed)
        XCTAssertNil(third.output)
        XCTAssertEqual(mock.runCount, 2)
    }

    // MARK: 7. 동시성 1

    func testConcurrentSubmitsRunOneAtATime() async throws {
        let repo = try makeRepo()
        let provider = SlowProvider(delayNanos: 30_000_000)
        let runner = AIJobRunner(repo: repo, provider: provider, stagingRoot: makeTempRoot())

        let requests = (0..<3).map { makeRequest(payload: #"{"i":\#($0)}"#) }

        try await withThrowingTaskGroup(of: AIJobResult.self) { group in
            for request in requests {
                group.addTask { try await runner.submit(request) }
            }
            for try await result in group {
                XCTAssertEqual(result.job.status, .succeeded)
            }
        }

        XCTAssertEqual(provider.maxConcurrent, 1)
        XCTAssertEqual(provider.runCount, 3)
    }

    // MARK: 8. 같은 key가 running 중이면 conflict

    func testSubmitWhileSameKeyRunningThrowsConflict() async throws {
        let repo = try makeRepo()
        let provider = GatedProvider()
        let runner = AIJobRunner(repo: repo, provider: provider, stagingRoot: makeTempRoot())
        let request = makeRequest()

        let firstTask = Task { try await runner.submit(request) }
        await provider.waitUntilStarted()   // 같은 key 행이 running 상태가 된 뒤

        do {
            _ = try await runner.submit(request)
            XCTFail("running 중 재제출은 conflict여야 한다")
        } catch let error as WorkLogError {
            guard case .conflict = error else {
                XCTFail("conflict가 아님: \(error)")
                return
            }
        }

        provider.open()
        let first = try await firstTask.value
        XCTAssertEqual(first.job.status, .succeeded)
        XCTAssertEqual(provider.runCount, 1)
    }

    // MARK: 9. AIPayloadGuard

    func testPayloadGuardBlocksBeforeCreatingRowOrCallingProvider() async throws {
        let canary = "SEC-CANARY-R-0001"
        let repo = try makeRepo()
        let mock = MockAIProvider()
        let runner = AIJobRunner(repo: repo, provider: mock, stagingRoot: makeTempRoot(),
                                 guard: AIPayloadGuard(blockedSubstrings: ["", canary]))

        // payload 안의 canary
        do {
            _ = try await runner.submit(makeRequest(payload: #"{"note":"\#(canary)"}"#))
            XCTFail("payload canary는 차단되어야 한다")
        } catch let error as WorkLogError {
            guard case .policyBlocked(let message) = error else {
                XCTFail("policyBlocked가 아님: \(error)")
                return
            }
            XCTAssertFalse(message.contains(canary))   // 차단 문자열 자체는 메시지에 넣지 않는다
        }

        // instructions 안의 canary
        do {
            _ = try await runner.submit(makeRequest(instructions: "지침 \(canary)"))
            XCTFail("instructions canary는 차단되어야 한다")
        } catch let error as WorkLogError {
            guard case .policyBlocked = error else {
                XCTFail("policyBlocked가 아님: \(error)")
                return
            }
        }

        XCTAssertEqual(mock.runCount, 0)
        XCTAssertEqual(try repo.db.scalarInt("SELECT COUNT(*) FROM ai_job"), 0)
    }

    func testPayloadGuardIgnoresEmptyRules() async throws {
        let repo = try makeRepo()
        let mock = MockAIProvider()
        let runner = AIJobRunner(repo: repo, provider: mock, stagingRoot: makeTempRoot(),
                                 guard: AIPayloadGuard(blockedSubstrings: [""]))

        let result = try await runner.submit(makeRequest())
        XCTAssertEqual(result.job.status, .succeeded)   // 빈 규칙은 무시되어 차단되지 않는다
        XCTAssertEqual(mock.runCount, 1)
    }

    // MARK: 10. recoverInterrupted

    func testRecoverInterruptedRevertsRunningRows() throws {
        let repo = try makeRepo()
        let clock = FixedClock(baseDate)
        for index in 0..<2 {
            let job = AIJob(id: "job-\(index)", type: AIJobType.groundedAnswer.rawValue,
                            idempotencyKey: "key-\(index)", inputDigest: "digest-\(index)",
                            status: .running, attempts: 1, lastErrorClass: nil, resultJSON: nil,
                            createdAt: clock.now(), updatedAt: clock.now())
            try repo.insertAIJob(job)
        }
        let runner = AIJobRunner(repo: repo, provider: MockAIProvider(), stagingRoot: makeTempRoot())

        let recovered = try runner.recoverInterrupted()

        XCTAssertEqual(recovered, 2)
        XCTAssertEqual(try repo.aiJobs(status: .running).count, 0)
        XCTAssertEqual(try repo.aiJobs(status: .queued).count, 2)
        XCTAssertEqual(try repo.aiJob(id: "job-0")?.status, .queued)
    }

    // MARK: 11. staging 정리

    func testStagingDirectoryRemovedAfterSuccess() async throws {
        let repo = try makeRepo()
        let root = makeTempRoot()
        let provider = StagingWriterProvider(root: root, shouldFail: false)
        let runner = AIJobRunner(repo: repo, provider: provider, stagingRoot: root)

        let result = try await runner.submit(makeRequest())

        XCTAssertEqual(result.job.status, .succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingPath(root, result.job.id)))
    }

    func testStagingDirectoryRemovedAfterFailure() async throws {
        let repo = try makeRepo()
        let root = makeTempRoot()
        let provider = StagingWriterProvider(root: root, shouldFail: true)
        let runner = AIJobRunner(repo: repo, provider: provider, stagingRoot: root)

        let result = try await runner.submit(makeRequest())

        XCTAssertEqual(result.job.status, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingPath(root, result.job.id)))
    }

    private func stagingPath(_ root: URL, _ jobId: String) -> String {
        root.appendingPathComponent(jobId, isDirectory: true).path
    }

    // MARK: 12. 출력 민감 마커 검사

    func testOutputWithCredentialMarkerIsNotStored() async throws {
        let repo = try makeRepo()
        let mock = MockAIProvider(responses: [
            .groundedAnswer: #"{"text":"see ~/.codex/auth.json refresh_token=abc"}"#,
        ])
        let runner = AIJobRunner(repo: repo, provider: mock, stagingRoot: makeTempRoot())

        let result = try await runner.submit(makeRequest())

        XCTAssertNil(result.output)
        XCTAssertEqual(result.job.status, .failed)
        XCTAssertEqual(result.job.lastErrorClass, .outputInvalid)
        XCTAssertEqual(result.job.attempts, 1)

        let stored = try XCTUnwrap(try repo.aiJob(id: result.job.id))
        XCTAssertEqual(stored.status, .failed)
        XCTAssertNil(stored.resultJSON)
    }

    func testOutputMarkerCheckIsCaseInsensitive() async throws {
        let repo = try makeRepo()
        let mock = MockAIProvider(responses: [
            .groundedAnswer: #"{"text":"-----BEGIN private key-----"}"#,
        ])
        let runner = AIJobRunner(repo: repo, provider: mock, stagingRoot: makeTempRoot())

        let result = try await runner.submit(makeRequest())

        XCTAssertNil(result.output)
        XCTAssertEqual(result.job.status, .failed)
        XCTAssertEqual(result.job.lastErrorClass, .outputInvalid)
    }

    func testOutputContainingBlockedPathIsNotStored() async throws {
        let repo = try makeRepo()
        let mock = MockAIProvider(responses: [
            .groundedAnswer: #"{"text":"/tmp/x/vault/vault.sqlite"}"#,
        ])
        // 입력에는 해당 경로가 없다 → payloadGuard가 아니라 출력 검사로 차단되어야 한다.
        let runner = AIJobRunner(repo: repo, provider: mock, stagingRoot: makeTempRoot(),
                                 guard: AIPayloadGuard(blockedSubstrings: ["/tmp/x/vault"]))

        let result = try await runner.submit(makeRequest())

        XCTAssertNil(result.output)
        XCTAssertEqual(result.job.status, .failed)
        XCTAssertEqual(result.job.lastErrorClass, .outputInvalid)
        let stored = try XCTUnwrap(try repo.aiJob(id: result.job.id))
        XCTAssertNil(stored.resultJSON)
    }

    func testCleanOutputStillSucceeds() async throws {
        let repo = try makeRepo()
        let mock = MockAIProvider(responses: [.groundedAnswer: #"{"answer":"ok"}"#])
        let runner = AIJobRunner(repo: repo, provider: mock, stagingRoot: makeTempRoot())

        let result = try await runner.submit(makeRequest())

        XCTAssertEqual(result.job.status, .succeeded)
        XCTAssertEqual(result.output?.rawJSON, #"{"answer":"ok"}"#)
        let stored = try XCTUnwrap(try repo.aiJob(id: result.job.id))
        XCTAssertNotNil(stored.resultJSON)
    }

    func testOutputGuardIgnoresEmptyRulesAndCleanText() {
        let standard = AIOutputGuard()
        XCTAssertFalse(standard.containsSensitiveContent(""))
        XCTAssertFalse(standard.containsSensitiveContent("오늘 한 일 요약"))

        let noRules = AIOutputGuard(markers: [], blockedSubstrings: [])
        XCTAssertFalse(noRules.containsSensitiveContent("일반 텍스트"))

        let emptyRules = AIOutputGuard(markers: [""], blockedSubstrings: [""])
        XCTAssertFalse(emptyRules.containsSensitiveContent("일반 텍스트"))

        // 대소문자 무시 비교
        XCTAssertTrue(standard.containsSensitiveContent("AUTH.JSON"))
        XCTAssertTrue(standard.containsSensitiveContent("bearer abc"))
    }
}

// MARK: - 테스트용 가짜 AIProvider (네트워크·프로세스·Secret 없음)

/// 실행 중 동시 개수를 기록하는 느린 provider.
private final class SlowProvider: AIProvider, @unchecked Sendable {
    let delayNanos: UInt64
    private let lock = NSLock()
    private var runningCount = 0
    private var peak = 0
    private var calls = 0

    init(delayNanos: UInt64) { self.delayNanos = delayNanos }

    var maxConcurrent: Int { lock.lock(); defer { lock.unlock() }; return peak }
    var runCount: Int { lock.lock(); defer { lock.unlock() }; return calls }

    func checkCapabilities() async -> AICapabilities {
        AICapabilities(installed: true, version: "slow", protocolCompatible: true)
    }
    func getAccountStatus() async throws -> AIAccountState {
        .loggedIn(accountType: "test", email: nil, planType: nil)
    }
    func beginOfficialLogin() async throws -> URL? { nil }
    func listAvailableSkills() async throws -> [DiscoveredSkill] { [] }
    func cancel(jobId: String) async {}

    func run(_ input: AIJobInput) async throws -> AIJobOutput {
        enterRun()
        try? await Task.sleep(nanoseconds: delayNanos)
        exitRun()
        return AIJobOutput(rawJSON: #"{"ok":true}"#, model: "slow", providerRef: nil)
    }

    // 동기 헬퍼에서 잠금을 다뤄 async 컨텍스트 경고를 피한다.
    private func enterRun() {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        runningCount += 1
        peak = max(peak, runningCount)
    }

    private func exitRun() {
        lock.lock(); defer { lock.unlock() }
        runningCount -= 1
    }
}

/// run이 시작되면 신호하고, open() 전까지 대기하는 provider.
private final class GatedProvider: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var calls = 0

    var runCount: Int { lock.lock(); defer { lock.unlock() }; return calls }

    func waitUntilStarted() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if startedOrEnqueue(continuation) { continuation.resume() }
        }
    }

    /// 이미 시작됐으면 true(즉시 resume), 아니면 대기열 등록 후 false.
    private func startedOrEnqueue(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if started { return true }
        startedWaiters.append(continuation)
        return false
    }

    func open() {
        let waiters = openAndDrain()
        waiters.forEach { $0.resume() }
    }

    private func openAndDrain() -> [CheckedContinuation<Void, Never>] {
        lock.lock(); defer { lock.unlock() }
        isOpen = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        return waiters
    }

    func checkCapabilities() async -> AICapabilities {
        AICapabilities(installed: true, version: "gated", protocolCompatible: true)
    }
    func getAccountStatus() async throws -> AIAccountState {
        .loggedIn(accountType: "test", email: nil, planType: nil)
    }
    func beginOfficialLogin() async throws -> URL? { nil }
    func listAvailableSkills() async throws -> [DiscoveredSkill] { [] }
    func cancel(jobId: String) async {}

    func run(_ input: AIJobInput) async throws -> AIJobOutput {
        let state = beginRun()
        state.starters.forEach { $0.resume() }

        if !state.alreadyOpen {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if openOrEnqueue(continuation) { continuation.resume() }
            }
        }
        return AIJobOutput(rawJSON: #"{"ok":true}"#, model: "gated", providerRef: nil)
    }

    private func beginRun() -> (starters: [CheckedContinuation<Void, Never>], alreadyOpen: Bool) {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        started = true
        let starters = startedWaiters
        startedWaiters.removeAll()
        return (starters, isOpen)
    }

    /// 이미 열렸으면 true(즉시 resume), 아니면 대기열 등록 후 false.
    private func openOrEnqueue(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if isOpen { return true }
        releaseWaiters.append(continuation)
        return false
    }
}

/// AIProviderError가 아닌 일반 오류를 던지는 provider(unknown 분류 확인).
private struct GenericError: Error {}

private final class GenericErrorProvider: AIProvider, @unchecked Sendable {
    func checkCapabilities() async -> AICapabilities {
        AICapabilities(installed: true, version: "bad", protocolCompatible: true)
    }
    func getAccountStatus() async throws -> AIAccountState {
        .loggedIn(accountType: "test", email: nil, planType: nil)
    }
    func beginOfficialLogin() async throws -> URL? { nil }
    func listAvailableSkills() async throws -> [DiscoveredSkill] { [] }
    func cancel(jobId: String) async {}
    func run(_ input: AIJobInput) async throws -> AIJobOutput { throw GenericError() }
}

/// stagingRoot/<jobId>에 파일을 남기고 성공 또는 실패하는 provider.
private final class StagingWriterProvider: AIProvider, @unchecked Sendable {
    let root: URL
    let shouldFail: Bool

    init(root: URL, shouldFail: Bool) {
        self.root = root
        self.shouldFail = shouldFail
    }

    func checkCapabilities() async -> AICapabilities {
        AICapabilities(installed: true, version: "staging", protocolCompatible: true)
    }
    func getAccountStatus() async throws -> AIAccountState {
        .loggedIn(accountType: "test", email: nil, planType: nil)
    }
    func beginOfficialLogin() async throws -> URL? { nil }
    func listAvailableSkills() async throws -> [DiscoveredSkill] { [] }
    func cancel(jobId: String) async {}

    func run(_ input: AIJobInput) async throws -> AIJobOutput {
        let dir = root.appendingPathComponent(input.jobId, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data("artifact".utf8).write(to: dir.appendingPathComponent("artifact.txt"))
        if shouldFail { throw AIProviderError(.rateLimited, "boom") }
        return AIJobOutput(rawJSON: "{}", model: "staging", providerRef: nil)
    }
}
