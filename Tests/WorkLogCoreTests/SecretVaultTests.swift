import XCTest
@testable import WorkLogCore

/// SEC-01~07 / 기술설계 §10: vault.sqlite 암호화 보관함.
/// 실제 파일 DB를 임시 디렉터리에 만들어 검증한다(평문 잔존·변조 감지 포함).
final class SecretVaultTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecretVaultTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func databaseURL(_ dir: URL) -> URL {
        dir.appendingPathComponent("vault.sqlite")
    }

    private func fixedClock() -> FixedClock {
        let start = WorkCalendar().startOfDay(WorkDate(year: 2026, month: 10, day: 1))
        return FixedClock(start)
    }

    private func openVault(_ dir: URL, keyStore: VaultKeyStore,
                           clock: Clock = SystemClock()) throws -> (SQLiteDatabase, SecretVault) {
        let db = try SQLiteDatabase(path: databaseURL(dir).path)
        let vault = try SecretVault(db: db, keyStore: keyStore, clock: clock)
        return (db, vault)
    }

    /// vault.sqlite 및 WAL/SHM 잔존 파일의 바이트들.
    private func databaseFileBytes(_ dir: URL) -> [Data] {
        var result: [Data] = []
        for suffix in ["", "-wal", "-shm"] {
            let path = databaseURL(dir).path + suffix
            if let data = FileManager.default.contents(atPath: path) { result.append(data) }
        }
        return result
    }

    private func fileBytesContainPlaintext(_ needle: String, in dir: URL) -> Bool {
        let target = Data(needle.utf8)
        return databaseFileBytes(dir).contains { $0.range(of: target) != nil }
    }

    private func loadFixture() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/example_data", withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertIntegrity(_ expression: @autoclosure () throws -> Any,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let wl = error as? WorkLogError, case .integrity = wl else {
                XCTFail("integrity 오류를 기대했지만 \(error)", file: file, line: line)
                return
            }
        }
    }

    private func assertVaultKeyMissing(_ expression: @autoclosure () throws -> Any,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(error as? WorkLogError, .vaultKeyMissing, file: file, line: line)
        }
    }

    private func assertValidation(_ expression: @autoclosure () throws -> Any,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let wl = error as? WorkLogError, case .validation = wl else {
                XCTFail("validation 오류를 기대했지만 \(error)", file: file, line: line)
                return
            }
        }
    }

    // MARK: - SEC-T12: 픽스처 부분 수정

    func testPartialUpdateFixtureScenario() throws {
        let fixture = try loadFixture()
        let scenario = try XCTUnwrap(fixture["secretPartialUpdateCase"] as? [String: Any])
        let initial = try XCTUnwrap(scenario["initialRows"] as? [[String: Any]])
        let patch = try XCTUnwrap(scenario["patch"] as? [String: Any])
        let expected = try XCTUnwrap(scenario["expectedRows"] as? [[String: Any]])
        let expectedRevisionCount = try XCTUnwrap(scenario["expectedRevisionCountAfterOneSave"] as? Int)

        let dir = try makeTempDir()
        let (db, vault) = try openVault(dir, keyStore: InMemoryVaultKeyStore())
        defer { db.close() }

        let meta = try vault.create(title: "서버", groupName: "infra", rows: initial.map {
            SecretRowInput(key: $0["key"] as? String ?? "", value: $0["value"] as? String ?? "")
        })

        let current = try vault.currentRows(secretId: meta.id)
        XCTAssertEqual(current.count, 2)
        let apiRow = try XCTUnwrap(current.first { $0.key == "API_KEY" })

        let outcome = try vault.save(secretId: meta.id, changes: SecretChangeSet(upserts: [
            SecretRowInput(id: apiRow.id,
                           key: patch["key"] as? String ?? "",
                           value: patch["value"] as? String ?? "")
        ]))
        XCTAssertEqual(outcome, .saved(version: 2))

        let revisions = try vault.revisions(secretId: meta.id)
        XCTAssertEqual(revisions.count, expectedRevisionCount)

        let after = try vault.currentRows(secretId: meta.id)
        XCTAssertEqual(after.count, 2)
        for row in expected {
            let key = row["key"] as? String ?? ""
            let value = row["value"] as? String ?? ""
            let actual = try XCTUnwrap(after.first { $0.key == key }, "\(key) 행이 없음")
            XCTAssertEqual(actual.value, value)
        }
        XCTAssertEqual(after.first { $0.key == "API_KEY" }?.id, apiRow.id)
    }

    // MARK: - SEC-T13: save는 revision을 1 증가시킨다

    func testSaveIncrementsRevision() throws {
        let dir = try makeTempDir()
        let (db, vault) = try openVault(dir, keyStore: InMemoryVaultKeyStore(), clock: fixedClock())
        defer { db.close() }

        let meta = try vault.create(title: "증가", groupName: nil,
                                    rows: [SecretRowInput(key: "A", value: "1")])
        XCTAssertEqual(try vault.revisions(secretId: meta.id).count, 1)

        let rowId = try XCTUnwrap(try vault.currentRows(secretId: meta.id).first?.id)
        XCTAssertEqual(try vault.save(secretId: meta.id, changes: SecretChangeSet(upserts: [
            SecretRowInput(id: rowId, key: "A", value: "2")
        ])), .saved(version: 2))
        XCTAssertEqual(try vault.revisions(secretId: meta.id).count, 2)
    }

    // MARK: - SEC-T14: 앞뒤 공백만 다르면 unchanged

    func testWhitespaceOnlySaveIsUnchanged() throws {
        let dir = try makeTempDir()
        let (db, vault) = try openVault(dir, keyStore: InMemoryVaultKeyStore())
        defer { db.close() }

        let meta = try vault.create(title: "공백", groupName: nil,
                                    rows: [SecretRowInput(key: "K", value: "V")])
        let rowId = try XCTUnwrap(try vault.currentRows(secretId: meta.id).first?.id)

        let outcome = try vault.save(secretId: meta.id, changes: SecretChangeSet(upserts: [
            SecretRowInput(id: rowId, key: "  K  ", value: "\tV\n")
        ]))
        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(try vault.revisions(secretId: meta.id).count, 1)
    }

    // MARK: - SEC-T15: key 이름 변경 시 행 ID 유지, 이전 revision에서 옛 값 조회

    func testKeyRenameKeepsRowIdAndHistory() throws {
        let dir = try makeTempDir()
        let (db, vault) = try openVault(dir, keyStore: InMemoryVaultKeyStore())
        defer { db.close() }

        let meta = try vault.create(title: "이름변경", groupName: nil,
                                    rows: [SecretRowInput(key: "OLD_KEY", value: "old-value")])
        let before = try vault.currentRows(secretId: meta.id)
        let rowId = try XCTUnwrap(before.first?.id)
        let revision1 = try XCTUnwrap(try vault.revisions(secretId: meta.id).first)

        XCTAssertEqual(try vault.save(secretId: meta.id, changes: SecretChangeSet(upserts: [
            SecretRowInput(id: rowId, key: "NEW_KEY", value: "old-value")
        ])), .saved(version: 2))

        let after = try vault.currentRows(secretId: meta.id)
        XCTAssertEqual(after.first?.id, rowId)
        XCTAssertEqual(after.first?.key, "NEW_KEY")

        let old = try vault.rows(secretId: meta.id, revisionId: revision1.id)
        XCTAssertEqual(old.first?.id, rowId)
        XCTAssertEqual(old.first?.key, "OLD_KEY")
        XCTAssertEqual(old.first?.value, "old-value")
    }

    // MARK: - SEC-T23: 행 삭제 후 이전 revision 복원

    func testRowDeleteThenRestoreRevisionKeepsHistory() throws {
        let dir = try makeTempDir()
        let (db, vault) = try openVault(dir, keyStore: InMemoryVaultKeyStore())
        defer { db.close() }

        let meta = try vault.create(title: "복원", groupName: nil, rows: [
            SecretRowInput(key: "A", value: "1"),
            SecretRowInput(key: "B", value: "2"),
        ])
        let rows = try vault.currentRows(secretId: meta.id)
        let bId = try XCTUnwrap(rows.first { $0.key == "B" }?.id)
        let revision1 = try XCTUnwrap(try vault.revisions(secretId: meta.id).first)

        XCTAssertEqual(try vault.save(secretId: meta.id, changes: SecretChangeSet(deletedRowIds: [bId])),
                       .saved(version: 2))
        XCTAssertEqual(try vault.currentRows(secretId: meta.id).count, 1)

        XCTAssertEqual(try vault.restoreRevision(secretId: meta.id, revisionId: revision1.id),
                       .saved(version: 3))
        let restored = try vault.currentRows(secretId: meta.id)
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.first { $0.key == "B" }?.value, "2")
        XCTAssertEqual(restored.first { $0.key == "B" }?.id, bId)
        XCTAssertEqual(try vault.revisions(secretId: meta.id).count, 3)
        // 복원해도 과거 이력은 삭제되지 않는다.
        XCTAssertEqual(try vault.rows(secretId: meta.id, revisionId: revision1.id).count, 2)
    }

    func testRestoreRevisionWithSameContentIsUnchanged() throws {
        let dir = try makeTempDir()
        let (db, vault) = try openVault(dir, keyStore: InMemoryVaultKeyStore())
        defer { db.close() }

        let meta = try vault.create(title: "동일", groupName: nil,
                                    rows: [SecretRowInput(key: "A", value: "1")])
        let latest = try XCTUnwrap(try vault.revisions(secretId: meta.id).last)
        XCTAssertEqual(try vault.restoreRevision(secretId: meta.id, revisionId: latest.id), .unchanged)
        XCTAssertEqual(try vault.revisions(secretId: meta.id).count, 1)
    }

    // MARK: - SEC-T22: 휴지통 이동·복원

    func testTrashAndRestore() throws {
        let dir = try makeTempDir()
        let (db, vault) = try openVault(dir, keyStore: InMemoryVaultKeyStore())
        defer { db.close() }

        let meta = try vault.create(title: "휴지통", groupName: "grp",
                                    rows: [SecretRowInput(key: "A", value: "1")])
        let revisionsBefore = try vault.revisions(secretId: meta.id)

        try vault.moveToTrash(secretId: meta.id)
        XCTAssertTrue(try vault.searchTitles("").isEmpty)
        XCTAssertTrue(try vault.searchTitles("휴지통").isEmpty)
        XCTAssertTrue(try vault.searchTitles("휴지통", includeDeleted: true).contains { $0.id == meta.id })
        let trashed = try vault.trash()
        XCTAssertEqual(trashed.map { $0.id }, [meta.id])
        XCTAssertNotNil(trashed.first?.deletedAt)

        try vault.restoreFromTrash(secretId: meta.id)
        XCTAssertTrue(try vault.trash().isEmpty)
        let restored = try XCTUnwrap(try vault.metadata(id: meta.id))
        XCTAssertEqual(restored.id, meta.id)
        XCTAssertNil(restored.deletedAt)
        XCTAssertEqual(try vault.revisions(secretId: meta.id), revisionsBefore)
        XCTAssertTrue(try vault.searchTitles("휴지통").contains { $0.id == meta.id })
    }

    // MARK: - SEC-T24: 영구 삭제(휴지통 항목만)

    func testPurgeRemovesMetadataAndRevisions() throws {
        let dir = try makeTempDir()
        let (db, vault) = try openVault(dir, keyStore: InMemoryVaultKeyStore())
        defer { db.close() }

        let meta = try vault.create(title: "영구", groupName: nil,
                                    rows: [SecretRowInput(key: "A", value: "1")])
        try vault.moveToTrash(secretId: meta.id)
        try vault.purge(secretId: meta.id)

        XCTAssertEqual(try db.query("SELECT 1 AS x FROM secret_item WHERE id = ?", [meta.id]).count, 0)
        XCTAssertEqual(try db.query("SELECT 1 AS x FROM secret_revision WHERE secret_id = ?", [meta.id]).count, 0)
        XCTAssertNil(try vault.metadata(id: meta.id))
    }

    func testPurgeNonTrashedFails() throws {
        let dir = try makeTempDir()
        let (db, vault) = try openVault(dir, keyStore: InMemoryVaultKeyStore())
        defer { db.close() }

        let meta = try vault.create(title: "살아있음", groupName: nil,
                                    rows: [SecretRowInput(key: "A", value: "1")])
        assertValidation(try vault.purge(secretId: meta.id))
        XCTAssertNotNil(try vault.metadata(id: meta.id))
    }

    // MARK: - SEC-T25: 평문 잔존 없음(카나리아)

    func testCanaryValuesAreNotPlaintextInDatabaseFiles() throws {
        let canaryKey = "CANARY-KEY-91b2"
        let canaryValue = "CANARY-VALUE-7f3a"
        let dir = try makeTempDir()

        let (db, vault) = try openVault(dir, keyStore: InMemoryVaultKeyStore())
        _ = try vault.create(title: "카나리아", groupName: "cana",
                             rows: [SecretRowInput(key: canaryKey, value: canaryValue)])
        db.close()

        let bytes = databaseFileBytes(dir)
        XCTAssertFalse(bytes.isEmpty, "DB 파일을 읽지 못함")
        XCTAssertFalse(fileBytesContainPlaintext(canaryKey, in: dir), "key 평문이 DB 파일에 남음")
        XCTAssertFalse(fileBytesContainPlaintext(canaryValue, in: dir), "value 평문이 DB 파일에 남음")
    }

    // MARK: - SEC-T27: 변조·바꿔치기 감지

    func testTamperedCiphertextFailsIntegrity() throws {
        let dir = try makeTempDir()
        let (db, vault) = try openVault(dir, keyStore: InMemoryVaultKeyStore())
        defer { db.close() }

        let meta = try vault.create(title: "변조", groupName: nil,
                                    rows: [SecretRowInput(key: "A", value: "1")])
        let revision = try XCTUnwrap(try vault.revisions(secretId: meta.id).first)
        let stored = try XCTUnwrap(try db.queryOne(
            "SELECT encrypted_payload FROM secret_revision WHERE id = ?", [revision.id]))
        var ciphertext = try XCTUnwrap(stored.data("encrypted_payload"))
        ciphertext[0] = ciphertext[0] ^ 0xFF
        try db.run("UPDATE secret_revision SET encrypted_payload = ? WHERE id = ?",
                   [ciphertext, revision.id])

        assertIntegrity(try vault.currentRows(secretId: meta.id))
    }

    func testSwappedPayloadFailsIntegrityByAAD() throws {
        let dir = try makeTempDir()
        let (db, vault) = try openVault(dir, keyStore: InMemoryVaultKeyStore())
        defer { db.close() }

        let a = try vault.create(title: "A", groupName: nil,
                                 rows: [SecretRowInput(key: "A", value: "1")])
        let b = try vault.create(title: "B", groupName: nil,
                                 rows: [SecretRowInput(key: "B", value: "2")])
        let revisionA = try XCTUnwrap(try vault.revisions(secretId: a.id).first)
        let revisionB = try XCTUnwrap(try vault.revisions(secretId: b.id).first)
        let payloadB = try XCTUnwrap(try db.queryOne(
            "SELECT encrypted_payload FROM secret_revision WHERE id = ?", [revisionB.id]))
            .data("encrypted_payload")

        try db.run("UPDATE secret_revision SET encrypted_payload = ? WHERE id = ?",
                   [payloadB, revisionA.id])
        assertIntegrity(try vault.currentRows(secretId: a.id))
    }

    // MARK: - SEC-T28: 키가 없으면 새 키를 만들지 않는다

    func testMissingKeyKeepsVaultUnchanged() throws {
        let dir = try makeTempDir()
        let keyStore = InMemoryVaultKeyStore()

        let (db1, vault1) = try openVault(dir, keyStore: keyStore)
        XCTAssertEqual(vault1.keyStatus, .ready)
        let version = try XCTUnwrap(vault1.keyVersion)
        let meta = try vault1.create(title: "키없음", groupName: nil,
                                     rows: [SecretRowInput(key: "A", value: "1")])
        let revisionCount = try db1.query(
            "SELECT 1 AS x FROM secret_revision WHERE secret_id = ?", [meta.id]).count
        db1.close()

        let (db2, vault2) = try openVault(dir, keyStore: InMemoryVaultKeyStore())
        defer { db2.close() }
        XCTAssertEqual(vault2.keyStatus, .missing)
        XCTAssertEqual(vault2.keyVersion, version)

        assertVaultKeyMissing(try vault2.create(title: "새로", groupName: nil,
                                                rows: [SecretRowInput(key: "X", value: "1")]))
        // searchTitles는 키 없이 동작한다.
        XCTAssertTrue(try vault2.searchTitles("키없음").contains { $0.id == meta.id })
        // 기존 revision 행 수는 변하지 않는다.
        XCTAssertEqual(try db2.query(
            "SELECT 1 AS x FROM secret_revision WHERE secret_id = ?", [meta.id]).count, revisionCount)
    }

    func testMissingKeyCurrentRowsThrows() throws {
        let dir = try makeTempDir()
        let (db1, vault1) = try openVault(dir, keyStore: InMemoryVaultKeyStore())
        let meta = try vault1.create(title: "키없음2", groupName: nil,
                                     rows: [SecretRowInput(key: "A", value: "1")])
        db1.close()

        let (db2, vault2) = try openVault(dir, keyStore: InMemoryVaultKeyStore())
        defer { db2.close() }
        assertVaultKeyMissing(try vault2.currentRows(secretId: meta.id))
        assertVaultKeyMissing(try vault2.saveDraft(SecretPayload(items: [])))
    }

    // MARK: - SEC-T02: 기본 제목과 문자열 값

    func testDefaultTitleAndStringValues() throws {
        let dir = try makeTempDir()
        let (db, vault) = try openVault(dir, keyStore: InMemoryVaultKeyStore(), clock: fixedClock())
        defer { db.close() }

        let meta = try vault.create(title: "   ", groupName: nil, rows: [
            SecretRowInput(key: "PIN", value: "00123"),
            SecretRowInput(key: "ENABLED", value: "true"),
            SecretRowInput(key: "JSONISH", value: "{x:1}"),
        ])
        XCTAssertEqual(meta.title, "새 Secret 2026-10-01")

        let rows = try vault.currentRows(secretId: meta.id)
        XCTAssertEqual(rows.first { $0.key == "PIN" }?.value, "00123")
        XCTAssertEqual(rows.first { $0.key == "ENABLED" }?.value, "true")
        XCTAssertEqual(rows.first { $0.key == "JSONISH" }?.value, "{x:1}")
    }

    func testNilTitleGetsDefault() throws {
        let dir = try makeTempDir()
        let (db, vault) = try openVault(dir, keyStore: InMemoryVaultKeyStore(), clock: fixedClock())
        defer { db.close() }

        let meta = try vault.create(title: nil, groupName: nil,
                                    rows: [SecretRowInput(key: "A", value: "1")])
        XCTAssertEqual(meta.title, "새 Secret 2026-10-01")
    }

    // MARK: - SEC-T07: 중복 key는 저장하지 않는다

    func testDuplicateKeyRejectedAndNothingSaved() throws {
        let dir = try makeTempDir()
        let (db, vault) = try openVault(dir, keyStore: InMemoryVaultKeyStore())
        defer { db.close() }

        assertValidation(try vault.create(title: "중복", groupName: nil, rows: [
            SecretRowInput(key: "DUP", value: "1"),
            SecretRowInput(key: "  DUP  ", value: "2"),
        ]))
        XCTAssertEqual(try db.query("SELECT 1 AS x FROM secret_item").count, 0)
        XCTAssertEqual(try db.query("SELECT 1 AS x FROM secret_revision").count, 0)
    }

    func testDuplicateKeyOnSaveRejectedAndRevisionUnchanged() throws {
        let dir = try makeTempDir()
        let (db, vault) = try openVault(dir, keyStore: InMemoryVaultKeyStore())
        defer { db.close() }

        let meta = try vault.create(title: "중복저장", groupName: nil,
                                    rows: [SecretRowInput(key: "A", value: "1")])
        let rowId = try XCTUnwrap(try vault.currentRows(secretId: meta.id).first?.id)
        assertValidation(try vault.save(secretId: meta.id, changes: SecretChangeSet(upserts: [
            SecretRowInput(id: rowId, key: "A", value: "1"),
            SecretRowInput(key: "A", value: "2"),
        ])))
        XCTAssertEqual(try vault.revisions(secretId: meta.id).count, 1)
    }

    // MARK: - SEC-T29: 암호화 초안

    func testDraftRoundTripAndNoPlaintext() throws {
        let canaryKey = "DRAFT-KEY-3c9d"
        let canaryValue = "DRAFT-VALUE-8e21"
        let dir = try makeTempDir()

        let (db, vault) = try openVault(dir, keyStore: InMemoryVaultKeyStore())
        XCTAssertNil(try vault.loadDraft())

        let payload = SecretPayload(schemaVersion: 1, items: [
            SecretRow(id: "draft-row", key: canaryKey, value: canaryValue, order: 0)
        ])
        try vault.saveDraft(payload)
        XCTAssertEqual(try vault.loadDraft(), payload)

        db.close()
        XCTAssertFalse(fileBytesContainPlaintext(canaryKey, in: dir), "초안 key 평문이 DB 파일에 남음")
        XCTAssertFalse(fileBytesContainPlaintext(canaryValue, in: dir), "초안 value 평문이 DB 파일에 남음")
    }

    func testClearDraft() throws {
        let dir = try makeTempDir()
        let (db, vault) = try openVault(dir, keyStore: InMemoryVaultKeyStore())
        defer { db.close() }

        try vault.saveDraft(SecretPayload(items: [SecretRow(id: "r", key: "K", value: "V", order: 0)]))
        XCTAssertNotNil(try vault.loadDraft())
        try vault.clearDraft()
        XCTAssertNil(try vault.loadDraft())
    }

    // MARK: - 제목 검색(잠금 중) 이스케이프 · 정렬

    func testSearchTitlesEscapesLikeWildcards() throws {
        let dir = try makeTempDir()
        let (db, vault) = try openVault(dir, keyStore: InMemoryVaultKeyStore())
        defer { db.close() }

        let literal = try vault.create(title: "100%_완료", groupName: nil,
                                       rows: [SecretRowInput(key: "A", value: "1")])
        _ = try vault.create(title: "100X완료", groupName: nil,
                             rows: [SecretRowInput(key: "B", value: "2")])

        let byPercent = try vault.searchTitles("100%")
        XCTAssertEqual(byPercent.map { $0.id }, [literal.id])
        let byUnderscore = try vault.searchTitles("_완료")
        XCTAssertEqual(byUnderscore.map { $0.id }, [literal.id])
    }

    func testRenameUpdatesTitleAndGroup() throws {
        let dir = try makeTempDir()
        let (db, vault) = try openVault(dir, keyStore: InMemoryVaultKeyStore())
        defer { db.close() }

        let meta = try vault.create(title: "이전", groupName: nil,
                                    rows: [SecretRowInput(key: "A", value: "1")])
        try vault.rename(secretId: meta.id, title: "이후", groupName: "새그룹")
        let after = try XCTUnwrap(try vault.metadata(id: meta.id))
        XCTAssertEqual(after.title, "이후")
        XCTAssertEqual(after.groupName, "새그룹")
        // 내용은 그대로.
        XCTAssertEqual(try vault.currentRows(secretId: meta.id).first?.value, "1")
    }
}
