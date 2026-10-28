import XCTest
@testable import WorkLogCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ActivityImportTests: XCTestCase {
    private func connection() -> ActivityConnection {
        var value = ActivityConnection(source: .github)
        value.enabled = true; value.baseURL = "https://git.example.test"; value.account = "sample-user"
        return value
    }
    private func event(_ id: String = "event-1", title: String = "PR test") -> ImportedActivity {
        .init(id: id, occurredAt: SQLDate.parse("2026-10-27T16:00:00Z")!, title: title,
              detail: "가짜 활동", url: "https://git.example.test/demo/repo/pull/1")
    }

    func testImportUsesWorkTimezoneAndPreservesEditsAndTrash() throws {
        let repo = try WorkRepository.inMemory(ids: SequentialIDGenerator())
        let c = connection(), day = WorkDate("2026-10-28")!
        XCTAssertEqual(try repo.importActivities([event(), event()], connection: c), 1)
        let memo = try XCTUnwrap(repo.importedActivityRecords(on: day).first).memo
        XCTAssertTrue(try repo.memos(on: day).isEmpty)
        XCTAssertEqual(try repo.links(ownerType: .memo, ownerId: memo.id).count, 1)
        _ = try repo.updateMemoBody(id: memo.id, body: "사용자가 고친 기록", workDate: day)
        XCTAssertEqual(try repo.importActivities([event()], connection: c), 0)
        XCTAssertEqual(try repo.memo(id: memo.id)?.body, "사용자가 고친 기록")
        try repo.softDeleteMemo(id: memo.id)
        XCTAssertEqual(try repo.importActivities([event()], connection: c), 0)
        XCTAssertTrue(try repo.memos(on: day).isEmpty)
        XCTAssertEqual(try repo.db.queryV("SELECT * FROM imported_activity").count, 1)
    }

    func testExternalIDsAreScopedToServerAndAccount() throws {
        let repo = try WorkRepository.inMemory(ids: SequentialIDGenerator())
        var c = connection()
        XCTAssertEqual(try repo.importActivities([event()], connection: c), 1)
        c.baseURL = "https://other.example.test"
        XCTAssertEqual(try repo.importActivities([event()], connection: c), 1)
        c.account = "other-user"
        XCTAssertEqual(try repo.importActivities([event()], connection: c), 1)
    }

    func testImportBatchRollsBackOnStorageFailure() throws {
        let repo = try WorkRepository.inMemory(ids: SequentialIDGenerator())
        try repo.db.execute("CREATE TRIGGER reject_fixture BEFORE INSERT ON memo WHEN NEW.body LIKE '%reject-fixture%' BEGIN SELECT RAISE(ABORT, 'fixture'); END;")
        XCTAssertThrowsError(try repo.importActivities([event(), event("event-2", title: "reject-fixture")], connection: connection()))
        XCTAssertTrue(try repo.memos(on: WorkDate("2026-10-28")!).isEmpty)
        XCTAssertTrue(try repo.db.queryV("SELECT * FROM imported_activity").isEmpty)
    }

    func testSettingsRoundTripExcludesTokensAndRejectsUnsafeEndpoints() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActivityIntegrationSettingsStore(dataRoot: root, ids: SequentialIDGenerator())
        XCTAssertFalse(try store.load().github.enabled)
        var settings = ActivityIntegrationSettings(); settings.github = connection()
        try store.save(settings)
        XCTAssertEqual(try store.load(), settings)
        let url = root.appendingPathComponent(ActivityIntegrationSettingsStore.fileName)
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(json.contains("token")); XCTAssertFalse(json.contains("password"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        for address in ["http://git.example.test", "https://user:pass@git.example.test", "https://git.example.test?token=fake", "https://git.example.test/#secret"] {
            settings.github.baseURL = address
            XCTAssertThrowsError(try store.save(settings))
        }
        XCTAssertEqual(try store.load().github, connection())
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: url), Data("broken".utf8))
    }

    @MainActor func testAutomaticFailureAttemptsOnceDailyAndManualRetryIsExplicit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let c = connection(), credentials = ImportTestCredentials(), transport = ImportTestTransport()
        try credentials.write("fake-token", account: c.credentialAccount)
        let clock = FixedClock(SQLDate.parse("2026-10-28T00:00:00Z")!)
        let repo = try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator())
        var settings = ActivityIntegrationSettings(); settings.github = c
        try ActivityIntegrationSettingsStore(dataRoot: root).save(settings)
        let model = ActivityIntegrationsModel(dataRoot: root, repo: repo, credentials: credentials,
            client: ActivityAPIClient(transport: transport))
        XCTAssertEqual(credentials.interactionPolicies, [], "App initialization must not read credentials")
        await model.sync(); await model.sync()
        XCTAssertEqual(credentials.interactionPolicies, [false])
        var count = await transport.calls; XCTAssertEqual(count, 1)
        XCTAssertTrue(model.message?.contains("한도") == true)
        XCTAssertFalse(model.message?.contains("should-not-display") == true)
        XCTAssertNil(try repo.activitySyncCompletedAt(connection: c))
        // Restarting the model does not bypass the persisted attempt marker.
        let reopened = ActivityIntegrationsModel(dataRoot: root, repo: repo, credentials: credentials,
            client: ActivityAPIClient(transport: transport))
        await reopened.sync(); count = await transport.calls; XCTAssertEqual(count, 1)
        await reopened.sync(manual: true); count = await transport.calls; XCTAssertEqual(count, 2)
        XCTAssertEqual(credentials.interactionPolicies, [false, true])
        clock.advance(by: 86_400)
        await reopened.sync(); count = await transport.calls; XCTAssertEqual(count, 3)
        XCTAssertEqual(credentials.interactionPolicies, [false, true, false])
    }

    @MainActor func testDirtySettingsDoNotSendManualRequestsAndSavingStoresTokenSeparately() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = ImportTestCredentials(), transport = ImportTestTransport()
        let repo = try WorkRepository.inMemory(ids: SequentialIDGenerator())
        let model = ActivityIntegrationsModel(dataRoot: root, repo: repo, credentials: credentials,
            client: ActivityAPIClient(transport: transport))
        model.draft.github = connection(); model.githubToken = "fake-private-token"
        await model.sync(manual: true)
        let count = await transport.calls; XCTAssertEqual(count, 0)
        model.save()
        XCTAssertFalse(model.isDirty); XCTAssertTrue(model.githubToken.isEmpty)
        XCTAssertEqual(try credentials.read(account: connection().credentialAccount), "fake-private-token")
        let data = try String(contentsOf: root.appendingPathComponent(ActivityIntegrationSettingsStore.fileName), encoding: .utf8)
        XCTAssertFalse(data.contains("fake-private-token"))
    }

    @MainActor func testDetachReleasesRepositoryAndBlocksDelayedUIRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-detach-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ImportTestTransport(), credentials = ImportTestCredentials()
        var repository: WorkRepository? = try WorkRepository.inMemory(ids: SequentialIDGenerator())
        weak var previous = repository
        let model = ActivityIntegrationsModel(dataRoot: root, repo: repository!, credentials: credentials,
            client: ActivityAPIClient(transport: transport))
        model.draft.github = connection(); model.githubToken = "fake-token"; model.save()
        repository = nil
        XCTAssertNotNil(previous)
        model.detach()
        XCTAssertNil(previous)
        XCTAssertFalse(model.isLoaded)
        await model.sync(manual: true)
        let count = await transport.calls; XCTAssertEqual(count, 0)
    }

    @MainActor func testAllCredentialsValidateBeforeAnyExistingTokenChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-validation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = ImportTestCredentials()
        try credentials.write("old-fake-token", account: connection().credentialAccount)
        let model = ActivityIntegrationsModel(dataRoot: root, repo: try WorkRepository.inMemory(), credentials: credentials)
        model.draft.github = connection(); model.githubToken = "new-fake-token"
        model.draft.jira.baseURL = "invalid"; model.jiraToken = "other-fake-token"
        model.save()
        XCTAssertEqual(try credentials.read(account: connection().credentialAccount), "old-fake-token")
        XCTAssertTrue(model.isDirty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(ActivityIntegrationSettingsStore.fileName).path))
    }

    @MainActor func testSettingsWriteFailureRollsBackCredentialReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-rollback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = ImportTestCredentials()
        try credentials.write("old-fake-token", account: connection().credentialAccount)
        let model = ActivityIntegrationsModel(dataRoot: root, repo: try WorkRepository.inMemory(), credentials: credentials)
        model.draft.github = connection(); model.githubToken = "new-fake-token"
        // Simulate an atomic settings replacement failure after the Keychain write succeeds.
        try FileManager.default.createDirectory(at: root.appendingPathComponent(ActivityIntegrationSettingsStore.fileName), withIntermediateDirectories: true)
        model.save()
        XCTAssertEqual(try credentials.read(account: connection().credentialAccount), "old-fake-token")
        XCTAssertTrue(model.isDirty)
        XCTAssertNotNil(model.message)
    }
}

private final class ImportTestCredentials: ServiceCredentialStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()
    private(set) var interactionPolicies: [Bool] = []
    func read(account: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func read(account: String, allowAuthenticationUI: Bool) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        interactionPolicies.append(allowAuthenticationUI)
        return values[account]
    }
    func write(_ credential: String, account: String) throws { lock.lock(); defer { lock.unlock() }; values[account] = credential }
    func delete(account: String) throws { lock.lock(); defer { lock.unlock() }; values[account] = nil }
}
private actor ImportTestTransport: ChatGPTHTTPTransport {
    var calls = 0
    func send(_ request: URLRequest) async throws -> ChatGPTHTTPResponse {
        calls += 1
        return .init(status: 429, body: Data("should-not-display".utf8))
    }
}
