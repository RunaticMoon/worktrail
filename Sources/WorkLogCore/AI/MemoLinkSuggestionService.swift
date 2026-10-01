import Foundation

// MEM-02: 회사 AI(AIJobRunner)가 Memo와 기존 Task의 연결을 제안하고,
// 사용자가 승인·거절·나중에를 결정한다.
//
// - AI 결과는 로컬 검증을 통과한 제안만 proposed로 저장한다.
// - 승인(decide)은 Task 생성·완료·Memo 이동을 일으키지 않는다.
// - Secret 타입·파일 경로·설정 값은 payload에 넣지 않는다(일반 기록만).
// - 실제 codex 실행은 없으며 테스트는 MockAIProvider를 쓴다.

/// P-05 결과 계약. AI가 반환한 검증 전 JSON.
public struct MemoTaskSuggestionOutput: Codable, Sendable, Hashable {
    public struct Suggestion: Codable, Sendable, Hashable {
        public var memoId: String
        public var taskId: String
        public var reason: String
        public var evidenceIds: [String]

        public init(memoId: String, taskId: String, reason: String, evidenceIds: [String]) {
            self.memoId = memoId; self.taskId = taskId; self.reason = reason; self.evidenceIds = evidenceIds
        }
    }

    public var schemaVersion: Int
    public var jobType: String
    public var suggestions: [Suggestion]

    public init(schemaVersion: Int, jobType: String, suggestions: [Suggestion]) {
        self.schemaVersion = schemaVersion; self.jobType = jobType; self.suggestions = suggestions
    }
}

/// suggest 결과. links는 이번 호출에서 새로 proposed로 저장된 것만 담는다.
public struct MemoLinkSuggestionResult: Sendable {
    public var links: [MemoTaskLink]
    /// AI 실패 시 failed/blockedAuth 등 그대로 전달한다(기록 저장은 막지 않는다).
    public var jobStatus: AIJobStatus
    /// 검증 탈락 사유(한국어).
    public var warnings: [String]

    public init(links: [MemoTaskLink], jobStatus: AIJobStatus, warnings: [String]) {
        self.links = links; self.jobStatus = jobStatus; self.warnings = warnings
    }
}

/// Memo ↔ Task 연결 제안 서비스.
public final class MemoLinkSuggestionService {
    private let repo: WorkRepository
    private let runner: AIJobRunner
    private let templates: TemplateStore
    private let maxCandidates: Int

    public init(repo: WorkRepository, runner: AIJobRunner, templates: TemplateStore, maxCandidates: Int = 30) {
        self.repo = repo
        self.runner = runner
        self.templates = templates
        self.maxCandidates = maxCandidates
    }

    // MARK: - 제안

    /// 후보 Task와 Memo로 payload를 만들어 runner.submit → 결과 검증 → 새 제안만 proposed 저장.
    public func suggest(memoId: String) async throws -> MemoLinkSuggestionResult {
        let memo = try requireMemo(memoId)
        let prepared = try prepare(memo: memo)
        let versionId = try resolveTemplateVersionId()
        let instructions = try templates.composeInstructions(versionId: versionId)

        let request = AIJobRequest(jobType: .memoTaskSuggestions,
                                   periodStart: nil, periodEndExclusive: nil,
                                   instructions: instructions,
                                   payloadJSON: prepared.payloadJSON,
                                   templateVersionId: versionId)
        let result = try await runner.submit(request)

        // 8) AI가 성공하지 않았으면 저장하지 않고 상태만 전달한다.
        guard result.job.status == .succeeded else {
            return MemoLinkSuggestionResult(links: [], jobStatus: result.job.status, warnings: [])
        }
        guard let output = result.output else {
            return MemoLinkSuggestionResult(links: [], jobStatus: result.job.status,
                                            warnings: ["AI 결과가 비어 있습니다."])
        }
        return try store(output: output.rawJSON, memo: memo, prepared: prepared, jobStatus: result.job.status)
    }

    /// accepted / rejected / deferred 결정. decidedAt=now.
    /// proposed 외 상태로의 변경만 허용(accepted→rejected 같은 재결정도 허용).
    /// Task·Memo는 변경하지 않는다.
    public func decide(linkId: String, status: MemoTaskLinkStatus) throws -> MemoTaskLink {
        guard status != .proposed else {
            throw WorkLogError.validation("제안 상태로 되돌릴 수 없습니다.")
        }
        guard var link = try memoTaskLink(id: linkId) else {
            throw WorkLogError.notFound("memo_task_link \(linkId)")
        }
        link.status = status
        link.decidedAt = repo.clock.now()
        try repo.upsertMemoTaskLink(link)
        return link
    }

    /// 테스트·미리보기용: payload JSON 생성(결정적, StableJSON).
    public func buildPayload(memoId: String) throws -> String {
        let memo = try requireMemo(memoId)
        return try prepare(memo: memo).payloadJSON
    }

    // MARK: - 내부: payload 준비

    /// payload 문자열과 검증에 쓸 후보 Task ID·근거 sourceId 집합.
    private struct Prepared {
        var payloadJSON: String
        var candidateTaskIds: Set<String>
        var evidenceSourceIds: Set<String>
    }

    private struct Candidate {
        var task: WorkTask
        var status: TaskStatus?
        /// 정렬용: 최근 활동 업무일, 활동이 없으면 Task 생성 시각의 업무일.
        var lastActivityOn: WorkDate
    }

    private struct MemoLinkPayload: Encodable {
        struct MemoPart: Encodable {
            var id: String
            var body: String
            var workDate: WorkDate
            var revision: Int
            var sourceId: String
        }
        struct ActivityPart: Encodable {
            var sourceId: String
            var workDate: WorkDate
            var text: String
        }
        struct TaskPart: Encodable {
            var id: String
            var title: String
            var status: String
            var recentActivities: [ActivityPart]
        }
        var jobType: String
        var memo: MemoPart
        var candidateTasks: [TaskPart]
    }

    private func prepare(memo: Memo) throws -> Prepared {
        let candidates = try candidateTasks()
        var sourceIds: Set<String> = ["memo:\(memo.id)"]
        var candidateIds: Set<String> = []
        var taskParts: [MemoLinkPayload.TaskPart] = []

        for candidate in candidates {
            candidateIds.insert(candidate.task.id)
            var activityParts: [MemoLinkPayload.ActivityPart] = []
            for activity in try recentActivities(taskId: candidate.task.id) {
                let sourceId = "activity:\(activity.id)"
                sourceIds.insert(sourceId)
                activityParts.append(MemoLinkPayload.ActivityPart(sourceId: sourceId,
                                                                  workDate: activity.workDate,
                                                                  text: activity.body))
            }
            taskParts.append(MemoLinkPayload.TaskPart(id: candidate.task.id,
                                                      title: candidate.task.title,
                                                      status: (candidate.status ?? .planned).rawValue,
                                                      recentActivities: activityParts))
        }

        let payload = MemoLinkPayload(
            jobType: AIJobType.memoTaskSuggestions.rawValue,
            memo: MemoLinkPayload.MemoPart(id: memo.id, body: memo.body, workDate: memo.workDate,
                                           revision: memo.revision, sourceId: "memo:\(memo.id)"),
            candidateTasks: taskParts)
        return Prepared(payloadJSON: try StableJSON.string(payload),
                        candidateTaskIds: candidateIds,
                        evidenceSourceIds: sourceIds)
    }

    /// 삭제되지 않았고 현재 상태가 cancelled가 아닌 Task. 최근 활동(업무일) 내림차순 → id 오름차순.
    private func candidateTasks() throws -> [Candidate] {
        let taskService = TaskService(repo: repo)
        var candidates: [Candidate] = []
        for task in try repo.tasks() {
            let status: TaskStatus?
            if let cached = task.cachedStatus {
                status = cached
            } else {
                status = (try? taskService.currentStatus(taskId: task.id)) ?? nil
            }
            if status == .cancelled { continue }
            let activities = try repo.activities(taskId: task.id)
            let lastActivityOn = activities.map { $0.workDate }.max()
                ?? repo.calendar.workDate(of: task.createdAt)
            candidates.append(Candidate(task: task, status: status, lastActivityOn: lastActivityOn))
        }
        candidates.sort { lhs, rhs in
            if lhs.lastActivityOn != rhs.lastActivityOn { return lhs.lastActivityOn > rhs.lastActivityOn }
            return lhs.task.id < rhs.task.id
        }
        return Array(candidates.prefix(maxCandidates))
    }

    /// Task당 최근 3개. 업무일·기록시각·id 내림차순(최근 우선).
    private func recentActivities(taskId: String) throws -> [Activity] {
        let activities = try repo.activities(taskId: taskId)
        let sorted = activities.sorted { lhs, rhs in
            if lhs.workDate != rhs.workDate { return lhs.workDate > rhs.workDate }
            if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt > rhs.recordedAt }
            return lhs.id > rhs.id
        }
        return Array(sorted.prefix(3))
    }

    // MARK: - 내부: 템플릿

    private func resolveTemplateVersionId() throws -> String {
        if let template = try templates.preferredTemplate(for: .memoTaskLinks),
           let version = try templates.activeVersion(templateId: template.id) {
            return version.id
        }
        // 템플릿이 없으면 기본값을 시드한 뒤 재시도한다.
        try templates.seedDefaults()
        guard let template = try templates.preferredTemplate(for: .memoTaskLinks),
              let version = try templates.activeVersion(templateId: template.id) else {
            throw WorkLogError.notFound("memo_task_links 템플릿")
        }
        return version.id
    }

    // MARK: - 내부: 결과 검증·저장

    private func store(output: String, memo: Memo, prepared: Prepared,
                       jobStatus: AIJobStatus) throws -> MemoLinkSuggestionResult {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded: MemoTaskSuggestionOutput
        do {
            decoded = try StableJSON.decode(MemoTaskSuggestionOutput.self, from: trimmed)
        } catch {
            return MemoLinkSuggestionResult(links: [], jobStatus: jobStatus, warnings: ["AI 결과 형식 오류"])
        }
        guard decoded.schemaVersion == 1,
              decoded.jobType == AIJobType.memoTaskSuggestions.rawValue else {
            return MemoLinkSuggestionResult(links: [], jobStatus: jobStatus,
                                            warnings: ["AI 결과 계약이 맞지 않아 전체를 무시했습니다."])
        }

        let existing = try repo.memoTaskLinks(memoId: memo.id)
        let now = repo.clock.now()
        var warnings: [String] = []
        var created: [MemoTaskLink] = []
        var seenTaskIds: Set<String> = []

        for suggestion in decoded.suggestions {
            guard suggestion.memoId == memo.id else {
                warnings.append("다른 Memo에 대한 제안을 무시했습니다.")
                continue
            }
            guard seenTaskIds.insert(suggestion.taskId).inserted else {
                warnings.append("같은 Task에 대한 중복 제안 중 첫 번째만 사용했습니다.")
                continue
            }
            guard prepared.candidateTaskIds.contains(suggestion.taskId) else {
                warnings.append("후보 Task가 아닌 제안을 무시했습니다.")
                continue
            }
            let reason = suggestion.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...300).contains(reason.count) else {
                warnings.append("제안 사유가 비어 있거나 너무 깁니다.")
                continue
            }
            guard Set(suggestion.evidenceIds).isSubset(of: prepared.evidenceSourceIds) else {
                warnings.append("근거 ID를 확인할 수 없는 제안을 무시했습니다.")
                continue
            }
            if shouldSkip(taskId: suggestion.taskId, existing: existing, memoRevision: memo.revision) {
                continue
            }

            let link = MemoTaskLink(id: repo.ids.make(), memoId: memo.id, taskId: suggestion.taskId,
                                    status: .proposed, reason: reason, sourceRevision: memo.revision,
                                    createdAt: now, decidedAt: nil)
            try repo.upsertMemoTaskLink(link)
            created.append(link)
        }
        return MemoLinkSuggestionResult(links: created, jobStatus: jobStatus, warnings: warnings)
    }

    /// 같은 (memoId, taskId)에 accepted/proposed/deferred가 있으면 새로 만들지 않는다.
    /// rejected이고 그 링크의 sourceRevision == 현재 revision이면(근거 변화 없음) 다시 제안하지 않는다.
    private func shouldSkip(taskId: String, existing: [MemoTaskLink], memoRevision: Int) -> Bool {
        for link in existing where link.taskId == taskId {
            switch link.status {
            case .accepted, .proposed, .deferred:
                return true
            case .rejected:
                if link.sourceRevision == memoRevision { return true }
            }
        }
        return false
    }

    // MARK: - 내부: 조회

    private func requireMemo(_ memoId: String) throws -> Memo {
        guard let memo = try repo.memo(id: memoId) else {
            throw WorkLogError.notFound("memo \(memoId)")
        }
        return memo
    }

    private func memoTaskLink(id linkId: String) throws -> MemoTaskLink? {
        guard let row = try repo.db.queryOne("SELECT * FROM memo_task_link WHERE id = ?",
                                             [linkId as SQLBindable]) else {
            return nil
        }
        guard let id = row.string("id"), let memoId = row.string("memo_id"),
              let taskId = row.string("task_id"),
              let statusRaw = row.string("status"),
              let status = MemoTaskLinkStatus(rawValue: statusRaw) else {
            throw WorkLogError.storage("memo_task_link row 손상")
        }
        return MemoTaskLink(id: id, memoId: memoId, taskId: taskId, status: status,
                            reason: row.string("reason") ?? "",
                            sourceRevision: row.int("source_revision") ?? 1,
                            createdAt: row.date("created_at") ?? Date(timeIntervalSince1970: 0),
                            decidedAt: row.date("decided_at"))
    }
}
