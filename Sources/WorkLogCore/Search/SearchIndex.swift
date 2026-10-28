import Foundation

/// 원문 검색 문서의 출처 유형. search_doc.source_type 값과 1:1 대응한다.
public enum SearchSourceType: String, Codable, Sendable, CaseIterable {
    case memo
    case task
    case activity
    case report
    case github
    case jira

    /// 출처별 검색 유형은 나누되 기존 원문·근거 식별자는 유지한다.
    public var canonicalSourceType: SearchSourceType {
        switch self { case .github, .jira: return .memo; default: return self }
    }

    public var recordReferenceKind: RecordReferenceKind {
        switch self {
        case .memo, .github, .jira: return .memo
        case .task: return .task
        case .activity: return .activity
        case .report: return .reportVersion
        }
    }
}

/// 원문 검색 질의. text는 원문 부분 문자열(공백 분리 AND), 나머지는 구조화 필터다.
public struct SearchQuery: Sendable {
    public var text: String
    /// nil = 전체 유형
    public var types: Set<SearchSourceType>?
    /// 하나라도 연결되면 통과
    public var projectIds: [String]
    /// 하나라도 연결되면 통과
    public var tagIds: [String]
    /// work_date 기준 [start, endExclusive)
    public var range: DateRange?
    public var limit: Int

    public init(text: String, types: Set<SearchSourceType>? = nil, projectIds: [String] = [],
                tagIds: [String] = [], range: DateRange? = nil, limit: Int = 50) {
        self.text = text
        self.types = types
        self.projectIds = projectIds
        self.tagIds = tagIds
        self.range = range
        self.limit = limit
    }
}

/// 검색 결과 한 건. snippet은 첫 일치 위치 주변 최대 120자다.
/// projectNames는 이 원문에 연결된 프로젝트 이름(이름 오름차순, 중복 없음)이다.
public struct SearchHit: Hashable, Sendable {
    public var sourceType: SearchSourceType
    public var sourceId: String
    public var taskId: String?
    public var workDate: WorkDate?
    public var snippet: String
    public var projectNames: [String]

    public init(sourceType: SearchSourceType, sourceId: String, taskId: String?,
                workDate: WorkDate?, snippet: String, projectNames: [String] = []) {
        self.sourceType = sourceType
        self.sourceId = sourceId
        self.taskId = taskId
        self.workDate = workDate
        self.snippet = snippet
        self.projectNames = projectNames
    }
}

/// 검색 결과 항목을 가리키는 안정 키. 결과가 갱신돼도 같은 항목인지 판단한다.
public struct SearchHitKey: Hashable, Sendable {
    public let sourceType: SearchSourceType
    public let sourceId: String

    public init(sourceType: SearchSourceType, sourceId: String) {
        self.sourceType = sourceType
        self.sourceId = sourceId
    }
}

public extension SearchHit {
    var key: SearchHitKey { SearchHitKey(sourceType: sourceType, sourceId: sourceId) }
    var recordReference: RecordReference { RecordReference(kind: sourceType.recordReferenceKind, id: sourceId) }
}

/// 일반 기록(Memo·Task·Activity·Report 본문)의 로컬 원문 검색 인덱스.
///
/// - Secret(vault)은 이 코드에서 참조하지 않는다. 네트워크·AI 호출도 하지 않는다.
/// - 원본 변화는 `WorkRepository.onSourceChanged`에 연결해 저장 직후 반영한다.
/// - FTS5 trigram을 쓸 수 있으면 search_fts를 함께 유지하고, 아니면 LIKE 경로만 쓴다.
public final class SearchIndex: @unchecked Sendable {
    public func allowsExternalAI(sourceType: SearchSourceType, sourceID: String) throws -> Bool {
        try TaskDisclosurePolicy(repo: repo).allows(sourceType, sourceID: sourceID)
    }

    private let repo: WorkRepository
    private let db: SQLiteDatabase

    /// 이 SQLite 빌드가 FTS5 trigram을 지원해 search_fts를 유지하는지.
    public let usesTrigram: Bool

    /// - Note: 기존 `onSourceChanged` 핸들러가 있으면 체인으로 함께 호출한다.
    public init(repo: WorkRepository) throws {
        self.repo = repo
        self.db = repo.db
        let trigram = repo.db.supportsFTS5Trigram()
        self.usesTrigram = trigram
        if trigram {
            try repo.db.execute("""
                CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(
                    text, source_type UNINDEXED, source_id UNINDEXED, tokenize='trigram'
                )
                """)
        }
        _ = try repairImportedActivityDocs()
        let previous = repo.onSourceChanged
        repo.onSourceChanged = { [weak self] sourceType, id in
            previous?(sourceType, id)
            try? self?.reindex(sourceType: sourceType, id: id)
        }
    }

    // MARK: - 색인 갱신

    /// 원본을 저장소에서 다시 읽어 search_doc(+search_fts)을 갱신한다.
    /// soft delete·없음·미지원 유형이면 인덱스에서 제거한다.
    public func reindex(sourceType: String, id: String) throws {
        guard let type = SearchSourceType(rawValue: sourceType) else {
            // report는 report_version id로 색인한다. 알 수 없는 유형은 무시한다.
            return
        }
        switch type {
        case .memo, .github, .jira: try reindexMemo(id)
        case .task: try reindexTask(id)
        case .activity: try reindexActivity(id)
        case .report: try reindexReport(id)
        }
    }

    /// 전체 원문을 처음부터 다시 색인한다. search_doc·search_fts를 비우고 다시 채운다.
    public func rebuildAll() throws {
        try db.transaction {
            try db.runV("DELETE FROM search_doc")
            if usesTrigram { try db.runV("DELETE FROM search_fts") }

            for row in try db.queryV("SELECT id FROM memo WHERE deleted_at IS NULL ORDER BY id ASC") {
                if let id = row.string("id") { try reindexMemo(id) }
            }
            for row in try db.queryV("SELECT id FROM task WHERE deleted_at IS NULL ORDER BY id ASC") {
                if let id = row.string("id") { try reindexTask(id) }
            }
            for row in try db.queryV("SELECT id FROM activity WHERE deleted_at IS NULL ORDER BY id ASC") {
                if let id = row.string("id") { try reindexActivity(id) }
            }
            for row in try db.queryV("""
                SELECT rv.id AS id, rv.content AS content, r.start AS start
                FROM report_version rv JOIN report r ON r.id = rv.report_id
                ORDER BY rv.id ASC
                """) {
                guard let id = row.string("id") else { continue }
                try upsertDoc(sourceType: .report, sourceId: id, taskId: nil,
                              workDate: row.workDate("start"), text: row.string("content") ?? "")
            }
        }
    }

    /// 오래된 task 문서만 복구한다. 색인이 최신인 문서에는 쓰기를 하지 않는다.
    ///
    /// 이전 버전에서 제목만 색인된 업무 문서를 복구하는 것이 목적이다. 삭제되지 않은 모든 task의
    /// 기대 텍스트·workDate를 `reindexTask`와 같은 규칙으로 계산해 현재 search_doc과 비교하고,
    /// 없거나 다를 때만 upsert한다. 원본이 없는(삭제된) task의 남은 문서는 제거한다.
    /// - Returns: 실제로 갱신·삭제한 문서 수. 0이면 DB에 쓰기가 없었다.
    public func repairStaleTaskDocs() throws -> Int {
        // 비교는 트랜잭션 밖 읽기로 끝내고, 실제로 바뀐 문서만 한 트랜잭션에서 쓴다.
        var updates: [(id: String, workDate: WorkDate?, text: String)] = []
        for task in try repo.tasks() {  // deleted_at IS NULL만 반환
            let doc = try taskDoc(task)
            if let row = try db.queryOneV("""
                SELECT text AS text, work_date AS work_date FROM search_doc
                WHERE source_type = ? AND source_id = ?
                """, SearchSourceType.task.rawValue, task.id),
               row.string("text") == doc.text,
               row.workDate("work_date") == doc.workDate {
                continue
            }
            updates.append((task.id, doc.workDate, doc.text))
        }
        var removals: [String] = []
        for row in try db.queryV("""
            SELECT source_id AS source_id FROM search_doc
            WHERE source_type = ? AND source_id NOT IN (
                SELECT id FROM task WHERE deleted_at IS NULL
            )
            """, SearchSourceType.task.rawValue) {
            if let id = row.string("source_id") { removals.append(id) }
        }
        if updates.isEmpty && removals.isEmpty { return 0 }

        try db.transaction {
            for update in updates {
                try upsertDoc(sourceType: .task, sourceId: update.id, taskId: nil,
                              workDate: update.workDate, text: update.text)
            }
            for id in removals { try removeDoc(sourceType: .task, sourceId: id) }
        }
        return updates.count + removals.count
    }

    /// 기존 수집 메모 색인을 출처별로 복구한다. 본문 접두사가 아닌 imported_activity 매핑만 사용한다.
    /// 최신 문서는 그대로 두고, 오래된 memo/다른 출처 문서와 FTS 사본도 함께 정리한다.
    @discardableResult
    public func repairImportedActivityDocs() throws -> Int {
        let candidates = try db.queryV("""
            SELECT memo_id AS id FROM imported_activity
            UNION SELECT source_id AS id FROM search_doc WHERE source_type IN (?, ?)
            ORDER BY id
            """, SearchSourceType.github.rawValue, SearchSourceType.jira.rawValue)
        var updates: [String] = []
        for candidate in candidates {
            guard let id = candidate.string("id") else { continue }
            let rows = try db.queryV("""
                SELECT rowid, source_type, text, work_date FROM search_doc
                WHERE source_id = ? AND source_type IN (?, ?, ?)
                """, id, SearchSourceType.memo.rawValue, SearchSourceType.github.rawValue, SearchSourceType.jira.rawValue)
            guard let memo = try repo.memo(id: id) else {
                if !rows.isEmpty { updates.append(id) }
                continue
            }
            let type = try memoSourceType(id)
            let text = try memoText(memo)
            if rows.count == 1, let row = rows.first, row.string("source_type") == type.rawValue,
               row.string("text") == text, row.workDate("work_date") == memo.workDate {
                if !usesTrigram { continue }
                if let rowID = row.int("rowid"), let fts = try db.queryOneV(
                    "SELECT source_type, source_id, text FROM search_fts WHERE rowid = ?", rowID),
                   fts.string("source_type") == type.rawValue, fts.string("source_id") == id,
                   fts.string("text") == text { continue }
            }
            updates.append(id)
        }
        if updates.isEmpty { return 0 }
        try db.transaction { for id in updates { try reindexMemo(id) } }
        return updates.count
    }

    /// 상세 리포트 본문(및 같은 방식의 제출용 리포트) 색인. 리포트 버전 생성 시 호출한다.
    public func indexReport(versionId: String, text: String, workDate: WorkDate?) throws {
        let date: WorkDate?
        if let workDate { date = workDate } else { date = try reportStart(versionId) }
        try upsertDoc(sourceType: .report, sourceId: versionId, taskId: nil, workDate: date, text: text)
    }

    public func removeReport(versionId: String) throws {
        try removeDoc(sourceType: .report, sourceId: versionId)
    }

    // MARK: - 유형별 색인

    private func reindexMemo(_ id: String) throws {
        try db.transaction {
            let memo = try repo.memo(id: id)  // deleted_at IS NULL만 반환
            let type = try memoSourceType(id)
            for previousType in [SearchSourceType.memo, .github, .jira]
                where memo == nil || previousType != type {
                try removeDoc(sourceType: previousType, sourceId: id)
            }
            guard let memo else { return }
            try upsertDoc(sourceType: type, sourceId: id, taskId: nil,
                          workDate: memo.workDate, text: memoText(memo))
        }
    }

    private func memoSourceType(_ id: String) throws -> SearchSourceType {
        let source = try db.queryOneV("""
            SELECT source FROM imported_activity WHERE memo_id = ?
            ORDER BY connection_key, external_id LIMIT 1
            """, id)?.string("source")
        switch source {
        case "github": return .github
        case "jira": return .jira
        default: return .memo
        }
    }

    private func memoText(_ memo: Memo) throws -> String {
        var parts = [memo.body]
        parts.append(contentsOf: try memoProjectNames(memo.id))
        parts.append(contentsOf: try memoTagNames(memo.id))
        return joined(parts)
    }

    private func reindexTask(_ id: String) throws {
        guard let task = try repo.task(id: id) else {
            try removeDoc(sourceType: .task, sourceId: id)
            return
        }
        let doc = try taskDoc(task)
        try upsertDoc(sourceType: .task, sourceId: id, taskId: nil,
                      workDate: doc.workDate, text: doc.text)
    }

    /// task 원문의 기대 색인 텍스트·workDate. reindexTask와 repairStaleTaskDocs가 같은 규칙을 쓴다.
    private func taskDoc(_ task: WorkTask) throws -> (text: String, workDate: WorkDate?) {
        var parts = [task.title]
        parts.append(contentsOf: try repo.checklistItems(taskId: task.id).map { $0.text })
        parts.append(contentsOf: try taskProjectNames(task.id))
        parts.append(contentsOf: try taskTagNames(task.id))
        return (joined(parts), repo.calendar.workDate(of: task.createdAt))
    }

    private func reindexActivity(_ id: String) throws {
        guard let activity = try repo.activity(id: id), activity.deletedAt == nil else {
            try removeDoc(sourceType: .activity, sourceId: id)
            return
        }
        var parts = [activity.body]
        parts.append(contentsOf: try activityProjectNames(id))
        try upsertDoc(sourceType: .activity, sourceId: id, taskId: activity.taskId,
                      workDate: activity.workDate, text: joined(parts))
    }

    private func reindexReport(_ id: String) throws {
        guard let row = try db.queryOneV("""
            SELECT rv.content AS content, r.start AS start
            FROM report_version rv JOIN report r ON r.id = rv.report_id
            WHERE rv.id = ?
            """, id) else {
            try removeDoc(sourceType: .report, sourceId: id)
            return
        }
        try upsertDoc(sourceType: .report, sourceId: id, taskId: nil,
                      workDate: row.workDate("start"), text: row.string("content") ?? "")
    }

    // MARK: - search_doc / search_fts 유지

    /// search_doc을 upsert하고, search_fts에는 search_doc의 rowid로 맞춰 넣는다.
    /// (rowid를 공유하면 갱신·삭제가 전체 스캔 없이 동작한다.)
    private func upsertDoc(sourceType: SearchSourceType, sourceId: String, taskId: String?,
                           workDate: WorkDate?, text: String) throws {
        try db.transaction {
            if usesTrigram {
                try db.runV("""
                    DELETE FROM search_fts WHERE rowid IN (
                        SELECT rowid FROM search_doc WHERE source_type = ? AND source_id = ?
                    )
                    """, sourceType.rawValue, sourceId)
            }
            try db.runV("""
                INSERT OR REPLACE INTO search_doc (source_type, source_id, task_id, work_date, text)
                VALUES (?, ?, ?, ?, ?)
                """, sourceType.rawValue, sourceId, taskId, workDate, text)
            if usesTrigram {
                let rowid = try db.scalarIntV("""
                    SELECT rowid FROM search_doc WHERE source_type = ? AND source_id = ?
                    """, sourceType.rawValue, sourceId)
                try db.runV("""
                    INSERT INTO search_fts (rowid, text, source_type, source_id) VALUES (?, ?, ?, ?)
                    """, rowid, text, sourceType.rawValue, sourceId)
            }
        }
    }

    private func removeDoc(sourceType: SearchSourceType, sourceId: String) throws {
        // search_fts의 rowid를 search_doc에서 먼저 찾아 지운 뒤 doc 행을 지운다.
        if usesTrigram {
            try db.runV("""
                DELETE FROM search_fts WHERE rowid IN (
                    SELECT rowid FROM search_doc WHERE source_type = ? AND source_id = ?
                )
                """, sourceType.rawValue, sourceId)
        }
        try db.runV("DELETE FROM search_doc WHERE source_type = ? AND source_id = ?",
                    sourceType.rawValue, sourceId)
    }

    private func reportStart(_ versionId: String) throws -> WorkDate? {
        try db.queryOneV("""
            SELECT r.start AS start
            FROM report_version rv JOIN report r ON r.id = rv.report_id
            WHERE rv.id = ?
            """, versionId)?.workDate("start")
    }

    // MARK: - 검색

    public func search(_ query: SearchQuery) throws -> [SearchHit] {
        let trimmed = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let limit = max(0, query.limit)
        if limit == 0 { return [] }

        var params: [SQLBindable] = []
        var filters: [String] = []

        // 모든 term이 3글자(Character) 이상일 때만 trigram MATCH를 쓴다.
        let useFTS = usesTrigram && !terms.isEmpty && terms.allSatisfy { $0.count >= 3 }

        var sql: String
        if useFTS {
            sql = """
                SELECT d.source_type AS source_type, d.source_id AS source_id,
                       d.task_id AS task_id, d.work_date AS work_date, d.text AS text
                FROM search_doc d
                JOIN search_fts f ON f.rowid = d.rowid
                WHERE f.search_fts MATCH ?
                """
            params.append(ftsMatch(terms))
        } else {
            sql = """
                SELECT d.source_type AS source_type, d.source_id AS source_id,
                       d.task_id AS task_id, d.work_date AS work_date, d.text AS text
                FROM search_doc d
                WHERE 1 = 1
                """
            for term in terms {
                filters.append("d.text LIKE ? ESCAPE '\\'")
                params.append("%\(escapeLike(term))%")
            }
        }

        // 매핑 직후 재색인에 실패했어도 수집 자료를 일반 메모로 노출하지 않는다.
        filters.append("""
            NOT (d.source_type = 'memo' AND EXISTS (
                SELECT 1 FROM imported_activity imported WHERE imported.memo_id = d.source_id))
            """)
        if let types = query.types {
            if types.isEmpty { return [] }
            let ordered = types.map(\.rawValue).sorted()
            let placeholders = Array(repeating: "?", count: ordered.count).joined(separator: ", ")
            filters.append("d.source_type IN (\(placeholders))")
            for raw in ordered { params.append(raw) }
        }

        if !query.projectIds.isEmpty {
            let placeholders = Array(repeating: "?", count: query.projectIds.count).joined(separator: ", ")
            filters.append("""
                EXISTS (
                    SELECT 1 FROM project p WHERE p.id IN (\(placeholders)) AND (
                        (d.source_type IN ('memo', 'github', 'jira') AND EXISTS (
                            SELECT 1 FROM memo_project mp WHERE mp.memo_id = d.source_id AND mp.project_id = p.id))
                        OR (d.source_type = 'task' AND EXISTS (
                            SELECT 1 FROM task_project tp
                            WHERE tp.task_id = d.source_id AND tp.project_id = p.id AND tp.removed_on IS NULL))
                        OR (d.source_type = 'activity' AND (
                            EXISTS (SELECT 1 FROM activity_project ap
                                    WHERE ap.activity_id = d.source_id AND ap.project_id = p.id)
                            OR EXISTS (SELECT 1 FROM activity a JOIN task_project tp2 ON tp2.task_id = a.task_id
                                       WHERE a.id = d.source_id AND tp2.project_id = p.id AND tp2.removed_on IS NULL)))
                    )
                )
                """)
            for id in query.projectIds { params.append(id) }
        }

        if !query.tagIds.isEmpty {
            let placeholders = Array(repeating: "?", count: query.tagIds.count).joined(separator: ", ")
            filters.append("""
                EXISTS (
                    SELECT 1 FROM tag t WHERE t.id IN (\(placeholders)) AND (
                        (d.source_type IN ('memo', 'github', 'jira') AND EXISTS (
                            SELECT 1 FROM memo_tag mt WHERE mt.memo_id = d.source_id AND mt.tag_id = t.id))
                        OR (d.source_type = 'task' AND EXISTS (
                            SELECT 1 FROM task_tag tt WHERE tt.task_id = d.source_id AND tt.tag_id = t.id))
                        OR (d.source_type = 'activity' AND EXISTS (
                            SELECT 1 FROM activity a JOIN task_tag tt2 ON tt2.task_id = a.task_id
                            WHERE a.id = d.source_id AND tt2.tag_id = t.id))
                    )
                )
                """)
            for id in query.tagIds { params.append(id) }
        }

        if let range = query.range {
            filters.append("d.work_date >= ? AND d.work_date < ?")
            params.append(range.start)
            params.append(range.endExclusive)
        }

        for f in filters { sql += " AND " + f }
        sql += " ORDER BY d.work_date DESC, d.source_id ASC LIMIT ?"
        params.append(limit)

        let rows = try db.query(sql, params)
        var hits: [SearchHit] = []
        hits.reserveCapacity(rows.count)
        for row in rows {
            guard let typeRaw = row.string("source_type"),
                  let type = SearchSourceType(rawValue: typeRaw),
                  let sourceId = row.string("source_id") else { continue }
            let text = row.string("text") ?? ""
            let taskId = row.string("task_id")
            hits.append(SearchHit(sourceType: type, sourceId: sourceId, taskId: taskId,
                                  workDate: row.workDate("work_date"),
                                  snippet: snippet(from: text, terms: terms),
                                  projectNames: (try? projectNames(sourceType: type, sourceId: sourceId,
                                                                  taskId: taskId)) ?? []))
        }
        return hits
    }

    // MARK: - 헬퍼

    /// 각 term을 큰따옴표 문구로 감싸 AND로 연결한다. 내부 `"`는 `""`로 이스케이프한다.
    /// 사용자 입력을 FTS 문법으로 해석하지 않는다.
    private func ftsMatch(_ terms: [String]) -> String {
        terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " AND ")
    }

    /// LIKE 패턴용 이스케이프. `%`, `_`, `\`를 리터럴로 취급하게 한다.
    private func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func joined(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// 첫 일치 위치 주변 최대 120자. 일치가 없으면 앞부분 120자.
    private func snippet(from text: String, terms: [String]) -> String {
        guard !terms.isEmpty else { return String(text.prefix(120)) }
        let lowered = text.lowercased()
        var firstOffset: Int?
        for term in terms {
            guard let range = lowered.range(of: term.lowercased()) else { continue }
            let offset = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
            if firstOffset == nil || offset < firstOffset! { firstOffset = offset }
        }
        guard let matchOffset = firstOffset else { return String(text.prefix(120)) }
        let startOffset = max(0, matchOffset - 40)
        let start = text.index(text.startIndex, offsetBy: startOffset)
        let end = text.index(start, offsetBy: min(120, text.distance(from: start, to: text.endIndex)))
        return String(text[start..<end])
    }

    // MARK: - 조인 이름 조회

    private func memoProjectNames(_ memoId: String) throws -> [String] {
        try db.queryV("""
            SELECT p.name AS name FROM project p
            JOIN memo_project mp ON mp.project_id = p.id
            WHERE mp.memo_id = ? ORDER BY p.name ASC, p.id ASC
            """, memoId).compactMap { $0.string("name") }
    }

    private func memoTagNames(_ memoId: String) throws -> [String] {
        try db.queryV("""
            SELECT t.name AS name FROM tag t
            JOIN memo_tag mt ON mt.tag_id = t.id
            WHERE mt.memo_id = ? ORDER BY t.name ASC, t.id ASC
            """, memoId).compactMap { $0.string("name") }
    }

    private func taskProjectNames(_ taskId: String) throws -> [String] {
        try db.queryV("""
            SELECT p.name AS name FROM project p
            JOIN task_project tp ON tp.project_id = p.id
            WHERE tp.task_id = ? AND tp.removed_on IS NULL ORDER BY p.name ASC, p.id ASC
            """, taskId).compactMap { $0.string("name") }
    }

    private func taskTagNames(_ taskId: String) throws -> [String] {
        try db.queryV("""
            SELECT t.name AS name FROM tag t
            JOIN task_tag tt ON tt.tag_id = t.id
            WHERE tt.task_id = ? ORDER BY t.name ASC, t.id ASC
            """, taskId).compactMap { $0.string("name") }
    }

    private func activityProjectNames(_ activityId: String) throws -> [String] {
        try db.queryV("""
            SELECT p.name AS name FROM project p
            JOIN activity_project ap ON ap.project_id = p.id
            WHERE ap.activity_id = ? ORDER BY p.name ASC, p.id ASC
            """, activityId).compactMap { $0.string("name") }
    }

    /// 검색 결과의 projectNames. 유형별 연결 규칙:
    /// memo → 연결 프로젝트, task → 제거되지 않은 연결 프로젝트,
    /// activity → 진행 기록 자체 프로젝트가 있으면 그것, 없으면 소속 업무의 프로젝트, report → 항상 [].
    private func projectNames(sourceType: SearchSourceType, sourceId: String,
                              taskId: String?) throws -> [String] {
        switch sourceType {
        case .memo, .github, .jira:
            return sortedUnique(try memoProjectNames(sourceId))
        case .task:
            return sortedUnique(try taskProjectNames(sourceId))
        case .activity:
            let own = try activityProjectNames(sourceId)
            if !own.isEmpty { return sortedUnique(own) }
            guard let taskId else { return [] }
            return sortedUnique(try taskProjectNames(taskId))
        case .report:
            return []
        }
    }

    /// 이름 오름차순, 중복 제거.
    private func sortedUnique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names where seen.insert(name).inserted { result.append(name) }
        return result.sorted()
    }
}
