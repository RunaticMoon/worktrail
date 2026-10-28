import XCTest
@testable import WorkLogCore

/// Synthetic stores only; these tests never touch a user's Keychain.
final class LazyVaultKeyAccessTests: XCTestCase {
    private func paths() -> AppPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lazy-vault-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return AppPaths(dataRoot: root.appendingPathComponent("data"), backupRoot: root.appendingPathComponent("backups"))
    }

    private func open(_ paths: AppPaths, store: VaultKeyStore) throws -> AppEnvironment {
        try AppEnvironment.open(.init(paths: paths, keyStore: store,
            authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(),
            clock: FixedClock(Date(timeIntervalSince1970: 1_800_000_000)), ids: SequentialIDGenerator()))
    }

    func testFirstLaunchBackupAndMetadataSearchDoNotCreateOrReadKeychainItem() async throws {
        let store = SpyKeyStore(), environment = try open(paths(), store: store)
        let launch = environment.onLaunch()
        XCTAssertNil(launch.backupError)
        XCTAssertTrue(launch.backupCreated)
        XCTAssertTrue(try environment.vaultSession.searchTitles("").isEmpty)
        XCTAssertEqual(store.loads, 0); XCTAssertEqual(store.stores, 0)
        try await environment.vaultSession.unlock(reason: "fake user requested Secret")
        XCTAssertEqual(store.loads, 0); XCTAssertEqual(store.stores, 1)
        _ = try environment.vaultSession.create(title: "fake Secret", groupName: nil,
            rows: [.init(key: "fake-key", value: "fake-value")])
        XCTAssertEqual(store.stores, 1)
    }

    func testUpdatedAppOpensAndBacksUpWhileKeychainDeniedThenUnlockCanRetryWithoutReplacingKey() async throws {
        let location = paths(), store = SpyKeyStore()
        let initial = try open(location, store: store)
        try await initial.vaultSession.unlock(reason: "fake setup")
        let item = try initial.vaultSession.create(title: "fake title", groupName: nil,
            rows: [.init(key: "fake-key", value: "fake-value")])
        let originalIDs = Set(store.values.keys)
        store.denied = true
        let updated = try open(location, store: store)
        XCTAssertNil(updated.onLaunch().backupError)
        XCTAssertEqual(try updated.vaultSession.searchTitles("fake title").map(\.id), [item.id])
        XCTAssertEqual(store.loads, 0); XCTAssertEqual(store.stores, 1)
        do {
            try await updated.vaultSession.unlock(reason: "fake explicit request")
            XCTFail("Denied access must stay locked")
        } catch { XCTAssertEqual(updated.vaultSession.state, .locked) }
        XCTAssertEqual(store.loads, 1); XCTAssertEqual(store.stores, 1)
        store.denied = false
        try await updated.vaultSession.unlock(reason: "fake explicit retry")
        XCTAssertEqual(try updated.vaultSession.currentRows(secretId: item.id).first?.value, "fake-value")
        XCTAssertEqual(store.loads, 2); XCTAssertEqual(store.stores, 1)
        XCTAssertEqual(Set(store.values.keys), originalIDs)
    }

    func testExistingVersionWithMissingKeyIsNeverReplacedByDeferredAccess() async throws {
        let location = paths(), original = SpyKeyStore()
        let initial = try open(location, store: original)
        try await initial.vaultSession.unlock(reason: "fake setup")
        _ = try initial.vaultSession.create(title: "preserved fake title", groupName: nil,
            rows: [.init(key: "fake-key", value: "fake-value")])
        let missing = SpyKeyStore(), reopened = try open(location, store: missing)
        XCTAssertEqual(missing.loads, 0)
        do {
            try await reopened.vaultSession.unlock(reason: "fake missing key")
            XCTFail("Missing key must not be silently replaced")
        } catch { XCTAssertEqual(error as? WorkLogError, .vaultKeyMissing) }
        XCTAssertEqual(missing.loads, 1); XCTAssertEqual(missing.stores, 0)
        XCTAssertEqual(try reopened.vaultSession.searchTitles("preserved").count, 1)
    }

    func testDeferredStatusAndKeyVersionReadDoNotAccessKeyStore() throws {
        let db = try SQLiteDatabase(path: ":memory:"), store = SpyKeyStore()
        let vault = try SecretVault(db: db, keyStore: store, deferKeyAccess: true)
        XCTAssertEqual(vault.keyStatus, .notLoaded)
        XCTAssertNil(vault.keyVersion)
        XCTAssertTrue(try vault.searchTitles("").isEmpty)
        XCTAssertEqual(store.loads, 0); XCTAssertEqual(store.stores, 0)
        try vault.prepareKey()
        XCTAssertEqual(vault.keyStatus, .ready)
        XCTAssertNotNil(vault.keyVersion)
        XCTAssertEqual(store.stores, 1)
    }
}

private final class SpyKeyStore: VaultKeyStore, @unchecked Sendable {
    var values: [String: Data] = [:]
    var denied = false
    var loads = 0
    var stores = 0
    func loadKey(id: String) throws -> Data? {
        loads += 1
        if denied { throw WorkLogError.storage("fake locked Keychain") }
        return values[id]
    }
    func storeKey(_ key: Data, id: String) throws { stores += 1; values[id] = key }
    func deleteKey(id: String) throws { values[id] = nil }
}
