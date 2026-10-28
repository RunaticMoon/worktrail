#if os(macOS)
import Foundation
import WorkLogCore

/// Operational outcomes only. Inputs, responses, account details and server addresses never enter diagnostics.
final class DiagnosticAIProvider: AIProvider, AIModelCatalogProvider, @unchecked Sendable {
    private let provider: any AIProvider
    init(_ provider: any AIProvider) { self.provider = provider }

    func checkCapabilities() async -> AICapabilities {
        let result = await provider.checkCapabilities()
        AppDiagnostics.shared.record(.operationSucceeded, category: .ai,
            fields: [.available: .flag(result.installed && result.protocolCompatible)])
        return result
    }
    func getAccountStatus() async throws -> AIAccountState {
        do { return try await provider.getAccountStatus() }
        catch { AppDiagnostics.shared.recordFailure(error, category: .ai); throw error }
    }
    func beginOfficialLogin() async throws -> URL? {
        do { return try await provider.beginOfficialLogin() }
        catch { AppDiagnostics.shared.recordFailure(error, category: .ai); throw error }
    }
    func listAvailableSkills() async throws -> [DiscoveredSkill] {
        do { return try await provider.listAvailableSkills() }
        catch { AppDiagnostics.shared.recordFailure(error, category: .ai); throw error }
    }
    func listAvailableModels() async throws -> [DiscoveredAIModel] {
        guard let catalog = provider as? any AIModelCatalogProvider else { return [] }
        do { return try await catalog.listAvailableModels() }
        catch { AppDiagnostics.shared.recordFailure(error, category: .ai); throw error }
    }
    func run(_ input: AIJobInput) async throws -> AIJobOutput {
        AppDiagnostics.shared.record(.operationStarted, category: .ai)
        do {
            let output = try await provider.run(input)
            AppDiagnostics.shared.record(.operationSucceeded, category: .ai)
            return output
        } catch { AppDiagnostics.shared.recordFailure(error, category: .ai); throw error }
    }
    func cancel(jobId: String) async {
        await provider.cancel(jobId: jobId)
        AppDiagnostics.shared.record(.operationSucceeded, category: .ai, fields: [.reason: .state(.cancelled)])
    }
}
#endif
