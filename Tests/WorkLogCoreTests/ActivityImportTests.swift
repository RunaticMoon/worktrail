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
    // MARK: - Import identity / legacy key adoption (issue #58)

    func testImportIdentityIgnoresAddressSpellingAndGitHubAccountCase() throws {
        var spelling = connection()
        spelling.baseURL = "https://Git.EXAMPLE.test:443/"
        spelling.account = " Sample-User "
        XCTAssertEqual(spelling.importIdentity, connection().importIdentity)
        // The Keychain account still identifies one exact configured spelling.
        XCTAssertNotEqual(spelling.credentialAccount, connection().credentialAccount)

        var jira = ActivityConnection(source: .jira)
        jira.baseURL = "https://git.example.test"; jira.account = "sample-user"
        jira.jiraJQL = "project = DEMO"
        XCTAssertNotEqual(jira.importIdentity, connection().importIdentity)

        var otherAccount = connection(); otherAccount.account = "other-user"
        XCTAssertNotEqual(otherAccount.importIdentity, connection().importIdentity)

        // Jira accounts may be e-mail addresses, so their casing is meaningful.
        var upperJira = jira; upperJira.account = "Sample-User"
        XCTAssertNotEqual(upperJira.importIdentity, jira.importIdentity)

        // An invalid address keeps the previous behaviour instead of inventing a key.
        var invalid = connection(); invalid.baseURL = "http://git.example.test"
        XCTAssertEqual(invalid.importIdentity, invalid.credentialAccount)
    }

    func testLegacyRowsAreAdoptedAndReimportingTheSameEventIsANoOp() throws {
        let repo = try WorkRepository.inMemory(ids: SequentialIDGenerator())
        let c = connection()
        let day = WorkDate("2026-10-28")!
        let memo = try TaskService(repo: repo).captureMemo(body: "legacy memo", workDate: day)
        let occurredAt = try XCTUnwrap(SQLDate.parse("2026-10-27T16:00:00Z"))
        try repo.db.runV("""
            INSERT INTO imported_activity
            (connection_key, external_id, source, memo_id, occurred_at, fetched_at, source_url)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, c.credentialAccount, "event-1", "github", memo.id, occurredAt, occurredAt, "https://git.example.test/x")
        try repo.db.runV("INSERT INTO activity_sync_state (connection_key, attempted_on, completed_at) VALUES (?, ?, ?)",
                         c.credentialAccount, day, Date(timeIntervalSince1970: 100))

        XCTAssertEqual(try repo.importActivities([event()], connection: c), 0)
        XCTAssertEqual(try repo.db.queryV("SELECT * FROM imported_activity").count, 1)
        XCTAssertEqual(try repo.db.queryV("SELECT * FROM imported_activity WHERE connection_key = ?", c.importIdentity).count, 1)
        XCTAssertEqual(try repo.db.queryV("SELECT * FROM imported_activity WHERE connection_key = ?", c.credentialAccount).count, 0)
        XCTAssertEqual(try repo.activitySyncAttemptedOn(connection: c), day)
        XCTAssertEqual(try XCTUnwrap(repo.activitySyncCompletedAt(connection: c)).timeIntervalSince1970, 100, accuracy: 0.001)
        XCTAssertTrue(try repo.db.queryV("SELECT * FROM activity_sync_state WHERE connection_key = ?", c.credentialAccount).isEmpty)

        // Adopting again changes nothing.
        try repo.adoptLegacyActivityImportKey(for: c)
        XCTAssertEqual(try repo.db.queryV("SELECT * FROM imported_activity").count, 1)
        XCTAssertEqual(try repo.db.queryV("SELECT * FROM activity_sync_state").count, 1)
    }

    func testAdoptionKeepsBothRowsWhenTheEventAlreadyExistsUnderTheCurrentKey() throws {
        let repo = try WorkRepository.inMemory(ids: SequentialIDGenerator())
        let c = connection()
        let day = WorkDate("2026-10-28")!
        let service = TaskService(repo: repo)
        let legacyMemo = try service.captureMemo(body: "legacy memo", workDate: day)
        let currentMemo = try service.captureMemo(body: "current memo", workDate: day)
        let occurredAt = try XCTUnwrap(SQLDate.parse("2026-10-27T16:00:00Z"))
        for (key, memoID) in [(c.credentialAccount, legacyMemo.id), (c.importIdentity, currentMemo.id)] {
            try repo.db.runV("""
                INSERT INTO imported_activity
                (connection_key, external_id, source, memo_id, occurred_at, fetched_at, source_url)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, key, "event-1", "github", memoID, occurredAt, occurredAt, "https://git.example.test/x")
        }

        try repo.adoptLegacyActivityImportKey(for: c)

        // Nothing is deleted or merged: both memos and both rows survive, the conflict row stays legacy.
        XCTAssertEqual(try repo.db.queryV("SELECT * FROM imported_activity").count, 2)
        XCTAssertEqual(try repo.db.queryV("SELECT * FROM imported_activity WHERE connection_key = ?", c.credentialAccount).count, 1)
        XCTAssertEqual(try repo.db.queryV("SELECT * FROM imported_activity WHERE connection_key = ?", c.importIdentity).count, 1)
        XCTAssertNotNil(try repo.memo(id: legacyMemo.id))
        XCTAssertNotNil(try repo.memo(id: currentMemo.id))
        XCTAssertEqual(try repo.importActivities([event()], connection: c), 0)
        XCTAssertEqual(try repo.db.queryV("SELECT * FROM imported_activity").count, 2)
    }

    func testAdoptionKeepsTheLaterCompletedSyncState() throws {
        let c = connection()
        let day = WorkDate("2026-10-20")!

        // A completed time wins over an attempt-only row, even an older one.
        let attemptOnly = try WorkRepository.inMemory(ids: SequentialIDGenerator())
        try attemptOnly.db.runV("INSERT INTO activity_sync_state (connection_key, attempted_on, completed_at) VALUES (?, ?, ?)",
                                c.credentialAccount, day, SQLValue.null)
        try attemptOnly.db.runV("INSERT INTO activity_sync_state (connection_key, attempted_on, completed_at) VALUES (?, ?, ?)",
                                c.importIdentity, day, Date(timeIntervalSince1970: 200))
        try attemptOnly.adoptLegacyActivityImportKey(for: c)
        let kept = try XCTUnwrap(attemptOnly.db.queryOneV(
            "SELECT * FROM activity_sync_state WHERE connection_key = ?", c.importIdentity))
        XCTAssertEqual(try XCTUnwrap(kept.date("completed_at")).timeIntervalSince1970, 200, accuracy: 0.001)
        XCTAssertEqual(try attemptOnly.db.queryV("SELECT * FROM activity_sync_state").count, 1)

        // Two completed times keep the later one, under the current key.
        let completed = try WorkRepository.inMemory(ids: SequentialIDGenerator())
        try completed.db.runV("INSERT INTO activity_sync_state (connection_key, attempted_on, completed_at) VALUES (?, ?, ?)",
                              c.credentialAccount, day, Date(timeIntervalSince1970: 300))
        try completed.db.runV("INSERT INTO activity_sync_state (connection_key, attempted_on, completed_at) VALUES (?, ?, ?)",
                              c.importIdentity, day, Date(timeIntervalSince1970: 200))
        try completed.adoptLegacyActivityImportKey(for: c)
        let winner = try XCTUnwrap(completed.db.queryOneV(
            "SELECT * FROM activity_sync_state WHERE connection_key = ?", c.importIdentity))
        XCTAssertEqual(try XCTUnwrap(winner.date("completed_at")).timeIntervalSince1970, 300, accuracy: 0.001)
        XCTAssertEqual(try completed.db.queryV("SELECT * FROM activity_sync_state").count, 1)
    }

    func testAdoptionRollsBackWhenSyncStateCannotMove() throws {
        let repo = try WorkRepository.inMemory(ids: SequentialIDGenerator())
        let c = connection()
        let day = WorkDate("2026-10-28")!
        let memo = try TaskService(repo: repo).captureMemo(body: "legacy memo", workDate: day)
        let occurredAt = try XCTUnwrap(SQLDate.parse("2026-10-27T16:00:00Z"))
        try repo.db.runV("""
            INSERT INTO imported_activity
            (connection_key, external_id, source, memo_id, occurred_at, fetched_at, source_url)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, c.credentialAccount, "event-1", "github", memo.id, occurredAt, occurredAt, "https://git.example.test/x")
        try repo.db.runV("INSERT INTO activity_sync_state (connection_key, attempted_on) VALUES (?, ?)",
                         c.credentialAccount, day)
        try repo.db.execute("""
            CREATE TEMP TRIGGER reject_adoption BEFORE UPDATE ON activity_sync_state
            BEGIN SELECT RAISE(ABORT, 'fixture'); END;
            """)

        XCTAssertThrowsError(try repo.adoptLegacyActivityImportKey(for: c))
        // The imported-event move is part of the same transaction and is rolled back with it.
        XCTAssertEqual(try repo.db.queryV("SELECT * FROM imported_activity WHERE connection_key = ?", c.credentialAccount).count, 1)
        XCTAssertTrue(try repo.db.queryV("SELECT * FROM imported_activity WHERE connection_key = ?", c.importIdentity).isEmpty)
        XCTAssertEqual(try repo.db.queryV("SELECT * FROM activity_sync_state WHERE connection_key = ?", c.credentialAccount).count, 1)
    }

    @MainActor func testRemoveTokenDeletesTheSavedKeyAndTheDraftKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-remove-token-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = connection()
        var settings = ActivityIntegrationSettings(); settings.github = saved
        try ActivityIntegrationSettingsStore(dataRoot: root, ids: SequentialIDGenerator()).save(settings)
        let credentials = ImportTestCredentials()
        try credentials.write("saved-fake-token", account: saved.credentialAccount)
        let model = ActivityIntegrationsModel(dataRoot: root, repo: try WorkRepository.inMemory(), credentials: credentials)
        // A never-saved edit means collection still reads the saved key, not the draft one.
        model.draft.github.baseURL = "https://other.example.test"
        model.draft.github.account = "other-user"
        let draftKey = model.draft.github.credentialAccount
        try credentials.write("stale-fake-token", account: draftKey)
        XCTAssertNotEqual(draftKey, saved.credentialAccount)

        model.removeToken(for: .github)

        XCTAssertNil(try credentials.read(account: saved.credentialAccount))
        XCTAssertNil(try credentials.read(account: draftKey))
        XCTAssertFalse(model.message?.isEmpty ?? true)
    }

    // MARK: - Acceptance pairs: equivalent spellings share one imported event (issue #58)

    /// Imports `event-1` under `first`, applies `mutate` to the created memo, then imports the same
    /// event under `second`. The second import must be a no-op: the memo keeps its identity and the
    /// mutation, one memo exists in total, and exactly one `imported_activity` row (under the new
    /// identity) maps to it.
    private func importEventUnderBothSpellings(
        _ first: ActivityConnection, _ second: ActivityConnection,
        file: StaticString = #filePath, line: UInt = #line,
        mutate: (WorkRepository, Memo, WorkDate) throws -> Void = { _, _, _ in }
    ) throws -> (repo: WorkRepository, before: Memo, after: Memo) {
        let repo = try WorkRepository.inMemory(ids: SequentialIDGenerator())
        let day = WorkDate("2026-10-28")!
        XCTAssertEqual(first.importIdentity, second.importIdentity,
                       "equivalent spellings must share an import identity", file: file, line: line)
        // Keychain isolation is unchanged: each configured spelling keeps its own account.
        XCTAssertNotEqual(first.credentialAccount, second.credentialAccount,
                          "Keychain accounts must stay distinct", file: file, line: line)

        XCTAssertEqual(try repo.importActivities([event()], connection: first), 1, file: file, line: line)
        let memo = try XCTUnwrap(repo.importedActivityRecords(on: day).first?.memo, file: file, line: line)
        try mutate(repo, memo, day)

        XCTAssertEqual(try repo.importActivities([event()], connection: second), 0,
                       "re-importing the same event must be a no-op", file: file, line: line)
        let after = try XCTUnwrap(repo.memo(id: memo.id, includeDeleted: true), file: file, line: line)
        XCTAssertEqual(after.id, memo.id, file: file, line: line)
        XCTAssertEqual(try repo.db.queryV("SELECT * FROM memo").count, 1, file: file, line: line)
        XCTAssertEqual(try repo.db.queryV("SELECT * FROM imported_activity").count, 1, file: file, line: line)
        XCTAssertEqual(try repo.db.queryV(
            "SELECT * FROM imported_activity WHERE connection_key = ? AND memo_id = ?",
            second.importIdentity, memo.id).count, 1, file: file, line: line)
        XCTAssertTrue(try repo.db.queryV(
            "SELECT * FROM imported_activity WHERE connection_key = ?", second.credentialAccount).isEmpty,
            file: file, line: line)
        return (repo, memo, after)
    }

    func testEquivalentSpellingPairsImportTheEventOnce() throws {
        let enterprise = connection()
        var enterpriseAPI = connection(); enterpriseAPI.baseURL = "https://git.example.test/api/v3"

        var github = connection(); github.baseURL = "https://github.com"
        var githubAPI = connection(); githubAPI.baseURL = "https://api.github.com"

        var jira = ActivityConnection(source: .jira)
        jira.enabled = true; jira.baseURL = "https://demo.atlassian.net"; jira.account = "fixture@example.test"
        var jiraAPI = jira; jiraAPI.baseURL = "https://demo.atlassian.net/rest/api/3"

        var lowerAccount = connection(); lowerAccount.account = "fixture"
        var upperAccount = connection(); upperAccount.account = "FiXtUrE"

        let pairs: [(String, ActivityConnection, ActivityConnection)] = [
            ("GitHub Enterprise with and without /api/v3", enterprise, enterpriseAPI),
            ("github.com and api.github.com", github, githubAPI),
            ("Jira with and without /rest/api/3", jira, jiraAPI),
            ("GitHub account casing", lowerAccount, upperAccount),
        ]

        for (name, first, second) in pairs {
            // An edited memo must survive the second import, whichever spelling finds the event.
            let edited = try importEventUnderBothSpellings(first, second) { repo, memo, day in
                _ = try repo.updateMemoBody(id: memo.id, body: "사용자가 고친 기록", workDate: day)
            }
            XCTAssertEqual(edited.after.body, "사용자가 고친 기록", name)
            XCTAssertEqual(edited.after.revision, edited.before.revision + 1, name)
            XCTAssertNil(edited.after.deletedAt, name)

            // A trashed memo stays trashed: the event is already known, so nothing is resurrected.
            let trashed = try importEventUnderBothSpellings(first, second) { repo, memo, _ in
                try repo.softDeleteMemo(id: memo.id)
            }
            XCTAssertEqual(trashed.after.body, trashed.before.body, name)
            XCTAssertEqual(trashed.after.revision, trashed.before.revision, name)
            XCTAssertNotNil(trashed.after.deletedAt, name)
        }
    }

    func testDifferentServersAndAccountsStillImportSeparately() throws {
        let repo = try WorkRepository.inMemory(ids: SequentialIDGenerator())
        let c = connection()
        XCTAssertEqual(try repo.importActivities([event()], connection: c), 1)

        var otherServer = c; otherServer.baseURL = "https://git.other.test"
        XCTAssertNotEqual(otherServer.importIdentity, c.importIdentity)
        XCTAssertEqual(try repo.importActivities([event()], connection: otherServer), 1)

        var otherAccount = c; otherAccount.account = "another-user"
        XCTAssertNotEqual(otherAccount.importIdentity, c.importIdentity)
        XCTAssertEqual(try repo.importActivities([event()], connection: otherAccount), 1)

        // Same external id, three genuinely different API scopes: three memos, three rows.
        XCTAssertEqual(try repo.db.queryV("SELECT * FROM imported_activity").count, 3)
        XCTAssertEqual(try repo.db.queryV("SELECT * FROM memo").count, 3)
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
