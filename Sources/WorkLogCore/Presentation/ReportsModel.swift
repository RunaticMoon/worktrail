import Foundation
import Observation

/// Explicit report actions. Families, frozen evidence and confirmed versions stay separate.
@Observable @MainActor public final class ReportsModel {
    public var family: ReportFamily = .submission
    public var reportDate: WorkDate
    public var performanceDate: WorkDate
    public var periodType: PeriodType = .weekly
    public var evaluationPeriodId: String?
    public var useAI: Bool
    public var content = ""
    public var includedSubmissionIds: Set<String> = []
    public private(set) var submissionDraft: SubmissionDraft?
    public var evaluationStart: WorkDate { didSet { proposal = nil } }
    public var evaluationEnd: WorkDate { didSet { proposal = nil } }
    public var deriveEvaluationStart = false { didSet { proposal = nil } }
    public private(set) var submissionReports: [Report] = []
    public private(set) var performanceReports: [Report] = []
    public private(set) var evaluationPeriods: [EvaluationPeriod] = []
    public private(set) var proposal: EvaluationPeriodProposal?
    public private(set) var report: Report?
    public private(set) var versions: [ReportVersion] = []
    public private(set) var version: ReportVersion?
    /// 재생성 보호: 화면에 보이던 수정본·확정본을 그대로 두고 새 버전을 대기시킬 때 담는다.
    public private(set) var pendingRegeneration: ReportVersion?
    /// 복사·확정 등 사용자에게 보여줄 마지막 상태 문구. 버전 상태와는 무관하다.
    public private(set) var statusMessage: String?
    public private(set) var evidence: [ReportEvidenceRow] = []
    public private(set) var sources: [FactSource] = []
    public private(set) var findings: [ValidationFinding] = []
    public private(set) var usedFallback = false
    public private(set) var aiJobStatus: AIJobStatus?
    public private(set) var isStale = false
    public private(set) var isGenerating = false
    public private(set) var errorMessage: String?
    public var isAIAvailable: Bool { environment.aiRunner != nil }
    public var visibleReports: [Report] { family == .submission ? submissionReports : performanceReports }
    public var canEdit: Bool { !isGenerating && (version?.state == .draft || version?.state == .edited) }
    public var hasChanges: Bool { canEdit && content != version?.content }
    /// 대기 중인 새 초안이 있으면 현재 화면 본문과의 줄 단위 차이.
    public var pendingDiff: [DiffLine] {
        guard let pendingRegeneration else { return [] }
        return LineDiff.diff(old: content, new: pendingRegeneration.content)
    }
    /// 재생성 버튼 제목. 수정본·확정본을 보고 있으면 새 버전이 화면을 덮지 않는다.
    public var regenerateTitle: String {
        switch version?.state {
        case .edited, .confirmed: return "새 초안 만들기(현재 본문 유지)"
        default: return "초안 다시 만들기"
        }
    }
    /// 현재 버전을 편집할 수 없을 때의 이유. 편집 가능하면 nil.
    public var readOnlyReason: String? {
        guard !canEdit, !isGenerating else { return nil }
        switch version?.state {
        case .confirmed: return "확정본은 수정할 수 없습니다. 수정하면 새 버전으로 남습니다."
        case .superseded: return "이전 버전은 수정할 수 없습니다."
        default: return nil
        }
    }
    /// 현재 버전 상태 라벨. 예: "초안 v1", "확정본 v2".
    public var stateLabel: String {
        guard let version else { return "" }
        let base: String
        switch version.state {
        case .draft: base = "초안"
        case .edited: base = "수정본"
        case .confirmed: base = "확정본"
        case .superseded: base = "이전 버전"
        }
        return "\(base) v\(version.version)"
    }
    /// "지난주 실적 9월 28일(월) ~ 10월 4일(일) · 일요일 종료 기준"
    public var previousPeriodLabel: String {
        "지난주 실적 \(KoreanDateLabel.range(submissionPeriods.previous, calendar: environment.calendar)) · 일요일 종료 기준"
    }
    /// "이번 주 계획 10월 5일(월) ~ 10월 11일(일)"
    public var planPeriodLabel: String {
        "이번 주 계획 \(KoreanDateLabel.range(submissionPeriods.plan, calendar: environment.calendar))"
    }
    /// 현재 family의 활성 템플릿 표시. 예: "제출용 주간보고 v1". 템플릿이 없으면 nil.
    public var templateLabel: String? {
        let purpose: TemplatePurpose
        switch family {
        case .submission: purpose = .submissionWeekly
        case .performance: purpose = periodType == .daily ? .performanceDaily : .performancePeriodic
        }
        guard let template = try? environment.templates.preferredTemplate(for: purpose),
              let active = try? environment.templates.activeVersion(templateId: template.id) else {
            return nil
        }
        let name = family == .submission ? "제출용 주간보고" : "성과자료"
        return "\(name) v\(active.version)"
    }
    /// 화면 목적 부제. 주간보고와 성과자료를 "Weekly" 같은 공통 이름으로 합치지 않는다.
    public var purposeLabel: String {
        family == .submission ? "팀 제출용" : "성과평가용 상세 기록"
    }
    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private var results: [String: ReportGenerationResult] = [:]
    @ObservationIgnored private var pendingVersionId: String?

    public init(environment: AppEnvironment) {
        self.environment = environment
        let today = environment.calendar.workDate(of: environment.options.clock.now())
        reportDate = environment.periods.weekStart(containing: today)
        performanceDate = today; evaluationStart = today; evaluationEnd = today
        useAI = environment.aiRunner != nil
    }
    public var submissionPeriods: (previous: DateRange, plan: DateRange) {
        environment.periods.submissionWeek(reportDate: reportDate)
    }
    /// Reloads the report lists; a user-initiated reload discards a deferred version request.
    public func load() {
        pendingVersionId = nil
        pendingRegeneration = nil
        statusMessage = nil
        reloadLists()
    }
    /// Defer exact-version navigation until the destination loads its selection.
    public func requestVersionSelection(_ id: String) {
        guard !isGenerating, !hasChanges else { return }
        pendingVersionId = id
    }
    /// Read-only navigation never calls AI or generates a report.
    public func loadSelection() {
        guard !isGenerating, !hasChanges else { return }
        reportDate = environment.periods.weekStart(containing: reportDate)
        // Keep the pending request alive until it is consumed below.
        reloadLists()
        guard errorMessage == nil else { return }
        if let id = pendingVersionId {
            pendingVersionId = nil
            do {
                guard let requested = try environment.repo.reportVersion(id: id),
                      let selected = try environment.repo.report(id: requested.reportId) else {
                    errorMessage = "요청한 리포트 버전을 찾을 수 없습니다. 그래프를 새로고침하세요."
                    return
                }
                try showReport(selected, versionId: requested.id)
            } catch { errorMessage = "리포트 버전을 불러오지 못했습니다. 다시 선택하세요." }
            return
        }
        let match = visibleReports.first {
            if family == .submission { return $0.periodKey == reportDate.iso }
            if let evaluationPeriodId { return $0.evaluationPeriodId == evaluationPeriodId }
            return $0.periodType == periodType && $0.periodKey == environment.periods.periodKey(periodType, containing: performanceDate)
        }
        if let match {
            // Period/family changes made by navigation can trigger additional view reloads.
            // Keep the exact version while those controls still identify the same report.
            let selectedVersionId = report?.id == match.id ? version?.id : nil
            do { try showReport(match, versionId: selectedVersionId) }
            catch { errorMessage = "리포트 버전을 불러오지 못했습니다. 다시 선택하세요." }
        } else { clearPreview() }
    }
    /// A direct user selection supersedes any deferred version request.
    public func selectReport(_ id: String) {
        guard !isGenerating, !hasChanges, let selected = visibleReports.first(where: { $0.id == id }) else { return }
        pendingVersionId = nil
        pendingRegeneration = nil
        statusMessage = nil
        do {
            try showReport(selected)
            errorMessage = nil
        } catch { errorMessage = "리포트 버전을 불러오지 못했습니다. 다시 선택하세요." }
    }
    /// A direct user selection supersedes any deferred version request.
    public func selectVersion(_ id: String) {
        guard !isGenerating, !hasChanges, let selected = versions.first(where: { $0.id == id }) else { return }
        pendingVersionId = nil
        pendingRegeneration = nil
        statusMessage = nil
        do { try showVersion(selected); errorMessage = nil }
        catch { errorMessage = "버전의 근거를 불러오지 못했습니다. 다시 선택하세요." }
    }
    /// 사용자가 명시적으로 실행하는 생성. 현재 수정본·확정본은 화면에서 유지하고 새 버전을 대기시킨다.
    public func generate() async {
        await runGeneration(useAI: useAI && isAIAvailable, mode: .userRequested)
    }
    /// 주간보고 화면 진입 시: 그 주 리포트가 없으면 AI 없이 결정적 초안을 즉시 준비한다.
    /// 성과자료(.performance)는 자동 생성하지 않는다(명시 실행 유지).
    /// 이미 리포트가 있으면 새로 만들지 않고 기존 선택 로직만 수행한다.
    public func ensureDraftForCurrentPeriod() async {
        guard family == .submission, !isGenerating, !hasChanges else { return }
        reportDate = environment.periods.weekStart(containing: reportDate)
        let existing: Report?
        do {
            existing = try environment.repo.report(family: .submission, periodType: .weekly,
                                                   periodKey: reportDate.iso)
        } catch {
            errorMessage = "리포트 목록을 불러오지 못했습니다. 다시 불러오세요."
            return
        }
        if existing != nil { loadSelection(); return }
        // mode .automatic: 같은 원본이면 새 버전을 만들지 않아 화면을 다시 열어도 초안이 중복되지 않는다.
        await runGeneration(useAI: false, mode: .automatic)
    }
    /// 대기 중인 새 초안을 화면에 적용한다. 새 버전은 이력에 이미 저장되어 있다.
    public func applyPendingRegeneration() {
        guard !isGenerating, let pending = pendingRegeneration else { return }
        do {
            try showVersion(pending)
            pendingRegeneration = nil
            errorMessage = nil
        } catch { errorMessage = "새 초안을 열지 못했습니다. 다시 시도하세요." }
    }
    /// 화면에 보던 버전을 유지한 채 대기 중인 새 초안을 닫는다. 새 버전은 이력에 남는다.
    public func dismissPendingRegeneration() {
        pendingRegeneration = nil
    }
    /// 복사 완료 문구만 남긴다. 버전 상태(초안/수정본/확정본)는 바뀌지 않는다.
    public func markCopied() {
        statusMessage = "클립보드에 복사했습니다 · 제출 상태는 바뀌지 않습니다"
    }
    private func runGeneration(useAI: Bool, mode: GenerationMode) async {
        guard !isGenerating, !hasChanges else { return }
        isGenerating = true; errorMessage = nil; statusMessage = nil
        defer { isGenerating = false }
        let displayed = version
        do {
            let result: ReportGenerationResult
            if family == .submission {
                reportDate = environment.periods.weekStart(containing: reportDate)
                result = try await environment.reports.generateSubmission(reportDate: reportDate, mode: mode, useAI: useAI)
            } else if let evaluationPeriodId {
                result = try await environment.reports.generateEvaluation(periodId: evaluationPeriodId, mode: mode, useAI: useAI)
            } else {
                result = try await environment.reports.generatePerformance(periodType: periodType, containing: performanceDate, mode: mode, useAI: useAI)
            }
            let saved: ReportVersion
            switch result.outcome { case .created(let row), .unchanged(let row): saved = row }
            results[saved.id] = result
            load(); report = result.report
            versions = try environment.repo.reportVersions(reportId: result.report.id)
            let preservesDisplay = displayed.map {
                ($0.state == .edited || $0.state == .confirmed)
                    && $0.reportId == result.report.id && $0.id != saved.id
            } ?? false
            if preservesDisplay {
                // 수정본·확정본은 화면에서 유지하고 새 버전은 대기시킨다(적용은 사용자가 결정).
                pendingRegeneration = saved
            } else {
                pendingRegeneration = nil
                try showVersion(saved)
            }
        } catch { errorMessage = "리포트를 생성하지 못했습니다. 기록과 AI 연결을 확인하고 다시 생성하세요." }
    }
    public func saveEdits() {
        guard canEdit, hasChanges, let version else { return }
        do { try refreshVersion(environment.reports.edit(versionId: version.id, content: content)); errorMessage = nil }
        catch { errorMessage = "본문을 저장하지 못했습니다. 입력은 유지됩니다. 다시 저장하세요." }
    }
    public func discardEdits() { content = version?.content ?? "" }
    public func applySubmissionSelection() {
        guard canEdit, !hasChanges, version?.state == .draft, var draft = submissionDraft else { return }
        draft.groups = draft.groups.compactMap { group in
            var filtered = group
            filtered.items = group.items.filter { includedSubmissionIds.contains($0.itemId) }
            return filtered.items.isEmpty ? nil : filtered
        }
        content = SubmissionComposer.render(draft)
    }
    public func confirm() {
        guard canEdit, !hasChanges, let version else { return }
        do {
            let confirmed = try environment.reports.confirm(versionId: version.id)
            try refreshVersion(confirmed)
            load()
            statusMessage = "확정본 v\(confirmed.version) · 이후 수정은 새 버전으로 남습니다"
        } catch { errorMessage = "리포트를 확정하지 못했습니다. 다시 시도하세요." }
    }
    public func checkStale() {
        guard let version else { return }
        do { isStale = try environment.reports.isStale(versionId: version.id) }
        catch { errorMessage = "원본 변경 여부를 확인하지 못했습니다. 다시 불러오세요." }
    }
    public func proposeEvaluation() {
        do {
            proposal = try environment.evaluationPeriods.propose(start: deriveEvaluationStart ? nil : evaluationStart, endInclusive: evaluationEnd)
            errorMessage = nil
        } catch { proposal = nil; errorMessage = "평가 기간을 제안하지 못했습니다. 첫 평가의 시작일과 종료일을 확인하세요." }
    }
    public func createEvaluation() {
        guard let proposal, !isGenerating, !hasChanges else { return }
        do {
            let (period, _) = try environment.evaluationPeriods.create(start: proposal.range.start, endInclusive: evaluationEnd)
            self.proposal = nil; evaluationPeriodId = period.id; loadSelection()
        } catch { errorMessage = "평가 기간을 저장하지 못했습니다. 날짜를 확인하고 다시 제안하세요." }
    }
    private func reloadLists() {
        do {
            submissionReports = try environment.repo.reports(family: .submission)
            performanceReports = try environment.repo.reports(family: .performance)
            evaluationPeriods = try environment.repo.evaluationPeriods()
            errorMessage = nil
        } catch { errorMessage = "리포트 목록을 불러오지 못했습니다. 다시 불러오세요." }
    }
    private func showReport(_ selected: Report, versionId: String? = nil) throws {
        let rows = try environment.repo.reportVersions(reportId: selected.id)
        clearPreview(); family = selected.family; report = selected; versions = rows
        if selected.family == .submission { reportDate = selected.planRange?.start ?? reportDate }
        else {
            performanceDate = selected.range.start
            evaluationPeriodId = selected.evaluationPeriodId
            if selected.periodType != .yearly { periodType = selected.periodType }
        }
        let requested = versionId.flatMap { id in rows.first { $0.id == id } }
        if let selectedVersion = requested ?? rows.last(where: { $0.state != .superseded }) {
            try showVersion(selectedVersion)
        }
    }
    private func refreshVersion(_ saved: ReportVersion) throws {
        versions = try environment.repo.reportVersions(reportId: saved.reportId)
        try showVersion(saved)
    }
    private func showVersion(_ selected: ReportVersion) throws {
        let rows = try environment.repo.reportEvidence(versionId: selected.id)
        let snapshot = try environment.repo.sourceSnapshot(id: selected.sourceSnapshotId)
        let facts = try snapshot.map { try StableJSON.decode(ReportFacts.self, from: $0.frozenFactsJSON) }
        let stale = try environment.reports.isStale(versionId: selected.id)
        proposal = nil
        version = selected; content = selected.content; evidence = rows; sources = facts?.sources ?? []; isStale = stale
        submissionDraft = report?.family == .submission ? selected.structuredJSON.flatMap { try? StableJSON.decode(SubmissionDraft.self, from: $0) } : nil
        includedSubmissionIds = Set(submissionDraft?.groups.flatMap(\.items).map(\.itemId) ?? [])
        findings = results[selected.id]?.findings ?? []
        usedFallback = results[selected.id]?.usedFallback ?? false
        aiJobStatus = results[selected.id]?.aiJobStatus
    }
    private func clearPreview() {
        proposal = nil
        report = nil; versions = []; version = nil; content = ""; evidence = []; sources = []
        submissionDraft = nil; includedSubmissionIds = []
        findings = []; usedFallback = false; aiJobStatus = nil; isStale = false
        pendingRegeneration = nil; statusMessage = nil
    }
}
