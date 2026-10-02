import XCTest
@testable import WorkLogCore

final class SecretsSettingsBackupPresentationTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }
    private func paths() throws -> AppPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AJ-Presentation-\(UUID().uuidString)")
        roots.append(root)
        return AppPaths(dataRoot: root.appendingPathComponent("data"), backupRoot: root.appendingPathComponent("backups"))
    }
    private func environment(keyStore: VaultKeyStore = InMemoryVaultKeyStore(),
                             auth: MockDeviceAuthenticator = MockDeviceAuthenticator(),
                             pasteboard: InMemoryPasteboard = InMemoryPasteboard(),
                             clock: FixedClock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))) throws -> AppEnvironment {
        try AppEnvironment.open(AppEnvironmentOptions(paths: paths(), keyStore: keyStore,
            authenticator: auth, pasteboard: pasteboard, clock: clock, ids: SequentialIDGenerator()))
    }
    @MainActor private func savedSecret(_ model: SecretsModel, value: String = " canary-SECRET 00123 ") async throws -> SecretRow {
        await model.unlock()
        model.title = "회사 테스트"
        model.groupName = "개발"
        model.addRow()
        model.rows[0].key = " API_KEY "
        model.rows[0].value = value
        XCTAssertTrue(model.save())
        return try XCTUnwrap(model.rows.first)
    }

    @MainActor func testLockedTitleSearchRejectsValueAccessAndSanitizesErrors() async throws {
        let auth = MockDeviceAuthenticator()
        let env = try environment(auth: auth)
        let model = SecretsModel(environment: env)
        let row = try await savedSecret(model)
        let metadata = try XCTUnwrap(model.titles.first)
        model.lock()
        model.query = "회사"
        XCTAssertEqual(model.titles.map(\.title), ["회사 테스트"])
        model.open(metadata)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.isLocked)
        XCTAssertTrue(model.message?.contains("잠겨") == true)
        model.copyRow(row)
        XCTAssertFalse(env.clipboard.hasPendingClear)
        XCTAssertFalse(model.message?.contains("canary-SECRET") == true)
        model.query = "canary-SECRET"
        XCTAssertTrue(model.titles.isEmpty)
        XCTAssertEqual(auth.callCount, 1)
    }

    @MainActor func testAuthenticatedCreatePartialEditKeepsStableIDsAndOtherRows() async throws {
        let env = try environment()
        let model = SecretsModel(environment: env)
        let original = try await savedSecret(model, value: " 00123 ")
        model.addRow(); model.rows[1].key = "FLAG"; model.rows[1].value = " true "
        XCTAssertTrue(model.save())
        let second = model.rows[1]
        model.rows[0].key = " RENAMED "
        model.rows[0].value = "  A  B\nC  "
        XCTAssertTrue(model.save())
        XCTAssertEqual(model.rows[0].id, original.id)
        XCTAssertEqual(model.rows[0].key, "RENAMED")
        XCTAssertEqual(model.rows[0].value, "A  B\nC")
        XCTAssertEqual(model.rows[1], second)
        let count = model.revisions.count
        XCTAssertTrue(model.save())
        XCTAssertEqual(model.revisions.count, count)
    }

    @MainActor func testClipboardClearsAt120SecondsOnlyForUnchangedMarker() async throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let board = InMemoryPasteboard()
        let env = try environment(pasteboard: board, clock: clock)
        let model = SecretsModel(environment: env)
        let row = try await savedSecret(model, value: "canary-copy")
        model.copyRow(row)
        XCTAssertEqual(board.string, "canary-copy")
        XCTAssertTrue(model.message?.contains("120") == true)
        clock.advance(by: 119); model.tick()
        XCTAssertEqual(board.string, "canary-copy")
        clock.advance(by: 1); model.tick()
        XCTAssertNil(board.string)
        model.copyRow(row)
        board.simulateExternalCopy("canary-copy")
        clock.advance(by: 120); model.tick()
        XCTAssertEqual(board.string, "canary-copy")
        XCTAssertFalse(env.clipboard.hasPendingClear)
        model.copyRow(row); board.simulateExternalCopy("다른 앱 복사")
        model.lock()
        XCTAssertEqual(board.string, "다른 앱 복사")
    }

    @MainActor func testPastePreviewPreservesAmbiguousRowsAndDuplicateRejectionPreservesValues() async throws {
        let env = try environment()
        let model = SecretsModel(environment: env)
        await model.unlock()
        model.acceptPaste(" A=canary-one=tail\nhttps://example.test/a:b\n A : canary-two\nflag=true\nnumber=00123 ")
        XCTAssertEqual(model.preview.count, 5)
        XCTAssertEqual(model.preview[0].input.value, "canary-one=tail")
        XCTAssertTrue(model.preview[1].ambiguous)
        XCTAssertEqual(model.preview[1].input.value, "https://example.test/a:b")
        model.appendPreview()
        let before = model.rows
        XCTAssertFalse(model.save())
        XCTAssertEqual(model.rows, before)
        XCTAssertEqual(model.duplicateRowIds.count, 2)
        XCTAssertFalse(model.message?.contains("canary-one") == true)
        XCTAssertFalse(model.message?.contains("canary-two") == true)
        model.rows[2].key = "different"
        XCTAssertTrue(model.save())
        XCTAssertTrue(model.rows.contains { $0.key == "key1" && $0.value == "https://example.test/a:b" })
        XCTAssertTrue(model.rows.contains { $0.key == "number" && $0.value == "00123" })
    }

    @MainActor func testIdleLockConcealsAllValuesAndEncryptedDraftRecoversEditor() async throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let env = try environment(clock: clock)
        let model = SecretsModel(environment: env)
        _ = try await savedSecret(model)
        model.title = "수정한 제목"
        model.groupName = "수정한 그룹"
        model.rows[0].value = "canary-edited"
        model.pasteText = "pending=canary-paste"
        model.makePastePreview()
        model.showsValues = true
        model.selectRevision(try XCTUnwrap(model.revisions.first))
        clock.advance(by: 1800)
        model.tick()
        XCTAssertTrue(model.isLocked)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.preview.isEmpty)
        XCTAssertTrue(model.pasteText.isEmpty)
        XCTAssertTrue(model.revisionRows.isEmpty)
        XCTAssertTrue(model.revisions.isEmpty)
        XCTAssertFalse(model.showsValues)
        XCTAssertNil(model.selectedId)
        await model.unlock()
        XCTAssertTrue(model.hasRecoverableDraft)
        model.recoverDraft()
        XCTAssertFalse(model.hasRecoverableDraft)
        XCTAssertEqual(model.title, "수정한 제목")
        XCTAssertEqual(model.groupName, "수정한 그룹")
        XCTAssertEqual(model.rows[0].value, "canary-edited")
        XCTAssertEqual(model.preview[0].input.value, "canary-paste")
        XCTAssertNotNil(model.selectedId)
        model.appendPreview(); XCTAssertTrue(model.save())
        XCTAssertNil(try env.vaultSession.loadDraft())
        for file in [env.options.paths.workDatabase, env.options.paths.vaultDatabase,
                     URL(fileURLWithPath: env.options.paths.vaultDatabase.path + "-wal")] {
            if let bytes = try? Data(contentsOf: file) {
                XCTAssertNil(bytes.range(of: Data("canary-edited".utf8)))
                XCTAssertNil(bytes.range(of: Data("canary-paste".utf8)))
            }
        }
        XCTAssertTrue(try env.search.search(SearchQuery(text: "canary-edited")).isEmpty)
    }

    @MainActor func testDraftRecoveryDoesNotOverwriteConcurrentlyChangedItem() async throws {
        let env = try environment()
        let model = SecretsModel(environment: env)
        let row = try await savedSecret(model, value: "old")
        let id = try XCTUnwrap(model.selectedId)
        model.rows[0].value = "draft-value"
        _ = try env.vaultSession.save(secretId: id, changes: SecretChangeSet(upserts: [SecretRowInput(id: row.id, key: row.key, value: "newer")]))
        model.lock(); await model.unlock(); model.recoverDraft()
        XCTAssertNil(model.selectedId)
        XCTAssertEqual(model.rows[0].value, "draft-value")
        XCTAssertEqual(try env.vaultSession.currentRows(secretId: id)[0].value, "newer")
        XCTAssertTrue(model.save())
        XCTAssertNotEqual(model.selectedId, id)
    }

    @MainActor func testRevisionRestoreTrashRestoreAndPurge() async throws {
        let env = try environment()
        let model = SecretsModel(environment: env)
        _ = try await savedSecret(model, value: "first")
        let id = try XCTUnwrap(model.selectedId)
        let revision = try XCTUnwrap(model.revisions.first)
        model.rows[0].value = "second"; XCTAssertTrue(model.save())
        model.selectRevision(revision)
        XCTAssertEqual(model.revisionRows[0].value, "first")
        model.restoreSelectedRevision()
        XCTAssertEqual(model.rows[0].value, "first")
        XCTAssertEqual(model.revisions.count, 3)
        model.moveToTrash()
        XCTAssertTrue(model.titles.isEmpty)
        XCTAssertEqual(model.trashItems.map(\.id), [id])
        model.restoreTrash(id)
        model.open(try XCTUnwrap(model.titles.first))
        XCTAssertEqual(model.revisions.count, 3)
        model.moveToTrash(); model.purge(id)
        XCTAssertTrue(model.trashItems.isEmpty)
        XCTAssertTrue(model.message?.contains("과거 백업") == true)
    }

    @MainActor func testAuthenticationFailureNeverEchoesAuthenticatorError() async throws {
        let auth = MockDeviceAuthenticator(result: .failed("canary-auth-value"))
        let model = SecretsModel(environment: try environment(auth: auth))
        await model.unlock()
        XCTAssertTrue(model.isLocked)
        XCTAssertFalse(model.message?.contains("canary-auth-value") == true)
        XCTAssertFalse(model.isUnlocking)
    }

    @MainActor func testSettingsSaveAppliesSecurityLimitsSkillsAndValidationKeepsOldSettings() throws {
        let env = try environment()
        let model = SettingsModel(environment: env)
        model.draft.secretIdleLockMinutes = 10
        model.draft.clipboardClearSeconds = 60
        model.draft.backupRetentionDays = 45
        model.draft.mondayReminderTime = "10:30"
        model.draft.aiEnabled = false
        model.draft.codexExecutablePath = "/fake/codex"
        for type in AIJobType.allCases { model.setSkill("example-skill", for: type) }
        XCTAssertTrue(model.save())
        XCTAssertEqual(try env.settingsStore.load(), model.draft)
        XCTAssertEqual(env.vaultSession.idleTimeout, 600)
        XCTAssertEqual(env.clipboard.clearAfter, 60)
        XCTAssertEqual(env.skillResolver.skill(for: .groundedAnswer)?.name, "example-skill")
        let saved = env.settings
        model.draft.secretIdleLockMinutes = 0
        model.draft.clipboardClearSeconds = 1
        model.draft.mondayReminderTime = "25:00"
        XCTAssertFalse(model.save())
        XCTAssertEqual(env.settings, saved)
        XCTAssertEqual(try env.settingsStore.load(), saved)
        XCTAssertGreaterThanOrEqual(model.errors.count, 3)
        model.reset(); XCTAssertFalse(model.hasChanges)
    }
    @MainActor func testDefaultCaptureKindSavesAndReloadsForAllSupportedKinds() throws {
        let env = try environment()
        let model = SettingsModel(environment: env)
        XCTAssertEqual(model.defaultCaptureKind, .memo)
        for kind in [CaptureKind.task, .secret, .memo] {
            model.defaultCaptureKind = kind
            XCTAssertTrue(model.hasChanges)
            XCTAssertTrue(model.save())
            XCTAssertEqual(env.settings.defaultCaptureKind, kind)
            XCTAssertEqual(try env.settingsStore.load().defaultCaptureKind, kind)
            let reloaded = SettingsModel(environment: env)
            XCTAssertEqual(reloaded.defaultCaptureKind, kind)
            XCTAssertFalse(reloaded.hasChanges)
            model.defaultCaptureKind = kind == .memo ? .task : .memo
            model.reset()
            XCTAssertEqual(model.defaultCaptureKind, kind)
        }
    }
    @MainActor func testDiscardingDraftClearsRecoverableDraftWithoutEchoingSecret() async throws {
        let env = try environment()
        let model = SecretsModel(environment: env)
        await model.unlock()
        XCTAssertFalse(model.hasRecoverableDraft)
        model.beginNew()
        XCTAssertNil(model.selectedId)
        model.addRow(); model.rows[0].key = "fake-key"; model.rows[0].value = "fake-discard-canary"
        model.lock()
        XCTAssertTrue(model.isLocked)
        await model.unlock()
        XCTAssertTrue(model.hasRecoverableDraft)
        model.discardDraft()
        XCTAssertFalse(model.hasRecoverableDraft)
        XCTAssertTrue(try env.search.search(SearchQuery(text: "fake-discard-canary")).isEmpty)
    }

    @MainActor func testHotkeyAliasesAndRegistrationFailureKeepSavedSettings() throws {
        let env = try environment()
        let model = SettingsModel(environment: env)
        let old = env.settings
        model.draft.captureHotkey = "command+control+F"
        model.draft.searchHotkey = "CTRL+CMD+f"
        XCTAssertFalse(model.save())
        XCTAssertEqual(env.settings, old)
        model.reset(); model.draft.captureHotkey = "ctrl+opt+k"
        XCTAssertFalse(model.save(apply: { _ in throw WorkLogError.validation("canary-registration") }))
        XCTAssertEqual(env.settings, old)
        XCTAssertFalse(model.errors.joined().contains("canary-registration"))
    }

    @MainActor func testAccountStatusUsesOnlyExplicitProviderRequest() async throws {
        let model = SettingsModel(environment: try environment())
        XCTAssertTrue(model.accountMessage.contains("아직"))
        let provider = MockAIProvider()
        provider.accountState = .loggedOut
        await model.checkAccount(provider: provider)
        XCTAssertTrue(model.accountMessage.contains("로그인되어 있지"))
        provider.accountState = .loggedIn(accountType: "chatgpt", email: "not-displayed@example.test", planType: "enterprise")
        await model.checkAccount(provider: provider)
        XCTAssertTrue(model.accountMessage.contains("Enterprise"))
        XCTAssertFalse(model.accountMessage.contains("not-displayed"))
        XCTAssertTrue(SettingsModel.transmissionNotice.contains("제목"))
    }

    @MainActor func testBackupCreateListVerifyAndCorruptFailure() async throws {
        let env = try environment()
        let model = BackupModel(environment: env)
        XCTAssertTrue(model.backups.isEmpty)
        await model.create()
        let backup = try XCTUnwrap(model.backups.first)
        XCTAssertEqual(backup.manifest.reason, .manual)
        XCTAssertEqual(model.status.lastSuccessAt, env.options.clock.now())
        XCTAssertGreaterThan(BackupModel.size(backup), 0)
        let verified = await model.verify(backup)
        XCTAssertTrue(verified)
        XCTAssertTrue(model.verifiedIds.contains(backup.id))
        try Data("damaged".utf8).write(to: backup.directory.appendingPathComponent(BackupService.workFileName))
        let corruptVerified = await model.verify(backup)
        XCTAssertFalse(corruptVerified)
        XCTAssertFalse(model.verifiedIds.contains(backup.id))
        XCTAssertTrue(model.message?.contains("손상") == true)
    }

    @MainActor func testMissingKeyRestoreOffersOrdinaryOnlyAndKeepsExistingSecret() async throws {
        let env = try environment()
        let secret = SecretsModel(environment: env)
        _ = try await savedSecret(secret, value: "canary-backup")
        _ = try env.tasks.captureMemo(body: "일반 기록 복원")
        let model = BackupModel(environment: env)
        await model.create()
        let backup = try XCTUnwrap(model.backups.first)
        let target = try paths()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        var targetEnv: AppEnvironment? = try AppEnvironment.open(AppEnvironmentOptions(paths: target,
            keyStore: InMemoryVaultKeyStore(), authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(), clock: clock))
        // Release target connections; source backup connections do not point into target.
        targetEnv = nil
        XCTAssertNil(targetEnv)
        let vaultBefore = try Data(contentsOf: target.vaultDatabase)
        model.detach()
        let withSecrets = await model.restoreAfterClosing(backup, into: target, keyStore: InMemoryVaultKeyStore(), includeVault: true, clock: clock)
        XCTAssertFalse(withSecrets)
        XCTAssertTrue(model.offersOrdinaryOnlyRestore)
        XCTAssertFalse(model.includeSecrets)
        XCTAssertTrue(model.message?.contains("같은 Mac") == true)
        XCTAssertFalse(model.message?.contains("canary-backup") == true)
        XCTAssertEqual(try Data(contentsOf: target.vaultDatabase), vaultBefore)
        let ordinaryOnly = await model.restoreAfterClosing(backup, into: target, keyStore: InMemoryVaultKeyStore(), includeVault: false, clock: clock)
        XCTAssertTrue(ordinaryOnly)
        XCTAssertEqual(try Data(contentsOf: target.vaultDatabase), vaultBefore)
        let reopened = try AppEnvironment.open(AppEnvironmentOptions(paths: target, keyStore: InMemoryVaultKeyStore(),
            authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(), clock: clock))
        XCTAssertEqual(try reopened.search.search(SearchQuery(text: "일반 기록 복원")).count, 1)
    }

    @MainActor func testWrongKeyRestoreOffersOrdinaryOnlyWithoutEchoingFailureDetails() async throws {
        let env = try environment()
        let secret = SecretsModel(environment: env)
        _ = try await savedSecret(secret, value: "canary-key-mismatch")
        let model = BackupModel(environment: env)
        await model.create()
        let backup = try XCTUnwrap(model.backups.first)
        let wrongKey = InMemoryVaultKeyStore()
        try wrongKey.storeKey(Data(repeating: 0, count: 32), id: XCTUnwrap(backup.manifest.vaultKeyVersion))
        model.detach()
        let target = try paths()
        let restored = await model.restoreAfterClosing(backup, into: target, keyStore: wrongKey, includeVault: true,
            clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertFalse(restored)
        XCTAssertTrue(model.offersOrdinaryOnlyRestore)
        XCTAssertFalse(model.includeSecrets)
        XCTAssertFalse(model.message?.contains("canary-key-mismatch") == true)
        model.recordFailure(BackupFailure.ioFailed("canary-arbitrary-error"))
        XCTAssertFalse(model.message?.contains("canary-arbitrary-error") == true)
    }

    @MainActor func testRestoreRequiresEnvironmentDetach() async throws {
        let env = try environment()
        let model = BackupModel(environment: env)
        await model.create()
        let backup = try XCTUnwrap(model.backups.first)
        let restored = await model.restoreAfterClosing(backup, into: env.options.paths, keyStore: env.options.keyStore,
            includeVault: true, clock: env.options.clock)
        XCTAssertFalse(restored)
        XCTAssertTrue(model.message?.contains("연결을 먼저 닫아야") == true)
    }
}
