import Foundation

// MARK: - 상태

/// Task·프로젝트 적용·체크리스트 공통 상태. 재개는 별도 상태가 아니라 사건이다.
public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case planned = "planned"          // 예정
    case inProgress = "in_progress"   // 진행
    case onHold = "on_hold"           // 보류
    case completed = "completed"      // 완료
    case cancelled = "cancelled"      // 취소

    public var koreanLabel: String {
        switch self {
        case .planned: return "예정"
        case .inProgress: return "진행"
        case .onHold: return "보류"
        case .completed: return "완료"
        case .cancelled: return "취소"
        }
    }
}

/// 단순 연결(shared) vs 프로젝트별 적용 상태 관리(per_project).
public enum ProjectTrackingMode: String, Codable, Sendable {
    case shared = "shared"
    case perProject = "per_project"
}

// MARK: - 원문 엔터티

public struct Project: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var archivedAt: Date?
    public init(id: String, name: String, archivedAt: Date? = nil) {
        self.id = id; self.name = name; self.archivedAt = archivedAt
    }
}

public struct Tag: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// 제목 없는 기록. 첫 줄은 미리보기일 뿐이다.
public struct Memo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var body: String
    public var workDate: WorkDate
    public var recordedAt: Date
    public var revision: Int
    public var deletedAt: Date?
    public var projectIds: [String]
    public var tagIds: [String]

    public init(id: String, body: String, workDate: WorkDate, recordedAt: Date, revision: Int = 1,
                deletedAt: Date? = nil, projectIds: [String] = [], tagIds: [String] = []) {
        self.id = id; self.body = body; self.workDate = workDate; self.recordedAt = recordedAt
        self.revision = revision; self.deletedAt = deletedAt; self.projectIds = projectIds; self.tagIds = tagIds
    }

    /// 첫 번째 비어 있지 않은 줄(최대 80자).
    public var preview: String {
        let line = body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return line.count > 80 ? String(line.prefix(80)) + "…" : line
    }
}

/// 전역 원본 Task. 상태는 이벤트 재생으로 계산하며 cachedStatus는 재생성 가능한 캐시다.
public struct WorkTask: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var dueOn: WorkDate?
    public var createdAt: Date
    public var projectTrackingMode: ProjectTrackingMode
    public var revision: Int
    public var deletedAt: Date?
    public var tagIds: [String]
    public var cachedStatus: TaskStatus?

    public init(id: String, title: String, dueOn: WorkDate? = nil, createdAt: Date,
                projectTrackingMode: ProjectTrackingMode = .shared, revision: Int = 1,
                deletedAt: Date? = nil, tagIds: [String] = [], cachedStatus: TaskStatus? = nil) {
        self.id = id; self.title = title; self.dueOn = dueOn; self.createdAt = createdAt
        self.projectTrackingMode = projectTrackingMode; self.revision = revision
        self.deletedAt = deletedAt; self.tagIds = tagIds; self.cachedStatus = cachedStatus
    }
}

/// Task ↔ 프로젝트 연결. scopeId는 "\(taskId)/\(projectId)".
public struct TaskProject: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var taskId: String
    public var projectId: String
    public var trackingEnabled: Bool
    public var linkedOn: WorkDate
    public var removedOn: WorkDate?

    public init(id: String, taskId: String, projectId: String, trackingEnabled: Bool,
                linkedOn: WorkDate, removedOn: WorkDate? = nil) {
        self.id = id; self.taskId = taskId; self.projectId = projectId
        self.trackingEnabled = trackingEnabled; self.linkedOn = linkedOn; self.removedOn = removedOn
    }

    public static func scopeId(taskId: String, projectId: String) -> String { "\(taskId)/\(projectId)" }
    public var scopeId: String { TaskProject.scopeId(taskId: taskId, projectId: projectId) }
}

/// 한 단계 하위 체크리스트. 완료 이력은 이벤트로 남긴다.
public struct ChecklistItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var taskId: String
    public var text: String
    public var sortOrder: Int
    public var projectIds: [String]
    public var deletedAt: Date?

    public init(id: String, taskId: String, text: String, sortOrder: Int,
                projectIds: [String] = [], deletedAt: Date? = nil) {
        self.id = id; self.taskId = taskId; self.text = text; self.sortOrder = sortOrder
        self.projectIds = projectIds; self.deletedAt = deletedAt
    }
}

public enum ActivityKind: String, Codable, Sendable {
    case progress = "progress"       // 진행 기록·한 일
    case note = "note"               // 확인한 사항
    case completion = "completion"   // 완료 기록 본문
}

/// 진행 기록. projectIds가 비어 있으면 Task 공통 기록이다. 활동 원본은 하나다.
public struct Activity: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var taskId: String
    public var body: String
    public var workDate: WorkDate
    public var recordedAt: Date
    public var kind: ActivityKind
    public var projectIds: [String]
    public var checklistItemIds: [String]
    public var revision: Int
    public var deletedAt: Date?

    public init(id: String, taskId: String, body: String, workDate: WorkDate, recordedAt: Date,
                kind: ActivityKind = .progress, projectIds: [String] = [], checklistItemIds: [String] = [],
                revision: Int = 1, deletedAt: Date? = nil) {
        self.id = id; self.taskId = taskId; self.body = body; self.workDate = workDate
        self.recordedAt = recordedAt; self.kind = kind; self.projectIds = projectIds
        self.checklistItemIds = checklistItemIds; self.revision = revision; self.deletedAt = deletedAt
    }
}

// MARK: - 상태 이력 (이벤트)

public enum EventScopeType: String, Codable, Sendable {
    case task = "task"                    // scopeId = taskId
    case taskProject = "task_project"     // scopeId = "taskId/projectId"
    case checklistItem = "checklist_item" // scopeId = checklistItemId
}

public enum DomainEventKind: String, Codable, Sendable {
    // 상태를 정하는 사건 (toStatus 필수)
    case created = "created"              // 최초 상태(예정/진행/완료 등) 지정
    case started = "started"              // → 진행
    case paused = "paused"                // → 보류
    case resumed = "resumed"              // 보류/취소 → 진행
    case completed = "completed"          // → 완료 (전체 Task는 사용자가 직접)
    case reopened = "reopened"            // 완료 → 진행 (이전 완료 사건 보존)
    case cancelled = "cancelled"          // → 취소
    case replanned = "replanned"          // 보류/취소 → 예정
    // 상태를 정하지 않는 사건
    case activityAdded = "activity_added"
    case projectLinked = "project_linked"
    case projectUnlinked = "project_unlinked"
    case evidenceAdded = "evidence_added"
    /// supersedesEventId가 가리키는 사건을 무효화하는 명시적 정정.
    case voided = "voided"

    public var isStatusEvent: Bool {
        switch self {
        case .created, .started, .paused, .resumed, .completed, .reopened, .cancelled, .replanned: return true
        default: return false
        }
    }
}

/// 상태 이력의 원본. 현재 상태는 MAX(recordedAt)가 아니라
/// (effectiveDate, effectiveOrder, recordedAt, id) 순서의 재생으로 계산한다.
public struct DomainEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var taskId: String
    public var scopeType: EventScopeType
    public var scopeId: String
    public var kind: DomainEventKind
    public var toStatus: TaskStatus?
    /// 실제 업무일(지역 달력)
    public var effectiveDate: WorkDate
    /// 사용자가 실제 시각을 아는 경우만. 날짜만 아는 사건에 시각을 만들지 않는다.
    public var effectiveTime: Date?
    /// 같은 업무일 안의 결정적 순서
    public var effectiveOrder: Int
    /// 앱이 기록을 받은 시각(UTC)
    public var recordedAt: Date
    public var supersedesEventId: String?
    public var note: String?
    /// 관련 활동 ID (activityAdded 등)
    public var activityId: String?

    public init(id: String, taskId: String, scopeType: EventScopeType, scopeId: String,
                kind: DomainEventKind, toStatus: TaskStatus? = nil, effectiveDate: WorkDate,
                effectiveTime: Date? = nil, effectiveOrder: Int, recordedAt: Date,
                supersedesEventId: String? = nil, note: String? = nil, activityId: String? = nil) {
        self.id = id; self.taskId = taskId; self.scopeType = scopeType; self.scopeId = scopeId
        self.kind = kind; self.toStatus = toStatus; self.effectiveDate = effectiveDate
        self.effectiveTime = effectiveTime; self.effectiveOrder = effectiveOrder
        self.recordedAt = recordedAt; self.supersedesEventId = supersedesEventId
        self.note = note; self.activityId = activityId
    }
}

// MARK: - 연결·링크

public enum MemoTaskLinkStatus: String, Codable, Sendable {
    case proposed, accepted, rejected, deferred
}

/// Memo ↔ Task 연결. 승인 전에는 근거로 쓰지 않는다. 승인이 Task 생성·완료를 유발하지 않는다.
public struct MemoTaskLink: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var memoId: String
    public var taskId: String
    public var status: MemoTaskLinkStatus
    public var reason: String
    public var sourceRevision: Int
    public var createdAt: Date
    public var decidedAt: Date?

    public init(id: String, memoId: String, taskId: String, status: MemoTaskLinkStatus, reason: String,
                sourceRevision: Int, createdAt: Date, decidedAt: Date? = nil) {
        self.id = id; self.memoId = memoId; self.taskId = taskId; self.status = status
        self.reason = reason; self.sourceRevision = sourceRevision; self.createdAt = createdAt
        self.decidedAt = decidedAt
    }
}

public enum TaskRelationType: String, Codable, Sendable {
    case followUp = "follow_up"
    case related = "related"
}

public struct TaskRelation: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var fromTaskId: String
    public var toTaskId: String
    public var type: TaskRelationType
    public var createdAt: Date
    public init(id: String, fromTaskId: String, toTaskId: String, type: TaskRelationType, createdAt: Date) {
        self.id = id; self.fromTaskId = fromTaskId; self.toTaskId = toTaskId; self.type = type
        self.createdAt = createdAt
    }
}

public enum LinkOwnerType: String, Codable, Sendable { case memo, task, activity }

public enum LinkType: String, Codable, Sendable {
    case githubPullRequest = "github_pr"
    case jiraIssue = "jira_issue"
    case generic = "generic"

    /// URL 모양으로 유형만 표시한다. 첫 버전은 내용을 가져오지 않는다.
    public static func classify(_ url: String) -> LinkType {
        let lower = url.lowercased()
        if lower.contains("/pull/") { return .githubPullRequest }
        if lower.contains("/browse/") && lower.range(of: #"[a-z][a-z0-9]+-\d+"#, options: .regularExpression) != nil {
            return .jiraIssue
        }
        return .generic
    }
}

/// URL 보관. 첫 버전은 저장·열기만 하며 fetch 하지 않는다.
public struct WorkLink: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var ownerType: LinkOwnerType
    public var ownerId: String
    public var url: String
    public var linkType: LinkType
    public var createdAt: Date
    public init(id: String, ownerType: LinkOwnerType, ownerId: String, url: String,
                linkType: LinkType, createdAt: Date) {
        self.id = id; self.ownerType = ownerType; self.ownerId = ownerId; self.url = url
        self.linkType = linkType; self.createdAt = createdAt
    }
}

// MARK: - 주간 계획

public enum PlanScopeType: String, Codable, Sendable {
    case wholeTask = "whole_task"         // scopeId = nil
    case taskProject = "task_project"     // scopeId = "taskId/projectId"
    case checklistItem = "checklist_item" // scopeId = checklistItemId
}

public enum PlanItemState: String, Codable, Sendable {
    case candidate, confirmed, excluded
}

/// 특정 주의 계획. 계획 포함은 착수·상태 변경이 아니다.
public struct WeekPlan: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var weekStart: WorkDate           // 월요일
    public var revision: Int
    public var confirmedAt: Date?
    public init(id: String, weekStart: WorkDate, revision: Int = 1, confirmedAt: Date? = nil) {
        self.id = id; self.weekStart = weekStart; self.revision = revision; self.confirmedAt = confirmedAt
    }
}

public struct WeekPlanItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var weekPlanId: String
    public var taskId: String
    public var scopeType: PlanScopeType
    public var scopeId: String?
    /// 사용자가 적은 세부 계획 문구
    public var label: String?
    public var state: PlanItemState
    /// 후보 제안 사유 (지난주 미완료, 이번 주 마감 등)
    public var candidateReason: String?
    public var confirmedAt: Date?

    public init(id: String, weekPlanId: String, taskId: String, scopeType: PlanScopeType,
                scopeId: String? = nil, label: String? = nil, state: PlanItemState,
                candidateReason: String? = nil, confirmedAt: Date? = nil) {
        self.id = id; self.weekPlanId = weekPlanId; self.taskId = taskId; self.scopeType = scopeType
        self.scopeId = scopeId; self.label = label; self.state = state
        self.candidateReason = candidateReason; self.confirmedAt = confirmedAt
    }
}

// MARK: - 성과 보충

public enum SupplementOutcome: String, Codable, Sendable {
    case answered = "answered"
    case noResult = "no_result"   // 확인한 결과 없음
    case later = "later"          // 나중에
    case excluded = "excluded"    // 이 질문 제외
}

/// 성과 보충 답변. recordedAt(입력한 날)과 적용 기간(설명 대상)을 분리한다.
/// 입력한 날의 새 실적으로 집계하지 않는다.
public struct EvidenceSupplement: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var taskId: String
    public var topicKey: String
    public var question: String
    public var answer: String?
    public var outcome: SupplementOutcome
    public var applies: DateRange
    public var sourceDigest: String
    public var recordedAt: Date

    public init(id: String, taskId: String, topicKey: String, question: String, answer: String?,
                outcome: SupplementOutcome, applies: DateRange, sourceDigest: String, recordedAt: Date) {
        self.id = id; self.taskId = taskId; self.topicKey = topicKey; self.question = question
        self.answer = answer; self.outcome = outcome; self.applies = applies
        self.sourceDigest = sourceDigest; self.recordedAt = recordedAt
    }
}

// MARK: - 템플릿

public enum TemplatePurpose: String, Codable, Sendable, CaseIterable {
    case submissionWeekly = "submission_weekly"
    case performanceDaily = "performance_daily"
    case performancePeriodic = "performance_periodic"
    case evidenceQuiz = "evidence_quiz"
    case memoTaskLinks = "memo_task_links"
    case queryPlan = "query_plan"
    case groundedAnswer = "grounded_answer"
}

public struct ReportTemplate: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var purpose: TemplatePurpose
    public var name: String
    public var activeVersionId: String?
    public var archivedAt: Date?
    public init(id: String, purpose: TemplatePurpose, name: String, activeVersionId: String? = nil,
                archivedAt: Date? = nil) {
        self.id = id; self.purpose = purpose; self.name = name
        self.activeVersionId = activeVersionId; self.archivedAt = archivedAt
    }
}

/// 템플릿 버전은 불변이다. 수정은 새 버전, 팀 변경은 복제.
public struct TemplateVersion: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var templateId: String
    public var version: Int
    public var instructions: String
    public var outputExample: String
    /// 선택한 Codex 스킬 식별자 (없으면 앱 기본 지침)
    public var skillRef: String?
    public var createdAt: Date
    public init(id: String, templateId: String, version: Int, instructions: String,
                outputExample: String, skillRef: String? = nil, createdAt: Date) {
        self.id = id; self.templateId = templateId; self.version = version
        self.instructions = instructions; self.outputExample = outputExample
        self.skillRef = skillRef; self.createdAt = createdAt
    }
}

// MARK: - 리포트

/// 제출용 주간보고(submission)와 성과 리포트(performance)는 다른 family다. 절대 합치지 않는다.
public enum ReportFamily: String, Codable, Sendable {
    case submission = "submission"
    case performance = "performance"
}

public enum PeriodType: String, Codable, Sendable, CaseIterable {
    case daily, weekly, monthly, quarterly, yearly
}

public struct Report: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var family: ReportFamily
    public var periodType: PeriodType
    /// 예: "2026-10-05", "2026-W40", "2026-10", "2026-Q4", 평가 기간 ID
    public var periodKey: String
    public var range: DateRange
    /// 제출용만: 이번 주 계획 구간
    public var planRange: DateRange?
    public var evaluationPeriodId: String?
    public var createdAt: Date

    public init(id: String, family: ReportFamily, periodType: PeriodType, periodKey: String,
                range: DateRange, planRange: DateRange? = nil, evaluationPeriodId: String? = nil,
                createdAt: Date) {
        self.id = id; self.family = family; self.periodType = periodType; self.periodKey = periodKey
        self.range = range; self.planRange = planRange; self.evaluationPeriodId = evaluationPeriodId
        self.createdAt = createdAt
    }
}

public enum ReportVersionState: String, Codable, Sendable {
    case draft = "draft"         // 자동/AI 생성 초안
    case edited = "edited"       // 사용자가 수정한 초안 (자동으로 덮어쓰지 않음)
    case confirmed = "confirmed" // 확정본 (불변)
    case superseded = "superseded"
}

public struct ReportVersion: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var reportId: String
    public var version: Int
    public var state: ReportVersionState
    /// 사용자에게 보이는 본문(제출용 plain text 또는 상세 리포트 텍스트)
    public var content: String
    /// 구조화된 결과 JSON (AI 결과 계약 또는 결정적 렌더러 출력)
    public var structuredJSON: String?
    public var sourceSnapshotId: String
    public var templateVersionId: String?
    public var skillRef: String?
    public var aiModel: String?
    /// "deterministic" | "mock" | "codex"
    public var generator: String
    public var warnings: [String]
    public var basedOnVersionId: String?
    public var createdAt: Date
    public var confirmedAt: Date?

    public init(id: String, reportId: String, version: Int, state: ReportVersionState, content: String,
                structuredJSON: String? = nil, sourceSnapshotId: String, templateVersionId: String? = nil,
                skillRef: String? = nil, aiModel: String? = nil, generator: String,
                warnings: [String] = [], basedOnVersionId: String? = nil, createdAt: Date,
                confirmedAt: Date? = nil) {
        self.id = id; self.reportId = reportId; self.version = version; self.state = state
        self.content = content; self.structuredJSON = structuredJSON; self.sourceSnapshotId = sourceSnapshotId
        self.templateVersionId = templateVersionId; self.skillRef = skillRef; self.aiModel = aiModel
        self.generator = generator; self.warnings = warnings; self.basedOnVersionId = basedOnVersionId
        self.createdAt = createdAt; self.confirmedAt = confirmedAt
    }
}

/// 리포트 생성에 사용한 원본의 고정 사본. 확정본은 이 snapshot으로 재현 가능하다.
public struct SourceSnapshot: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var range: DateRange
    /// 상태 기준 시점(그때 알던 정보). 예: 일요일 종료 = 월요일 00:00 KST.
    public var stateCutoff: Date
    /// knownAt: 이 시각까지 기록된 원본만 사용
    public var knownAt: Date
    /// 고정된 사실 JSON (ReportFacts 직렬화)
    public var frozenFactsJSON: String
    public var digest: String
    public var createdAt: Date

    public init(id: String, range: DateRange, stateCutoff: Date, knownAt: Date,
                frozenFactsJSON: String, digest: String, createdAt: Date) {
        self.id = id; self.range = range; self.stateCutoff = stateCutoff; self.knownAt = knownAt
        self.frozenFactsJSON = frozenFactsJSON; self.digest = digest; self.createdAt = createdAt
    }
}

/// 연간 평가 기간. 기간 ID와 리포트 버전 ID는 분리한다.
public struct EvaluationPeriod: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var range: DateRange
    public var previousPeriodId: String?
    public var confirmedReportVersionId: String?
    public var createdAt: Date
    public init(id: String, range: DateRange, previousPeriodId: String? = nil,
                confirmedReportVersionId: String? = nil, createdAt: Date) {
        self.id = id; self.range = range; self.previousPeriodId = previousPeriodId
        self.confirmedReportVersionId = confirmedReportVersionId; self.createdAt = createdAt
    }
}

// MARK: - AI 작업·스케줄

public enum AIJobStatus: String, Codable, Sendable {
    case queued, running, succeeded, failed
    case blockedAuth = "blocked_auth"
    case blockedPolicy = "blocked_policy"
    case cancelled
}

public enum AIErrorClass: String, Codable, Sendable, Equatable {
    case notInstalled = "not_installed"
    case notLoggedIn = "not_logged_in"
    case authExpired = "auth_expired"
    case policyRestricted = "policy_restricted"
    case rateLimited = "rate_limited"
    case network = "network"
    case protocolMismatch = "protocol_mismatch"
    case outputInvalid = "output_invalid"
    case cancelled = "cancelled"
    case timeout = "timeout"
    case unknown = "unknown"
}

public struct AIJob: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var type: String
    public var idempotencyKey: String
    public var inputDigest: String
    public var status: AIJobStatus
    public var attempts: Int
    public var lastErrorClass: AIErrorClass?
    public var resultJSON: String?
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: String, type: String, idempotencyKey: String, inputDigest: String,
                status: AIJobStatus, attempts: Int = 0, lastErrorClass: AIErrorClass? = nil,
                resultJSON: String? = nil, createdAt: Date, updatedAt: Date) {
        self.id = id; self.type = type; self.idempotencyKey = idempotencyKey; self.inputDigest = inputDigest
        self.status = status; self.attempts = attempts; self.lastErrorClass = lastErrorClass
        self.resultJSON = resultJSON; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public enum ScheduledJobType: String, Codable, Sendable {
    case dailyClose = "daily_close"             // 전날 Daily 마감
    case weeklyPerformance = "weekly_performance"
    case monthlyPerformance = "monthly_performance"
    case quarterlyPerformance = "quarterly_performance"
    case mondayReview = "monday_review"         // 월요일 제출용 준비 알림
    case backup = "backup"
}

public enum ScheduledJobState: String, Codable, Sendable {
    case pending, running, succeeded, failed, skipped
}

/// (type, periodKey)가 유일하다. 놓친 작업은 다음 실행 때 복구한다.
public struct ScheduledJob: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var type: ScheduledJobType
    public var periodKey: String
    public var scheduledFor: Date
    public var state: ScheduledJobState
    public var attempts: Int
    public var lastAttemptAt: Date?
    /// 예정 시각보다 늦게(재실행 시) 처리된 경우 true. 자정 실행 성공으로 허위 표시하지 않기 위함.
    public var recoveredLate: Bool
    public var lastError: String?
    public init(id: String, type: ScheduledJobType, periodKey: String, scheduledFor: Date,
                state: ScheduledJobState = .pending, attempts: Int = 0, lastAttemptAt: Date? = nil,
                recoveredLate: Bool = false, lastError: String? = nil) {
        self.id = id; self.type = type; self.periodKey = periodKey; self.scheduledFor = scheduledFor
        self.state = state; self.attempts = attempts; self.lastAttemptAt = lastAttemptAt
        self.recoveredLate = recoveredLate; self.lastError = lastError
    }
}

// MARK: - 설정

public enum CaptureKind: String, Codable, Sendable, CaseIterable {
    case memo, task, secret
}

/// 사용자 설정. 토큰·Secret 값은 절대 넣지 않는다.
public struct AppSettings: Codable, Equatable, Sendable {
    public var defaultCaptureKind: CaptureKind = .memo
    /// 예: "ctrl+opt+space" — 실제 조합은 제안 기본값이며 설정에서 변경한다.
    public var captureHotkey: String = "ctrl+opt+space"
    public var searchHotkey: String = "ctrl+opt+f"
    public var timeZoneIdentifier: String = "Asia/Seoul"
    public var secretIdleLockMinutes: Int = 30
    public var clipboardClearSeconds: Int = 120
    public var backupRetentionDays: Int = 30
    /// 월요일 검토 알림 "HH:mm"
    public var mondayReminderTime: String = "09:00"
    public var maxQuizQuestions: Int = 3
    public var aiEnabled: Bool = true
    public var aiConcurrency: Int = 1
    /// codex 실행 파일 경로 (nil이면 PATH 탐색)
    public var codexExecutablePath: String?
    /// 작업 유형별 선택 스킬 (jobType → skill 이름/경로). 기존 스킬 파일은 수정하지 않는다.
    public var skillBindings: [String: String] = [:]
    public var menuBarResident: Bool = true
    public var launchAtLogin: Bool = false

    public init() {}

    /// 구버전 설정 파일·누락 키에 관대하게 디코딩한다.
    /// 모든 키를 decodeIfPresent로 읽고, 없으면 기본값을 유지한다. 알 수 없는 키는 무시한다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func decode<T: Decodable>(_ key: CodingKeys, default fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        self.defaultCaptureKind = try decode(.defaultCaptureKind, default: .memo)
        self.captureHotkey = try decode(.captureHotkey, default: "ctrl+opt+space")
        self.searchHotkey = try decode(.searchHotkey, default: "ctrl+opt+f")
        self.timeZoneIdentifier = try decode(.timeZoneIdentifier, default: "Asia/Seoul")
        self.secretIdleLockMinutes = try decode(.secretIdleLockMinutes, default: 30)
        self.clipboardClearSeconds = try decode(.clipboardClearSeconds, default: 120)
        self.backupRetentionDays = try decode(.backupRetentionDays, default: 30)
        self.mondayReminderTime = try decode(.mondayReminderTime, default: "09:00")
        self.maxQuizQuestions = try decode(.maxQuizQuestions, default: 3)
        self.aiEnabled = try decode(.aiEnabled, default: true)
        self.aiConcurrency = try decode(.aiConcurrency, default: 1)
        self.codexExecutablePath = try c.decodeIfPresent(String.self, forKey: .codexExecutablePath)
        self.skillBindings = try decode(.skillBindings, default: [:])
        self.menuBarResident = try decode(.menuBarResident, default: true)
        self.launchAtLogin = try decode(.launchAtLogin, default: false)
    }
}
