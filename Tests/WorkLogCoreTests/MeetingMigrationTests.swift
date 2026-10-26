import XCTest
@testable import WorkLogCore

final class MeetingMigrationTests: XCTestCase {
    func testV4UpgradePreservesMemoAndCreatesMeetingTablesOnlyOnce() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try Migrator.migrate(db, migrations: WorkSchema.migrations.filter { $0.version <= 4 })
        XCTAssertEqual(db.userVersion, 4)
        try db.run("INSERT INTO memo (id, body, work_date, recorded_at) VALUES (?, ?, ?, ?)",
            ["prior-memo", "기존 일반 기록", "2026-10-26", "2026-10-26T00:00:00.000Z"])
        let repo = try WorkRepository(db: db, clock: FixedClock(Date(timeIntervalSince1970: 1_792_972_800)),
            ids: SequentialIDGenerator())
        XCTAssertEqual(db.userVersion, WorkSchema.migrations.map(\.version).max())
        let service = MeetingService(repo: repo)
        let meeting = try service.create(title: "업그레이드 이후 회의", memoIDs: ["prior-memo"])
        XCTAssertEqual(meeting.memoSnapshots.first?.body, "기존 일반 기록")
        try Migrator.migrate(db, migrations: WorkSchema.migrations)
        XCTAssertEqual(try service.meetings().count, 1)
        XCTAssertEqual(try repo.memo(id: "prior-memo")?.body, "기존 일반 기록")
        XCTAssertTrue(try db.integrityCheck())
    }
}
