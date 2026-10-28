import Foundation
import XCTest
import CSQLite
@testable import WorkLogCore

final class SQLiteDiagnosticTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("sqlite-diagnostics-" + UUIDGenerator().make())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testSuccessfulSQLAndBackupDoNotProduceEvents() throws {
        let codes = CodeRecorder()
        let db = try SQLiteDatabase(path: ":memory:", onError: { codes.record($0) })
        try db.execute("CREATE TABLE records (value TEXT UNIQUE)")
        try db.run("INSERT INTO records (value) VALUES (?)", ["FAKE_PRIVATE_RECORD"])
        _ = try db.transaction { try db.run("UPDATE records SET value = ?", ["FAKE_PRIVATE_UPDATED"]) }
        XCTAssertEqual(try db.scalarInt("SELECT count(*) FROM records"), 1)
        XCTAssertTrue(try db.integrityCheck())
        try db.backup(to: root.appendingPathComponent("snapshot.sqlite").path)
        XCTAssertTrue(codes.values.isEmpty)
    }

    func testPrepareExecuteBindRunAndQueryFailuresReportOnlyTheirCodesOnce() throws {
        let codes = CodeRecorder()
        let db = try SQLiteDatabase(path: ":memory:", onError: { codes.record($0) })
        try db.execute("CREATE TABLE records (value TEXT UNIQUE)")
        try db.run("INSERT INTO records (value) VALUES (?)", ["FAKE_PRIVATE_RECORD"])
        XCTAssertThrowsError(try db.query("SELECT value FROM FAKE_PRIVATE_MISSING_TABLE"))
        XCTAssertThrowsError(try db.execute("INVALID_SQL_FAKE_PRIVATE_CONTENT"))
        XCTAssertThrowsError(try db.run("INSERT INTO records (value) VALUES (?)", ["FAKE_PRIVATE_RECORD"]))
        XCTAssertThrowsError(try db.query("SELECT ?", ["FAKE_PRIVATE_PARAMETER", "FAKE_PRIVATE_EXTRA_PARAMETER"]))
        XCTAssertThrowsError(try db.query("SELECT abs(?)", [Int64.min]))
        XCTAssertEqual(codes.values, [SQLITE_ERROR, SQLITE_ERROR, SQLITE_CONSTRAINT, SQLITE_RANGE, SQLITE_ERROR])
    }

    func testClosedConnectionAndEmptyPreparedStatementReportMisuse() throws {
        let codes = CodeRecorder()
        let db = try SQLiteDatabase(path: ":memory:", onError: { codes.record($0) })
        XCTAssertThrowsError(try db.query(""))
        db.close()
        XCTAssertThrowsError(try db.execute("SELECT 1"))
        XCTAssertThrowsError(try db.run("SELECT 1"))
        XCTAssertThrowsError(try db.query("SELECT 1"))
        XCTAssertThrowsError(try db.backup(to: root.appendingPathComponent("closed.sqlite").path))
        XCTAssertThrowsError(try db.transaction { XCTFail("Closed transaction must not run its body") })
        XCTAssertEqual(codes.values, Array(repeating: SQLITE_MISUSE, count: 6))
    }

    func testTransactionsKeepRollbackBehaviorAndDoNotLogNonSQLiteBodyErrors() throws {
        let codes = CodeRecorder()
        let db = try SQLiteDatabase(path: ":memory:", onError: { codes.record($0) })
        try db.execute("CREATE TABLE records (value TEXT UNIQUE)")
        XCTAssertThrowsError(try db.transaction {
            try db.run("INSERT INTO records (value) VALUES (?)", ["FAKE_PRIVATE_RECORD"])
            throw WorkLogError.validation("FAKE_PRIVATE_VALIDATION")
        })
        XCTAssertTrue(codes.values.isEmpty)
        XCTAssertEqual(try db.scalarInt("SELECT count(*) FROM records"), 0)
        XCTAssertThrowsError(try db.transaction {
            try db.run("INSERT INTO records (value) VALUES (?)", ["FAKE_PRIVATE_RECORD"])
            try db.run("INSERT INTO records (value) VALUES (?)", ["FAKE_PRIVATE_RECORD"])
        })
        XCTAssertEqual(codes.values, [SQLITE_CONSTRAINT])
        XCTAssertEqual(try db.scalarInt("SELECT count(*) FROM records"), 0)
    }

    func testOpenAndBackupDestinationFailuresReportCodes() throws {
        let codes = CodeRecorder()
        XCTAssertThrowsError(try SQLiteDatabase(path: root.path, onError: { codes.record($0) }))
        let db = try SQLiteDatabase(path: ":memory:", onError: { codes.record($0) })
        XCTAssertThrowsError(try db.backup(to: root.path))
        XCTAssertEqual(codes.values, [SQLITE_CANTOPEN, SQLITE_CANTOPEN])
    }

    func testNumericCallbackCannotCarrySQLParametersPathsOrMessagesIntoDiagnostics() throws {
        let diagnostics = DiagnosticLogStore(directory: root.appendingPathComponent("logs"),
            clock: FixedClock(Date(timeIntervalSince1970: 1_800_000_000)))
        // This public boundary accepts Int32 only. There is no Error, SQL, path or data payload.
        let callback: @Sendable (Int32) -> Void = { code in
            diagnostics.record(.operationFailed, category: .storage, fields: [.errorCode: .integer(Int(code))])
        }
        let db = try SQLiteDatabase(path: root.appendingPathComponent("FAKE_PRIVATE_DATABASE.sqlite").path,
                                     onError: callback)
        XCTAssertThrowsError(try db.query("SELECT value FROM FAKE_PRIVATE_TABLE WHERE value = ?", ["FAKE_SECRET_TOKEN"]))
        let data = try diagnostics.exportReport(metadata: DiagnosticReportMetadata(appVersion: "1.0.0", appBuild: "1",
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("FAKE_"))
        XCTAssertFalse(text.contains(root.path))
        XCTAssertFalse(text.contains("SELECT"))
        XCTAssertFalse(text.contains("no such table"))
        XCTAssertEqual(diagnostics.status().eventCount, 1)
    }

    func testEnvironmentForwardsWorkAndVaultDatabaseErrors() throws {
        let codes = CodeRecorder()
        let paths = AppPaths(dataRoot: root.appendingPathComponent("data"), backupRoot: root.appendingPathComponent("backups"))
        let options = AppEnvironmentOptions(paths: paths, keyStore: InMemoryVaultKeyStore(),
            authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(),
            clock: FixedClock(Date(timeIntervalSince1970: 1_800_000_000)), ids: SequentialIDGenerator())
        let env = try AppEnvironment.open(options, onStorageError: { codes.record($0) })
        codes.clear()
        XCTAssertThrowsError(try env.repo.db.query("SELECT value FROM FAKE_PRIVATE_MISSING_TABLE"))
        XCTAssertEqual(codes.values, [SQLITE_ERROR])

        let corruptPaths = AppPaths(dataRoot: root.appendingPathComponent("corrupt-data"),
                                    backupRoot: root.appendingPathComponent("corrupt-backups"))
        try corruptPaths.createDirectories()
        try Data("FAKE_CORRUPT_VAULT_DATA".utf8).write(to: corruptPaths.vaultDatabase)
        let corruptOptions = AppEnvironmentOptions(paths: corruptPaths, keyStore: InMemoryVaultKeyStore(),
            authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard())
        codes.clear()
        XCTAssertThrowsError(try AppEnvironment.open(corruptOptions, onStorageError: { codes.record($0) }))
        XCTAssertEqual(codes.values, [SQLITE_NOTADB])
    }
}

private final class CodeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int32] = []
    var values: [Int32] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(_ code: Int32) { lock.lock(); recorded.append(code); lock.unlock() }
    func clear() { lock.lock(); recorded.removeAll(); lock.unlock() }
}
