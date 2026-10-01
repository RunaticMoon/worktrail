import Foundation

// SQLiteDatabase의 파라미터 배열 API를 가변 인자로 감싼 내부 편의 함수.
// 값은 항상 `?` 바인딩으로 전달된다(문자열 결합 없음).
extension SQLiteDatabase {
    @discardableResult
    func runV(_ sql: String, _ params: SQLBindable...) throws -> Int {
        try run(sql, params)
    }

    func queryV(_ sql: String, _ params: SQLBindable...) throws -> [SQLRow] {
        try query(sql, params)
    }

    func queryOneV(_ sql: String, _ params: SQLBindable...) throws -> SQLRow? {
        try queryOne(sql, params)
    }

    func scalarIntV(_ sql: String, _ params: SQLBindable...) throws -> Int {
        try scalarInt(sql, params)
    }
}

// MARK: - Project / Tag / Memo / WorkLink / TaskRelation / MemoTaskLink
//
// 원문 엔터티의 저장·조회. 배열 필드는 조인 테이블에 두고 조회 시 정렬된 배열로 채운다.
// 여러 테이블에 쓰는 메서드는 단일 transaction 안에서 처리한다.
extension WorkRepository {

    // MARK: Project

    /// 새 프로젝트. 같은 이름(공백 제거 후)이 이미 있으면 conflict.
    public func createProject(name: String) throws -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if try db.queryOneV("SELECT 1 AS x FROM project WHERE name = ?", trimmed) != nil {
            throw WorkLogError.conflict("이미 존재하는 프로젝트 이름: \(trimmed)")
        }
        let id = ids.make()
        try db.runV("INSERT INTO project (id, name, archived_at) VALUES (?, ?, NULL)", id, trimmed)
        return Project(id: id, name: trimmed)
    }

    /// 공백을 제거한 이름으로 찾고, 없으면 만든다.
    public func findOrCreateProject(name: String) throws -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try db.transaction {
            if let row = try db.queryOneV("SELECT * FROM project WHERE name = ?", trimmed) {
                return try projectRow(row)
            }
            let id = ids.make()
            try db.runV("INSERT INTO project (id, name, archived_at) VALUES (?, ?, NULL)", id, trimmed)
            return Project(id: id, name: trimmed)
        }
    }

    public func renameProject(id: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if try db.queryOneV("SELECT 1 AS x FROM project WHERE name = ? AND id <> ?", trimmed, id) != nil {
            throw WorkLogError.conflict("이미 존재하는 프로젝트 이름: \(trimmed)")
        }
        let n = try db.runV("UPDATE project SET name = ? WHERE id = ?", trimmed, id)
        if n == 0 { throw WorkLogError.notFound("project \(id)") }
    }

    /// 이름순. 기본은 보관되지 않은 프로젝트만.
    public func projects(includeArchived: Bool = false) throws -> [Project] {
        let sql = includeArchived
            ? "SELECT * FROM project ORDER BY name ASC, id ASC"
            : "SELECT * FROM project WHERE archived_at IS NULL ORDER BY name ASC, id ASC"
        return try db.queryV(sql).map { try projectRow($0) }
    }

    public func project(id: String) throws -> Project? {
        try db.queryOneV("SELECT * FROM project WHERE id = ?", id).map { try projectRow($0) }
    }

    // MARK: Tag

    public func findOrCreateTag(name: String) throws -> Tag {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try db.transaction {
            if let row = try db.queryOneV("SELECT * FROM tag WHERE name = ?", trimmed) {
                return try tagRow(row)
            }
            let id = ids.make()
            try db.runV("INSERT INTO tag (id, name) VALUES (?, ?)", id, trimmed)
            return Tag(id: id, name: trimmed)
        }
    }

    public func tags() throws -> [Tag] {
        try db.queryV("SELECT * FROM tag ORDER BY name ASC, id ASC").map { try tagRow($0) }
    }

    // MARK: Memo

    public func insertMemo(_ memo: Memo) throws {
        try db.transaction {
            try db.runV("""
                INSERT INTO memo (id, body, work_date, recorded_at, revision, deleted_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, memo.id, memo.body, memo.workDate, memo.recordedAt, memo.revision, memo.deletedAt)
            for projectId in memo.projectIds {
                try db.runV("INSERT OR IGNORE INTO memo_project (memo_id, project_id) VALUES (?, ?)",
                           memo.id, projectId)
            }
            for tagId in memo.tagIds {
                try db.runV("INSERT OR IGNORE INTO memo_tag (memo_id, tag_id) VALUES (?, ?)",
                           memo.id, tagId)
            }
        }
        onSourceChanged?("memo", memo.id)
    }

    /// 본문을 바꾸고 이전 본문을 memo_revision에 보존한다. revision은 +1.
    @discardableResult
    public func updateMemoBody(id: String, body: String, workDate: WorkDate) throws -> Memo {
        let updated: Memo = try db.transaction {
            guard let previous = try memo(id: id) else {
                throw WorkLogError.notFound("memo \(id)")
            }
            try db.runV("""
                INSERT OR REPLACE INTO memo_revision (memo_id, revision, body, work_date, recorded_at)
                VALUES (?, ?, ?, ?, ?)
                """, previous.id, previous.revision, previous.body, previous.workDate, previous.recordedAt)
            let nextRevision = previous.revision + 1
            try db.runV("UPDATE memo SET body = ?, work_date = ?, revision = ? WHERE id = ?",
                       body, workDate, nextRevision, id)
            guard let result = try memo(id: id) else {
                throw WorkLogError.storage("memo \(id) 갱신 후 조회 실패")
            }
            return result
        }
        onSourceChanged?("memo", id)
        return updated
    }

    public func memo(id: String, includeDeleted: Bool = false) throws -> Memo? {
        let sql = includeDeleted
            ? "SELECT * FROM memo WHERE id = ?"
            : "SELECT * FROM memo WHERE id = ? AND deleted_at IS NULL"
        return try db.queryOneV(sql, id).map { try memoRow($0) }
    }

    /// work_date 기준, recorded_at 오름차순.
    public func memos(on date: WorkDate) throws -> [Memo] {
        try db.queryV("""
            SELECT * FROM memo WHERE work_date = ? AND deleted_at IS NULL
            ORDER BY recorded_at ASC, id ASC
            """, date).map { try memoRow($0) }
    }

    public func memos(in range: DateRange) throws -> [Memo] {
        try db.queryV("""
            SELECT * FROM memo WHERE work_date >= ? AND work_date < ? AND deleted_at IS NULL
            ORDER BY work_date ASC, recorded_at ASC, id ASC
            """, range.start, range.endExclusive).map { try memoRow($0) }
    }

    /// 보존된 과거 revision (오래된 순). 조인 정보는 담지 않는다.
    public func memoRevisions(id: String) throws -> [Memo] {
        try db.queryV("""
            SELECT * FROM memo_revision WHERE memo_id = ? ORDER BY revision ASC
            """, id).map { row in
            Memo(id: row.string("memo_id") ?? id,
                 body: row.string("body") ?? "",
                 workDate: row.workDate("work_date") ?? WorkDate(year: 1970, month: 1, day: 1),
                 recordedAt: row.date("recorded_at") ?? Date(timeIntervalSince1970: 0),
                 revision: row.int("revision") ?? 1)
        }
    }

    public func softDeleteMemo(id: String) throws {
        let n = try db.runV("UPDATE memo SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL",
                           clock.now(), id)
        if n == 0 { throw WorkLogError.notFound("memo \(id)") }
        onSourceChanged?("memo", id)
    }

    // MARK: WorkLink

    public func insertLink(_ link: WorkLink) throws {
        try db.runV("""
            INSERT INTO work_link (id, owner_type, owner_id, url, link_type, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, link.id, link.ownerType.rawValue, link.ownerId, link.url,
               link.linkType.rawValue, link.createdAt)
    }

    public func links(ownerType: LinkOwnerType, ownerId: String) throws -> [WorkLink] {
        try db.queryV("""
            SELECT * FROM work_link WHERE owner_type = ? AND owner_id = ?
            ORDER BY created_at ASC, id ASC
            """, ownerType.rawValue, ownerId).map { try linkRow($0) }
    }

    // MARK: TaskRelation

    public func insertRelation(_ relation: TaskRelation) throws {
        try db.runV("""
            INSERT INTO task_relation (id, from_task_id, to_task_id, relation_type, created_at)
            VALUES (?, ?, ?, ?, ?)
            """, relation.id, relation.fromTaskId, relation.toTaskId,
               relation.type.rawValue, relation.createdAt)
    }

    /// from 또는 to로 걸린 관계.
    public func relations(taskId: String) throws -> [TaskRelation] {
        try db.queryV("""
            SELECT * FROM task_relation WHERE from_task_id = ? OR to_task_id = ?
            ORDER BY created_at ASC, id ASC
            """, taskId, taskId).map { try relationRow($0) }
    }

    // MARK: MemoTaskLink

    /// id 기준 insert or replace.
    public func upsertMemoTaskLink(_ link: MemoTaskLink) throws {
        try db.runV("""
            INSERT OR REPLACE INTO memo_task_link
                (id, memo_id, task_id, status, reason, source_revision, created_at, decided_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, link.id, link.memoId, link.taskId, link.status.rawValue, link.reason,
               link.sourceRevision, link.createdAt, link.decidedAt)
    }

    public func memoTaskLinks(memoId: String) throws -> [MemoTaskLink] {
        try db.queryV("""
            SELECT * FROM memo_task_link WHERE memo_id = ? ORDER BY created_at ASC, id ASC
            """, memoId).map { try memoTaskLinkRow($0) }
    }

    public func memoTaskLinks(taskId: String, status: MemoTaskLinkStatus? = nil) throws -> [MemoTaskLink] {
        if let status {
            return try db.queryV("""
                SELECT * FROM memo_task_link WHERE task_id = ? AND status = ?
                ORDER BY created_at ASC, id ASC
                """, taskId, status.rawValue).map { try memoTaskLinkRow($0) }
        }
        return try db.queryV("""
            SELECT * FROM memo_task_link WHERE task_id = ? ORDER BY created_at ASC, id ASC
            """, taskId).map { try memoTaskLinkRow($0) }
    }

    // MARK: - Row mapping

    private func projectRow(_ row: SQLRow) throws -> Project {
        guard let id = row.string("id"), let name = row.string("name") else {
            throw WorkLogError.storage("project row 손상")
        }
        return Project(id: id, name: name, archivedAt: row.date("archived_at"))
    }

    private func tagRow(_ row: SQLRow) throws -> Tag {
        guard let id = row.string("id"), let name = row.string("name") else {
            throw WorkLogError.storage("tag row 손상")
        }
        return Tag(id: id, name: name)
    }

    private func memoRow(_ row: SQLRow) throws -> Memo {
        guard let id = row.string("id"), let body = row.string("body"),
              let workDate = row.workDate("work_date") else {
            throw WorkLogError.storage("memo row 손상")
        }
        let projectIds = try db.queryV("""
            SELECT project_id FROM memo_project WHERE memo_id = ? ORDER BY project_id ASC
            """, id).compactMap { $0.string("project_id") }
        let tagIds = try db.queryV("""
            SELECT tag_id FROM memo_tag WHERE memo_id = ? ORDER BY tag_id ASC
            """, id).compactMap { $0.string("tag_id") }
        return Memo(id: id, body: body, workDate: workDate,
                    recordedAt: row.date("recorded_at") ?? Date(timeIntervalSince1970: 0),
                    revision: row.int("revision") ?? 1,
                    deletedAt: row.date("deleted_at"),
                    projectIds: projectIds, tagIds: tagIds)
    }

    private func linkRow(_ row: SQLRow) throws -> WorkLink {
        guard let id = row.string("id"),
              let ownerRaw = row.string("owner_type"), let ownerType = LinkOwnerType(rawValue: ownerRaw),
              let ownerId = row.string("owner_id"), let url = row.string("url"),
              let linkRaw = row.string("link_type"), let linkType = LinkType(rawValue: linkRaw) else {
            throw WorkLogError.storage("work_link row 손상")
        }
        return WorkLink(id: id, ownerType: ownerType, ownerId: ownerId, url: url,
                        linkType: linkType,
                        createdAt: row.date("created_at") ?? Date(timeIntervalSince1970: 0))
    }

    private func relationRow(_ row: SQLRow) throws -> TaskRelation {
        guard let id = row.string("id"), let from = row.string("from_task_id"),
              let to = row.string("to_task_id"),
              let typeRaw = row.string("relation_type"), let type = TaskRelationType(rawValue: typeRaw) else {
            throw WorkLogError.storage("task_relation row 손상")
        }
        return TaskRelation(id: id, fromTaskId: from, toTaskId: to, type: type,
                            createdAt: row.date("created_at") ?? Date(timeIntervalSince1970: 0))
    }

    private func memoTaskLinkRow(_ row: SQLRow) throws -> MemoTaskLink {
        guard let id = row.string("id"), let memoId = row.string("memo_id"),
              let taskId = row.string("task_id"),
              let statusRaw = row.string("status"), let status = MemoTaskLinkStatus(rawValue: statusRaw) else {
            throw WorkLogError.storage("memo_task_link row 손상")
        }
        return MemoTaskLink(id: id, memoId: memoId, taskId: taskId, status: status,
                            reason: row.string("reason") ?? "",
                            sourceRevision: row.int("source_revision") ?? 1,
                            createdAt: row.date("created_at") ?? Date(timeIntervalSince1970: 0),
                            decidedAt: row.date("decided_at"))
    }
}
