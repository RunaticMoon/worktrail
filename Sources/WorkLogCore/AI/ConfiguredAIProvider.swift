import Foundation

public struct AIProviderSelection: Equatable, Sendable {
    public var connection: AIConnectionSettings
    public var codexExecutablePath: String?
    public init(connection: AIConnectionSettings, codexExecutablePath: String? = nil) {
        self.connection = connection; self.codexExecutablePath = codexExecutablePath
    }
}

/// Keeps queued requests bound to their selected endpoint/CLI configuration.
public actor ConfiguredAIProvider: AIProvider, AIModelCatalogProvider, AIAccountGenerationProvider {
    private let selection: @Sendable () throws -> AIProviderSelection
    private let factory: @Sendable (AIProviderSelection) throws -> any AIProvider
    private var cachedSelection: AIProviderSelection?
    private var cachedProvider: (any AIProvider)?
    private var generation = 0
    private var running: [String: any AIProvider] = [:]
    public init(selection: @escaping @Sendable () throws -> AIProviderSelection,
                factory: @escaping @Sendable (AIProviderSelection) throws -> any AIProvider) {
        self.selection = selection; self.factory = factory
    }
    private func currentProvider() throws -> any AIProvider {
        let current = try selection()
        if current != cachedSelection {
            cachedSelection = current; cachedProvider = nil; generation += 1
        }
        if let cachedProvider { return cachedProvider }
        let provider = try factory(current); cachedProvider = provider; return provider
    }
    public func invalidateConnection() async {
        generation += 1; cachedProvider = nil
        let active = running
        for (job, provider) in active { await provider.cancel(jobId: job) }
    }
    public func accountGeneration() async -> Int { _ = try? currentProvider(); return generation }
    public func checkCapabilities() async -> AICapabilities {
        guard let provider = try? currentProvider() else { return AICapabilities(installed: true, protocolCompatible: false) }
        return await provider.checkCapabilities()
    }
    public func getAccountStatus() async throws -> AIAccountState { try await currentProvider().getAccountStatus() }
    public func beginOfficialLogin() async throws -> URL? { try await currentProvider().beginOfficialLogin() }
    public func listAvailableSkills() async throws -> [DiscoveredSkill] { try await currentProvider().listAvailableSkills() }
    public func listAvailableModels() async throws -> [DiscoveredAIModel] {
        guard let provider = try currentProvider() as? any AIModelCatalogProvider else { return [] }
        return try await provider.listAvailableModels()
    }
    public func run(_ input: AIJobInput) async throws -> AIJobOutput {
        let expected = await accountGeneration()
        return try await run(input, expectedAccountGeneration: expected)
    }
    public func run(_ input: AIJobInput, expectedAccountGeneration: Int) async throws -> AIJobOutput {
        let provider = try currentProvider()
        guard generation == expectedAccountGeneration else { throw changedConnectionError() }
        running[input.jobId] = provider
        defer { running.removeValue(forKey: input.jobId) }
        let output = try await provider.run(input)
        _ = try currentProvider()
        guard generation == expectedAccountGeneration else { throw changedConnectionError() }
        return output
    }
    public func cancel(jobId: String) async { await running[jobId]?.cancel(jobId: jobId) }
    private func changedConnectionError() -> AIProviderError {
        AIProviderError(.cancelled, "AI 연결 설정이 바뀌어 이전 연결의 작업을 취소했습니다. 다시 요청하세요.")
    }
}
