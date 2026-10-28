import Foundation

/// Existing history has no reliable classification snapshot; NULL explicitly means unknown.
enum MemoHistorySchema {
    static let v10 = """
    ALTER TABLE memo ADD COLUMN updated_at TEXT;
    ALTER TABLE memo_revision ADD COLUMN project_ids_json TEXT;
    ALTER TABLE memo_revision ADD COLUMN tag_ids_json TEXT;
    ALTER TABLE memo_revision ADD COLUMN superseded_at TEXT;
    """
}

public struct MemoHistoryEntry: Identifiable, Sendable {
    public var id: Int { memo.revision }
    public let memo: Memo
    public let classificationRecorded: Bool
    public let supersededAt: Date?
}

extension WorkRepository {
    /// One transaction owns the body, date, classifications and prior revision.
    @discardableResult public func updateMemo(id: String, body: String, workDate: WorkDate,
        projectIds: [String], tagNames: [String], expectedRevision: Int? = nil) throws -> Memo {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkLogError.validation("메모 내용을 입력하세요.")
        }
        let result: Memo = try db.transaction {
            guard let previous = try memo(id: id) else { throw WorkLogError.notFound("memo") }
            if let expectedRevision, expectedRevision != previous.revision {
                throw WorkLogError.conflict("다른 곳에서 수정한 메모입니다. 다시 불러와 확인하세요.")
            }
            let projects = Array(Set(projectIds)).sorted()
            for id in projects {
                guard try project(id: id) != nil else { throw WorkLogError.validation("선택한 프로젝트를 찾을 수 없습니다.") }
            }
            let names = Set(tagNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            let tags = try names.sorted().map { try findOrCreateTag(name: $0).id }.sorted()
            guard previous.body != body || previous.workDate != workDate || previous.projectIds != projects || previous.tagIds != tags else { return previous }
            try db.runV("""
                INSERT INTO memo_revision (memo_id, revision, body, work_date, recorded_at,
                    project_ids_json, tag_ids_json, superseded_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, id, previous.revision, previous.body, previous.workDate, previous.recordedAt,
                try StableJSON.string(previous.projectIds), try StableJSON.string(previous.tagIds), clock.now())
            try db.runV("UPDATE memo SET body = ?, work_date = ?, revision = ?, updated_at = ? WHERE id = ?",
                        body, workDate, previous.revision + 1, clock.now(), id)
            try db.runV("DELETE FROM memo_project WHERE memo_id = ?", id)
            for projectId in projects { try db.runV("INSERT INTO memo_project (memo_id, project_id) VALUES (?, ?)", id, projectId) }
            try db.runV("DELETE FROM memo_tag WHERE memo_id = ?", id)
            for tagId in tags { try db.runV("INSERT INTO memo_tag (memo_id, tag_id) VALUES (?, ?)", id, tagId) }
            guard let updated = try memo(id: id) else { throw WorkLogError.storage("메모 갱신 후 조회 실패") }
            return updated
        }
        onSourceChanged?("memo", id)
        return result
    }

    public func memoUpdatedAt(id: String) throws -> Date? {
        try db.queryOneV("SELECT updated_at FROM memo WHERE id = ?", id)?.date("updated_at")
    }

    public func memoHistory(id: String) throws -> [MemoHistoryEntry] {
        try db.queryV("SELECT * FROM memo_revision WHERE memo_id = ? ORDER BY revision DESC", id).map { row in
            let projects = row.string("project_ids_json")
            let tags = row.string("tag_ids_json")
            return MemoHistoryEntry(memo: Memo(id: id, body: row.string("body") ?? "",
                workDate: row.workDate("work_date") ?? WorkDate(year: 1970, month: 1, day: 1),
                recordedAt: row.date("recorded_at") ?? Date(timeIntervalSince1970: 0), revision: row.int("revision") ?? 1,
                projectIds: try projects.map { try StableJSON.decode([String].self, from: $0) } ?? [],
                tagIds: try tags.map { try StableJSON.decode([String].self, from: $0) } ?? []),
                classificationRecorded: projects != nil && tags != nil, supersededAt: row.date("superseded_at"))
        }
    }
}
