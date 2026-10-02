import Foundation

/// 일반 기록 간 수동 관련 연결(`record_link`, v4)의 저장소.
///
/// - 무방향 링크를 `RecordReference.canonicalPair`의 정규 순서로 저장한다.
///   SQL의 `CHECK (from_kind < to_kind OR (from_kind = to_kind AND from_id < to_id))`와
///   같은 UTF-8/BINARY 순서다.
/// - 다형 참조라 FK 하나로 대상을 검증할 수 없다. `add`에서 같은 트랜잭션 안에
///   종류별 고정 SQL로 양쪽 대상의 존재·미삭제를 검사한다.
/// - Secret(Vault)은 후보·참조 종류·SQL에 존재하지 않는다. work.sqlite의 일반 테이블만 읽는다.
/// - 모든 SQL은 값 바인딩(`?`)을 사용하고, kind는 enum switch로 고정 문자열을 고른다.
public final class RecordLinkStore {
    private let repo: WorkRepository
    private let clock: Clock
    private let ids: IDGenerator

    public init(repo: WorkRepository, clock: Clock, ids: IDGenerator) {
        self.repo = repo
        self.clock = clock
        self.ids = ids
    }

    /// 저장소에 주입된 Clock/IDGenerator를 그대로 사용하는 편의 초기화.
    public convenience init(repo: WorkRepository) {
        self.init(repo: repo, clock: repo.clock, ids: repo.ids)
    }

    // MARK: - 추가·삭제

    /// 두 기록을 정규 순서로 저장한다.
    ///
    /// - 자기 연결은 `WorkLogError.validation`.
    /// - 양쪽 대상이 존재하지 않거나 소프트 삭제됐으면 `WorkLogError.validation`.
    /// - 같은 링크가 이미 있으면 새로 만들지 않고 기존 링크를 반환한다(idempotent).
    @discardableResult
    public func add(between first: RecordReference, and second: RecordReference) throws -> RecordLink {
        guard let (a, b) = RecordReference.canonicalPair(first, second) else {
            throw WorkLogError.validation("자기 자신은 연결할 수 없습니다: \(first.kind.rawValue) \(first.id)")
        }
        return try repo.db.transaction {
            try requireTarget(a)
            try requireTarget(b)

            if let existing = try fetchLink(from: a, to: b) {
                return existing
            }

            let link = RecordLink(id: ids.make(), first: a, second: b,
                                  relationType: "related", createdAt: clock.now())
            try repo.db.run("""
                INSERT INTO record_link
                    (id, from_kind, from_id, to_kind, to_id, relation_type, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, [link.id, a.kind.rawValue, a.id, b.kind.rawValue, b.id,
                      link.relationType, link.createdAt])
            return link
        }
    }

    /// 한 원본에서 여러 대상으로 링크를 저장한다. 트랜잭션 하나이며 하나라도 실패하면 전체 롤백한다.
    @discardableResult
    public func add(from source: RecordReference, to targets: [RecordReference]) throws -> [RecordLink] {
        try repo.db.transaction {
            var result: [RecordLink] = []
            for target in targets {
                result.append(try add(between: source, and: target))
            }
            return result
        }
    }

    /// 정규 순서쌍의 링크를 지운다. 없는 링크·자기 연결은 아무 것도 하지 않는다.
    public func remove(between first: RecordReference, and second: RecordReference) throws {
        guard let (a, b) = RecordReference.canonicalPair(first, second) else { return }
        try repo.db.transaction {
            try repo.db.run("""
                DELETE FROM record_link
                WHERE from_kind = ? AND from_id = ? AND to_kind = ? AND to_id = ?
                  AND relation_type = 'related'
                """, [a.kind.rawValue, a.id, b.kind.rawValue, b.id])
        }
    }

    // MARK: - 조회

    /// 주어진 기록에 연결된 링크를 양방향으로 조회한다. id 오름차순.
    public func links(for record: RecordReference) throws -> [RecordLink] {
        let rows = try repo.db.query("""
            SELECT id, from_kind, from_id, to_kind, to_id, relation_type, created_at
            FROM record_link
            WHERE (from_kind = ? AND from_id = ?) OR (to_kind = ? AND to_id = ?)
            ORDER BY id ASC
            """, [record.kind.rawValue, record.id, record.kind.rawValue, record.id])
        return try rows.map { try Self.link(from: $0) }
    }

    /// 그래프용 전체 링크. id 오름차순.
    public func allLinks() throws -> [RecordLink] {
        let rows = try repo.db.query("""
            SELECT id, from_kind, from_id, to_kind, to_id, relation_type, created_at
            FROM record_link
            ORDER BY id ASC
            """)
        return try rows.map { try Self.link(from: $0) }
    }

    // MARK: - 후보 조회

    /// 수동 연결 후보를 종류별로 모아 최근 순으로 반환한다.
    ///
    /// - `query`가 비면 최근 항목(업무일/수정일 내림차순)을 종류 혼합으로 반환한다.
    /// - 값이 있으면 제목/본문 `LIKE`(이스케이프된 `?` 바인딩)로 거른다.
    /// - `excluding`의 참조는 제외하고 `limit`을 적용한다. 정렬은 결정적이다.
    public func candidates(query: String, excluding: Set<RecordReference>,
                           limit: Int) throws -> [RelatedRecordCandidate] {
        let capped = max(0, limit)
        guard capped > 0 else { return [] }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var entries: [CandidateEntry] = []
        entries += try memoEntries(query: trimmed, limit: capped)
        entries += try taskEntries(query: trimmed, limit: capped)
        entries += try activityEntries(query: trimmed, limit: capped)
        entries += try reportVersionEntries(query: trimmed, limit: capped)

        return entries
            .filter { !excluding.contains($0.reference) }
            .sorted(by: Self.precedes)
            .prefix(capped)
            .map { RelatedRecordCandidate(reference: $0.reference, title: $0.title,
                                          subtitle: $0.subtitle) }
    }

    // MARK: - 대상 검증

    /// 종류별 고정 SQL로 대상이 존재하고 삭제되지 않았는지 검사한다.
    /// kind는 enum이므로 SQL 문자열에 사용자 입력이 섞이지 않는다. id는 바인딩한다.
    private func requireTarget(_ ref: RecordReference) throws {
        let sql: String
        switch ref.kind {
        case .memo:
            sql = "SELECT 1 AS found FROM memo WHERE id = ? AND deleted_at IS NULL"
        case .task:
            sql = "SELECT 1 AS found FROM task WHERE id = ? AND deleted_at IS NULL"
        case .activity:
            sql = "SELECT 1 AS found FROM activity WHERE id = ? AND deleted_at IS NULL"
        case .reportVersion:
            sql = "SELECT 1 AS found FROM report_version WHERE id = ?"
        }
        guard try repo.db.queryOne(sql, [ref.id]) != nil else {
            throw WorkLogError.validation("연결 대상 기록을 찾을 수 없습니다: \(ref.kind.rawValue) \(ref.id)")
        }
    }

    // MARK: - 링크 조회 헬퍼

    private func fetchLink(from a: RecordReference, to b: RecordReference) throws -> RecordLink? {
        let row = try repo.db.queryOne("""
            SELECT id, from_kind, from_id, to_kind, to_id, relation_type, created_at
            FROM record_link
            WHERE from_kind = ? AND from_id = ? AND to_kind = ? AND to_id = ?
              AND relation_type = 'related'
            """, [a.kind.rawValue, a.id, b.kind.rawValue, b.id])
        return try row.map { try Self.link(from: $0) }
    }

    private static func link(from row: SQLRow) throws -> RecordLink {
        guard let id = row.string("id"),
              let fromRaw = row.string("from_kind"),
              let fromKind = RecordReferenceKind(rawValue: fromRaw),
              let fromId = row.string("from_id"),
              let toRaw = row.string("to_kind"),
              let toKind = RecordReferenceKind(rawValue: toRaw),
              let toId = row.string("to_id"),
              let relationType = row.string("relation_type"),
              let createdAt = row.date("created_at") else {
            throw WorkLogError.storage("record_link row 손상")
        }
        return RecordLink(id: id,
                          first: RecordReference(kind: fromKind, id: fromId),
                          second: RecordReference(kind: toKind, id: toId),
                          relationType: relationType,
                          createdAt: createdAt)
    }

    // MARK: - 후보 종류별 조회

    private func memoEntries(query: String, limit: Int) throws -> [CandidateEntry] {
        let rows: [SQLRow]
        if query.isEmpty {
            rows = try repo.db.query("""
                SELECT id, body, work_date FROM memo
                WHERE deleted_at IS NULL
                ORDER BY work_date DESC, id ASC
                LIMIT ?
                """, [limit])
        } else {
            rows = try repo.db.query("""
                SELECT id, body, work_date FROM memo
                WHERE deleted_at IS NULL AND body LIKE ? ESCAPE '\\'
                ORDER BY work_date DESC, id ASC
                LIMIT ?
                """, [Self.likePattern(query), limit])
        }
        return rows.compactMap { row in
            guard let id = row.string("id"), let body = row.string("body"),
                  let date = row.workDate("work_date") else { return nil }
            return CandidateEntry(reference: RecordReference(kind: .memo, id: id),
                                  title: Self.firstLine(body),
                                  subtitle: "메모 \(date.iso)",
                                  sortDate: repo.calendar.startOfDay(date))
        }
    }

    private func activityEntries(query: String, limit: Int) throws -> [CandidateEntry] {
        let rows: [SQLRow]
        if query.isEmpty {
            rows = try repo.db.query("""
                SELECT id, body, work_date FROM activity
                WHERE deleted_at IS NULL
                ORDER BY work_date DESC, id ASC
                LIMIT ?
                """, [limit])
        } else {
            rows = try repo.db.query("""
                SELECT id, body, work_date FROM activity
                WHERE deleted_at IS NULL AND body LIKE ? ESCAPE '\\'
                ORDER BY work_date DESC, id ASC
                LIMIT ?
                """, [Self.likePattern(query), limit])
        }
        return rows.compactMap { row in
            guard let id = row.string("id"), let body = row.string("body"),
                  let date = row.workDate("work_date") else { return nil }
            return CandidateEntry(reference: RecordReference(kind: .activity, id: id),
                                  title: Self.firstLine(body),
                                  subtitle: "진행기록 \(date.iso)",
                                  sortDate: repo.calendar.startOfDay(date))
        }
    }

    private func taskEntries(query: String, limit: Int) throws -> [CandidateEntry] {
        let rows: [SQLRow]
        if query.isEmpty {
            rows = try repo.db.query("""
                SELECT id, title, created_at FROM task
                WHERE deleted_at IS NULL
                ORDER BY created_at DESC, id ASC
                LIMIT ?
                """, [limit])
        } else {
            rows = try repo.db.query("""
                SELECT id, title, created_at FROM task
                WHERE deleted_at IS NULL AND title LIKE ? ESCAPE '\\'
                ORDER BY created_at DESC, id ASC
                LIMIT ?
                """, [Self.likePattern(query), limit])
        }
        return rows.compactMap { row in
            guard let id = row.string("id"), let title = row.string("title"),
                  let createdAt = row.date("created_at") else { return nil }
            let date = repo.calendar.workDate(of: createdAt)
            return CandidateEntry(reference: RecordReference(kind: .task, id: id),
                                  title: title,
                                  subtitle: "업무 \(date.iso)",
                                  sortDate: createdAt)
        }
    }

    private func reportVersionEntries(query: String, limit: Int) throws -> [CandidateEntry] {
        let rows: [SQLRow]
        if query.isEmpty {
            rows = try repo.db.query("""
                SELECT rv.id AS id, rv.version AS version, rv.created_at AS created_at,
                       r.family AS family, r.start AS start, r.end_exclusive AS end_exclusive
                FROM report_version rv JOIN report r ON r.id = rv.report_id
                ORDER BY rv.created_at DESC, rv.id ASC
                LIMIT ?
                """, [limit])
        } else {
            rows = try repo.db.query("""
                SELECT rv.id AS id, rv.version AS version, rv.created_at AS created_at,
                       r.family AS family, r.start AS start, r.end_exclusive AS end_exclusive
                FROM report_version rv JOIN report r ON r.id = rv.report_id
                WHERE rv.content LIKE ? ESCAPE '\\'
                ORDER BY rv.created_at DESC, rv.id ASC
                LIMIT ?
                """, [Self.likePattern(query), limit])
        }
        return rows.compactMap { row in
            guard let id = row.string("id"), let version = row.int("version"),
                  let createdAt = row.date("created_at"),
                  let familyRaw = row.string("family"),
                  let family = ReportFamily(rawValue: familyRaw),
                  let start = row.workDate("start"),
                  let endExclusive = row.workDate("end_exclusive") else { return nil }
            let endInclusive = repo.calendar.adding(days: -1, to: endExclusive)
            return CandidateEntry(reference: RecordReference(kind: .reportVersion, id: id),
                                  title: "\(Self.familyDisplayName(family)) \(start.iso)~\(endInclusive.iso) v\(version)",
                                  subtitle: "리포트 \(start.iso)",
                                  sortDate: createdAt)
        }
    }

    // MARK: - 정렬·문자열 헬퍼

    /// (업무일/수정일 내림차순, kind, id) 순. 입력 순서와 무관하게 결정적이다.
    private static func precedes(_ a: CandidateEntry, _ b: CandidateEntry) -> Bool {
        if a.sortDate != b.sortDate { return a.sortDate > b.sortDate }
        if a.reference.kind.rawValue != b.reference.kind.rawValue {
            return a.reference.kind.rawValue < b.reference.kind.rawValue
        }
        return a.reference.id < b.reference.id
    }

    /// LIKE 패턴용 이스케이프. `%`, `_`, `\`를 리터럴로 취급한다.
    private static func likePattern(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    private static func familyDisplayName(_ family: ReportFamily) -> String {
        switch family {
        case .submission: return "제출용 주간보고"
        case .performance: return "상세 성과 리포트"
        }
    }

    /// 본문 첫 번째 비어 있지 않은 줄의 앞 `maxLength`자. 없으면 빈 문자열.
    private static func firstLine(_ body: String, maxLength: Int = 40) -> String {
        let line = body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return line.count > maxLength ? String(line.prefix(maxLength)) : line
    }

    private struct CandidateEntry {
        let reference: RecordReference
        let title: String
        let subtitle: String?
        let sortDate: Date
    }
}
