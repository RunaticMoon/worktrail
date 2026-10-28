import XCTest
@testable import WorkLogCore

/// Never opens the login Keychain; all records and keys are synthetic.
final class BackupUninitializedVaultTests: XCTestCase {
    private let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("empty-vault-backup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func paths(_ root: URL) -> AppPaths {
        AppPaths(dataRoot: root.appendingPathComponent("data"), backupRoot: root.appendingPathComponent("backups"))
    }

    private func seedOrdinaryTarget(_ paths: AppPaths) throws -> String {
        let db = try SQLiteDatabase(path: paths.workDatabase.path)
        defer { db.close() }
        let repo = try WorkRepository(db: db, clock: clock, ids: SequentialIDGenerator(prefix: "target"))
        return try TaskService(repo: repo).captureMemo(body: "synthetic previous ordinary record").id
    }

    private func makeBackup(_ paths: AppPaths, mutate: (SQLiteDatabase) throws -> Void) throws -> BackupInfo {
        let work = try SQLiteDatabase(path: paths.workDatabase.path)
        defer { work.close() }
        _ = try WorkRepository(db: work, clock: clock, ids: SequentialIDGenerator())
        let vault = try SQLiteDatabase(path: paths.vaultDatabase.path)
        defer { vault.close() }
        try Migrator.migrate(vault, migrations: VaultSchema.migrations)
        try mutate(vault)
        return try BackupService(paths: paths, workDB: work, vaultDB: vault, clock: clock,
            ids: SequentialIDGenerator()).createBackup(reason: .manual)
    }

    func testFirstLaunchBackupRestoresOrdinaryRecordsAndPreservesPreRestoreWithoutKeychainAccess() async throws {
        let directory = try root(), keys = RestoreSpyKeyStore()
        let source = paths(directory.appendingPathComponent("source"))
        let environment = try AppEnvironment.open(.init(paths: source, keyStore: keys,
            authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(), clock: clock,
            ids: SequentialIDGenerator(prefix: "source")))
        let memo = try environment.tasks.captureMemo(body: "synthetic source ordinary record")
        let backup = try environment.backup.createBackup(reason: .manual)
        XCTAssertNil(backup.manifest.vaultKeyVersion)
        let backupVault = backup.directory.appendingPathComponent(BackupService.vaultFileName)
        let originalVault = try Data(contentsOf: backupVault)
        let target = paths(directory.appendingPathComponent("target"))
        let oldMemoID = try seedOrdinaryTarget(target)

        try BackupService.restore(backup, into: target, keyStore: keys, clock: clock)
        XCTAssertEqual(keys.loads, 0)
        XCTAssertEqual(keys.stores, 0)
        XCTAssertEqual(try Data(contentsOf: backupVault), originalVault, "verification must leave the backup untouched")
        let restored = try AppEnvironment.open(.init(paths: target, keyStore: keys,
            authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(), clock: clock,
            ids: SequentialIDGenerator(prefix: "restored")))
        XCTAssertEqual(try restored.repo.memo(id: memo.id)?.body, memo.body)
        XCTAssertNil(try restored.repo.memo(id: oldMemoID))
        let preserved = try XCTUnwrap(try restored.backup.listBackups().first { $0.manifest.reason == .preRestore })
        let oldDatabase = try SQLiteDatabase(path: preserved.directory.appendingPathComponent(BackupService.workFileName).path, readOnly: true)
        defer { oldDatabase.close() }
        XCTAssertNotNil(try oldDatabase.queryOne("SELECT id FROM memo WHERE id = ?", [oldMemoID]))
        XCTAssertEqual(keys.loads, 0)
        XCTAssertEqual(keys.stores, 0)
        try await restored.vaultSession.unlock(reason: "synthetic explicit Secret use")
        _ = try restored.vaultSession.create(title: "synthetic new Secret", groupName: nil,
            rows: [.init(key: "fake-key", value: "fake-value")])
        XCTAssertEqual(keys.stores, 1, "the restored empty vault initializes only on explicit use")
    }

    func testMissingVersionRejectsMetadataEncryptedDataAndDamagedSchemasBeforeChangingTarget() throws {
        let directory = try root(), target = paths(directory.appendingPathComponent("target"))
        _ = try seedOrdinaryTarget(target)
        let originalWork = try Data(contentsOf: target.workDatabase)
        let cases: [(String, (SQLiteDatabase) throws -> Void)] = [
            ("metadata", { try $0.run("INSERT INTO vault_meta (key, value) VALUES (?, ?)", ["unknown", "fake"]) }),
            ("group", { try $0.run("INSERT INTO secret_group (id, name) VALUES (?, ?)", ["fake-group", "fake name"]) }),
            ("item", { try $0.run("INSERT INTO secret_item (id, title, created_at, updated_at) VALUES (?, ?, ?, ?)",
                ["fake-item", "fake title", "fake-date", "fake-date"]) }),
            ("revision", {
                try $0.execute("PRAGMA foreign_keys = OFF")
                try $0.run("INSERT INTO secret_revision (id, secret_id, version, key_version, encrypted_payload, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                    ["fake-revision", "fake-item", 1, "missing-version", Data([1, 2, 3]), "fake-date"])
            }),
            ("draft", { try $0.run("INSERT INTO secret_draft (id, key_version, encrypted_payload, updated_at) VALUES (?, ?, ?, ?)",
                ["draft", "missing-version", Data([1, 2, 3]), "fake-date"]) }),
            ("missing-table", { try $0.execute("DROP TABLE secret_draft") }),
            ("damaged-column", { try $0.execute("ALTER TABLE secret_item RENAME COLUMN title TO damaged_title") }),
            ("unexpected-table", { try $0.execute("CREATE TABLE unexpected (value TEXT)") }),
            ("wrong-version", { try $0.setUserVersion(0) }),
        ]
        for (name, mutate) in cases {
            let backup = try makeBackup(paths(directory.appendingPathComponent(name)), mutate: mutate)
            XCTAssertNil(backup.manifest.vaultKeyVersion)
            let keys = RestoreSpyKeyStore()
            XCTAssertThrowsError(try BackupService.restore(backup, into: target, keyStore: keys, clock: clock)) {
                XCTAssertEqual($0 as? BackupFailure, .vaultKeyMissing(keyVersion: nil), name)
            }
            XCTAssertEqual(try Data(contentsOf: target.workDatabase), originalWork, name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.vaultDatabase.path), name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.backupRoot.path), "failed preflight must not begin restore: " + name)
            XCTAssertEqual(keys.loads, 0, name)
            XCTAssertEqual(keys.stores, 0, name)
        }
    }

    func testInitializedVaultStillRequiresOriginalKeyEvenWhenEmptyOrMetadataWasRemoved() throws {
        let directory = try root(), originalKeys = InMemoryVaultKeyStore()
        let target = paths(directory.appendingPathComponent("target"))
        _ = try seedOrdinaryTarget(target)
        let originalWork = try Data(contentsOf: target.workDatabase)
        for populated in [false, true] {
            let backup = try makeBackup(paths(directory.appendingPathComponent(populated ? "nonempty" : "initialized-empty"))) { db in
                let vault = try SecretVault(db: db, keyStore: originalKeys, clock: clock, ids: SequentialIDGenerator())
                if populated {
                    _ = try vault.create(title: "synthetic secret", groupName: nil, rows: [.init(key: "fake", value: "fake")])
                    try db.run("DELETE FROM vault_meta WHERE key = ?", ["key_version"])
                }
            }
            let keys = RestoreSpyKeyStore()
            XCTAssertThrowsError(try BackupService.restore(backup, into: target, keyStore: keys, clock: clock)) {
                XCTAssertEqual($0 as? BackupFailure, .vaultKeyMissing(keyVersion: backup.manifest.vaultKeyVersion))
            }
            XCTAssertEqual(keys.loads, populated ? 0 : 1)
            XCTAssertEqual(keys.stores, 0)
            XCTAssertEqual(try Data(contentsOf: target.workDatabase), originalWork)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.vaultDatabase.path))
        }
    }
}

private final class RestoreSpyKeyStore: VaultKeyStore, @unchecked Sendable {
    private var keys: [String: Data] = [:]
    private(set) var loads = 0
    private(set) var stores = 0
    func loadKey(id: String) throws -> Data? { loads += 1; return keys[id] }
    func storeKey(_ key: Data, id: String) throws { stores += 1; keys[id] = key }
    func deleteKey(id: String) throws { keys.removeValue(forKey: id) }
}
