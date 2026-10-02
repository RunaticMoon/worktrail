import XCTest
@testable import WorkLogCore

final class SecretEditorOwnershipTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }
    private func paths() throws -> AppPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WTUX-P-Ownership-\(UUID().uuidString)")
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

    @MainActor func testAcquireFailsForSecondHostAndSameHostReacquires() throws {
        let model = SecretsModel(environment: try environment())
        XCTAssertNil(model.editorOwner)
        XCTAssertFalse(model.canEdit(from: .main))
        XCTAssertFalse(model.canEdit(from: .capture))

        XCTAssertTrue(model.acquireEditor(.main))
        XCTAssertEqual(model.editorOwner, .main)
        XCTAssertTrue(model.canEdit(from: .main))
        XCTAssertFalse(model.canEdit(from: .capture))

        // A different host cannot take over while main owns the editor.
        XCTAssertFalse(model.acquireEditor(.capture))
        XCTAssertEqual(model.editorOwner, .main)

        // The same host may re-acquire idempotently.
        XCTAssertTrue(model.acquireEditor(.main))
        XCTAssertEqual(model.editorOwner, .main)

        // Releasing from a non-owner host is ignored.
        model.releaseEditor(.capture)
        XCTAssertEqual(model.editorOwner, .main)

        // The owner can release, after which either host may acquire.
        model.releaseEditor(.main)
        XCTAssertNil(model.editorOwner)
        XCTAssertTrue(model.acquireEditor(.capture))
        XCTAssertEqual(model.editorOwner, .capture)
    }

    @MainActor func testLockResetsOwnershipAlongWithPlaintext() async throws {
        let env = try environment()
        let model = SecretsModel(environment: env)
        await model.unlock()
        XCTAssertFalse(model.isLocked)
        model.beginNew()
        model.addRow()
        model.rows[0].key = "fake-owner-key"
        model.rows[0].value = "fake-owner-lock-canary"
        model.showsValues = true
        XCTAssertTrue(model.acquireEditor(.capture))
        XCTAssertEqual(model.editorOwner, .capture)

        model.lock()
        XCTAssertTrue(model.isLocked)
        XCTAssertNil(model.editorOwner)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertFalse(model.showsValues)
    }

    @MainActor func testOwnershipChangesDoNotDiscardDraftOrToggleShowsValues() async throws {
        let env = try environment()
        let model = SecretsModel(environment: env)
        await model.unlock()
        model.beginNew()
        model.addRow()
        model.rows[0].key = "fake-key"
        model.rows[0].value = "fake-ownership-canary"
        model.showsValues = true
        let rowsBefore = model.rows
        let titleBefore = model.title
        let ownerBefore = model.selectedId

        XCTAssertNil(model.editorOwner)
        XCTAssertTrue(model.hasUnsavedDraft)

        XCTAssertTrue(model.acquireEditor(.main))
        XCTAssertEqual(model.editorOwner, .main)
        XCTAssertEqual(model.rows, rowsBefore)
        XCTAssertEqual(model.title, titleBefore)
        XCTAssertEqual(model.selectedId, ownerBefore)
        XCTAssertTrue(model.showsValues)
        XCTAssertTrue(model.hasUnsavedDraft)

        // A rejected acquire from another host must not alter anything either.
        XCTAssertFalse(model.acquireEditor(.capture))
        XCTAssertEqual(model.rows, rowsBefore)
        XCTAssertTrue(model.showsValues)

        model.releaseEditor(.main)
        XCTAssertNil(model.editorOwner)
        XCTAssertEqual(model.rows, rowsBefore)
        XCTAssertTrue(model.showsValues)
        XCTAssertTrue(model.hasUnsavedDraft)
    }

    @MainActor func testHasUnsavedDraftTracksEditorChanges() async throws {
        let env = try environment()
        let model = SecretsModel(environment: env)
        await model.unlock()
        model.beginNew()
        XCTAssertFalse(model.hasUnsavedDraft)
        model.title = "fake-title"
        XCTAssertTrue(model.hasUnsavedDraft)
        model.title = ""
        XCTAssertFalse(model.hasUnsavedDraft)
        model.addRow()
        XCTAssertTrue(model.hasUnsavedDraft)
    }
}
