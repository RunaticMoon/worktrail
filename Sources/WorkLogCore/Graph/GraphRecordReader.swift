import Foundation

/// work.sqlite의 일반 기록(memo/task/activity)과 기존 관계를 그래프 DTO로 변환하는 읽기 전용 리더.
///
/// - work.sqlite의 일반 테이블만 읽는다. Secret(Vault) 테이블에는 접근하지 않는다.
/// - v4 `record_link`(수동 관련 연결)는 이 리더의 범위가 아니다(`RecordLinkStore`/`GraphService` 담당).
/// - 모든 SQL은 고정 문자열 + `?` 바인딩이며 값을 문자열로 결합하지 않는다.
public struct GraphRecordReader {
    private let repo: WorkRepository

    public init(repo: WorkRepository) {
        self.repo = repo
    }

    /// 일반 기록과 기존 관계를 노드·엣지로 읽는다.
    ///
    /// `range`가 있으면 `work_date`가 범위에 드는 memo/activity와,
    /// 범위 안에 활동이 있거나 범위 안에 생성된 task를 포함한다. nil이면 전체를 읽는다.
    /// 결과는 노드를 `id.key`, 엣지를 `key`로 정렬해 반환한다.
    public func read(range: DateRange?) throws -> (nodes: [GraphNode], edges: [GraphEdge]) {
        let memos = try readMemos(range: range)
        let tasks = try readTasks(range: range)
        let activities = try readActivities(range: range)

        var nodeMap: [GraphNodeID: GraphNode] = [:]
        for memo in memos {
            let id = GraphNodeID(kind: .memo, id: memo.id)
            nodeMap[id] = GraphNode(id: id, title: Self.title(from: memo.body),
                                    record: RecordReference(kind: .memo, id: memo.id),
                                    date: memo.workDate)
        }

        let taskByID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for task in tasks {
            let id = GraphNodeID(kind: .task, id: task.id)
            nodeMap[id] = GraphNode(id: id, title: task.title,
                                    record: RecordReference(kind: .task, id: task.id),
                                    date: repo.calendar.workDate(of: task.createdAt))
        }
        for activity in activities {
            let id = GraphNodeID(kind: .activity, id: activity.id)
            nodeMap[id] = GraphNode(id: id, title: Self.title(from: activity.body),
                                    subtitle: taskByID[activity.taskId]?.title,
                                    record: RecordReference(kind: .activity, id: activity.id),
                                    date: activity.workDate)
        }

        var edgeMap: [String: GraphEdge] = [:]
        func add(_ edge: GraphEdge) { edgeMap[edge.key] = edge }

        // activity → task (직접 관계). task 노드가 없으면 엣지를 만들지 않는다.
        for activity in activities where taskByID[activity.taskId] != nil {
            add(GraphEdge(from: GraphNodeID(kind: .activity, id: activity.id),
                          to: GraphNodeID(kind: .task, id: activity.taskId),
                          kind: .activityTask,
                          sourceKey: "activity:\(activity.id)",
                          isDirected: true))
        }

        // memo → task 승인 연결만. 두 끝점 노드가 모두 있을 때만 만든다.
        for link in try readAcceptedMemoTaskLinks() {
            guard nodeMap[GraphNodeID(kind: .memo, id: link.memoId)] != nil,
                  nodeMap[GraphNodeID(kind: .task, id: link.taskId)] != nil else { continue }
            add(GraphEdge(from: GraphNodeID(kind: .memo, id: link.memoId),
                          to: GraphNodeID(kind: .task, id: link.taskId),
                          kind: .acceptedMemoTask,
                          sourceKey: "memo_task_link:\(link.id)",
                          isDirected: true))
        }

        // task → task. 기존 from→to 방향과 유형을 보존한다.
        for relation in try readTaskRelations() {
            guard taskByID[relation.fromTaskId] != nil, taskByID[relation.toTaskId] != nil else { continue }
            add(GraphEdge(from: GraphNodeID(kind: .task, id: relation.fromTaskId),
                          to: GraphNodeID(kind: .task, id: relation.toTaskId),
                          kind: relation.type == .followUp ? .taskFollowUp : .taskRelated,
                          sourceKey: "task_relation:\(relation.id)",
                          isDirected: true))
        }

        // supplement → task. 대상 task가 결과에 포함된 보충만 읽는다.
        for supplement in try readSupplements(taskIds: Set(tasks.map { $0.id })) {
            let from = GraphNodeID(kind: .supplement, id: supplement.id)
            nodeMap[from] = GraphNode(id: from, title: Self.title(from: supplement.question),
                                      subtitle: supplement.answer, record: nil,
                                      date: supplement.appliesStart)
            add(GraphEdge(from: from,
                          to: GraphNodeID(kind: .task, id: supplement.taskId),
                          kind: .supplementTask,
                          sourceKey: "evidence_supplement:\(supplement.id)",
                          isDirected: true))
        }

        // 프로젝트·태그 소속. 공유 태그·프로젝트를 경유할 뿐 기록-기록 직접 엣지는 만들지 않는다.
        let memberships = try readMemberships(memos: memos, tasks: tasks, activities: activities)
        try addMembershipNodes(memberships: memberships, nodeMap: &nodeMap)
        for membership in memberships {
            let to = GraphNodeID(kind: membership.nodeKind, id: membership.nodeId)
            guard nodeMap[to] != nil else { continue }
            add(GraphEdge(from: GraphNodeID(kind: membership.recordKind, id: membership.recordId),
                          to: to, kind: membership.edgeKind,
                          sourceKey: membership.sourceKey, isDirected: true))
        }

        // 엣지 양끝이 모두 노드에 존재하도록 정리하고 결정적으로 정렬한다.
        let nodeKeys = Set(nodeMap.keys)
        let nodes = nodeMap.values.sorted { $0.id.key < $1.id.key }
        let edges = edgeMap.values
            .filter { nodeKeys.contains($0.from) && nodeKeys.contains($0.to) }
            .sorted { $0.key < $1.key }
        return (nodes, edges)
    }

    // MARK: - 읽기

    private func readMemos(range: DateRange?) throws -> [MemoEntry] {
        let rows: [SQLRow]
        if let range {
            rows = try repo.db.query("""
                SELECT id, body, work_date FROM memo
                WHERE deleted_at IS NULL AND work_date >= ? AND work_date < ?
                ORDER BY work_date ASC, id ASC
                """, [range.start, range.endExclusive])
        } else {
            rows = try repo.db.query("""
                SELECT id, body, work_date FROM memo
                WHERE deleted_at IS NULL
                ORDER BY work_date ASC, id ASC
                """)
        }
        return try rows.map { row in
            guard let id = row.string("id"), let body = row.string("body"),
                  let workDate = row.workDate("work_date") else {
                throw WorkLogError.storage("memo row 손상")
            }
            return MemoEntry(id: id, body: body, workDate: workDate)
        }
    }

    private func readActivities(range: DateRange?) throws -> [ActivityEntry] {
        let rows: [SQLRow]
        if let range {
            rows = try repo.db.query("""
                SELECT id, task_id, body, work_date FROM activity
                WHERE deleted_at IS NULL AND work_date >= ? AND work_date < ?
                ORDER BY work_date ASC, id ASC
                """, [range.start, range.endExclusive])
        } else {
            rows = try repo.db.query("""
                SELECT id, task_id, body, work_date FROM activity
                WHERE deleted_at IS NULL
                ORDER BY work_date ASC, id ASC
                """)
        }
        return try rows.map { row in
            guard let id = row.string("id"), let taskId = row.string("task_id"),
                  let body = row.string("body"), let workDate = row.workDate("work_date") else {
                throw WorkLogError.storage("activity row 손상")
            }
            return ActivityEntry(id: id, taskId: taskId, body: body, workDate: workDate)
        }
    }

    /// 삭제되지 않은 모든 task 중, 범위 안에 생성되었거나 범위 안에 활동이 있는 task.
    private func readTasks(range: DateRange?) throws -> [WorkTask] {
        let all = try repo.tasks()
        guard let range else { return all }
        let activeTaskIds = try taskIDsWithActivity(in: range)
        return all.filter { task in
            range.contains(repo.calendar.workDate(of: task.createdAt)) || activeTaskIds.contains(task.id)
        }
    }

    private func taskIDsWithActivity(in range: DateRange) throws -> Set<String> {
        let rows = try repo.db.query("""
            SELECT DISTINCT task_id FROM activity
            WHERE deleted_at IS NULL AND work_date >= ? AND work_date < ?
            """, [range.start, range.endExclusive])
        return Set(rows.compactMap { $0.string("task_id") })
    }

    private func readAcceptedMemoTaskLinks() throws -> [AcceptedLink] {
        try repo.db.query("""
            SELECT id, memo_id, task_id FROM memo_task_link
            WHERE status = ?
            ORDER BY created_at ASC, id ASC
            """, [MemoTaskLinkStatus.accepted.rawValue]).compactMap { row in
            guard let id = row.string("id"), let memoId = row.string("memo_id"),
                  let taskId = row.string("task_id") else { return nil }
            return AcceptedLink(id: id, memoId: memoId, taskId: taskId)
        }
    }

    private func readTaskRelations() throws -> [RelationEntry] {
        try repo.db.query("""
            SELECT id, from_task_id, to_task_id, relation_type FROM task_relation
            ORDER BY created_at ASC, id ASC
            """).compactMap { row in
            guard let id = row.string("id"), let from = row.string("from_task_id"),
                  let to = row.string("to_task_id"), let raw = row.string("relation_type"),
                  let type = TaskRelationType(rawValue: raw) else { return nil }
            return RelationEntry(id: id, fromTaskId: from, toTaskId: to, type: type)
        }
    }

    private func readSupplements(taskIds: Set<String>) throws -> [SupplementEntry] {
        try repo.db.query("""
            SELECT id, task_id, question, answer, applies_start FROM evidence_supplement
            ORDER BY applies_start ASC, id ASC
            """).compactMap { row in
            guard let id = row.string("id"), let taskId = row.string("task_id"),
                  let question = row.string("question"),
                  let appliesStart = row.workDate("applies_start"),
                  taskIds.contains(taskId) else { return nil }
            return SupplementEntry(id: id, taskId: taskId, question: question,
                                   answer: row.string("answer"), appliesStart: appliesStart)
        }
    }

    // MARK: - 소속 관계

    private func readMemberships(memos: [MemoEntry], tasks: [WorkTask],
                                 activities: [ActivityEntry]) throws -> [Membership] {
        let memoIds = Set(memos.map(\.id))
        let taskIds = Set(tasks.map(\.id))
        let activityIds = Set(activities.map(\.id))

        var result: [Membership] = []
        result += try loadMemberships(
            sql: "SELECT memo_id AS record_id, project_id AS node_id FROM memo_project ORDER BY memo_id ASC, project_id ASC",
            allowed: memoIds, recordKind: .memo, nodeKind: .project,
            edgeKind: .projectMembership, sourceTable: "memo_project")
        result += try loadMemberships(
            sql: "SELECT memo_id AS record_id, tag_id AS node_id FROM memo_tag ORDER BY memo_id ASC, tag_id ASC",
            allowed: memoIds, recordKind: .memo, nodeKind: .tag,
            edgeKind: .tagMembership, sourceTable: "memo_tag")
        result += try loadMemberships(
            sql: "SELECT activity_id AS record_id, project_id AS node_id FROM activity_project ORDER BY activity_id ASC, project_id ASC",
            allowed: activityIds, recordKind: .activity, nodeKind: .project,
            edgeKind: .projectMembership, sourceTable: "activity_project")
        result += try loadMemberships(
            sql: "SELECT task_id AS record_id, project_id AS node_id FROM task_project WHERE removed_on IS NULL ORDER BY task_id ASC, project_id ASC",
            allowed: taskIds, recordKind: .task, nodeKind: .project,
            edgeKind: .projectMembership, sourceTable: "task_project")
        result += try loadMemberships(
            sql: "SELECT task_id AS record_id, tag_id AS node_id FROM task_tag ORDER BY task_id ASC, tag_id ASC",
            allowed: taskIds, recordKind: .task, nodeKind: .tag,
            edgeKind: .tagMembership, sourceTable: "task_tag")
        return result
    }

    private func loadMemberships(sql: String, allowed: Set<String>, recordKind: GraphNodeKind,
                                 nodeKind: GraphNodeKind, edgeKind: GraphEdgeKind,
                                 sourceTable: String) throws -> [Membership] {
        try repo.db.query(sql).compactMap { row in
            guard let recordId = row.string("record_id"), let nodeId = row.string("node_id"),
                  allowed.contains(recordId) else { return nil }
            return Membership(recordKind: recordKind, recordId: recordId, nodeKind: nodeKind,
                              nodeId: nodeId, edgeKind: edgeKind,
                              sourceKey: "\(sourceTable):\(recordId):\(nodeId)")
        }
    }

    /// 참조된 프로젝트·태그만 노드로 만든다.
    private func addMembershipNodes(memberships: [Membership],
                                    nodeMap: inout [GraphNodeID: GraphNode]) throws {
        let projectIds = Set(memberships.filter { $0.nodeKind == .project }.map(\.nodeId))
        let tagIds = Set(memberships.filter { $0.nodeKind == .tag }.map(\.nodeId))
        if !projectIds.isEmpty {
            for project in try repo.projects(includeArchived: true) where projectIds.contains(project.id) {
                let id = GraphNodeID(kind: .project, id: project.id)
                nodeMap[id] = GraphNode(id: id, title: project.name)
            }
        }
        if !tagIds.isEmpty {
            for tag in try repo.tags() where tagIds.contains(tag.id) {
                let id = GraphNodeID(kind: .tag, id: tag.id)
                nodeMap[id] = GraphNode(id: id, title: tag.name)
            }
        }
    }

    // MARK: - 제목

    /// 본문 첫 번째 비어 있지 않은 줄의 앞 `maxLength`자. 없으면 빈 문자열.
    private static func title(from body: String, maxLength: Int = 40) -> String {
        let line = body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return line.count > maxLength ? String(line.prefix(maxLength)) : line
    }

    // MARK: - 내부 행 표현

    private struct MemoEntry {
        let id: String
        let body: String
        let workDate: WorkDate
    }

    private struct ActivityEntry {
        let id: String
        let taskId: String
        let body: String
        let workDate: WorkDate
    }

    private struct SupplementEntry {
        let id: String
        let taskId: String
        let question: String
        let answer: String?
        let appliesStart: WorkDate
    }

    private struct AcceptedLink {
        let id: String
        let memoId: String
        let taskId: String
    }

    private struct RelationEntry {
        let id: String
        let fromTaskId: String
        let toTaskId: String
        let type: TaskRelationType
    }

    private struct Membership {
        let recordKind: GraphNodeKind
        let recordId: String
        let nodeKind: GraphNodeKind
        let nodeId: String
        let edgeKind: GraphEdgeKind
        let sourceKey: String
    }
}
