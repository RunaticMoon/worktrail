import Foundation

/// A local meeting's derived task stays protected even if the meeting is later
/// deleted or its policy changes. Ordinary local browsing remains available.
public struct TaskDisclosurePolicy {
    public let repo: WorkRepository
    public init(repo: WorkRepository) { self.repo = repo }

    public func protectedTaskIDs() throws -> Set<String> {
        Set(try repo.db.query("SELECT DISTINCT task_id FROM meeting_task_link WHERE local_only = 1").compactMap { $0.string("task_id") })
    }

    public func allows(_ type: SearchSourceType, sourceID: String) throws -> Bool {
        let protected = try protectedTaskIDs()
        guard !protected.isEmpty else { return true }
        switch type {
        case .task: return !protected.contains(sourceID)
        case .activity:
            return try repo.activity(id: sourceID).map { !protected.contains($0.taskId) } ?? false
        case .report:
            // Recheck frozen older reports too: linking an existing task must not
            // leave its previously generated report available to search AI.
            guard let row = try repo.db.queryOneV("SELECT ss.frozen_facts_json FROM report_version rv JOIN source_snapshot ss ON ss.id = rv.source_snapshot_id WHERE rv.id = ?", sourceID),
                  let json = row.string("frozen_facts_json"),
                  let facts = try? StableJSON.decode(ReportFacts.self, from: json) else { return false }
            return !facts.tasks.contains { protected.contains($0.id) }
                && !facts.sources.contains { $0.taskId.map(protected.contains) ?? false }
                && !facts.confirmedPlans.contains { protected.contains($0.taskId) }
                && !facts.memoLinksAccepted.contains { protected.contains($0.taskId) }
        case .memo, .github, .jira: return true
        }
    }

    /// Quiz callers may retain facts built before a task was protected. Validate
    /// again at the payload boundary rather than trusting that cached snapshot.
    public func requireDisclosable(_ facts: ReportFacts) throws {
        let protected = try protectedTaskIDs()
        guard !facts.tasks.contains(where: { protected.contains($0.id) }),
              !facts.sources.contains(where: { $0.taskId.map(protected.contains) ?? false }),
              !facts.confirmedPlans.contains(where: { protected.contains($0.taskId) }),
              !facts.memoLinksAccepted.contains(where: { protected.contains($0.taskId) }) else {
            throw WorkLogError.validation("로컬 전용 회의에서 연결한 업무가 포함되어 있습니다. 자료를 새로 불러온 후 다시 시도하세요.")
        }
    }
}
