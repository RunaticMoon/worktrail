#if os(macOS)
import Foundation
import WorkLogCore

enum AIProviderFactory {
    static func make(paths: AppPaths, credentials: any ServiceCredentialStore = ServiceKeychainCredentialStore()) -> ConfiguredAIProvider {
        let connections = AIConnectionSettingsStore(dataRoot: paths.dataRoot)
        let profiles = AITaskProfileStore(dataRoot: paths.dataRoot)
        let profileResolver: @Sendable (AIJobType) throws -> AITaskProfile = { type in
            guard try SettingsStore(fileURL: paths.settingsFile).load().aiEnabled else {
                throw AIProviderError(.policyRestricted, "설정에서 AI 사용이 꺼져 있습니다.")
            }
            return try profiles.load()[type]
        }
        return ConfiguredAIProvider(selection: {
            AIProviderSelection(connection: try connections.load(),
                codexExecutablePath: try SettingsStore(fileURL: paths.settingsFile).load().codexExecutablePath)
        }, factory: { selected in
            switch selected.connection.kind {
            case .codexCLI:
                return DiagnosticAIProvider(CodexAppServerProvider(config: CodexProviderConfig(
                    executablePath: selected.codexExecutablePath,
                    stagingRoot: paths.dataRoot.appendingPathComponent("ai-jobs"),
                    blockedSkillPathPrefixes: [paths.dataRoot.path, paths.backupRoot.path]), profileResolver: profileResolver))
            case .openAICompatible:
                return DiagnosticAIProvider(OpenAICompatibleProvider(settings: selected.connection, credentials: credentials,
                    blockedSkillPathPrefixes: [paths.dataRoot.path, paths.backupRoot.path], profileResolver: profileResolver))
            }
        })
    }
}
#endif
