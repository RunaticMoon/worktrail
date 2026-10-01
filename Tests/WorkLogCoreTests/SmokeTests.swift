import XCTest
@testable import WorkLogCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class SmokeTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmokeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        tempDirs.append(dir)
        return dir
    }

    private func posixPermissions(atPath path: String) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testMigrationsApply() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try Migrator.migrate(db, migrations: WorkSchema.migrations)
        XCTAssertEqual(db.userVersion, 3)
        let vault = try SQLiteDatabase(path: ":memory:")
        try Migrator.migrate(vault, migrations: VaultSchema.migrations)
        XCTAssertEqual(vault.userVersion, 1)
    }

    func testFixtureLoads() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/example_data", withExtension: "json"))
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 1000)
    }

    func testWorkDateParsing() {
        XCTAssertEqual(WorkDate("2026-10-05")?.iso, "2026-10-05")
        XCTAssertNil(WorkDate("2026-02-30"))
        XCTAssertEqual(WorkCalendar().isoWeekday(WorkDate("2026-10-05")!), 1)
    }

    // MARK: - DB 파일 권한 0600 (README §권한)

    // umask 0022 상태에서 만든 새 DB 파일(+ 존재하는 -wal)이 0600인지.
    func testNewDatabaseFilesAreCreatedWith0600() throws {
        let dir = try makeTempDir()
        let path = dir.appendingPathComponent("work.sqlite").path
        let previous = umask(0o022)
        defer { _ = umask(previous) }

        let db = try SQLiteDatabase(path: path)
        try db.execute("CREATE TABLE t (x INTEGER)")
        try db.run("INSERT INTO t (x) VALUES (?)", [1])
        db.close()

        XCTAssertEqual(try posixPermissions(atPath: path), 0o600)
        let wal = path + "-wal"
        if FileManager.default.fileExists(atPath: wal) {
            XCTAssertEqual(try posixPermissions(atPath: wal), 0o600)
        }
        let shm = path + "-shm"
        if FileManager.default.fileExists(atPath: shm) {
            XCTAssertEqual(try posixPermissions(atPath: shm), 0o600)
        }
    }

    // 기존에 0644였던 DB 파일도 열면 0600으로 조여진다.
    func testExistingDatabaseFileIsTightenedTo0600() throws {
        let dir = try makeTempDir()
        let path = dir.appendingPathComponent("work.sqlite").path
        _ = FileManager.default.createFile(atPath: path, contents: nil,
                                           attributes: [.posixPermissions: 0o644])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        XCTAssertEqual(try posixPermissions(atPath: path), 0o644)

        let db = try SQLiteDatabase(path: path)
        db.close()

        XCTAssertEqual(try posixPermissions(atPath: path), 0o600)
    }
}
