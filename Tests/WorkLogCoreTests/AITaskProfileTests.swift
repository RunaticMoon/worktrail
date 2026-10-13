import Foundation
import XCTest
@testable import WorkLogCore

final class AITaskProfileTests: XCTestCase {
    private var roots: [URL] = []
    private let ids = SequentialIDGenerator(prefix: "ai-profiles")
    private let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
        super.tearDown()
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AITaskProfileTests-\(ProcessInfo.processInfo.processIdentifier)-\(ids.make())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func environment() throws -> AppEnvironment {
        let root = try root()
        return try AppEnvironment.open(AppEnvironmentOptions(
            paths: AppPaths(dataRoot: root.appendingPathComponent("data"), backupRoot: root.appendingPathComponent("backup")),
            keyStore: InMemoryVaultKeyStore(), authenticator: MockDeviceAuthenticator(),
            pasteboard: InMemoryPasteboard(), clock: clock, ids: ids))
    }

    private var models: [DiscoveredAIModel] {
        [DiscoveredAIModel(id: "gpt-6-astra", title: "Astra", isDefault: true,
                           supportedEfforts: ["medium", "high"], defaultEffort: "medium"),
         DiscoveredAIModel(id: "gpt-6-luna", title: "Luna",
                           supportedEfforts: ["low", "medium", "high"], defaultEffort: "medium"),
         DiscoveredAIModel(id: "gpt-6.1-sol", title: "Sol",
                           supportedEfforts: ["low", "medium", "high"], defaultEffort: "medium")]
    }

    func testOlderInstallationAndEmptyDocumentUseAutomaticDefaultsWithoutWriting() throws {
        let root = try root()
        let store = AITaskProfileStore(dataRoot: root, ids: ids)
        XCTAssertEqual(try store.load(), AITaskProfiles())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(AITaskProfileStore.fileName).path))
        let old = try StableJSON.decode(AITaskProfiles.self, from: Data("{}".utf8))
        for type in AIJobType.allCases {
            XCTAssertEqual(old[type], AITaskProfile())
            XCTAssertEqual(old.executionProfile(for: type), AITaskProfile())
        }
    }

    func testRecommendationsUseDiscoveredModelsAndSupportedEfforts() {
        let profiles = AITaskProfiles(models: models)
        XCTAssertEqual(profiles.executionProfile(for: .memoTaskSuggestions), AITaskProfile(model: "gpt-6-luna", effort: "low"))
        XCTAssertEqual(profiles.executionProfile(for: .queryPlan), AITaskProfile(model: "gpt-6-luna", effort: "low"))
        XCTAssertEqual(profiles.executionProfile(for: .evidenceQuiz), AITaskProfile(model: "gpt-6-luna", effort: "medium"))
        XCTAssertEqual(profiles.executionProfile(for: .submissionWeekly), AITaskProfile(model: "gpt-6.1-sol", effort: "medium"))
        XCTAssertEqual(profiles.executionProfile(for: .groundedAnswer), AITaskProfile(model: "gpt-6.1-sol", effort: "medium"))
        XCTAssertEqual(profiles.executionProfile(for: .performanceReport), AITaskProfile(model: "gpt-6.1-sol", effort: "high"))

        let fallback = AITaskProfiles(models: [models[0]])
        XCTAssertEqual(fallback.executionProfile(for: .queryPlan), AITaskProfile(model: "gpt-6-astra", effort: "medium"))
    }

    @MainActor func testSelectionsPersistReloadAndResetWithoutChangingOtherJobs() async throws {
        let env = try environment()
        let settings = SettingsModel(environment: env)
        await settings.refreshModels(provider: Catalog(models: models))
        settings.setModel("gpt-6-astra", for: .performanceReport)
        settings.setEffort("high", for: .performanceReport)
        XCTAssertTrue(settings.hasChanges)
        XCTAssertTrue(settings.save())
        XCTAssertFalse(settings.hasChanges)

        let loaded = SettingsModel(environment: env)
        XCTAssertEqual(loaded.modelSelection(for: .performanceReport), "gpt-6-astra")
        XCTAssertEqual(loaded.effortSelection(for: .performanceReport), "high")
        XCTAssertEqual(loaded.modelSelection(for: .queryPlan), "")
        loaded.setModel("gpt-6-luna", for: .performanceReport)
        loaded.reset()
        XCTAssertEqual(loaded.modelSelection(for: .performanceReport), "gpt-6-astra")

        let url = env.options.paths.dataRoot.appendingPathComponent(AITaskProfileStore.fileName)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        loaded.restoreDefaultAIProfiles()
        XCTAssertTrue(loaded.save())
        XCTAssertEqual(try AITaskProfileStore(dataRoot: env.options.paths.dataRoot).load().profiles, [:])
    }

    @MainActor func testFailedHotkeyApplyRestoresPreviousProfiles() async throws {
        let env = try environment()
        let settings = SettingsModel(environment: env)
        await settings.refreshModels(provider: Catalog(models: models))
        XCTAssertTrue(settings.save())
        let store = AITaskProfileStore(dataRoot: env.options.paths.dataRoot, ids: ids)
        let before = try store.load()
        settings.setModel("gpt-6-astra", for: .groundedAnswer)
        XCTAssertFalse(settings.save(apply: { _ in throw WorkLogError.validation("fake registration failure") }))
        XCTAssertEqual(try store.load(), before)
        XCTAssertTrue(settings.hasChanges)
    }

    @MainActor func testChangingModelDropsUnsupportedEffortAndCatalogFailureKeepsSelection() async throws {
        let settings = SettingsModel(environment: try environment())
        await settings.refreshModels(provider: Catalog(models: models))
        settings.setModel("gpt-6-luna", for: .queryPlan)
        settings.setEffort("low", for: .queryPlan)
        settings.setModel("gpt-6-astra", for: .queryPlan)
        XCTAssertEqual(settings.effortSelection(for: .queryPlan), "")
        XCTAssertEqual(settings.effortOptions(for: .queryPlan).map(\.id), ["", "medium", "high"])
        await settings.refreshModels(provider: Catalog(models: [], fails: true))
        XCTAssertEqual(settings.modelSelection(for: .queryPlan), "gpt-6-astra")
        XCTAssertEqual(settings.modelOptions(for: .queryPlan).count, 4)
    }

    @MainActor func testResetDiscardsUnsavedCatalogAndRestoresEmptyCatalogMessage() async throws {
        let settings = SettingsModel(environment: try environment())
        let initialMessage = settings.modelCatalogMessage
        await settings.refreshModels(provider: Catalog(models: models))
        XCTAssertEqual(settings.modelOptions(for: .queryPlan).count, 4)
        XCTAssertNotEqual(settings.modelCatalogMessage, initialMessage)
        settings.reset()
        XCTAssertEqual(settings.modelOptions(for: .queryPlan).map(\.id), [""])
        XCTAssertEqual(settings.modelCatalogMessage, initialMessage)
        XCTAssertFalse(settings.hasChanges)
    }

    @MainActor func testCorruptProfilesAreNotOverwrittenByUnrelatedSettingsSave() throws {
        let env = try environment()
        let url = env.options.paths.dataRoot.appendingPathComponent(AITaskProfileStore.fileName)
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: url)
        let settings = SettingsModel(environment: env)
        settings.draft.backupRetentionDays = 33
        XCTAssertFalse(settings.save())
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testProfilesTravelWithBackupAndRestore() throws {
        let env = try environment()
        let original = AITaskProfiles(profiles: [AIJobType.performanceReport.rawValue:
            AITaskProfile(model: "fake-company-model", effort: "high")], models: models)
        try AITaskProfileStore(dataRoot: env.options.paths.dataRoot, ids: ids).save(original)
        let backup = try env.backup.createBackup(reason: .manual)
        XCTAssertTrue(backup.manifest.files.contains { $0.name == AITaskProfileStore.fileName })

        let restoreRoot = try root()
        let target = AppPaths(dataRoot: restoreRoot.appendingPathComponent("data"), backupRoot: restoreRoot.appendingPathComponent("backup"))
        try BackupService.restore(backup, into: target, keyStore: InMemoryVaultKeyStore(), includeVault: false, clock: clock)
        XCTAssertEqual(try AITaskProfileStore(dataRoot: target.dataRoot).load(), original)
    }

    func testDailyBackupDetectsProfileOnlyChangesAndSkipsUnchangedProfiles() throws {
        let env = try environment()
        let store = AITaskProfileStore(dataRoot: env.options.paths.dataRoot, ids: ids)
        _ = try env.backup.createBackup(reason: .manual)
        var profiles = AITaskProfiles(models: models)
        profiles[.performanceReport] = AITaskProfile(model: "gpt-6-astra", effort: "high")
        try store.save(profiles)

        // A profile added after an older backup must be noticed even with unchanged DBs.
        clock.advance(by: 24 * 60 * 60)
        let added = try XCTUnwrap(env.backup.createDailyBackupIfChanged(calendar: env.calendar))
        let backedUp = try AITaskProfileStore(dataRoot: added.directory).load()
        XCTAssertEqual(backedUp, profiles)

        // Detect edits as well as initial creation, and do not make redundant daily copies.
        profiles[.performanceReport].effort = "medium"
        try store.save(profiles)
        clock.advance(by: 24 * 60 * 60)
        let edited = try XCTUnwrap(env.backup.createDailyBackupIfChanged(calendar: env.calendar))
        XCTAssertEqual(try AITaskProfileStore(dataRoot: edited.directory).load(), profiles)
        clock.advance(by: 24 * 60 * 60)
        XCTAssertNil(try env.backup.createDailyBackupIfChanged(calendar: env.calendar))
    }

    func testModelDiscoveryPaginatesAndUsesOnlyAdvertisedEfforts() async throws {
        let server = FakeCodexServer()
        server.script.mutate {
            $0.modelPages[""] = json(#"{"data":[{"id":"entry-1","model":"gpt-6-luna","displayName":"Luna","isDefault":false,"supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Fast"}],"defaultReasoningEffort":"low"}],"nextCursor":"page-2"}"#)
            $0.modelPages["page-2"] = json(#"{"data":[{"id":"entry-2","model":"gpt-6.1-sol","displayName":"Sol","isDefault":true,"supportedReasoningEfforts":[{"reasoningEffort":"high","description":"Deep"}],"defaultReasoningEffort":"high"}],"nextCursor":null}"#)
        }
        let provider = CodexAppServerProvider(config: CodexProviderConfig(stagingRoot: try root()), transportFactory: { server })
        XCTAssertTrue(server.messages.isEmpty)
        let models = try await provider.listAvailableModels()
        XCTAssertEqual(models.map(\.id), ["gpt-6-luna", "gpt-6.1-sol"])
        XCTAssertEqual(models.map(\.supportedEfforts), [["low"], ["high"]])
        XCTAssertEqual(server.messages(withMethod: "model/list").last?["params"]?["cursor"], .string("page-2"))
        XCTAssertFalse(server.methods.contains("account/read"))
    }

    func testRuntimeRoutesByJobAndReadsChangedSettingsWithoutRestart() async throws {
        let server = successfulServer()
        let root = try root()
        let store = AITaskProfileStore(dataRoot: root, ids: ids)
        var profiles = AITaskProfiles(models: models)
        try store.save(profiles)
        let provider = CodexAppServerProvider(config: CodexProviderConfig(stagingRoot: root),
            profileResolver: { try store.load().executionProfile(for: $0) }, transportFactory: { server })
        _ = try await provider.run(input(.queryPlan))
        _ = try await provider.run(input(.performanceReport))
        profiles[.queryPlan] = AITaskProfile(model: "gpt-6-astra", effort: "high")
        try store.save(profiles)
        _ = try await provider.run(input(.queryPlan))
        let turns = server.messages(withMethod: "turn/start").compactMap { $0["params"] }
        XCTAssertEqual(turns.compactMap { $0["model"]?.stringValue }, ["gpt-6-luna", "gpt-6.1-sol", "gpt-6-astra"])
        XCTAssertEqual(turns.compactMap { $0["effort"]?.stringValue }, ["low", "high", "high"])
        XCTAssertEqual(server.messages(withMethod: "thread/start").last?["params"]?["model"], .string("gpt-6-astra"))
    }

    func testFirstAutomaticRunDiscoversCatalogAndGracefullyFallsBackIfUnavailable() async throws {
        for supported in [true, false] {
            let server = successfulServer()
            server.script.mutate {
                if supported {
                    $0.results["model/list"] = json(#"{"data":[{"model":"gpt-6-luna","displayName":"Luna","isDefault":true,"supportedReasoningEfforts":[{"reasoningEffort":"low"}],"defaultReasoningEffort":"low"}],"nextCursor":null}"#)
                } else { $0.errors["model/list"] = (-32601, "unsupported") }
            }
            let provider = CodexAppServerProvider(config: CodexProviderConfig(stagingRoot: try root()),
                profileResolver: { _ in AITaskProfile() }, transportFactory: { server })
            XCTAssertTrue(server.messages.isEmpty)
            _ = try await provider.run(input(.queryPlan))
            let turn = server.messages(withMethod: "turn/start").last?["params"]
            XCTAssertEqual(turn?["model"], supported ? .string("gpt-6-luna") : nil)
            XCTAssertEqual(turn?["effort"], supported ? .string("low") : nil)
            XCTAssertTrue(server.methods.contains("model/list"))
        }
    }

    private struct Catalog: AIModelCatalogProvider {
        var models: [DiscoveredAIModel]
        var fails = false
        func listAvailableModels() async throws -> [DiscoveredAIModel] {
            if fails { throw AIProviderError(.unknown, "fake") }
            return models
        }
    }

    private func json(_ value: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(value.utf8)) }
    private func input(_ type: AIJobType) -> AIJobInput {
        AIJobInput(jobId: ids.make(), jobType: type, instructions: "fake instructions", payloadJSON: "{}")
    }
    private func successfulServer() -> FakeCodexServer {
        let server = FakeCodexServer()
        server.script.mutate {
            $0.results["thread/start"] = json(#"{"thread":{"id":"thread-1"}}"#)
            $0.results["turn/start"] = json(#"{"turn":{"id":"turn-1"}}"#)
            $0.followups["turn/start"] = [
                json(#"{"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","delta":"{}"}}"#),
                json(#"{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed","items":[]}}}"#),
            ]
        }
        return server
    }
}
