import XCTest
@testable import WorkLogCore

/// Migration v4(record_link) 스키마 검증.
///
/// - 새 DB가 v4까지 적용되고 record_link가 존재한다.
/// - v1~v3만 적용된 DB가 v4로 승격되고 기존 데이터가 보존된다.
/// - 정규 순서·자기 연결·중복·허용되지 않은 kind·relation_type 제약이 동작한다.
/// - `RecordReference.canonicalPair`의 정규 순서가 SQL의 BINARY 순서와 일치한다.
final class GraphMigrationTests: XCTestCase {

    private func makeDatabase() throws -> SQLiteDatabase {
        try SQLiteDatabase(path: ":memory:")
    }

    private func objectExists(_ db: SQLiteDatabase, type: String, name: String) throws -> Bool {
        let rows = try db.query(
            "SELECT name FROM sqlite_master WHERE type = ? AND name = ?",
            [type, name])
        return !rows.isEmpty
    }

    /// record_link에 행을 추가한다. 모든 값은 `?` 바인딩으로 넣는다.
    private func insertLink(
        _ db: SQLiteDatabase,
        id: String,
        from: RecordReference,
        to: RecordReference,
        relationType: String = "related",
        createdAt: String = "2026-10-02T00:00:00.000Z"
    ) throws {
        try db.run("""
        INSERT INTO record_link (id, from_kind, from_id, to_kind, to_id, relation_type, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """, [id, from.kind.rawValue, from.id, to.kind.rawValue, to.id, relationType, createdAt])
    }

    private func count(_ db: SQLiteDatabase, table: String) throws -> Int {
        try db.query("SELECT COUNT(*) AS c FROM \(table)").first?.int("c") ?? -1
    }

    // MARK: 새 DB → v4

    func testFreshDatabaseMigratesToV4AndCreatesRecordLink() throws {
        let db = try makeDatabase()
        try Migrator.migrate(db, migrations: WorkSchema.migrations)

        XCTAssertEqual(db.userVersion, 4)
        XCTAssertTrue(try objectExists(db, type: "table", name: "record_link"),
                      "v4 적용 후 record_link 테이블이 있어야 한다")
        XCTAssertTrue(try objectExists(db, type: "index", name: "record_link_to"),
                      "v4 적용 후 record_link_to 인덱스가 있어야 한다")
    }

    // MARK: v3 DB → v4 승격 + 기존 데이터 보존

    func testV3DatabasePromotesToV4AndPreservesExistingData() throws {
        let db = try makeDatabase()
        let upToV3 = WorkSchema.migrations.filter { $0.version <= 3 }
        XCTAssertEqual(upToV3.map(\.version), [1, 2, 3])
        try Migrator.migrate(db, migrations: upToV3)

        XCTAssertEqual(db.userVersion, 3)
        XCTAssertFalse(try objectExists(db, type: "table", name: "record_link"))

        // v3 시점의 기존 일반 기록.
        try db.run("INSERT INTO memo (id, body, work_date, recorded_at) VALUES (?, ?, ?, ?)",
                   ["memo-keep", "승격 전 본문", "2026-10-01", "2026-10-01T09:00:00.000Z"])

        try Migrator.migrate(db, migrations: WorkSchema.migrations)

        XCTAssertEqual(db.userVersion, 4)
        XCTAssertTrue(try objectExists(db, type: "table", name: "record_link"))
        XCTAssertEqual(try count(db, table: "memo"), 1)
        let preserved = try db.query("SELECT body FROM memo WHERE id = ?", ["memo-keep"]).first
        XCTAssertEqual(preserved?.string("body"), "승격 전 본문")
    }

    // MARK: canonicalPair ↔ SQL 순서 일치

    func testCanonicalPairInsertSucceedsAndMatchesSQLOrdering() throws {
        let db = try makeDatabase()
        try Migrator.migrate(db, migrations: WorkSchema.migrations)

        // 한글·대소문자·숫자 id를 섞어 UTF-8/BINARY 순서를 확인한다.
        let refs = [
            RecordReference(kind: .task, id: "t2"),
            RecordReference(kind: .memo, id: "한글"),
            RecordReference(kind: .activity, id: "Zebra"),
            RecordReference(kind: .reportVersion, id: "v1"),
            RecordReference(kind: .memo, id: "apple"),
            RecordReference(kind: .task, id: "10"),
            RecordReference(kind: .task, id: "2"),
        ]

        var inserted = 0
        for i in 0..<refs.count {
            for j in (i + 1)..<refs.count {
                guard let pair = RecordReference.canonicalPair(refs[i], refs[j]) else {
                    return XCTFail("서로 다른 참조의 정규 순서쌍이 nil이면 안 된다")
                }
                // 정규 순서쌍을 그대로 INSERT하면 SQL CHECK를 통과해야 한다.
                try insertLink(db, id: "l-\(inserted)", from: pair.0, to: pair.1)
                inserted += 1
            }
        }
        XCTAssertEqual(try count(db, table: "record_link"), inserted)
    }

    // MARK: 제약 위반

    func testNonCanonicalOrderIsRejected() throws {
        let db = try makeDatabase()
        try Migrator.migrate(db, migrations: WorkSchema.migrations)

        // kind는 memo < task이므로 memo를 from에 두는 것이 정규 순서다. 뒤집으면 실패.
        XCTAssertThrowsError(try insertLink(
            db, id: "l-bad-kind",
            from: RecordReference(kind: .task, id: "t1"),
            to: RecordReference(kind: .memo, id: "m1")))

        // 같은 kind에서는 id 오름차순이어야 한다. "b" → "a"는 실패.
        XCTAssertThrowsError(try insertLink(
            db, id: "l-bad-id",
            from: RecordReference(kind: .memo, id: "b"),
            to: RecordReference(kind: .memo, id: "a")))

        XCTAssertEqual(try count(db, table: "record_link"), 0)
    }

    func testSelfLinkIsRejected() throws {
        let db = try makeDatabase()
        try Migrator.migrate(db, migrations: WorkSchema.migrations)

        XCTAssertThrowsError(try insertLink(
            db, id: "l-self",
            from: RecordReference(kind: .memo, id: "m1"),
            to: RecordReference(kind: .memo, id: "m1")))

        XCTAssertEqual(try count(db, table: "record_link"), 0)
    }

    func testDuplicateLinkIsRejected() throws {
        let db = try makeDatabase()
        try Migrator.migrate(db, migrations: WorkSchema.migrations)

        let from = RecordReference(kind: .memo, id: "m1")
        let to = RecordReference(kind: .task, id: "t1")
        try insertLink(db, id: "l-1", from: from, to: to)

        XCTAssertThrowsError(try insertLink(db, id: "l-2", from: from, to: to))
        XCTAssertEqual(try count(db, table: "record_link"), 1)
    }

    func testSecretKindIsRejected() throws {
        let db = try makeDatabase()
        try Migrator.migrate(db, migrations: WorkSchema.migrations)

        // from_kind의 허용 목록에 'secret'은 없다. 순서상 'secret' < 'task'라도 거절돼야 한다.
        XCTAssertThrowsError(try db.run("""
        INSERT INTO record_link (id, from_kind, from_id, to_kind, to_id, relation_type, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """, ["l-secret", "secret", "s1", "task", "t1", "related", "2026-10-02T00:00:00.000Z"]))

        // to_kind 쪽도 동일하게 거절된다.
        XCTAssertThrowsError(try db.run("""
        INSERT INTO record_link (id, from_kind, from_id, to_kind, to_id, relation_type, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """, ["l-secret-back", "memo", "m1", "vault", "v1", "related", "2026-10-02T00:00:00.000Z"]))

        XCTAssertEqual(try count(db, table: "record_link"), 0)
    }

    func testNonRelatedRelationTypeIsRejected() throws {
        let db = try makeDatabase()
        try Migrator.migrate(db, migrations: WorkSchema.migrations)

        XCTAssertThrowsError(try insertLink(
            db, id: "l-blocking",
            from: RecordReference(kind: .memo, id: "m1"),
            to: RecordReference(kind: .task, id: "t1"),
            relationType: "blocking"))

        XCTAssertEqual(try count(db, table: "record_link"), 0)
    }

    func testRelationTypeDefaultsToRelated() throws {
        let db = try makeDatabase()
        try Migrator.migrate(db, migrations: WorkSchema.migrations)

        try db.run("""
        INSERT INTO record_link (id, from_kind, from_id, to_kind, to_id, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """, ["l-default", "memo", "m1", "task", "t1", "2026-10-02T00:00:00.000Z"])

        let row = try db.query("SELECT relation_type FROM record_link WHERE id = ?", ["l-default"]).first
        XCTAssertEqual(row?.string("relation_type"), "related")
    }
}
