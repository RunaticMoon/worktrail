import Foundation

// 리포트 계약 타입. 05_RUNTIME_PROMPTS의 입력 자료 계약(jobContext/facts/sources)과
// 결과 계약(submission_weekly / performance_report)을 Swift 타입으로 고정한다.
// 이 타입들은 Secret 자료형을 절대 포함하지 않는다.

// MARK: - 입력 사실 (앱이 결정적으로 계산)

public struct FactProject: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct FactEvent: Codable, Hashable, Sendable {
    public var id: String
    public var taskId: String
    public var scopeType: EventScopeType
    public var scopeId: String
    public var kind: DomainEventKind
    public var toStatus: TaskStatus?
    public var effectiveDate: WorkDate
    public init(id: String, taskId: String, scopeType: EventScopeType, scopeId: String,
                kind: DomainEventKind, toStatus: TaskStatus?, effectiveDate: WorkDate) {
        self.id = id; self.taskId = taskId; self.scopeType = scopeType; self.scopeId = scopeId
        self.kind = kind; self.toStatus = toStatus; self.effectiveDate = effectiveDate
    }
}

public struct FactChecklistItem: Codable, Hashable, Sendable {
    public var id: String
    public var text: String
    public var projectIds: [String]
    public var doneAtCutoff: Bool
    public init(id: String, text: String, projectIds: [String], doneAtCutoff: Bool) {
        self.id = id; self.text = text; self.projectIds = projectIds; self.doneAtCutoff = doneAtCutoff
    }
}

public struct FactTask: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var trackingMode: ProjectTrackingMode
    /// 기간 시작 직전(start 전날 종료) 상태. 기간 이전에 없던 Task면 nil.
    public var statusAtStart: TaskStatus?
    /// 기간 종료 상태 (stateCutoff 기준, knownAt까지 기록된 정보)
    public var statusAtCutoff: TaskStatus?
    /// 기간 종료 시 연결된(제거되지 않은) 프로젝트 ID
    public var projectIds: [String]
    /// tracking 프로젝트의 기간 종료 상태 (projectId → 상태)
    public var projectStatuses: [String: TaskStatus]
    public var dueOn: WorkDate?
    public var firstStartedOn: WorkDate?
    /// 기간 안의 Task 전체 완료 사건 날짜
    public var completionDatesInRange: [WorkDate]
    /// 기간 안에 reopened 사건이 있었는지
    public var reopenedInRange: Bool
    /// 기간 안의 모든 상태·연결 사건
    public var eventsInRange: [FactEvent]
    public var checklist: [FactChecklistItem]
    /// 기간 안 활동(근거) source ID 목록
    public var activitySourceIds: [String]

    public init(id: String, title: String, trackingMode: ProjectTrackingMode, statusAtStart: TaskStatus?,
                statusAtCutoff: TaskStatus?, projectIds: [String], projectStatuses: [String: TaskStatus],
                dueOn: WorkDate?, firstStartedOn: WorkDate?, completionDatesInRange: [WorkDate],
                reopenedInRange: Bool, eventsInRange: [FactEvent], checklist: [FactChecklistItem],
                activitySourceIds: [String]) {
        self.id = id; self.title = title; self.trackingMode = trackingMode; self.statusAtStart = statusAtStart
        self.statusAtCutoff = statusAtCutoff; self.projectIds = projectIds; self.projectStatuses = projectStatuses
        self.dueOn = dueOn; self.firstStartedOn = firstStartedOn
        self.completionDatesInRange = completionDatesInRange; self.reopenedInRange = reopenedInRange
        self.eventsInRange = eventsInRange; self.checklist = checklist; self.activitySourceIds = activitySourceIds
    }
}

public enum FactSourceKind: String, Codable, Sendable {
    case activity, memo, supplement, report
}

/// AI와 검증기가 참조하는 근거 원문. id 형식: "activity:<id>", "memo:<id>", "supplement:<id>", "report:<versionId>"
public struct FactSource: Codable, Hashable, Sendable {
    public var id: String
    public var kind: FactSourceKind
    public var revision: Int
    public var recordedAt: Date
    public var workDate: WorkDate?
    /// 성과 보충 답변의 설명 대상 기간
    public var applies: DateRange?
    public var taskId: String?
    public var projectIds: [String]
    public var text: String
    /// 저장된 URL. 첫 버전은 본문을 가져오지 않으므로 urlBodyFetched == false
    public var sourceUrls: [String]
    public var urlBodyFetched: Bool

    public init(id: String, kind: FactSourceKind, revision: Int, recordedAt: Date, workDate: WorkDate?,
                applies: DateRange? = nil, taskId: String?, projectIds: [String], text: String,
                sourceUrls: [String] = [], urlBodyFetched: Bool = false) {
        self.id = id; self.kind = kind; self.revision = revision; self.recordedAt = recordedAt
        self.workDate = workDate; self.applies = applies; self.taskId = taskId; self.projectIds = projectIds
        self.text = text; self.sourceUrls = sourceUrls; self.urlBodyFetched = urlBodyFetched
    }

    public static func activityId(_ id: String) -> String { "activity:\(id)" }
    public static func memoId(_ id: String) -> String { "memo:\(id)" }
    public static func supplementId(_ id: String) -> String { "supplement:\(id)" }
}

/// 확정 계획 항목 (정규화 후). 후보는 포함하지 않는다.
public struct FactPlanItem: Codable, Hashable, Sendable {
    /// 정규화된 계획 항목 ID (원래 WeekPlanItem ID들)
    public var planItemIds: [String]
    public var taskId: String
    public var scopeType: PlanScopeType
    public var scopeId: String?
    /// 사용자가 적은 세부 문구들(병합)
    public var labels: [String]
    public init(planItemIds: [String], taskId: String, scopeType: PlanScopeType, scopeId: String?, labels: [String]) {
        self.planItemIds = planItemIds; self.taskId = taskId; self.scopeType = scopeType
        self.scopeId = scopeId; self.labels = labels
    }
}

public struct AcceptedMemoLink: Codable, Hashable, Sendable {
    public var memoId: String
    public var taskId: String
    public init(memoId: String, taskId: String) { self.memoId = memoId; self.taskId = taskId }
}

/// 앱이 계산한 집계. 각 지표는 기준이 다르며 서로 섞지 않는다. AI는 숫자를 새로 만들지 않는다.
public struct ReportMetrics: Codable, Hashable, Sendable {
    /// 기간에 관련된 고유 Task 수 (Task ID distinct)
    public var uniqueTaskCount: Int
    /// 수행 활동 수 (Activity ID distinct)
    public var activityCount: Int
    /// Task 전체 완료 사건 수 (재완료 포함)
    public var completionEventCount: Int
    /// 기간 종료 시 완료 상태인 고유 Task 수
    public var completedTaskCount: Int
    /// Task–프로젝트 연결 수 (프로젝트 연관 지표, 업무 건수 아님)
    public var projectAssociationCount: Int
    /// 프로젝트 적용 완료 사건 수
    public var projectCompletionEventCount: Int
    public init(uniqueTaskCount: Int = 0, activityCount: Int = 0, completionEventCount: Int = 0,
                completedTaskCount: Int = 0, projectAssociationCount: Int = 0, projectCompletionEventCount: Int = 0) {
        self.uniqueTaskCount = uniqueTaskCount; self.activityCount = activityCount
        self.completionEventCount = completionEventCount; self.completedTaskCount = completedTaskCount
        self.projectAssociationCount = projectAssociationCount
        self.projectCompletionEventCount = projectCompletionEventCount
    }
}

/// 리포트 생성 입력의 고정 사본 (SourceSnapshot.frozenFactsJSON 의 내용)
public struct ReportFacts: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var family: ReportFamily
    public var periodType: PeriodType
    public var locale: String
    public var timezone: String
    public var generatedAt: Date
    /// 대상 기간 [start, endExclusive)
    public var range: DateRange
    /// 상태 기준 시점 (range.endExclusive 지역 자정)
    public var statusCutoff: Date
    /// 이 시각까지 기록된 원본만 사용
    public var knownAt: Date
    /// 제출용: 이번 주 계획 구간
    public var planRange: DateRange?
    public var projects: [FactProject]
    public var tasks: [FactTask]
    public var sources: [FactSource]
    /// 제출용: 이번 주 확정 계획(정규화됨). 후보는 절대 포함하지 않는다.
    public var confirmedPlans: [FactPlanItem]
    public var memoLinksAccepted: [AcceptedMemoLink]
    public var metrics: ReportMetrics

    public init(schemaVersion: Int = 1, family: ReportFamily, periodType: PeriodType, locale: String = "ko-KR",
                timezone: String, generatedAt: Date, range: DateRange, statusCutoff: Date, knownAt: Date,
                planRange: DateRange? = nil, projects: [FactProject], tasks: [FactTask], sources: [FactSource],
                confirmedPlans: [FactPlanItem] = [], memoLinksAccepted: [AcceptedMemoLink] = [],
                metrics: ReportMetrics) {
        self.schemaVersion = schemaVersion; self.family = family; self.periodType = periodType
        self.locale = locale; self.timezone = timezone; self.generatedAt = generatedAt; self.range = range
        self.statusCutoff = statusCutoff; self.knownAt = knownAt; self.planRange = planRange
        self.projects = projects; self.tasks = tasks; self.sources = sources
        self.confirmedPlans = confirmedPlans; self.memoLinksAccepted = memoLinksAccepted; self.metrics = metrics
    }

    public func task(_ id: String) -> FactTask? { tasks.first { $0.id == id } }
    public func project(_ id: String) -> FactProject? { projects.first { $0.id == id } }
    public var sourceIds: Set<String> { Set(sources.map(\.id)) }
}

// MARK: - 제출용 주간보고 결과 계약 (P-01)

public enum SubmissionCategory: String, Codable, Sendable, CaseIterable {
    case completed = "completed"     // 완료
    case inProgress = "in_progress"  // 진행
    case planned = "planned"         // 예정

    public var koreanLabel: String {
        switch self {
        case .completed: return "완료"
        case .inProgress: return "진행"
        case .planned: return "예정"
        }
    }
}

public struct SubmissionItem: Codable, Hashable, Sendable {
    public var itemId: String
    public var category: SubmissionCategory
    public var text: String
    public var taskIds: [String]
    public var projectIds: [String]
    public var planItemIds: [String]
    public var evidenceIds: [String]
    public init(itemId: String, category: SubmissionCategory, text: String, taskIds: [String],
                projectIds: [String], planItemIds: [String] = [], evidenceIds: [String] = []) {
        self.itemId = itemId; self.category = category; self.text = text; self.taskIds = taskIds
        self.projectIds = projectIds; self.planItemIds = planItemIds; self.evidenceIds = evidenceIds
    }
}

public struct SubmissionGroup: Codable, Hashable, Sendable {
    public var heading: String
    public var items: [SubmissionItem]
    public init(heading: String, items: [SubmissionItem]) { self.heading = heading; self.items = items }
}

public struct SubmissionDraft: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var jobType: String
    public var groups: [SubmissionGroup]
    /// 보류·취소 등 세 가지 표기에 맞지 않아 검토 화면에 따로 보여줄 항목
    public var reviewNotes: [String]
    public var warnings: [String]
    public init(schemaVersion: Int = 1, jobType: String = "submission_weekly", groups: [SubmissionGroup],
                reviewNotes: [String] = [], warnings: [String] = []) {
        self.schemaVersion = schemaVersion; self.jobType = jobType; self.groups = groups
        self.reviewNotes = reviewNotes; self.warnings = warnings
    }
}

// MARK: - 성과 리포트 결과 계약 (P-02 / P-03)

public enum PerformanceItemKind: String, Codable, Sendable {
    case activity, state, discussion, plan, unknown
}

public struct PerformanceItem: Codable, Hashable, Sendable {
    public var itemId: String
    public var taskIds: [String]
    public var projectIds: [String]
    public var kind: PerformanceItemKind
    public var text: String
    public var evidenceIds: [String]
    public init(itemId: String, taskIds: [String], projectIds: [String], kind: PerformanceItemKind,
                text: String, evidenceIds: [String]) {
        self.itemId = itemId; self.taskIds = taskIds; self.projectIds = projectIds; self.kind = kind
        self.text = text; self.evidenceIds = evidenceIds
    }
}

public struct PerformanceSection: Codable, Hashable, Sendable {
    public var heading: String
    public var projectIds: [String]
    public var items: [PerformanceItem]
    public init(heading: String, projectIds: [String], items: [PerformanceItem]) {
        self.heading = heading; self.projectIds = projectIds; self.items = items
    }
}

public struct MissingEvidence: Codable, Hashable, Sendable {
    public var taskId: String
    public var field: String
    public var reason: String
    public init(taskId: String, field: String, reason: String) {
        self.taskId = taskId; self.field = field; self.reason = reason
    }
}

public struct PerformanceDraft: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var jobType: String
    public var periodType: PeriodType
    public var title: String
    public var sections: [PerformanceSection]
    public var missingEvidence: [MissingEvidence]
    public var warnings: [String]
    public init(schemaVersion: Int = 1, jobType: String = "performance_report", periodType: PeriodType,
                title: String, sections: [PerformanceSection], missingEvidence: [MissingEvidence] = [],
                warnings: [String] = []) {
        self.schemaVersion = schemaVersion; self.jobType = jobType; self.periodType = periodType
        self.title = title; self.sections = sections; self.missingEvidence = missingEvidence
        self.warnings = warnings
    }
}

// MARK: - 검증 결과

public enum ValidationSeverity: String, Codable, Sendable { case warning, error }

public struct ValidationFinding: Codable, Hashable, Sendable {
    public var severity: ValidationSeverity
    public var code: String
    public var message: String
    public var itemId: String?
    public init(severity: ValidationSeverity, code: String, message: String, itemId: String? = nil) {
        self.severity = severity; self.code = code; self.message = message; self.itemId = itemId
    }
}
