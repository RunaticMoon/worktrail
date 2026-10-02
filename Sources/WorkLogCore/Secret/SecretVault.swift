import Foundation

/// vault 키 상태. .missing이면 키가 필요한 연산은 거부한다.
public enum VaultKeyStatus: Equatable, Sendable { case ready, missing }

/// 저장 결과. 실제 변경이 없으면 새 revision을 만들지 않는다.
public enum SecretSaveOutcome: Equatable, Sendable { case unchanged, saved(version: Int) }

/// 이력 목록 항목(값 없음).
public struct SecretRevisionInfo: Hashable, Sendable {
    public var id: String
    public var version: Int
    public var createdAt: Date
}

/// 암호화된 Secret 보관함(vault.sqlite).
///
/// - 본문·이전 버전·초안은 모두 AES-GCM 암호문으로만 저장한다. 평문 파일을 만들지 않는다.
/// - title/group만 잠금 중 제목 검색을 위해 평문 메타데이터로 둔다.
/// - AI·네트워크 호출은 전혀 없다. print·로그로 값을 남기지 않는다.
///
/// 주의: 이 타입은 SQLite 연결을 직렬화된 큐로 감싼 SQLiteDatabase에 의존한다.
public final class SecretVault: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let keyStore: VaultKeyStore
    private let clock: Clock
    private let ids: IDGenerator
    private let calendar: WorkCalendar

    private let keyVersionValue: String?
    private let cachedKey: Data?

    private static let metaKeyVersion = "key_version"
    private static let draftId = "draft"
    /// Secret payload/AAD의 스키마 버전. 백업 시험 복호화 등에서 참조하므로 internal로 둔다.
    static let schemaVersion = 1
    /// 초안 AAD(단일 슬롯).
    private static let draftAAD = Data("worklog.secret.draft|v1".utf8)

    /// VaultSchema를 migrate하고 키 상태를 확정한다.
    /// 최초 설치(key_version 없음)면 새 키를 만들어 KeyStore에 저장하고 key_version을 기록한다.
    /// key_version이 있는데 KeyStore에 키가 없으면 .missing으로 두고 새 키를 만들지 않는다.
    public init(db: SQLiteDatabase, keyStore: VaultKeyStore, clock: Clock = SystemClock(),
                ids: IDGenerator = UUIDGenerator(), calendar: WorkCalendar = WorkCalendar()) throws {
        self.db = db
        self.keyStore = keyStore
        self.clock = clock
        self.ids = ids
        self.calendar = calendar

        try Migrator.migrate(db, migrations: VaultSchema.migrations)

        let storedVersion = try db.queryOne(
            "SELECT value FROM vault_meta WHERE key = ?", [Self.metaKeyVersion])?.string("value")

        if let storedVersion {
            self.keyVersionValue = storedVersion
            self.cachedKey = try keyStore.loadKey(id: storedVersion)
        } else {
            let key = VaultCrypto.generateKey()
            let version = ids.make()
            try keyStore.storeKey(key, id: version)
            _ = try db.transaction {
                try db.run("INSERT INTO vault_meta (key, value) VALUES (?, ?)",
                           [Self.metaKeyVersion, version])
            }
            self.keyVersionValue = version
            self.cachedKey = key
        }
    }

    public var keyStatus: VaultKeyStatus { cachedKey == nil ? .missing : .ready }
    public var keyVersion: String? { keyVersionValue }

    // MARK: - 생성 · 저장

    func create(title: String?, groupName: String?, rows: [SecretRowInput]) throws -> SecretMetadata {
        let key = try requireKey()

        let normalized = SecretNormalizer.apply(
            existing: [], changes: SecretChangeSet(upserts: rows), ids: ids)
        try throwIfIssues(normalized.issues, rows: normalized.rows)

        let now = clock.now()
        let resolvedTitle = resolveTitle(title, now: now)
        let secretId = ids.make()
        let revisionId = ids.make()
        let payload = SecretPayload(schemaVersion: Self.schemaVersion, items: normalized.rows)
        let encrypted = try encrypt(payload, key: key, secretId: secretId,
                                    revisionId: revisionId, version: 1)

        try db.transaction {
            let groupId = try resolveGroupId(groupName)
            try db.run("""
                INSERT INTO secret_item
                    (id, title, group_id, latest_revision_id, created_at, updated_at, deleted_at)
                VALUES (?, ?, ?, ?, ?, ?, NULL)
                """, [secretId, resolvedTitle, groupId, revisionId, now, now])
            try db.run("""
                INSERT INTO secret_revision
                    (id, secret_id, version, key_version, encrypted_payload, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, [revisionId, secretId, 1, keyVersionValue, encrypted, now])
        }

        guard let meta = try metadata(id: secretId) else {
            throw WorkLogError.storage("Secret 생성 후 조회 실패: \(secretId)")
        }
        return meta
    }

    func save(secretId: String, changes: SecretChangeSet) throws -> SecretSaveOutcome {
        let key = try requireKey()
        guard let meta = try metadata(id: secretId), meta.deletedAt == nil else {
            throw WorkLogError.notFound("Secret \(secretId)")
        }
        let current = try currentRows(secretId: secretId)

        let normalized = SecretNormalizer.apply(existing: current, changes: changes, ids: ids)
        try throwIfIssues(normalized.issues, rows: normalized.rows)
        guard normalized.changed else { return .unchanged }

        let version = meta.latestVersion + 1
        let revisionId = ids.make()
        let now = clock.now()
        let payload = SecretPayload(schemaVersion: Self.schemaVersion, items: normalized.rows)
        let encrypted = try encrypt(payload, key: key, secretId: secretId,
                                    revisionId: revisionId, version: version)

        try db.transaction {
            try db.run("""
                INSERT INTO secret_revision
                    (id, secret_id, version, key_version, encrypted_payload, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, [revisionId, secretId, version, keyVersionValue, encrypted, now])
            try db.run("""
                UPDATE secret_item SET latest_revision_id = ?, updated_at = ? WHERE id = ?
                """, [revisionId, now, secretId])
        }
        return .saved(version: version)
    }

    func rename(secretId: String, title: String, groupName: String?) throws {
        guard let meta = try metadata(id: secretId), meta.deletedAt == nil else {
            throw WorkLogError.notFound("Secret \(secretId)")
        }
        let trimmed = SecretNormalizer.trim(title)
        let resolved = trimmed.isEmpty ? meta.title : trimmed
        let now = clock.now()
        try db.transaction {
            let groupId = try resolveGroupId(groupName)
            try db.run("UPDATE secret_item SET title = ?, group_id = ?, updated_at = ? WHERE id = ?",
                       [resolved, groupId, now, secretId])
        }
    }

    // MARK: - 조회

    public func metadata(id: String) throws -> SecretMetadata? {
        try db.queryOne("""
            SELECT i.id, i.title, i.group_id, i.latest_revision_id, i.created_at, i.updated_at,
                   i.deleted_at,
                   g.name AS group_name,
                   (SELECT r.version FROM secret_revision r WHERE r.id = i.latest_revision_id)
                       AS latest_version
            FROM secret_item i
            LEFT JOIN secret_group g ON g.id = i.group_id
            WHERE i.id = ?
            """, [id]).map { try metadataRow($0) }
    }

    func currentRows(secretId: String) throws -> [SecretRow] {
        guard let meta = try metadata(id: secretId), let revisionId = meta.latestRevisionId else {
            return []
        }
        return try rows(secretId: secretId, revisionId: revisionId)
    }

    func revisions(secretId: String) throws -> [SecretRevisionInfo] {
        try db.query("""
            SELECT id, version, created_at FROM secret_revision
            WHERE secret_id = ? ORDER BY version ASC
            """, [secretId]).compactMap { row in
            guard let id = row.string("id"), let version = row.int("version"),
                  let createdAt = row.date("created_at") else { return nil }
            return SecretRevisionInfo(id: id, version: version, createdAt: createdAt)
        }
    }

    func rows(secretId: String, revisionId: String) throws -> [SecretRow] {
        let key = try requireKey()
        guard let row = try db.queryOne("""
            SELECT version, encrypted_payload FROM secret_revision
            WHERE id = ? AND secret_id = ?
            """, [revisionId, secretId]) else {
            throw WorkLogError.notFound("Secret revision \(revisionId)")
        }
        let version = row.int("version") ?? 0
        guard let encrypted = row.data("encrypted_payload") else {
            throw WorkLogError.integrity("Secret 암호문이 없습니다: \(revisionId)")
        }
        let aad = VaultCrypto.aad(secretId: secretId, revisionId: revisionId, version: version,
                                  schemaVersion: Self.schemaVersion)
        return try decrypt(encrypted, key: key, aad: aad).items
    }

    /// 이전 revision 내용을 새 최신 revision으로 추가한다(과거 이력 삭제 없음).
    func restoreRevision(secretId: String, revisionId: String) throws -> SecretSaveOutcome {
        let key = try requireKey()
        guard let meta = try metadata(id: secretId), meta.deletedAt == nil else {
            throw WorkLogError.notFound("Secret \(secretId)")
        }
        let target = try rows(secretId: secretId, revisionId: revisionId)
        let current = try currentRows(secretId: secretId)
        if rowsEqual(target, current) { return .unchanged }

        var restored = target
        for index in restored.indices { restored[index].order = index }

        let version = meta.latestVersion + 1
        let newRevisionId = ids.make()
        let now = clock.now()
        let payload = SecretPayload(schemaVersion: Self.schemaVersion, items: restored)
        let encrypted = try encrypt(payload, key: key, secretId: secretId,
                                    revisionId: newRevisionId, version: version)

        try db.transaction {
            try db.run("""
                INSERT INTO secret_revision
                    (id, secret_id, version, key_version, encrypted_payload, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, [newRevisionId, secretId, version, keyVersionValue, encrypted, now])
            try db.run("""
                UPDATE secret_item SET latest_revision_id = ?, updated_at = ? WHERE id = ?
                """, [newRevisionId, now, secretId])
        }
        return .saved(version: version)
    }

    /// 제목·그룹 이름 LIKE 검색. 키가 없어도 동작한다(잠금 중 제목 검색).
    public func searchTitles(_ query: String, includeDeleted: Bool = false,
                             limit: Int = 50) throws -> [SecretMetadata] {
        let pattern = Self.likePattern(query)
        var sql = """
            SELECT i.id, i.title, i.group_id, i.latest_revision_id, i.created_at, i.updated_at,
                   i.deleted_at,
                   g.name AS group_name,
                   (SELECT r.version FROM secret_revision r WHERE r.id = i.latest_revision_id)
                       AS latest_version
            FROM secret_item i
            LEFT JOIN secret_group g ON g.id = i.group_id
            WHERE (i.title LIKE ? ESCAPE '\\' OR g.name LIKE ? ESCAPE '\\')
            """
        var params: [SQLBindable] = [pattern, pattern]
        if !includeDeleted { sql += " AND i.deleted_at IS NULL" }
        sql += " ORDER BY i.updated_at DESC, i.id ASC LIMIT ?"
        params.append(limit)
        return try db.query(sql, params).map { try metadataRow($0) }
    }

    // MARK: - 휴지통

    func moveToTrash(secretId: String) throws {
        guard try metadata(id: secretId) != nil else {
            throw WorkLogError.notFound("Secret \(secretId)")
        }
        try db.run("UPDATE secret_item SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL",
                   [clock.now(), secretId])
    }

    func restoreFromTrash(secretId: String) throws {
        guard try metadata(id: secretId) != nil else {
            throw WorkLogError.notFound("Secret \(secretId)")
        }
        try db.run("UPDATE secret_item SET deleted_at = NULL WHERE id = ?", [secretId])
    }

    func trash() throws -> [SecretMetadata] {
        try db.query("""
            SELECT i.id, i.title, i.group_id, i.latest_revision_id, i.created_at, i.updated_at,
                   i.deleted_at,
                   g.name AS group_name,
                   (SELECT r.version FROM secret_revision r WHERE r.id = i.latest_revision_id)
                       AS latest_version
            FROM secret_item i
            LEFT JOIN secret_group g ON g.id = i.group_id
            WHERE i.deleted_at IS NOT NULL
            ORDER BY i.updated_at DESC, i.id ASC
            """).map { try metadataRow($0) }
    }

    /// 휴지통에 있는 항목만 현재 DB에서 영구 삭제한다(metadata + 모든 revision).
    func purge(secretId: String) throws {
        guard let meta = try metadata(id: secretId) else {
            throw WorkLogError.notFound("Secret \(secretId)")
        }
        guard meta.deletedAt != nil else {
            throw WorkLogError.validation("휴지통에 있는 Secret만 영구 삭제할 수 있습니다.")
        }
        try db.transaction {
            try db.run("DELETE FROM secret_revision WHERE secret_id = ?", [secretId])
            try db.run("DELETE FROM secret_item WHERE id = ?", [secretId])
        }
    }

    // MARK: - 초안

    func saveDraft(_ payload: SecretPayload) throws {
        let key = try requireKey()
        let encrypted = try encrypt(payload, key: key, aad: Self.draftAAD)
        try db.run("""
            INSERT OR REPLACE INTO secret_draft (id, key_version, encrypted_payload, updated_at)
            VALUES (?, ?, ?, ?)
            """, [Self.draftId, keyVersionValue, encrypted, clock.now()])
    }

    func loadDraft() throws -> SecretPayload? {
        let key = try requireKey()
        guard let row = try db.queryOne(
            "SELECT encrypted_payload FROM secret_draft WHERE id = ?", [Self.draftId]) else {
            return nil
        }
        guard let encrypted = row.data("encrypted_payload") else {
            throw WorkLogError.integrity("Secret 초안 암호문이 없습니다.")
        }
        return try decrypt(encrypted, key: key, aad: Self.draftAAD)
    }

    func clearDraft() throws {
        try db.run("DELETE FROM secret_draft WHERE id = ?", [Self.draftId])
    }

    // MARK: - 내부

    private func requireKey() throws -> Data {
        guard let key = cachedKey else { throw WorkLogError.vaultKeyMissing }
        return key
    }

    private func resolveTitle(_ title: String?, now: Date) -> String {
        let trimmed = SecretNormalizer.trim(title ?? "")
        if !trimmed.isEmpty { return trimmed }
        return "새 Secret \(calendar.workDate(of: now).iso)"
    }

    private func resolveGroupId(_ groupName: String?) throws -> String? {
        let trimmed = SecretNormalizer.trim(groupName ?? "")
        guard !trimmed.isEmpty else { return nil }
        if let row = try db.queryOne("SELECT id FROM secret_group WHERE name = ?", [trimmed]) {
            return row.string("id")
        }
        let groupId = ids.make()
        try db.run("INSERT INTO secret_group (id, name) VALUES (?, ?)", [groupId, trimmed])
        return groupId
    }

    /// 오류 메시지에 key·value를 넣지 않는다(key/value는 암호화 payload의 민감 정보).
    /// 중복 key는 행 위치(1부터 시작)로만 안내한다.
    private func throwIfIssues(_ issues: [SecretValidationIssue],
                               rows: [SecretRow]) throws {
        guard !issues.isEmpty else { return }
        let positions = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0 + 1) })
        let details = issues.map { issue -> String in
            switch issue {
            case .duplicateKey(_, let rowIds):
                let ordinals = rowIds.compactMap { positions[$0] }.map(String.init)
                    .joined(separator: ", ")
                return "중복된 항목 이름(행 \(ordinals))"
            case .unknownRowId:
                return "알 수 없는 행"
            }
        }
        throw WorkLogError.validation("Secret 저장 전 확인이 필요합니다: \(details.joined(separator: "; "))")
    }

    private func metadataRow(_ row: SQLRow) throws -> SecretMetadata {
        guard let id = row.string("id"), let title = row.string("title"),
              let createdAt = row.date("created_at"), let updatedAt = row.date("updated_at") else {
            throw WorkLogError.storage("Secret 메타데이터를 읽을 수 없습니다.")
        }
        return SecretMetadata(
            id: id, title: title,
            groupId: row.string("group_id"), groupName: row.string("group_name"),
            latestRevisionId: row.string("latest_revision_id"),
            latestVersion: row.int("latest_version") ?? 0,
            createdAt: createdAt, updatedAt: updatedAt, deletedAt: row.date("deleted_at"))
    }

    private func rowsEqual(_ a: [SecretRow], _ b: [SecretRow]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) where x.id != y.id || x.key != y.key || x.value != y.value {
            return false
        }
        return true
    }

    private func encode(_ payload: SecretPayload) throws -> Data {
        do {
            return try StableJSON.encode(payload)
        } catch {
            throw WorkLogError.storage("Secret 본문 직렬화 실패")
        }
    }

    private func encrypt(_ payload: SecretPayload, key: Data, aad: Data) throws -> Data {
        try VaultCrypto.seal(try encode(payload), key: key, aad: aad)
    }

    private func encrypt(_ payload: SecretPayload, key: Data, secretId: String,
                         revisionId: String, version: Int) throws -> Data {
        let aad = VaultCrypto.aad(secretId: secretId, revisionId: revisionId, version: version,
                                  schemaVersion: Self.schemaVersion)
        return try encrypt(payload, key: key, aad: aad)
    }

    private func decrypt(_ encrypted: Data, key: Data, aad: Data) throws -> SecretPayload {
        let plaintext = try VaultCrypto.open(encrypted, key: key, aad: aad)
        do {
            return try StableJSON.decode(SecretPayload.self, from: plaintext)
        } catch {
            throw WorkLogError.integrity("Secret 본문 형식이 올바르지 않습니다.")
        }
    }

    /// LIKE 패턴의 %, _, \ 를 이스케이프하고 앞뒤로 %를 붙인다.
    private static func likePattern(_ query: String) -> String {
        var escaped = ""
        for ch in query {
            if ch == "\\" || ch == "%" || ch == "_" { escaped.append("\\") }
            escaped.append(ch)
        }
        return "%\(escaped)%"
    }
}
