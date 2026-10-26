import Foundation
import XCTest
@testable import WorkLogCore

/// Fake accounts and model metadata only. No OAuth tokens, Keychain or network access.
final class ChatGPTSettingsTests: XCTestCase {
    private var roots: [URL] = []
    private let ids = SequentialIDGenerator(prefix: "chatgpt-settings")

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
        super.tearDown()
    }

    private func environment() throws -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatGPTSettingsTests-\(UUID().uuidString)")
        roots.append(root)
        let environment = try AppEnvironment.open(AppEnvironmentOptions(
            paths: AppPaths(dataRoot: root.appendingPathComponent("data"),
                            backupRoot: root.appendingPathComponent("backups")),
            keyStore: InMemoryVaultKeyStore(), authenticator: MockDeviceAuthenticator(),
            pasteboard: InMemoryPasteboard(), aiProvider: MockAIProvider(),
            clock: FixedClock(Date(timeIntervalSince1970: 1_800_000_000)), ids: ids))
        var settings = environment.settings
        settings.aiEnabled = true
        try environment.updateSettings(settings)
        return environment
    }

    private var oldModel: DiscoveredAIModel {
        DiscoveredAIModel(id: "fixture-old-account-model", title: "Previous account model",
            isDefault: true, supportedEfforts: ["low", "high"], defaultEffort: "low")
    }

    @MainActor func testAccountSwitchClearsStoredCatalogAndRejectsLateAccountStatus() async throws {
        let environment = try environment()
        let store = AITaskProfileStore(dataRoot: environment.options.paths.dataRoot, ids: ids)
        let preferences = [AIJobType.meetingSummary.rawValue: AITaskProfile(model: oldModel.id, effort: "high")]
        try store.save(AITaskProfiles(profiles: preferences, models: [oldModel]))
        let settings = SettingsModel(environment: environment)
        await settings.checkAccount()
        XCTAssertEqual(settings.aiConnectionSummary, .connected)
        XCTAssertFalse(settings.hasChanges)

        let gate = ChatGPTSettingsGate()
        let oldAccount = DelayedSettingsAccount(gate: gate)
        let check = Task { await settings.checkAccount(provider: oldAccount) }
        await gate.waitUntilStarted()
        settings.accountConnectionChanged()
        let invalidationMessage = settings.accountMessage

        XCTAssertEqual(settings.aiConnectionSummary, .notConfigured)
        XCTAssertTrue(settings.aiTaskProfiles.models.isEmpty)
        XCTAssertEqual(settings.aiTaskProfiles.profiles, preferences)
        XCTAssertFalse(settings.hasChanges, "Invalidating account metadata must not create unsaved preference edits")
        XCTAssertEqual(try store.load(), AITaskProfiles(profiles: preferences, models: []))

        await gate.open()
        await check.value
        XCTAssertEqual(settings.aiConnectionSummary, .notConfigured)
        XCTAssertEqual(settings.accountMessage, invalidationMessage)
        XCTAssertFalse(settings.accountMessage.contains("previous-account@example.invalid"))
        XCTAssertFalse(settings.isCheckingAccount)
        let reopened = SettingsModel(environment: environment)
        XCTAssertTrue(reopened.aiTaskProfiles.models.isEmpty)
        XCTAssertEqual(reopened.aiTaskProfiles.profiles, preferences)
    }

    @MainActor func testAccountSwitchPreservesUnsavedChoicesWithoutPersistingThem() throws {
        let environment = try environment()
        let store = AITaskProfileStore(dataRoot: environment.options.paths.dataRoot, ids: ids)
        var persisted = AITaskProfiles(profiles: [AIJobType.performanceReport.rawValue:
            AITaskProfile(model: oldModel.id, effort: "low")], models: [oldModel])
        try store.save(persisted)
        let settings = SettingsModel(environment: environment)
        settings.setModel("fixture-unsaved-meeting-model", for: .meetingSummary)
        settings.setEffort("medium", for: .meetingSummary)
        settings.setEffort("high", for: .performanceReport)
        settings.draft.backupRetentionDays = 47
        settings.setSkill("fixture-unsaved-skill", for: .meetingSummary)
        let unsavedProfiles = settings.aiTaskProfiles.profiles
        let unsavedDraft = settings.draft

        // A separate committed settings edit must also survive cache invalidation.
        persisted[.queryPlan] = AITaskProfile(model: "fixture-other-saved-model", effort: "low")
        try store.save(persisted)
        settings.accountConnectionChanged()

        XCTAssertEqual(settings.aiTaskProfiles.profiles, unsavedProfiles)
        XCTAssertEqual(settings.draft, unsavedDraft)
        XCTAssertTrue(settings.aiTaskProfiles.models.isEmpty)
        XCTAssertTrue(settings.hasChanges)
        let after = try store.load()
        XCTAssertTrue(after.models.isEmpty)
        XCTAssertEqual(after.profiles, persisted.profiles)
        XCTAssertNil(after[.meetingSummary].model, "Account events must not silently save the settings draft")
        XCTAssertEqual(after[.performanceReport].effort, "low")
        XCTAssertNotEqual(environment.settings.backupRetentionDays, settings.draft.backupRetentionDays)
    }

    @MainActor func testLatePreviousCatalogIsDroppedAndNewAccountCanDiscoverAgain() async throws {
        let environment = try environment()
        let store = AITaskProfileStore(dataRoot: environment.options.paths.dataRoot, ids: ids)
        try store.save(AITaskProfiles(models: [oldModel]))
        let settings = SettingsModel(environment: environment)
        let gate = ChatGPTSettingsGate()
        let previousCatalog = DelayedSettingsCatalog(gate: gate, models: [oldModel])
        let refresh = Task { await settings.loadModelsIfNeeded(provider: previousCatalog) }
        await gate.waitUntilStarted()
        XCTAssertTrue(settings.isLoadingModels)
        settings.accountConnectionChanged()
        let invalidationMessage = settings.modelCatalogMessage

        await gate.open()
        await refresh.value
        XCTAssertFalse(settings.isLoadingModels)
        XCTAssertTrue(settings.aiTaskProfiles.models.isEmpty)
        XCTAssertEqual(settings.modelCatalogMessage, invalidationMessage)
        XCTAssertTrue(try store.load().models.isEmpty)

        let newModel = DiscoveredAIModel(id: "fixture-new-account-model", title: "Current account model",
            isDefault: true, supportedEfforts: ["medium"], defaultEffort: "medium")
        let currentCatalog = CountingSettingsCatalog(models: [newModel])
        await settings.loadModelsIfNeeded(provider: currentCatalog)
        let requests = await currentCatalog.requestCount
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(settings.aiTaskProfiles.models, [newModel])
        XCTAssertFalse(settings.modelOptions(for: .meetingSummary).contains { $0.id == oldModel.id })
        XCTAssertTrue(try store.load().models.isEmpty, "Discovery remains a draft until the user saves settings")
    }
}

private actor ChatGPTSettingsGate {
    private var started = false
    private var isOpen = false
    private var starters: [CheckedContinuation<Void, Never>] = []
    private var releases: [CheckedContinuation<Void, Never>] = []

    func startAndWait() async {
        started = true
        starters.forEach { $0.resume() }; starters.removeAll()
        if !isOpen { await withCheckedContinuation { releases.append($0) } }
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { starters.append($0) } }
    }
    func open() {
        isOpen = true
        releases.forEach { $0.resume() }; releases.removeAll()
    }
}

private actor DelayedSettingsAccount: AIProvider {
    let gate: ChatGPTSettingsGate
    init(gate: ChatGPTSettingsGate) { self.gate = gate }
    func checkCapabilities() async -> AICapabilities { AICapabilities(installed: true, protocolCompatible: true) }
    func getAccountStatus() async throws -> AIAccountState {
        await gate.startAndWait()
        return .loggedIn(accountType: "fixture", email: "previous-account@example.invalid", planType: "fixture")
    }
    func beginOfficialLogin() async throws -> URL? { nil }
    func listAvailableSkills() async throws -> [DiscoveredSkill] { [] }
    func run(_ input: AIJobInput) async throws -> AIJobOutput { AIJobOutput(rawJSON: "{}") }
    func cancel(jobId: String) async { }
}

private struct DelayedSettingsCatalog: AIModelCatalogProvider {
    let gate: ChatGPTSettingsGate
    let models: [DiscoveredAIModel]
    func listAvailableModels() async throws -> [DiscoveredAIModel] {
        await gate.startAndWait()
        return models
    }
}

private actor CountingSettingsCatalog: AIModelCatalogProvider {
    let models: [DiscoveredAIModel]
    private(set) var requestCount = 0
    init(models: [DiscoveredAIModel]) { self.models = models }
    func listAvailableModels() async throws -> [DiscoveredAIModel] {
        requestCount += 1
        return models
    }
}
