import Foundation

/// 일반 업무 DB(work.sqlite) 스키마. Secret 관련 테이블은 여기에 절대 두지 않는다.
/// 날짜(WorkDate)는 'yyyy-MM-dd' TEXT, 순간(Date)은 ISO8601 UTC TEXT, 배열 연결은 조인 테이블.
public enum WorkSchema {
    public static let migrations: [Migration] = [
        Migration(version: 1, sql: v1),
        Migration(version: 2, sql: SearchSchema.v2),
    ]

    static let v1 = """
    CREATE TABLE project (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        archived_at TEXT
    );
    CREATE UNIQUE INDEX project_name_unique ON project(name);

    CREATE TABLE tag (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL
    );
    CREATE UNIQUE INDEX tag_name_unique ON tag(name);

    CREATE TABLE memo (
        id TEXT PRIMARY KEY,
        body TEXT NOT NULL,
        work_date TEXT NOT NULL,
        recorded_at TEXT NOT NULL,
        revision INTEGER NOT NULL DEFAULT 1,
        deleted_at TEXT
    );
    CREATE INDEX memo_work_date ON memo(work_date);
    CREATE TABLE memo_project (memo_id TEXT NOT NULL REFERENCES memo(id) ON DELETE CASCADE,
                               project_id TEXT NOT NULL REFERENCES project(id),
                               PRIMARY KEY (memo_id, project_id));
    CREATE TABLE memo_tag (memo_id TEXT NOT NULL REFERENCES memo(id) ON DELETE CASCADE,
                           tag_id TEXT NOT NULL REFERENCES tag(id),
                           PRIMARY KEY (memo_id, tag_id));
    -- 원문 수정 이력 (이전 본문 보존)
    CREATE TABLE memo_revision (
        memo_id TEXT NOT NULL REFERENCES memo(id) ON DELETE CASCADE,
        revision INTEGER NOT NULL,
        body TEXT NOT NULL,
        work_date TEXT NOT NULL,
        recorded_at TEXT NOT NULL,
        PRIMARY KEY (memo_id, revision)
    );

    CREATE TABLE task (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        due_on TEXT,
        created_at TEXT NOT NULL,
        project_tracking_mode TEXT NOT NULL DEFAULT 'shared',
        revision INTEGER NOT NULL DEFAULT 1,
        deleted_at TEXT,
        cached_status TEXT
    );
    CREATE TABLE task_tag (task_id TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
                           tag_id TEXT NOT NULL REFERENCES tag(id),
                           PRIMARY KEY (task_id, tag_id));
    CREATE TABLE task_project (
        id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
        project_id TEXT NOT NULL REFERENCES project(id),
        tracking_enabled INTEGER NOT NULL DEFAULT 0,
        linked_on TEXT NOT NULL,
        removed_on TEXT
    );
    CREATE UNIQUE INDEX task_project_unique ON task_project(task_id, project_id);

    CREATE TABLE checklist_item (
        id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
        text TEXT NOT NULL,
        sort_order INTEGER NOT NULL,
        deleted_at TEXT
    );
    CREATE TABLE checklist_project (checklist_item_id TEXT NOT NULL REFERENCES checklist_item(id) ON DELETE CASCADE,
                                    project_id TEXT NOT NULL REFERENCES project(id),
                                    PRIMARY KEY (checklist_item_id, project_id));

    CREATE TABLE activity (
        id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
        body TEXT NOT NULL,
        work_date TEXT NOT NULL,
        recorded_at TEXT NOT NULL,
        kind TEXT NOT NULL,
        revision INTEGER NOT NULL DEFAULT 1,
        deleted_at TEXT
    );
    CREATE INDEX activity_work_date ON activity(work_date);
    CREATE INDEX activity_task ON activity(task_id);
    CREATE TABLE activity_project (activity_id TEXT NOT NULL REFERENCES activity(id) ON DELETE CASCADE,
                                   project_id TEXT NOT NULL REFERENCES project(id),
                                   PRIMARY KEY (activity_id, project_id));
    CREATE TABLE activity_checklist (activity_id TEXT NOT NULL REFERENCES activity(id) ON DELETE CASCADE,
                                     checklist_item_id TEXT NOT NULL REFERENCES checklist_item(id),
                                     PRIMARY KEY (activity_id, checklist_item_id));

    -- 상태 이력 원본 (append-only). 정정은 kind='voided' + supersedes_event_id.
    CREATE TABLE domain_event (
        id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
        scope_type TEXT NOT NULL,
        scope_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        to_status TEXT,
        effective_date TEXT NOT NULL,
        effective_time TEXT,
        effective_order INTEGER NOT NULL,
        recorded_at TEXT NOT NULL,
        supersedes_event_id TEXT,
        note TEXT,
        activity_id TEXT
    );
    CREATE INDEX domain_event_task ON domain_event(task_id, effective_date, effective_order);
    CREATE INDEX domain_event_date ON domain_event(effective_date);

    CREATE TABLE memo_task_link (
        id TEXT PRIMARY KEY,
        memo_id TEXT NOT NULL REFERENCES memo(id) ON DELETE CASCADE,
        task_id TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
        status TEXT NOT NULL,
        reason TEXT NOT NULL DEFAULT '',
        source_revision INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        decided_at TEXT
    );
    CREATE INDEX memo_task_link_pair ON memo_task_link(memo_id, task_id);

    CREATE TABLE task_relation (
        id TEXT PRIMARY KEY,
        from_task_id TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
        to_task_id TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
        relation_type TEXT NOT NULL,
        created_at TEXT NOT NULL
    );

    CREATE TABLE work_link (
        id TEXT PRIMARY KEY,
        owner_type TEXT NOT NULL,
        owner_id TEXT NOT NULL,
        url TEXT NOT NULL,
        link_type TEXT NOT NULL,
        created_at TEXT NOT NULL
    );
    CREATE INDEX work_link_owner ON work_link(owner_type, owner_id);

    CREATE TABLE week_plan (
        id TEXT PRIMARY KEY,
        week_start TEXT NOT NULL UNIQUE,
        revision INTEGER NOT NULL DEFAULT 1,
        confirmed_at TEXT
    );
    CREATE TABLE week_plan_item (
        id TEXT PRIMARY KEY,
        week_plan_id TEXT NOT NULL REFERENCES week_plan(id) ON DELETE CASCADE,
        task_id TEXT NOT NULL REFERENCES task(id),
        scope_type TEXT NOT NULL,
        scope_id TEXT,
        label TEXT,
        state TEXT NOT NULL,
        candidate_reason TEXT,
        confirmed_at TEXT
    );

    CREATE TABLE evidence_supplement (
        id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
        topic_key TEXT NOT NULL,
        question TEXT NOT NULL,
        answer TEXT,
        outcome TEXT NOT NULL,
        applies_start TEXT NOT NULL,
        applies_end_exclusive TEXT NOT NULL,
        source_digest TEXT NOT NULL,
        recorded_at TEXT NOT NULL
    );
    CREATE INDEX evidence_supplement_task ON evidence_supplement(task_id, topic_key);

    CREATE TABLE report_template (
        id TEXT PRIMARY KEY,
        purpose TEXT NOT NULL,
        name TEXT NOT NULL,
        active_version_id TEXT,
        archived_at TEXT
    );
    CREATE TABLE template_version (
        id TEXT PRIMARY KEY,
        template_id TEXT NOT NULL REFERENCES report_template(id),
        version INTEGER NOT NULL,
        instructions TEXT NOT NULL,
        output_example TEXT NOT NULL,
        skill_ref TEXT,
        created_at TEXT NOT NULL,
        UNIQUE(template_id, version)
    );

    CREATE TABLE evaluation_period (
        id TEXT PRIMARY KEY,
        start TEXT NOT NULL,
        end_exclusive TEXT NOT NULL,
        previous_period_id TEXT REFERENCES evaluation_period(id),
        confirmed_report_version_id TEXT,
        created_at TEXT NOT NULL
    );

    CREATE TABLE report (
        id TEXT PRIMARY KEY,
        family TEXT NOT NULL,
        period_type TEXT NOT NULL,
        period_key TEXT NOT NULL,
        start TEXT NOT NULL,
        end_exclusive TEXT NOT NULL,
        plan_start TEXT,
        plan_end_exclusive TEXT,
        evaluation_period_id TEXT REFERENCES evaluation_period(id),
        created_at TEXT NOT NULL,
        UNIQUE(family, period_type, period_key)
    );
    CREATE TABLE source_snapshot (
        id TEXT PRIMARY KEY,
        start TEXT NOT NULL,
        end_exclusive TEXT NOT NULL,
        state_cutoff TEXT NOT NULL,
        known_at TEXT NOT NULL,
        frozen_facts_json TEXT NOT NULL,
        digest TEXT NOT NULL,
        created_at TEXT NOT NULL
    );
    CREATE TABLE report_version (
        id TEXT PRIMARY KEY,
        report_id TEXT NOT NULL REFERENCES report(id),
        version INTEGER NOT NULL,
        state TEXT NOT NULL,
        content TEXT NOT NULL,
        structured_json TEXT,
        source_snapshot_id TEXT NOT NULL REFERENCES source_snapshot(id),
        template_version_id TEXT,
        skill_ref TEXT,
        ai_model TEXT,
        generator TEXT NOT NULL,
        warnings_json TEXT NOT NULL DEFAULT '[]',
        based_on_version_id TEXT,
        created_at TEXT NOT NULL,
        confirmed_at TEXT,
        UNIQUE(report_id, version)
    );
    -- 확정본 불변 보호: confirmed 행의 본문·상태 변경과 삭제를 DB 수준에서 막는다.
    CREATE TRIGGER report_version_confirmed_immutable
    BEFORE UPDATE ON report_version
    WHEN OLD.state = 'confirmed' AND (NEW.content IS NOT OLD.content OR NEW.state IS NOT OLD.state
        OR NEW.structured_json IS NOT OLD.structured_json OR NEW.source_snapshot_id IS NOT OLD.source_snapshot_id)
    BEGIN SELECT RAISE(ABORT, 'confirmed report version is immutable'); END;
    CREATE TRIGGER report_version_confirmed_nodelete
    BEFORE DELETE ON report_version WHEN OLD.state = 'confirmed'
    BEGIN SELECT RAISE(ABORT, 'confirmed report version is immutable'); END;

    CREATE TABLE report_evidence (
        report_version_id TEXT NOT NULL REFERENCES report_version(id),
        item_id TEXT NOT NULL,
        task_id TEXT,
        source_id TEXT NOT NULL,
        source_revision INTEGER NOT NULL,
        PRIMARY KEY (report_version_id, item_id, source_id)
    );

    CREATE TABLE ai_job (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        idempotency_key TEXT NOT NULL UNIQUE,
        input_digest TEXT NOT NULL,
        status TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        last_error_class TEXT,
        result_json TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );

    CREATE TABLE scheduled_job (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        period_key TEXT NOT NULL,
        scheduled_for TEXT NOT NULL,
        state TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        last_attempt_at TEXT,
        recovered_late INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        UNIQUE(type, period_key)
    );

    -- 일반 원문 검색 인덱스 (재생성 가능). Secret 자료형은 절대 넣지 않는다.
    -- source_type: memo | task | activity | report
    CREATE TABLE search_doc (
        source_type TEXT NOT NULL,
        source_id TEXT NOT NULL,
        task_id TEXT,
        work_date TEXT,
        text TEXT NOT NULL,
        PRIMARY KEY (source_type, source_id)
    );
    """
}
