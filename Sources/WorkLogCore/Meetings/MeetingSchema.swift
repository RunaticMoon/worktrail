import Foundation

/// WorkSchema가 등록하는 추가 migration. 기존 v1-v4 SQL은 변경하지 않는다.
public enum MeetingSchema {
    public static let v11 = """
    ALTER TABLE meeting ADD COLUMN metadata_json TEXT;
    ALTER TABLE meeting_summary ADD COLUMN origin TEXT NOT NULL DEFAULT 'ai';
    CREATE TABLE meeting_summary_edit (
        id TEXT PRIMARY KEY, summary_id TEXT NOT NULL REFERENCES meeting_summary(id),
        previous_content TEXT NOT NULL, replacement_content TEXT NOT NULL, created_at TEXT NOT NULL
    );
    CREATE TABLE meeting_task_link (
        id TEXT PRIMARY KEY, meeting_id TEXT NOT NULL REFERENCES meeting(id),
        meeting_revision INTEGER NOT NULL, action_key TEXT NOT NULL,
        task_id TEXT NOT NULL REFERENCES task(id), transcript_run_id TEXT REFERENCES meeting_transcript_run(id),
        segment_id TEXT REFERENCES meeting_transcript_segment(id), quote TEXT NOT NULL,
        owner TEXT, local_only INTEGER NOT NULL DEFAULT 1 CHECK (local_only IN (0,1)),
        created_at TEXT NOT NULL, UNIQUE(meeting_id, action_key)
    );
    CREATE INDEX meeting_task_link_task ON meeting_task_link(task_id, local_only);
    """

    public static let v6 = """
    ALTER TABLE meeting ADD COLUMN local_only INTEGER NOT NULL DEFAULT 1 CHECK (local_only IN (0, 1));
    ALTER TABLE meeting ADD COLUMN active_transcript_run_id TEXT;
    CREATE TABLE meeting_recording (
        id TEXT PRIMARY KEY,
        meeting_id TEXT NOT NULL REFERENCES meeting(id),
        state TEXT NOT NULL CHECK (state IN ('recording','paused','completed','interrupted','failed','discarded')),
        revision INTEGER NOT NULL DEFAULT 1,
        started_at TEXT NOT NULL,
        ended_at TEXT,
        updated_at TEXT NOT NULL
    );
    CREATE INDEX meeting_recording_meeting ON meeting_recording(meeting_id, started_at);
    CREATE TABLE meeting_audio_track (
        id TEXT PRIMARY KEY,
        recording_id TEXT NOT NULL REFERENCES meeting_recording(id),
        kind TEXT NOT NULL CHECK (kind IN ('microphone','systemAudio','mixed','imported')),
        relative_path TEXT NOT NULL UNIQUE,
        file_state TEXT NOT NULL CHECK (file_state IN ('pending','writing','available','needsRecovery','missing','deleted')),
        sample_rate REAL NOT NULL CHECK (sample_rate > 0),
        channels INTEGER NOT NULL CHECK (channels > 0),
        start_offset REAL NOT NULL DEFAULT 0 CHECK (start_offset >= 0),
        duration REAL,
        interruptions_json TEXT NOT NULL DEFAULT '[]',
        revision INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );
    CREATE INDEX meeting_audio_track_recording ON meeting_audio_track(recording_id);
    CREATE TABLE meeting_transcript_run (
        id TEXT PRIMARY KEY,
        meeting_id TEXT NOT NULL REFERENCES meeting(id),
        recording_id TEXT REFERENCES meeting_recording(id),
        source_run_id TEXT REFERENCES meeting_transcript_run(id),
        stage TEXT NOT NULL CHECK (stage IN ('live','refined','diarized','manual','imported')),
        engine TEXT NOT NULL,
        model_identifier TEXT NOT NULL,
        model_revision TEXT,
        settings_json TEXT NOT NULL DEFAULT '{}',
        status TEXT NOT NULL CHECK (status IN ('running','completed','failed','cancelled','interrupted')),
        version INTEGER NOT NULL,
        revision INTEGER NOT NULL DEFAULT 1,
        manual_text TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        completed_at TEXT,
        UNIQUE (meeting_id, version)
    );
    CREATE TABLE meeting_speaker (
        id TEXT PRIMARY KEY,
        recording_id TEXT NOT NULL REFERENCES meeting_recording(id),
        run_id TEXT NOT NULL REFERENCES meeting_transcript_run(id),
        source_key TEXT NOT NULL,
        original_name TEXT NOT NULL,
        display_name TEXT NOT NULL,
        is_user_edited INTEGER NOT NULL DEFAULT 0,
        revision INTEGER NOT NULL DEFAULT 1,
        UNIQUE (run_id, source_key)
    );
    CREATE TABLE meeting_transcript_segment (
        id TEXT PRIMARY KEY,
        run_id TEXT NOT NULL REFERENCES meeting_transcript_run(id),
        track_id TEXT NOT NULL REFERENCES meeting_audio_track(id),
        source_key TEXT NOT NULL,
        start REAL NOT NULL CHECK (start >= 0),
        end REAL NOT NULL CHECK (end >= start),
        original_text TEXT NOT NULL,
        edited_text TEXT,
        original_speaker_id TEXT REFERENCES meeting_speaker(id),
        edited_speaker_id TEXT REFERENCES meeting_speaker(id),
        is_speaker_edited INTEGER NOT NULL DEFAULT 0,
        is_final INTEGER NOT NULL DEFAULT 1,
        revision INTEGER NOT NULL DEFAULT 1,
        UNIQUE (run_id, source_key)
    );
    CREATE INDEX meeting_segment_timeline ON meeting_transcript_segment(run_id, start, end);
    CREATE TABLE meeting_transcript_edit (
        id TEXT PRIMARY KEY,
        run_id TEXT NOT NULL REFERENCES meeting_transcript_run(id),
        segment_id TEXT REFERENCES meeting_transcript_segment(id),
        speaker_id TEXT REFERENCES meeting_speaker(id),
        previous_text TEXT NOT NULL,
        replacement_text TEXT NOT NULL,
        created_at TEXT NOT NULL
    );
    CREATE TABLE meeting_preview_gap (
        id TEXT PRIMARY KEY,
        run_id TEXT NOT NULL REFERENCES meeting_transcript_run(id),
        track_id TEXT NOT NULL REFERENCES meeting_audio_track(id),
        start REAL NOT NULL CHECK (start >= 0),
        end REAL NOT NULL CHECK (end > start),
        reason TEXT NOT NULL,
        created_at TEXT NOT NULL,
        UNIQUE (run_id, track_id, start, end, reason)
    );
    CREATE INDEX meeting_preview_gap_timeline ON meeting_preview_gap(run_id, start, end);
    """

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
