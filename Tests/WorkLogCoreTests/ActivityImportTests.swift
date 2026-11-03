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

    @MainActor func testAutomaticCollectionRunsHourlyAndManualRetryIsExplicit() async throws {
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
        var count = await transport.calls; XCTAssertEqual(count, 1, "A failed attempt waits for the interval")
        XCTAssertTrue(model.message?.contains("한도") == true)
        XCTAssertFalse(model.message?.contains("should-not-display") == true)
        XCTAssertNil(try repo.activitySyncCompletedAt(connection: c))
        clock.advance(by: ActivityIntegrationsModel.automaticSyncInterval - 1)
        await model.sync(); count = await transport.calls; XCTAssertEqual(count, 1)
        clock.advance(by: 1)
        await model.sync(); count = await transport.calls; XCTAssertEqual(count, 2)
        await model.sync(manual: true); count = await transport.calls; XCTAssertEqual(count, 3)
        XCTAssertEqual(credentials.interactionPolicies, [false, false, true])
        // A relaunch collects on its first pass without waiting for the previous process's interval.
        let reopened = ActivityIntegrationsModel(dataRoot: root, repo: repo, credentials: credentials,
            client: ActivityAPIClient(transport: transport))
        await reopened.sync(); count = await transport.calls; XCTAssertEqual(count, 4)
        await reopened.sync(); count = await transport.calls; XCTAssertEqual(count, 4)
        // A recent success in an earlier process does not delay the launch pass either.
        try repo.recordActivitySyncAttempt(connection: c, completed: true)
        clock.advance(by: 600)
        let relaunched = ActivityIntegrationsModel(dataRoot: root, repo: repo, credentials: credentials,
            client: ActivityAPIClient(transport: transport))
        await relaunched.sync(); count = await transport.calls; XCTAssertEqual(count, 5)
        // A clock moved backwards does not pause collection until it catches up.
        clock.advance(by: -7_200)
        await relaunched.sync(); count = await transport.calls; XCTAssertEqual(count, 6)
        // A success recorded days "in the future" still yields a valid range after the clock is corrected.
        clock.advance(by: -10 * 86_400)
        await relaunched.sync(); count = await transport.calls; XCTAssertEqual(count, 7)
    }

    @MainActor func testApprovalFailureShowsOneMessageAndApprovalIsReusedSilently() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-approval-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var jira = ActivityConnection(source: .jira)
        jira.enabled = true; jira.baseURL = "https://jira.example.test"; jira.account = "sample-user"
        let github = connection()
        let base = ApprovalGatedCredentials(values: [github.credentialAccount: "fake-token", jira.credentialAccount: "fake-token"])
        let credentials = CachingServiceCredentialStore(base), transport = ImportTestTransport()
        let clock = FixedClock(SQLDate.parse("2026-10-28T00:00:00Z")!)
        let repo = try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator())
        var settings = ActivityIntegrationSettings(); settings.github = github; settings.jira = jira
        try ActivityIntegrationSettingsStore(dataRoot: root).save(settings)
        let model = ActivityIntegrationsModel(dataRoot: root, repo: repo, credentials: credentials,
            client: ActivityAPIClient(transport: transport))
        XCTAssertEqual(Set(model.launchCredentialAccounts), [github.credentialAccount, jira.credentialAccount])
        await model.sync()
        var count = await transport.calls; XCTAssertEqual(count, 0)
        XCTAssertEqual(model.message, ActivityIntegrationsModel.keychainApprovalMessage, "One message for every service")
        await model.sync(); XCTAssertEqual(base.reads, [false, false], "Approval failures also wait for the interval")
        // Once approved (launch check or manual sync), manual and periodic collection reuse it.
        XCTAssertTrue(credentials.authorize(accounts: model.launchCredentialAccounts).isEmpty)
        await model.sync(manual: true)
        count = await transport.calls; XCTAssertEqual(count, 2)
        clock.advance(by: ActivityIntegrationsModel.automaticSyncInterval)
        await model.sync()
        count = await transport.calls; XCTAssertEqual(count, 4)
        XCTAssertEqual(base.reads, [false, false, true, true], "No further Keychain reads after the approval")
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

    @MainActor func testImportGenerationAndRangeAdvanceOnlyWhenNewRecordsAreStored() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-generation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let c = connection(), credentials = ImportTestCredentials()
        try credentials.write("fake-token", account: c.credentialAccount)
        let clock = FixedClock(SQLDate.parse("2026-10-28T00:00:00Z")!)
        let repo = try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator())
        var settings = ActivityIntegrationSettings(); settings.github = c
        try ActivityIntegrationSettingsStore(dataRoot: root).save(settings)
        // 같은 이벤트를 두 번 받아도 두 번째 수집은 새 기록 0건이어야 한다.
        let transport = ImportReplyTransport([
            .init(status: 200, body: Data(#"{"login":"sample-user"}"#.utf8)),
            .init(status: 200, body: Data(Self.githubEventsJSON.utf8)),
            .init(status: 200, body: Data(#"{"login":"sample-user"}"#.utf8)),
            .init(status: 200, body: Data(Self.githubEventsJSON.utf8))
        ])
        let model = ActivityIntegrationsModel(dataRoot: root, repo: repo, credentials: credentials,
            client: ActivityAPIClient(transport: transport))
        XCTAssertEqual(model.importGeneration, 0)
        XCTAssertNil(model.lastImportedRange)

        await model.sync()
        let range = DateRange(start: WorkDate("2026-10-21")!, endExclusive: WorkDate("2026-10-29")!)
        XCTAssertEqual(model.importGeneration, 1)
        XCTAssertEqual(model.lastImportedRange, range)

        await model.sync(manual: true)
        XCTAssertEqual(model.importGeneration, 1, "새 기록이 0건이면 세대가 늘지 않는다")
        XCTAssertEqual(model.lastImportedRange, range, "가져온 기록이 없으면 기간도 그대로 둔다")
    }

    @MainActor func testImportGenerationStaysPutWhenCollectionFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-generation-fail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let c = connection(), credentials = ImportTestCredentials()
        try credentials.write("fake-token", account: c.credentialAccount)
        let clock = FixedClock(SQLDate.parse("2026-10-28T00:00:00Z")!)
        let repo = try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator())
        var settings = ActivityIntegrationSettings(); settings.github = c
        try ActivityIntegrationSettingsStore(dataRoot: root).save(settings)
        let model = ActivityIntegrationsModel(dataRoot: root, repo: repo, credentials: credentials,
            client: ActivityAPIClient(transport: ImportTestTransport()))

        await model.sync()
        XCTAssertEqual(model.importGeneration, 0)
        XCTAssertNil(model.lastImportedRange)
        XCTAssertNil(try repo.activitySyncCompletedAt(connection: c))
        XCTAssertNotNil(model.message)
    }

    private static let githubEventsJSON = """
    [{"id":"event-1","type":"PushEvent","actor":{"login":"sample-user"},
      "created_at":"2026-10-27T16:00:00Z","repo":{"name":"sample/repo"},
      "payload":{"ref":"refs/heads/main","head":"abc123","size":1,
        "commits":[{"message":"변경 사항"}]}}]
    """

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
/// 정해진 순서대로 응답을 돌려주는 가짜 전송 계층. 실제 네트워크는 쓰지 않는다.
private actor ImportReplyTransport: ChatGPTHTTPTransport {
    private var replies: [ChatGPTHTTPResponse]
    init(_ replies: [ChatGPTHTTPResponse]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> ChatGPTHTTPResponse {
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        return replies.removeFirst()
    }
}
