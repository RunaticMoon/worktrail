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
}

public struct ImportedActivity: Equatable, Sendable {
    public let id: String
    public let occurredAt: Date
    public let title: String
    public let detail: String
    public let url: String
    public init(id: String, occurredAt: Date, title: String, detail: String, url: String) {
        self.id = id; self.occurredAt = occurredAt; self.title = title; self.detail = detail; self.url = url
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
                guard try db.queryV("SELECT memo_id FROM imported_activity WHERE connection_key = ? AND external_id = ?",
                                    connection.credentialAccount, event.id).isEmpty else { continue }
                let body = "[\(connection.source.title)] \(event.title)\n\(event.detail)\n\(event.url)"
                let memo = try TaskService(repo: self).captureMemo(body: body, workDate: calendar.workDate(of: event.occurredAt))
                try db.runV("""
                    INSERT INTO imported_activity
                    (connection_key, external_id, source, memo_id, occurred_at, fetched_at, source_url)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, connection.credentialAccount, event.id, connection.source.rawValue,
                    memo.id, event.occurredAt, clock.now(), event.url)
                count += 1
            }
            return count
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
