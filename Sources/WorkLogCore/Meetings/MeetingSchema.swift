import Foundation

/// WorkSchema가 등록하는 추가 migration. 기존 v1-v4 SQL은 변경하지 않는다.
public enum MeetingSchema {
    public static let v5 = """
    CREATE TABLE meeting (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        work_date TEXT NOT NULL,
        transcript TEXT NOT NULL DEFAULT '',
        notes TEXT NOT NULL DEFAULT '',
        revision INTEGER NOT NULL DEFAULT 1 CHECK (revision > 0),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT
    );
    CREATE INDEX meeting_work_date ON meeting(work_date, updated_at);
    CREATE TABLE meeting_memo_snapshot (
        meeting_id TEXT NOT NULL REFERENCES meeting(id) ON DELETE CASCADE,
        memo_id TEXT NOT NULL,
        source_revision INTEGER NOT NULL,
        body TEXT NOT NULL,
        work_date TEXT NOT NULL,
        captured_at TEXT NOT NULL,
        PRIMARY KEY (meeting_id, memo_id)
    );
    CREATE TABLE meeting_summary (
        id TEXT PRIMARY KEY,
        meeting_id TEXT NOT NULL REFERENCES meeting(id) ON DELETE CASCADE,
        version INTEGER NOT NULL CHECK (version > 0),
        revision INTEGER NOT NULL DEFAULT 1 CHECK (revision > 0),
        source_revision INTEGER NOT NULL,
        content TEXT NOT NULL,
        structured_json TEXT NOT NULL,
        sources_json TEXT NOT NULL,
        is_user_edited INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE (meeting_id, version)
    );
    """
}
