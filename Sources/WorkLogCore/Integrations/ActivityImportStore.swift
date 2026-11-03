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
        let key = try activityImportKey(connection)
        return try db.transaction {
            var count = 0
            for event in activities {
                let displayJSON = try event.display.map { String(decoding: try StableJSON.encode($0), as: UTF8.self) }
                if let previous = try db.queryOneV("SELECT memo_id FROM imported_activity WHERE connection_key = ? AND external_id = ?",
                                                  key, event.id) {
                    // Older imports gain API metadata without overwriting edited text or restoring trash.
                    // Periodic syncs re-fetch an overlap window, so only reindex rows that changed.
                    if let displayJSON,
                       try db.runV("UPDATE imported_activity SET display_json = ? WHERE connection_key = ? AND external_id = ? AND display_json IS NULL",
                                   displayJSON, key, event.id) > 0,
                       let id = previous.string("memo_id") { onSourceChanged?("memo", id) }
                    continue
                }
                let body = "[\(connection.source.title)] \(event.title)\n\(event.detail)\n\(event.url)"
                let memo = try TaskService(repo: self).captureMemo(body: body, workDate: calendar.workDate(of: event.occurredAt))
                try db.runV("""
                    INSERT INTO imported_activity
                    (connection_key, external_id, source, memo_id, occurred_at, fetched_at, source_url, display_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, key, event.id, connection.source.rawValue,
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
        let key = try activityImportKey(connection)
        return try db.queryV("SELECT attempted_on FROM activity_sync_state WHERE connection_key = ?", key)
            .first?.workDate("attempted_on")
    }

    public func activitySyncCompletedAt(connection: ActivityConnection) throws -> Date? {
        let key = try activityImportKey(connection)
        return try db.queryV("SELECT completed_at FROM activity_sync_state WHERE connection_key = ?", key)
            .first?.date("completed_at")
    }

    public func recordActivitySyncAttempt(connection: ActivityConnection, completed: Bool = false) throws {
        let key = try activityImportKey(connection)
        try db.runV("""
            INSERT INTO activity_sync_state (connection_key, attempted_on, completed_at) VALUES (?, ?, ?)
            ON CONFLICT(connection_key) DO UPDATE SET attempted_on = excluded.attempted_on,
                completed_at = COALESCE(excluded.completed_at, activity_sync_state.completed_at)
            """, key, calendar.workDate(of: clock.now()), completed ? clock.now() : nil)
    }

    /// Key for new `imported_activity`/`activity_sync_state` rows. Rows written before the import
    /// identity was split from the Keychain account are adopted first, so a sync never re-imports
    /// events it already holds. Adoption is idempotent and returns without work when nothing is left.
    private func activityImportKey(_ connection: ActivityConnection) throws -> String {
        try adoptLegacyActivityImportKey(for: connection)
        return connection.importIdentity
    }

    /// Moves rows stored under the legacy connection key to the current import identity.
    /// Imported memos are never deleted or merged: rows whose event already exists under the
    /// current key keep that row and the legacy row is left untouched.
    public func adoptLegacyActivityImportKey(for connection: ActivityConnection) throws {
        let legacy = connection.credentialAccount
        let current = connection.importIdentity
        guard legacy != current else { return }
        try db.transaction {
            let legacyRows = try db.scalarIntV("""
                SELECT (SELECT COUNT(*) FROM imported_activity WHERE connection_key = ?)
                     + (SELECT COUNT(*) FROM activity_sync_state WHERE connection_key = ?)
                """, legacy, legacy)
            guard legacyRows > 0 else { return }
            try db.runV("""
                UPDATE imported_activity SET connection_key = ?
                WHERE connection_key = ? AND NOT EXISTS (
                    SELECT 1 FROM imported_activity current
                    WHERE current.connection_key = ? AND current.external_id = imported_activity.external_id)
                """, current, legacy, current)
            guard let legacyState = try db.queryOneV(
                "SELECT attempted_on, completed_at FROM activity_sync_state WHERE connection_key = ?", legacy) else { return }
            if let currentState = try db.queryOneV(
                "SELECT attempted_on, completed_at FROM activity_sync_state WHERE connection_key = ?", current) {
                // One state row survives: the later successful sync, and a completed time wins over none.
                let surviving = Self.laterActivitySyncState(currentState, legacyState)
                try db.runV("UPDATE activity_sync_state SET attempted_on = ?, completed_at = ? WHERE connection_key = ?",
                            surviving["attempted_on"], surviving["completed_at"], current)
            } else {
                try db.runV("UPDATE activity_sync_state SET connection_key = ? WHERE connection_key = ?", current, legacy)
            }
            try db.runV("DELETE FROM activity_sync_state WHERE connection_key = ?", legacy)
        }
    }

    private static func laterActivitySyncState(_ current: SQLRow, _ legacy: SQLRow) -> SQLRow {
        switch (current.date("completed_at"), legacy.date("completed_at")) {
        case let (left?, right?): return right > left ? legacy : current
        case (nil, .some): return legacy
        default: return current
        }
    }
}
