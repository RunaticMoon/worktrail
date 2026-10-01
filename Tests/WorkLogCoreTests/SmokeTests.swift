import XCTest
@testable import WorkLogCore

final class SmokeTests: XCTestCase {
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
}
