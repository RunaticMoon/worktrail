import Foundation

// 결정적 테스트용 AIProvider. 네트워크·프로세스·Secret을 전혀 다루지 않는다.
// 전달된 입력을 그대로 기록하고 미리 정한 rawJSON을 돌려준다.
public final class MockAIProvider: AIProvider, @unchecked Sendable {
    private let lock = NSLock()

    private var responses: [AIJobType: String]
    private var _failure: AIProviderError?
    private var _receivedInputs: [AIJobInput] = []
    private var _runCount = 0
    private var _cancelledJobIds: Set<String> = []
    private var _skills: [DiscoveredSkill] = []
    private var _accountState: AIAccountState = .loggedIn(accountType: "mock", email: nil, planType: nil)

    public init(responses: [AIJobType: String] = [:]) {
        self.responses = responses
    }

    /// 설정하면 run이 이 오류를 throw한다.
    public var failure: AIProviderError? {
        get { lock.lock(); defer { lock.unlock() }; return _failure }
        set { lock.lock(); _failure = newValue; lock.unlock() }
    }

    /// run에 전달된 입력 기록 (Secret 미포함 검사용).
    public var receivedInputs: [AIJobInput] {
        lock.lock(); defer { lock.unlock() }
        return _receivedInputs
    }

    public var runCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _runCount
    }

    public var cancelledJobIds: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(_cancelledJobIds)
    }

    public var skills: [DiscoveredSkill] {
        get { lock.lock(); defer { lock.unlock() }; return _skills }
        set { lock.lock(); _skills = newValue; lock.unlock() }
    }

    public var accountState: AIAccountState {
        get { lock.lock(); defer { lock.unlock() }; return _accountState }
        set { lock.lock(); _accountState = newValue; lock.unlock() }
    }

    // MARK: - AIProvider

    public func checkCapabilities() async -> AICapabilities {
        AICapabilities(installed: true, version: "mock", protocolCompatible: true)
    }

    public func getAccountStatus() async throws -> AIAccountState {
        accountState
    }

    public func beginOfficialLogin() async throws -> URL? {
        URL(string: "https://example.invalid/mock-login")
    }

    public func listAvailableSkills() async throws -> [DiscoveredSkill] {
        skills
    }

    public func run(_ input: AIJobInput) async throws -> AIJobOutput {
        let outcome = recordRun(input)
        if let failure = outcome.failure { throw failure }
        return AIJobOutput(rawJSON: outcome.raw, model: "mock", providerRef: "mock-\(outcome.count)")
    }

    public func cancel(jobId: String) async {
        markCancelled(jobId)
    }

    // 동기 컨텍스트에서 잠금을 다뤄 async 컨텍스트의 NSLock 경고를 피한다.
    private func recordRun(_ input: AIJobInput) -> (count: Int, failure: AIProviderError?, raw: String) {
        lock.lock(); defer { lock.unlock() }
        _receivedInputs.append(input)
        _runCount += 1
        return (_runCount, _failure, responses[input.jobType] ?? "{}")
    }

    private func markCancelled(_ jobId: String) {
        lock.lock(); defer { lock.unlock() }
        _cancelledJobIds.insert(jobId)
    }
}
