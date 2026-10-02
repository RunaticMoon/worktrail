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
    public func load() {
        do {
            submissionReports = try environment.repo.reports(family: .submission)
            performanceReports = try environment.repo.reports(family: .performance)
            evaluationPeriods = try environment.repo.evaluationPeriods()
            errorMessage = nil
        } catch { errorMessage = "리포트 목록을 불러오지 못했습니다. 다시 불러오세요." }
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
        load()
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
    public func selectReport(_ id: String) {
        guard !isGenerating, !hasChanges, let selected = visibleReports.first(where: { $0.id == id }) else { return }
        do {
            try showReport(selected)
            errorMessage = nil
        } catch { errorMessage = "리포트 버전을 불러오지 못했습니다. 다시 선택하세요." }
    }
    public func selectVersion(_ id: String) {
        guard !isGenerating, !hasChanges, let selected = versions.first(where: { $0.id == id }) else { return }
        do { try showVersion(selected); errorMessage = nil }
        catch { errorMessage = "버전의 근거를 불러오지 못했습니다. 다시 선택하세요." }
    }
    public func generate() async {
        guard !isGenerating, !hasChanges else { return }
        isGenerating = true; errorMessage = nil
        defer { isGenerating = false }
        do {
            let result: ReportGenerationResult
            if family == .submission {
                reportDate = environment.periods.weekStart(containing: reportDate)
                result = try await environment.reports.generateSubmission(reportDate: reportDate, mode: .userRequested, useAI: useAI && isAIAvailable)
            } else if let evaluationPeriodId {
                result = try await environment.reports.generateEvaluation(periodId: evaluationPeriodId, mode: .userRequested, useAI: useAI && isAIAvailable)
            } else {
                result = try await environment.reports.generatePerformance(periodType: periodType, containing: performanceDate, mode: .userRequested, useAI: useAI && isAIAvailable)
            }
            let saved: ReportVersion
            switch result.outcome { case .created(let row), .unchanged(let row): saved = row }
            results[saved.id] = result
            load(); report = result.report
            versions = try environment.repo.reportVersions(reportId: result.report.id)
            try showVersion(saved)
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
        do { try refreshVersion(environment.reports.confirm(versionId: version.id)); load() }
        catch { errorMessage = "리포트를 확정하지 못했습니다. 다시 시도하세요." }
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
    }
}
