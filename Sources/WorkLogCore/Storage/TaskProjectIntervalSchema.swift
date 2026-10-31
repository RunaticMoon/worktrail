import Foundation

/// Task↔프로젝트 연결의 [linked_on, removed_on) 구간 이력.
///
/// v13 이전에는 `task_project` 행 하나에 연결 구간 하나만 저장했다. 재연결은 기존 행을 되살리며
/// `linked_on`을 덮어썼기 때문에, 그 사이의 미연결 기간은 이미 지워져 복구할 수 없다.
/// 따라서 backfill은 각 행에 저장된 구간 하나만 그대로 복사하며, 없던 이력을 만들어 내지 않는다.
enum TaskProjectIntervalSchema {
    static let v13 = """
    CREATE TABLE task_project_interval (
        id TEXT PRIMARY KEY,
        task_project_id TEXT NOT NULL REFERENCES task_project(id) ON DELETE CASCADE,
        linked_on TEXT NOT NULL,
        removed_on TEXT
    );
    CREATE INDEX task_project_interval_link ON task_project_interval(task_project_id, linked_on);
    CREATE UNIQUE INDEX task_project_interval_open ON task_project_interval(task_project_id) WHERE removed_on IS NULL;
    INSERT INTO task_project_interval (id, task_project_id, linked_on, removed_on)
        SELECT id || ':v13', id, linked_on, removed_on FROM task_project;
    """
}

/// 한 번의 연결 구간. 끝(`removed_on`)은 제외한다.
public struct TaskProjectInterval: Equatable, Hashable, Sendable {
    public var id: String
    public var taskProjectId: String
    public var linkedOn: WorkDate
    public var removedOn: WorkDate?

    public init(id: String, taskProjectId: String, linkedOn: WorkDate, removedOn: WorkDate?) {
        self.id = id
        self.taskProjectId = taskProjectId
        self.linkedOn = linkedOn
        self.removedOn = removedOn
    }

    /// 일 종료 시점 기준 포함 여부. 기존 규칙과 같다: linkedOn <= date < removedOn.
    public func isActive(on date: WorkDate) -> Bool {
        linkedOn <= date && (removedOn.map { date < $0 } ?? true)
    }
}

extension WorkRepository {

    /// 한 task_project 행의 연결 구간을 시간순으로 돌려준다.
    public func taskProjectIntervals(taskProjectId: String) throws -> [TaskProjectInterval] {
        try db.queryV("""
            SELECT * FROM task_project_interval WHERE task_project_id = ?
            ORDER BY linked_on ASC, id ASC
            """, taskProjectId).map { try taskProjectIntervalRow($0) }
    }

    /// `date`가 끝나는 시점에 연결되어 있던 task_project 행.
    /// 과거에만 연결되어 있던(현재는 해제된) 행도 포함한다.
    public func taskProjects(taskId: String, activeOn date: WorkDate) throws -> [TaskProject] {
        try db.queryV("""
            SELECT * FROM task_project tp
            WHERE tp.task_id = ?
              AND EXISTS (
                  SELECT 1 FROM task_project_interval i
                  WHERE i.task_project_id = tp.id
                    AND i.linked_on <= ?
                    AND (i.removed_on IS NULL OR i.removed_on > ?)
              )
            ORDER BY tp.linked_on ASC, tp.id ASC
            """, taskId, date, date).map { try taskProjectRow($0) }
    }

    /// 열린 구간이 없으면 마지막 구간을 다시 열거나 새 구간을 연다.
    /// 호출자의 transaction 안에서 동작하며 자체 transaction을 열지 않는다.
    func openTaskProjectInterval(taskProjectId: String, on date: WorkDate) throws {
        if try db.queryOneV("""
            SELECT 1 AS x FROM task_project_interval
            WHERE task_project_id = ? AND removed_on IS NULL
            """, taskProjectId) != nil {
            return
        }
        // 열린 구간이 없으므로 모든 구간의 removed_on은 NOT NULL이다. 가장 늦게 닫힌 구간을 본다.
        if let last = try db.queryOneV("""
            SELECT * FROM task_project_interval
            WHERE task_project_id = ? AND removed_on IS NOT NULL
            ORDER BY removed_on DESC, id DESC LIMIT 1
            """, taskProjectId),
           let lastId = last.string("id"),
           let lastRemovedOn = last.workDate("removed_on"),
           lastRemovedOn >= date {
            // 해제일 당일이나 그 이전 날짜로 재연결: 마지막 구간을 다시 열되 기록된 이력은 고쳐 쓰지 않는다.
            // 시작일을 앞으로 당기지 않으므로(linked_on 유지) 구간이 겹치지 않고, 그 사이 미연결 기간도 남는다.
            try db.runV("""
                UPDATE task_project_interval SET removed_on = NULL WHERE id = ?
                """, lastId)
            return
        }
        try db.runV("""
            INSERT INTO task_project_interval (id, task_project_id, linked_on, removed_on)
            VALUES (?, ?, ?, NULL)
            """, ids.make(), taskProjectId, date)
    }

    /// 열린 구간을 닫는다. 열린 구간이 없으면 아무것도 하지 않는다.
    func closeTaskProjectInterval(taskProjectId: String, on date: WorkDate) throws {
        try db.runV("""
            UPDATE task_project_interval SET removed_on = ?
            WHERE task_project_id = ? AND removed_on IS NULL
            """, date, taskProjectId)
    }

    private func taskProjectIntervalRow(_ row: SQLRow) throws -> TaskProjectInterval {
        guard let id = row.string("id"), let taskProjectId = row.string("task_project_id"),
              let linkedOn = row.workDate("linked_on") else {
            throw WorkLogError.storage("task_project_interval row 손상")
        }
        return TaskProjectInterval(id: id, taskProjectId: taskProjectId, linkedOn: linkedOn,
                                   removedOn: row.workDate("removed_on"))
    }
}
