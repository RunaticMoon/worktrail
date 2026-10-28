import Foundation

public enum ActivityImportSchema {
    public static let v8 = """
    CREATE TABLE imported_activity (
        connection_key TEXT NOT NULL,
        external_id TEXT NOT NULL,
        source TEXT NOT NULL CHECK (source IN ('github','jira')),
        memo_id TEXT NOT NULL REFERENCES memo(id),
        occurred_at TEXT NOT NULL,
        fetched_at TEXT NOT NULL,
        source_url TEXT NOT NULL,
        PRIMARY KEY (connection_key, external_id)
    );
    CREATE TABLE activity_sync_state (
        connection_key TEXT PRIMARY KEY,
        attempted_on TEXT NOT NULL,
        completed_at TEXT
    );
    """

    /// Preserve the existing record IDs, revisions and links; structured presentation is additive.
    public static let v9 = """
    ALTER TABLE imported_activity ADD COLUMN display_json TEXT;
    CREATE INDEX imported_activity_memo ON imported_activity(memo_id);
    """
}

public struct ImportedActivity: Equatable, Sendable {
    public let id: String
    public let occurredAt: Date
    public let title: String
    public let detail: String
    public let url: String
    public let display: ActivityDisplayMetadata?
    public init(id: String, occurredAt: Date, title: String, detail: String, url: String,
                display: ActivityDisplayMetadata? = nil) {
        self.id = id; self.occurredAt = occurredAt; self.title = title; self.detail = detail; self.url = url
        self.display = display
    }
}

/// A source activity has its own presentation while retaining the original record identity.
/// The backing record preserves edits, links, report citations, trash and backup compatibility.
public struct ImportedActivityRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String { memo.id }
    public var source: ActivitySource
    public var memo: Memo
    public var occurredAt: Date
    public var sourceURL: String
    public var display: ActivityDisplayMetadata

    public init(source: ActivitySource, memo: Memo, occurredAt: Date, sourceURL: String,
                display: ActivityDisplayMetadata) {
        self.source = source; self.memo = memo; self.occurredAt = occurredAt
        self.sourceURL = sourceURL; self.display = display
    }
}

public struct ActivityFetchResult: Sendable {
    public var activities: [ImportedActivity]
    public var warnings: [String]
    public init(activities: [ImportedActivity], warnings: [String] = []) {
        self.activities = activities; self.warnings = warnings
    }
}

extension WorkRepository {
    /// An imported event is immutable; local edits and trash decisions survive subsequent syncs.
    @discardableResult
    public func importActivities(_ activities: [ImportedActivity], connection: ActivityConnection) throws -> Int {
        try db.transaction {
            var count = 0
            for event in activities {
                let displayJSON = try event.display.map { String(decoding: try StableJSON.encode($0), as: UTF8.self) }
                if let previous = try db.queryOneV("SELECT memo_id FROM imported_activity WHERE connection_key = ? AND external_id = ?",
                                                  connection.credentialAccount, event.id) {
                    // Older imports gain API metadata without overwriting edited text or restoring trash.
                    if let displayJSON {
                        try db.runV("UPDATE imported_activity SET display_json = ? WHERE connection_key = ? AND external_id = ? AND display_json IS NULL",
                                    displayJSON, connection.credentialAccount, event.id)
                    }
                    if let id = previous.string("memo_id") { onSourceChanged?("memo", id) }
                    continue
                }
                let body = "[\(connection.source.title)] \(event.title)\n\(event.detail)\n\(event.url)"
                let memo = try TaskService(repo: self).captureMemo(body: body, workDate: calendar.workDate(of: event.occurredAt))
                try db.runV("""
                    INSERT INTO imported_activity
                    (connection_key, external_id, source, memo_id, occurred_at, fetched_at, source_url, display_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, connection.credentialAccount, event.id, connection.source.rawValue,
                    memo.id, event.occurredAt, clock.now(), event.url, displayJSON)
                onSourceChanged?("memo", memo.id)
                count += 1
            }
            return count
        }
    }

    public func importedActivityRecord(id: String) throws -> ImportedActivityRecord? {
        guard let memo = try memo(id: id),
              let row = try db.queryOneV("SELECT source, occurred_at, source_url, display_json FROM imported_activity WHERE memo_id = ?", id),
              let raw = row.string("source"), let source = ActivitySource(rawValue: raw),
              let occurredAt = row.date("occurred_at"), let url = row.string("source_url") else { return nil }
        let stored = row.string("display_json").flatMap { try? StableJSON.decode(ActivityDisplayMetadata.self, from: Data($0.utf8)) }
        // Derive old-format display facts from the original import, not a user's later edits.
        let originalBody: String
        if stored == nil, memo.revision > 1 {
            originalBody = try db.queryOneV("SELECT body FROM memo_revision WHERE memo_id = ? ORDER BY revision ASC LIMIT 1", id)?.string("body") ?? memo.body
        } else { originalBody = memo.body }
        return ImportedActivityRecord(source: source, memo: memo, occurredAt: occurredAt, sourceURL: url,
                                      display: stored ?? .legacy(source: source, body: originalBody, url: url))
    }

    public func importedActivityRecords(on date: WorkDate) throws -> [ImportedActivityRecord] {
        try db.queryV("""
            SELECT m.id FROM memo m JOIN imported_activity a ON a.memo_id = m.id
            WHERE m.work_date = ? AND m.deleted_at IS NULL
            ORDER BY a.occurred_at ASC, m.id ASC
            """, date).compactMap { row in
                guard let id = row.string("id") else { return nil }
                return try importedActivityRecord(id: id)
            }
    }

    public func activitySyncAttemptedOn(connection: ActivityConnection) throws -> WorkDate? {
        try db.queryV("SELECT attempted_on FROM activity_sync_state WHERE connection_key = ?",
                      connection.credentialAccount).first?.workDate("attempted_on")
    }

    public func activitySyncCompletedAt(connection: ActivityConnection) throws -> Date? {
        try db.queryV("SELECT completed_at FROM activity_sync_state WHERE connection_key = ?",
                      connection.credentialAccount).first?.date("completed_at")
    }

    public func recordActivitySyncAttempt(connection: ActivityConnection, completed: Bool = false) throws {
        try db.runV("""
            INSERT INTO activity_sync_state (connection_key, attempted_on, completed_at) VALUES (?, ?, ?)
            ON CONFLICT(connection_key) DO UPDATE SET attempted_on = excluded.attempted_on,
                completed_at = COALESCE(excluded.completed_at, activity_sync_state.completed_at)
            """, connection.credentialAccount, calendar.workDate(of: clock.now()), completed ? clock.now() : nil)
    }
}
