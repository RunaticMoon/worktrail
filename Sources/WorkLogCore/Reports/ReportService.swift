import Foundation

// MARK: - 리포트 생성 파이프라인 (REP-T03 / REP-T07 / REP-T11 / REP-T18 / PERF-05)
//
// 이미 있는 부품(FactsBuilder / Composer / Validator / Store / TemplateStore / AIJobRunner)을
// 엮어 제출용 주간보고와 상세 성과 리포트를 생성·저장한다.
//
// - 제출용(submission)과 성과(performance)는 family·템플릿·Composer·Validator·리포트 ID가 분리된다.
// - AI는 선택(useAI)이다. AI 결과는 반드시 로컬 검증을 통과해야 저장되고, 실패·검증 탈락이면
//   기록 기반 결정적 초안으로 대체한다. AI 실패가 저장을 막지 않는다.
// - 날짜·상태·집계는 앱이 계산한 facts만 사용한다.
// - Secret 자료형은 이 경로의 어떤 입력에도 들어가지 않는다.

/// 리포트 생성 결과. 저장 결과(outcome)와 사용한 사실·검증·AI 상태를 함께 돌려준다.
public struct ReportGenerationResult: Sendable {
    public var outcome: SaveOutcome
    public var report: Report
    public var facts: ReportFacts
    /// AI 결과(또는 결정적 초안) 검증 결과.
    public var findings: [ValidationFinding]
    /// AI를 호출하지 않았으면 nil.
    public var aiJobStatus: AIJobStatus?
    /// AI를 요청했지만 결정적 초안으로 대체했는지.
    public var usedFallback: Bool
    /// 자동 모드에서 원본 변화가 없어 AI 호출을 생략했는지.
    public var aiSkippedUnchanged: Bool

    public init(outcome: SaveOutcome, report: Report, facts: ReportFacts,
                findings: [ValidationFinding], aiJobStatus: AIJobStatus?,
                usedFallback: Bool, aiSkippedUnchanged: Bool) {
        self.outcome = outcome
        self.report = report
        self.facts = facts
        self.findings = findings
        self.aiJobStatus = aiJobStatus
        self.usedFallback = usedFallback
        self.aiSkippedUnchanged = aiSkippedUnchanged
    }
}

public final class ReportService {

    private let repo: WorkRepository
    private let periods: Periods
    private let factsBuilder: ReportFactsBuilder
    private let store: ReportStore
    private let templates: TemplateStore
    private let runner: AIJobRunner?
    private let evaluationPeriods: EvaluationPeriodService

    public init(repo: WorkRepository, periods: Periods, factsBuilder: ReportFactsBuilder, store: ReportStore,
                templates: TemplateStore, runner: AIJobRunner?, evaluationPeriods: EvaluationPeriodService) {
        self.repo = repo
        self.periods = periods
        self.factsBuilder = factsBuilder
        self.store = store
        self.templates = templates
        self.runner = runner
        self.evaluationPeriods = evaluationPeriods
    }

    // MARK: - 제출용 주간보고

    /// 제출용 주간보고. reportDate = 보고 월요일.
    /// periodKey = reportDate.iso, family .submission, periodType .weekly,
    /// range = 지난주, planRange = 이번 주.
    public func generateSubmission(reportDate: WorkDate, mode: GenerationMode, useAI: Bool,
                                   knownAt: Date? = nil) async throws -> ReportGenerationResult {
        let resolvedKnownAt = knownAt ?? repo.clock.now()
        let facts = try factsBuilder.submissionFacts(reportDate: reportDate, knownAt: resolvedKnownAt)
        let report = try store.ensureReport(family: .submission, periodType: .weekly,
                                            periodKey: reportDate.iso, range: facts.range,
                                            planRange: facts.planRange)
        return try await generate(report: report, facts: facts, mode: mode, useAI: useAI)
    }

    // MARK: - 상세 성과 리포트

    /// 상세 성과 리포트(daily/weekly/monthly/quarterly).
    /// yearly는 평가 기간 API(generateEvaluation)를 사용하므로 validation 오류다.
    /// range = periods.range(type, containing: date), periodKey = periods.periodKey(type, containing: date).
    public func generatePerformance(periodType: PeriodType, containing date: WorkDate,
                                    mode: GenerationMode, useAI: Bool,
                                    knownAt: Date? = nil) async throws -> ReportGenerationResult {
        guard periodType != .yearly else {
            throw WorkLogError.validation(
                "연간 리포트는 평가 기간 API(generateEvaluation)를 사용하세요.")
        }
        let resolvedKnownAt = knownAt ?? repo.clock.now()
        let range = periods.range(periodType, containing: date)
        let periodKey = periods.periodKey(periodType, containing: date)
        let facts = try factsBuilder.build(family: .performance, periodType: periodType,
                                           range: range, knownAt: resolvedKnownAt)
        let report = try store.ensureReport(family: .performance, periodType: periodType,
                                            periodKey: periodKey, range: range)
        return try await generate(report: report, facts: facts, mode: mode, useAI: useAI)
    }

    // MARK: - 평가 기간 리포트

    /// 평가 기간 리포트: periodType .yearly, range = 평가 기간 range(생성일로 확장 금지),
    /// periodKey = period.id, evaluationPeriodId = period.id.
    public func generateEvaluation(periodId: String, mode: GenerationMode, useAI: Bool,
                                   knownAt: Date? = nil) async throws -> ReportGenerationResult {
        guard let period = try repo.evaluationPeriod(id: periodId) else {
            throw WorkLogError.notFound("evaluation_period \(periodId)")
        }
        let resolvedKnownAt = knownAt ?? repo.clock.now()
        let facts = try factsBuilder.build(family: .performance, periodType: .yearly,
                                           range: period.range, knownAt: resolvedKnownAt)
        let report = try store.ensureReport(family: .performance, periodType: .yearly,
                                            periodKey: period.id, range: period.range,
                                            evaluationPeriodId: period.id)
        return try await generate(report: report, facts: facts, mode: mode, useAI: useAI)
    }

    // MARK: - 편집·확정·stale

    public func edit(versionId: String, content: String) throws -> ReportVersion {
        try store.edit(versionId: versionId, content: content)
    }

    /// store.confirm 후, 리포트에 evaluationPeriodId가 있으면 평가 기간에 연결한다.
    public func confirm(versionId: String) throws -> ReportVersion {
        let version = try store.confirm(versionId: versionId)
        if let report = try repo.report(id: version.reportId), let periodId = report.evaluationPeriodId {
            try evaluationPeriods.markConfirmed(periodId: periodId, reportVersionId: version.id)
        }
        return version
    }

    /// 같은 range/family/periodType/planRange로 facts를 knownAt=now로 다시 만들어 stale 여부를 본다.
    public func isStale(versionId: String) throws -> Bool {
        guard let version = try repo.reportVersion(id: versionId) else {
            throw WorkLogError.notFound("report_version \(versionId)")
        }
        guard let report = try repo.report(id: version.reportId) else {
            throw WorkLogError.notFound("report \(version.reportId)")
        }
        let facts = try factsBuilder.build(family: report.family, periodType: report.periodType,
                                           range: report.range, knownAt: repo.clock.now(),
                                           planRange: report.planRange)
        return try store.isStale(versionId: versionId, currentFacts: facts)
    }

    // MARK: - 공통 파이프라인

    private func generate(report: Report, facts: ReportFacts, mode: GenerationMode,
                          useAI: Bool) async throws -> ReportGenerationResult {
        let deterministic = try makeDeterministicDraft(facts)

        // 자동 모드 + 원본 변화 없음 → AI 호출 없이 기존 버전 유지(PERF-05).
        if mode == .automatic,
           let latest = try store.bundle(reportId: report.id).latest,
           let snapshot = try repo.sourceSnapshot(id: latest.sourceSnapshotId),
           snapshot.digest == (try ReportFactsBuilder.digest(facts)) {
            let outcome = try store.saveGenerated(reportId: report.id, facts: facts,
                                                  draft: deterministic.draft, mode: mode)
            return ReportGenerationResult(outcome: outcome, report: report, facts: facts,
                                          findings: deterministic.findings, aiJobStatus: nil,
                                          usedFallback: false, aiSkippedUnchanged: true)
        }

        // AI 미사용 → 결정적 초안 저장.
        guard useAI, let runner else {
            let outcome = try store.saveGenerated(reportId: report.id, facts: facts,
                                                  draft: deterministic.draft, mode: mode)
            return ReportGenerationResult(outcome: outcome, report: report, facts: facts,
                                          findings: deterministic.findings, aiJobStatus: nil,
                                          usedFallback: false, aiSkippedUnchanged: false)
        }

        // 템플릿 확보 (없으면 기본값 시드 후 재시도).
        var template = try templates.preferredTemplate(for: templatePurpose(for: facts))
        if template == nil {
            try templates.seedDefaults()
            template = try templates.preferredTemplate(for: templatePurpose(for: facts))
        }
        guard let template, let version = try templates.activeVersion(templateId: template.id) else {
            let fallback = fallbackDraft(deterministic.draft,
                                         warning: "AI 템플릿을 찾지 못해 기록 기반 초안을 사용했습니다.")
            let outcome = try store.saveGenerated(reportId: report.id, facts: facts,
                                                  draft: fallback, mode: mode)
            return ReportGenerationResult(outcome: outcome, report: report, facts: facts,
                                          findings: deterministic.findings, aiJobStatus: nil,
                                          usedFallback: true, aiSkippedUnchanged: false)
        }

        let jobType: AIJobType = facts.family == .submission ? .submissionWeekly : .performanceReport
        let instructions = substitutePlaceholders(
            try templates.composeInstructions(versionId: version.id), facts: facts)
        // 실행 시각(generatedAt·knownAt)은 내용이 아니므로 payload에서 고정값으로 둔다.
        // 그래야 같은 원본의 자동 재시도가 같은 idempotency key를 써서 재시도 한도가 적용된다.
        var payloadFacts = facts
        payloadFacts.generatedAt = Date(timeIntervalSince1970: 0)
        payloadFacts.knownAt = Date(timeIntervalSince1970: 0)
        let payloadJSON = try StableJSON.string(
            AIPayload(jobType: jobType.rawValue, facts: payloadFacts))
        let request = AIJobRequest(
            jobType: jobType, periodStart: facts.range.start, periodEndExclusive: facts.range.endExclusive,
            instructions: instructions, payloadJSON: payloadJSON, templateVersionId: version.id,
            regenerationNonce: mode == .userRequested ? repo.ids.make() : nil)

        let result = try await runner.submit(request)
        let aiJobStatus = result.job.status

        // AI 실패·차단 → 기록 기반 초안으로 대체(REP-T18).
        guard result.job.status == .succeeded, let output = result.output else {
            let fallback = fallbackDraft(
                deterministic.draft,
                warning: "AI 초안을 만들지 못해 기록 기반 초안을 사용했습니다(\(result.job.status.rawValue))")
            let outcome = try store.saveGenerated(reportId: report.id, facts: facts,
                                                  draft: fallback, mode: mode)
            return ReportGenerationResult(outcome: outcome, report: report, facts: facts,
                                          findings: deterministic.findings, aiJobStatus: aiJobStatus,
                                          usedFallback: true, aiSkippedUnchanged: false)
        }

        // AI 성공 → 로컬 검증. 파싱 실패·검증 오류면 기록 기반 초안으로 대체(REP-T15).
        let rawJSON = output.rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let aiDraft: StructuredDraft
        do {
            aiDraft = try decodeStructured(rawJSON, family: facts.family)
        } catch {
            let findings = [ValidationFinding(severity: .error, code: "ai_output_invalid",
                                              message: "AI 초안 JSON을 해석하지 못했습니다.")]
            let fallback = fallbackDraft(
                deterministic.draft,
                warning: "AI 초안 검증 실패로 기록 기반 초안을 사용했습니다: ai_output_invalid")
            let outcome = try store.saveGenerated(reportId: report.id, facts: facts,
                                                  draft: fallback, mode: mode)
            return ReportGenerationResult(outcome: outcome, report: report, facts: facts,
                                          findings: findings, aiJobStatus: aiJobStatus,
                                          usedFallback: true, aiSkippedUnchanged: false)
        }

        let findings = validate(aiDraft, facts: facts)
        if hasErrors(findings) {
            let codes = findings.filter { $0.severity == .error }.map(\.code).joined(separator: ", ")
            let fallback = fallbackDraft(
                deterministic.draft,
                warning: "AI 초안 검증 실패로 기록 기반 초안을 사용했습니다: \(codes)")
            let outcome = try store.saveGenerated(reportId: report.id, facts: facts,
                                                  draft: fallback, mode: mode)
            return ReportGenerationResult(outcome: outcome, report: report, facts: facts,
                                          findings: findings, aiJobStatus: aiJobStatus,
                                          usedFallback: true, aiSkippedUnchanged: false)
        }

        // 검증 통과 → AI 초안 저장.
        let warningMessages = findings.filter { $0.severity == .warning }.map(\.message)
        var warnings = aiDraft.warnings
        warnings.append(contentsOf: warningMessages)
        let draft = GeneratedDraft(
            content: render(aiDraft), structuredJSON: try aiDraft.structuredJSON(),
            warnings: warnings, generator: "codex", aiModel: output.model,
            templateVersionId: version.id,
            skillRef: result.skill.map { "\($0.name)@\($0.contentHash ?? "-")" },
            evidence: evidence(aiDraft))
        let outcome = try store.saveGenerated(reportId: report.id, facts: facts, draft: draft, mode: mode)
        return ReportGenerationResult(outcome: outcome, report: report, facts: facts,
                                      findings: findings, aiJobStatus: aiJobStatus,
                                      usedFallback: false, aiSkippedUnchanged: false)
    }

    // MARK: - 결정적 초안

    private func makeDeterministicDraft(_ facts: ReportFacts) throws -> (draft: GeneratedDraft,
                                                                        findings: [ValidationFinding]) {
        switch facts.family {
        case .submission:
            let structured = SubmissionComposer.compose(facts)
            let draft = GeneratedDraft(
                content: SubmissionComposer.render(structured),
                structuredJSON: try StableJSON.string(structured),
                warnings: structured.warnings, generator: "deterministic",
                evidence: evidence(.submission(structured)))
            return (draft, SubmissionValidator.validate(structured, facts: facts))
        case .performance:
            let structured = PerformanceComposer.compose(facts)
            let draft = GeneratedDraft(
                content: PerformanceComposer.render(structured),
                structuredJSON: try StableJSON.string(structured),
                warnings: structured.warnings, generator: "deterministic",
                evidence: evidence(.performance(structured)))
            return (draft, PerformanceValidator.validate(structured, facts: facts))
        }
    }

    private func fallbackDraft(_ base: GeneratedDraft, warning: String) -> GeneratedDraft {
        var draft = base
        draft.warnings.append(warning)
        return draft
    }

    // MARK: - 구조화 초안

    private enum StructuredDraft {
        case submission(SubmissionDraft)
        case performance(PerformanceDraft)

        var warnings: [String] {
            switch self {
            case .submission(let draft): return draft.warnings
            case .performance(let draft): return draft.warnings
            }
        }

        func structuredJSON() throws -> String {
            switch self {
            case .submission(let draft): return try StableJSON.string(draft)
            case .performance(let draft): return try StableJSON.string(draft)
            }
        }
    }

    private func decodeStructured(_ rawJSON: String, family: ReportFamily) throws -> StructuredDraft {
        switch family {
        case .submission:
            return .submission(try StableJSON.decode(SubmissionDraft.self, from: rawJSON))
        case .performance:
            return .performance(try StableJSON.decode(PerformanceDraft.self, from: rawJSON))
        }
    }

    private func validate(_ draft: StructuredDraft, facts: ReportFacts) -> [ValidationFinding] {
        switch draft {
        case .submission(let structured): return SubmissionValidator.validate(structured, facts: facts)
        case .performance(let structured): return PerformanceValidator.validate(structured, facts: facts)
        }
    }

    private func hasErrors(_ findings: [ValidationFinding]) -> Bool {
        findings.contains { $0.severity == .error }
    }

    private func render(_ draft: StructuredDraft) -> String {
        switch draft {
        case .submission(let structured): return SubmissionComposer.render(structured)
        case .performance(let structured): return PerformanceComposer.render(structured)
        }
    }

    private func evidence(_ draft: StructuredDraft) -> [DraftEvidence] {
        switch draft {
        case .submission(let structured):
            return structured.groups.flatMap(\.items).flatMap { item in
                item.evidenceIds.map {
                    DraftEvidence(itemId: item.itemId, taskId: item.taskIds.first, sourceId: $0)
                }
            }
        case .performance(let structured):
            return structured.sections.flatMap(\.items).flatMap { item in
                item.evidenceIds.map {
                    DraftEvidence(itemId: item.itemId, taskId: item.taskIds.first, sourceId: $0)
                }
            }
        }
    }

    // MARK: - 템플릿·플레이스홀더

    private func templatePurpose(for facts: ReportFacts) -> TemplatePurpose {
        switch facts.family {
        case .submission:
            return .submissionWeekly
        case .performance:
            return facts.periodType == .daily ? .performanceDaily : .performancePeriodic
        }
    }

    /// 있는 플레이스홀더만 치환한다. 날짜는 WorkDate.iso, 상태 기준 시각은 ISO8601.
    private func substitutePlaceholders(_ text: String, facts: ReportFacts) -> String {
        var result = text
        for (key, value) in placeholderValues(facts) {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }

    private func placeholderValues(_ facts: ReportFacts) -> [String: String] {
        var values: [String: String] = [
            "previousWeekStart": facts.range.start.iso,
            "previousWeekEndExclusive": facts.range.endExclusive.iso,
            "targetDate": facts.range.start.iso,
            "targetStart": facts.range.start.iso,
            "targetEndExclusive": facts.range.endExclusive.iso,
            "periodType": facts.periodType.rawValue,
            "statusCutoff": Self.iso8601(facts.statusCutoff, timeZone: facts.timezone),
        ]
        if let plan = facts.planRange {
            values["currentWeekStart"] = plan.start.iso
            values["currentWeekEndExclusive"] = plan.endExclusive.iso
        }
        return values
    }

    private static func iso8601(_ date: Date, timeZone: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: timeZone) ?? TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

/// AI 입력 페이로드 계약(jobType + facts). Secret 자료형을 포함하지 않는다.
private struct AIPayload: Codable {
    var jobType: String
    var facts: ReportFacts
}
