import XCTest
@testable import WorkLogCore

final class ReportsPlanPresentationTests: XCTestCase {
    private var roots: [URL] = []
    private let monday = WorkDate("2026-10-05")!
    private let prior = WorkDate("2026-09-30")!
    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []; super.tearDown()
    }
    private func environment(provider: AIProvider? = nil, aiEnabled: Bool = true) throws -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReportsPlanPresentationTests-\(UUID().uuidString)")
        roots.append(root)
        let paths = AppPaths(dataRoot: root.appendingPathComponent("data"), backupRoot: root.appendingPathComponent("backups"))
        var settings = AppSettings(); settings.aiEnabled = aiEnabled
        try SettingsStore(fileURL: paths.settingsFile).save(settings)
        return try AppEnvironment.open(AppEnvironmentOptions(paths: paths, keyStore: InMemoryVaultKeyStore(),
            authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(), aiProvider: provider,
            clock: FixedClock(WorkCalendar().startOfDay(monday)), ids: SequentialIDGenerator()))
    }
    @MainActor func testSubmissionAndPerformanceHaveSeparateIDsFamiliesAndLists() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "공통 업무", initialStatus: .inProgress, workDate: prior, projectNames: ["A", "B"])
        _ = try env.tasks.addActivity(taskId: task.id, body: "검증한 수행 근거", workDate: prior)
        let model = ReportsModel(environment: env)
        XCTAssertEqual(model.reportDate, monday)
        XCTAssertFalse(model.useAI)
        await model.generate()
        let submission = try XCTUnwrap(model.report)
        XCTAssertEqual(submission.family, .submission)
        XCTAssertEqual(submission.range, env.periods.submissionWeek(reportDate: monday).previous)
        XCTAssertEqual(submission.planRange, env.periods.submissionWeek(reportDate: monday).plan)
        model.family = .performance; model.performanceDate = prior
        model.loadSelection(); await model.generate()
        let performance = try XCTUnwrap(model.report)
        XCTAssertEqual(performance.family, .performance)
        XCTAssertNotEqual(submission.id, performance.id)
        XCTAssertNotEqual(model.submissionReports.first?.id, model.performanceReports.first?.id)
        XCTAssertTrue(model.visibleReports.allSatisfy { $0.family == .performance })
        XCTAssertFalse(model.evidence.isEmpty)
    }
    @MainActor func testEditingRequiresSaveAndConfirmedVersionCannotBeEdited() async throws {
        let env = try environment(); let model = ReportsModel(environment: env)
        await model.generate()
        let id = try XCTUnwrap(model.version?.id)
        model.content = "검토한 제출용 문장"
        XCTAssertTrue(model.hasChanges)
        model.confirm()
        XCTAssertEqual(model.version?.state, .draft)
        model.saveEdits()
        XCTAssertEqual(model.version?.state, .edited)
        XCTAssertFalse(model.hasChanges)
        model.confirm()
        XCTAssertEqual(model.version?.state, .confirmed)
        XCTAssertFalse(model.canEdit)
        model.content = "확정본 수정 시도"; model.saveEdits()
        XCTAssertEqual(try env.repo.reportVersion(id: id)?.content, "검토한 제출용 문장")
        XCTAssertEqual(try env.repo.reportVersions(reportId: XCTUnwrap(model.report?.id)).count, 1)
        await model.generate()
        XCTAssertEqual(model.version?.version, 2)
        XCTAssertEqual(try env.repo.reportVersion(id: id)?.state, .confirmed)
    }
    @MainActor func testUnstoredEditsSurviveReloadAndPreventRegeneration() async throws {
        let env = try environment(); let model = ReportsModel(environment: env)
        await model.generate()
        let id = model.version?.id
        model.content = "아직 저장하지 않은 문장"; model.load(); model.loadSelection()
        await model.generate()
        XCTAssertEqual(model.version?.id, id)
        XCTAssertEqual(model.content, "아직 저장하지 않은 문장")
        model.discardEdits(); XCTAssertFalse(model.hasChanges)
    }
    @MainActor func testRequestedHistoricalVersionSurvivesAppearanceAndControlReloadsWithoutGeneration() async throws {
        let provider = MockAIProvider(); let env = try environment(provider: provider)
        let task = try env.tasks.createTask(title: "버전별 수행 근거", initialStatus: .inProgress, workDate: prior)
        _ = try env.tasks.addActivity(taskId: task.id, body: "첫 버전의 수행 근거", workDate: prior)
        let writer = ReportsModel(environment: env); writer.useAI = false
        await writer.generate()
        let historical = try XCTUnwrap(writer.version)
        _ = try env.tasks.addActivity(taskId: task.id, body: "다음 버전에 추가한 근거", workDate: prior)
        await writer.generate()
        XCTAssertNotEqual(writer.version?.id, historical.id)
        let versionsBefore = try env.repo.reportVersions(reportId: historical.reportId)
        let evidence = try env.repo.reportEvidence(versionId: historical.id)
        XCTAssertFalse(evidence.isEmpty)
        XCTAssertGreaterThan(writer.evidence.count, evidence.count)

        let model = ReportsModel(environment: env)
        model.reportDate = env.calendar.adding(days: 14, to: monday)
        model.requestVersionSelection(historical.id)
        model.loadSelection() // ReportsScreen.onAppear
        XCTAssertEqual(model.report?.id, historical.reportId)
        XCTAssertEqual(model.version?.id, historical.id)
        XCTAssertEqual(model.version?.state, .superseded)
        XCTAssertEqual(model.content, historical.content)
        XCTAssertEqual(model.reportDate, monday)
        model.loadSelection() // ReportsScreen.onChange after the navigation updates its controls
        XCTAssertEqual(model.version?.id, historical.id)
        XCTAssertEqual(model.evidence, evidence)
        XCTAssertEqual(try env.repo.reportVersions(reportId: historical.reportId).map(\.id), versionsBefore.map(\.id))
        XCTAssertEqual(provider.runCount, 0)
        XCTAssertNil(model.errorMessage)
    }
    @MainActor func testRequestedPerformanceVersionOverridesPreviousEvaluationAndPeriodSelection() async throws {
        let env = try environment()
        let writer = ReportsModel(environment: env)
        writer.family = .performance; writer.periodType = .monthly; writer.performanceDate = prior
        await writer.generate(); writer.confirm()
        let historical = try XCTUnwrap(writer.version)
        let selectedReport = try XCTUnwrap(writer.report)
        await writer.generate()

        let model = ReportsModel(environment: env)
        model.family = .performance; model.periodType = .daily
        model.evaluationPeriodId = "previous-evaluation"
        model.requestVersionSelection(historical.id)
        model.loadSelection(); model.loadSelection()
        XCTAssertEqual(model.family, .performance)
        XCTAssertEqual(model.periodType, .monthly)
        XCTAssertEqual(model.performanceDate, selectedReport.range.start)
        XCTAssertNil(model.evaluationPeriodId)
        XCTAssertEqual(model.version?.id, historical.id)
        XCTAssertNil(model.errorMessage)
    }
    @MainActor func testRequestedEvaluationVersionSurvivesFamilyAndPeriodReloads() async throws {
        let env = try environment()
        let writer = ReportsModel(environment: env)
        writer.family = .performance; writer.evaluationStart = prior; writer.evaluationEnd = monday
        writer.proposeEvaluation(); writer.createEvaluation()
        await writer.generate(); writer.confirm()
        let historical = try XCTUnwrap(writer.version)
        let periodId = try XCTUnwrap(writer.evaluationPeriodId)
        await writer.generate()

        let model = ReportsModel(environment: env)
        model.requestVersionSelection(historical.id)
        model.loadSelection(); model.loadSelection()
        XCTAssertEqual(model.family, .performance)
        XCTAssertEqual(model.evaluationPeriodId, periodId)
        XCTAssertEqual(model.report?.periodType, .yearly)
        XCTAssertEqual(model.version?.id, historical.id)
        XCTAssertNil(model.errorMessage)
    }
    @MainActor func testPendingVersionIsConsumedBeforeNavigatingToAnotherPeriod() async throws {
        let env = try environment(); let writer = ReportsModel(environment: env)
        await writer.generate(); writer.confirm()
        let historicalId = try XCTUnwrap(writer.version?.id)
        await writer.generate()
        let latestId = try XCTUnwrap(writer.version?.id)
        let nextMonday = env.calendar.adding(days: 7, to: monday)
        writer.reportDate = nextMonday; writer.loadSelection(); await writer.generate()
        let nextWeekId = try XCTUnwrap(writer.version?.id)

        let model = ReportsModel(environment: env)
        model.requestVersionSelection(historicalId); model.loadSelection()
        XCTAssertEqual(model.version?.id, historicalId)
        model.reportDate = nextMonday; model.loadSelection()
        XCTAssertEqual(model.version?.id, nextWeekId)
        model.reportDate = monday; model.loadSelection()
        XCTAssertEqual(model.version?.id, latestId)
    }
    @MainActor func testVersionNavigationDoesNotDiscardUnsavedEditsOrLeaveARequestBehind() async throws {
        let env = try environment(); let model = ReportsModel(environment: env)
        await model.generate(); model.confirm()
        let historicalId = try XCTUnwrap(model.version?.id)
        await model.generate()
        let latestId = try XCTUnwrap(model.version?.id)
        model.content = "저장 전 본문"
        model.requestVersionSelection(historicalId); model.loadSelection()
        XCTAssertEqual(model.version?.id, latestId)
        XCTAssertEqual(model.content, "저장 전 본문")
        model.discardEdits(); model.loadSelection()
        XCTAssertEqual(model.version?.id, latestId)
    }
    @MainActor func testMissingRequestedVersionReportsAnErrorAndConsumesTheRequest() async throws {
        let env = try environment(); let model = ReportsModel(environment: env)
        await model.generate()
        let currentId = try XCTUnwrap(model.version?.id)
        model.requestVersionSelection("missing-version"); model.loadSelection()
        XCTAssertEqual(model.version?.id, currentId)
        XCTAssertNotNil(model.errorMessage)
        model.loadSelection()
        XCTAssertEqual(model.version?.id, currentId)
        XCTAssertNil(model.errorMessage)
    }
    @MainActor func testExplicitSelectionOrReloadDiscardsPendingVersionRequest() async throws {
        let env = try environment(); let writer = ReportsModel(environment: env)
        await writer.generate(); writer.confirm()
        let historicalId = try XCTUnwrap(writer.version?.id)
        await writer.generate()
        let reportId = try XCTUnwrap(writer.report?.id)
        let latestId = try XCTUnwrap(writer.version?.id)

        let model = ReportsModel(environment: env)
        model.requestVersionSelection(historicalId)
        model.load() // 사용자 새로고침
        model.loadSelection()
        XCTAssertEqual(model.version?.id, latestId, "load가 보류 버전 요청을 폐기한다")

        model.requestVersionSelection(historicalId)
        model.selectVersion(latestId)
        model.loadSelection()
        XCTAssertEqual(model.version?.id, latestId, "직접 선택한 버전 뒤 보류 요청이 되살아나지 않는다")

        model.requestVersionSelection(historicalId)
        model.selectReport(reportId)
        model.loadSelection()
        XCTAssertEqual(model.version?.id, latestId, "리포트 직접 선택 뒤 보류 요청이 되살아나지 않는다")
    }
    @MainActor func testPlanCandidatesCheckConfirmAndScopeKeepTaskStateUnchanged() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "공통 계획", workDate: prior, checklist: ["검증 범위"])
        let held = try env.tasks.createTask(title: "보류", initialStatus: .onHold, workDate: prior, dueOn: monday)
        let cancelled = try env.tasks.createTask(title: "취소", initialStatus: .cancelled, workDate: prior, dueOn: monday)
        let model = PlanModel(environment: env); model.load(); model.generateCandidates()
        XCTAssertEqual(model.weekStart, monday)
        XCTAssertFalse(model.candidates.contains { $0.taskId == held.id || $0.taskId == cancelled.id })
        XCTAssertTrue(model.confirmed.isEmpty)
        let item = try XCTUnwrap(model.candidates.first { $0.scopeType == .checklistItem })
        model.check(item.id, selected: true)
        XCTAssertTrue(model.confirmed.isEmpty)
        model.confirmChecked()
        XCTAssertEqual(model.confirmed.map(\.id), [item.id])
        XCTAssertEqual(model.candidates.count, 1)
        XCTAssertEqual(try env.tasks.currentStatus(taskId: task.id), .planned)
        XCTAssertNil(try env.tasks.detail(taskId: task.id).firstStartedOn)
        model.labels[item.id] = "사용자 계획 문구"; model.saveLabel(item.id)
        XCTAssertEqual(model.confirmed.first?.label, "사용자 계획 문구")
        model.unconfirm(item.id); XCTAssertTrue(model.confirmed.isEmpty)
        model.check(item.id, selected: true); model.confirmChecked(); model.exclude(item.id)
        XCTAssertEqual(model.excluded.map(\.id), [item.id])
        XCTAssertTrue(try env.plans.confirmedFacts(weekStart: monday).isEmpty)
        XCTAssertEqual(try env.tasks.currentStatus(taskId: task.id), .planned)
    }
    @MainActor func testManualHeldCandidateIsNotAutomaticallyConfirmedOrResumed() async throws {
        let env = try environment()
        let held = try env.tasks.createTask(title: "보류 업무", initialStatus: .onHold, workDate: prior)
        let model = PlanModel(environment: env); model.load(); model.addTask(held.id)
        XCTAssertEqual(model.candidates.count, 1); XCTAssertTrue(model.confirmed.isEmpty)
        model.confirmChecked(); XCTAssertTrue(model.confirmed.isEmpty)
        let item = try XCTUnwrap(model.candidates.first)
        model.check(item.id, selected: true); model.confirmChecked()
        XCTAssertEqual(try env.tasks.currentStatus(taskId: held.id), .onHold)
        model.selectWeek(env.calendar.adding(days: 7, to: monday))
        XCTAssertTrue(model.checkedIds.isEmpty); XCTAssertTrue(model.items.isEmpty)
    }
    @MainActor func testPlanLoadFailureClearsPreviouslyLoadedWeek() throws {
        let env = try environment()
        _ = try env.tasks.createTask(title: "기존 계획", workDate: prior)
        let model = PlanModel(environment: env)
        model.generateCandidates()
        let item = try XCTUnwrap(model.candidates.first)
        model.check(item.id, selected: true)
        model.labels[item.id] = "저장하지 않은 표시 문구"
        XCTAssertNotNil(model.plan)
        XCTAssertFalse(model.tasks.isEmpty)
        env.repo.db.close()
        model.weekStart = env.calendar.adding(days: 7, to: monday)
        model.load()
        XCTAssertNil(model.plan)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(model.tasks.isEmpty)
        XCTAssertTrue(model.checkedIds.isEmpty)
        XCTAssertTrue(model.labels.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }
    @MainActor func testReportNavigationClearsEvaluationProposal() async throws {
        let env = try environment()
        let model = ReportsModel(environment: env)
        model.family = .performance
        model.evaluationStart = prior; model.evaluationEnd = monday
        model.proposeEvaluation(); XCTAssertNotNil(model.proposal)
        model.family = .submission; model.loadSelection()
        XCTAssertNil(model.proposal)
        await model.generate()
        let reportId = try XCTUnwrap(model.report?.id)
        model.proposeEvaluation(); XCTAssertNotNil(model.proposal)
        model.selectReport(reportId)
        XCTAssertNil(model.proposal)
        model.proposeEvaluation(); XCTAssertNotNil(model.proposal)
        model.selectVersion(try XCTUnwrap(model.version?.id))
        XCTAssertNil(model.proposal)
    }
    @MainActor func testAIOnlyRunsOnExplicitGenerationWithUseAIEnabled() async throws {
        let provider = MockAIProvider(); let env = try environment(provider: provider)
        let model = ReportsModel(environment: env)
        XCTAssertTrue(model.useAI); XCTAssertTrue(model.isAIAvailable)
        model.load(); model.loadSelection(); XCTAssertEqual(provider.runCount, 0)
        model.useAI = false; await model.generate(); XCTAssertEqual(provider.runCount, 0)
        model.useAI = true; await model.generate(); XCTAssertEqual(provider.runCount, 1)
        XCTAssertTrue(model.usedFallback); XCTAssertFalse(model.findings.isEmpty)
        XCTAssertEqual(model.aiJobStatus, .succeeded)
        model.family = .performance; model.loadSelection()
        model.useAI = false; await model.generate(); XCTAssertEqual(provider.runCount, 1)
        model.useAI = true; await model.generate(); XCTAssertEqual(provider.runCount, 2)
        model.load(); model.selectVersion(try XCTUnwrap(model.versions.first?.id))
        XCTAssertEqual(provider.runCount, 2)
    }
    @MainActor func testQuizUnavailableWithoutAIAndWhenSettingsDisableAI() async throws {
        let quiz = QuizModel(environment: try environment())
        XCTAssertFalse(quiz.isAvailable); XCTAssertFalse(quiz.canGenerate)
        await quiz.generate(reportDate: monday); XCTAssertTrue(quiz.questions.isEmpty)
        let provider = MockAIProvider(); let env = try environment(provider: provider, aiEnabled: false)
        let disabled = QuizModel(environment: env)
        XCTAssertFalse(disabled.canGenerate)
        await disabled.generate(reportDate: monday)
        let reports = ReportsModel(environment: env); reports.useAI = true; await reports.generate()
        XCTAssertFalse(reports.isAIAvailable); XCTAssertEqual(provider.runCount, 0)
    }
    @MainActor func testQuizAnswerAndSkipAreRecordedForPriorPeriodWithoutChangingSubmission() async throws {
        let provider = MockAIProvider(responses: [.evidenceQuiz: """
        {"schemaVersion":1,"jobType":"evidence_quiz","questions":[
          {"taskId":"quiz-task","topicKey":"outcome","question":"확인한 결과는 무엇인가요?","evidenceIds":[]},
          {"taskId":"quiz-task","topicKey":"why","question":"왜 필요했나요?","evidenceIds":[]}
        ]}
        """])
        let env = try environment(provider: provider)
        let now = env.options.clock.now()
        try env.repo.insertTask(WorkTask(id: "quiz-task", title: "성과 대상", createdAt: now))
        try env.repo.appendEvent(DomainEvent(id: "quiz-event", taskId: "quiz-task", scopeType: .task,
            scopeId: "quiz-task", kind: .created, toStatus: .inProgress, effectiveDate: prior,
            effectiveOrder: 1, recordedAt: now))
        let reports = ReportsModel(environment: env); reports.useAI = false
        await reports.generate(); reports.confirm()
        let body = try XCTUnwrap(reports.version?.content)
        let quiz = QuizModel(environment: env)
        XCTAssertEqual(provider.runCount, 0)
        await quiz.generate(reportDate: monday)
        XCTAssertEqual(provider.runCount, 1)
        XCTAssertEqual(quiz.questions.count, 2)
        let answer = try XCTUnwrap(quiz.questions.first)
        quiz.answers[answer.id] = "검증 결과를 확인했습니다."
        quiz.record(answer.id, outcome: .answered)
        quiz.record(answer.id, outcome: .answered)
        quiz.record(try XCTUnwrap(quiz.questions.last?.id), outcome: .later)
        let stored = try env.repo.supplements(taskId: "quiz-task")
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(stored.first?.applies, env.periods.submissionWeek(reportDate: monday).previous)
        XCTAssertEqual(stored.first?.recordedAt, now)
        XCTAssertEqual(stored.first?.outcome, .answered)
        XCTAssertEqual(stored.last?.outcome, .later)
        XCTAssertEqual(reports.version?.content, body)
        XCTAssertEqual(try env.tasks.currentStatus(taskId: "quiz-task"), .inProgress)
    }
    @MainActor func testStaleWarningAndNewVersionPreserveConfirmedBody() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "진행 업무", initialStatus: .inProgress, workDate: prior)
        let model = ReportsModel(environment: env); await model.generate(); model.confirm()
        let confirmed = try XCTUnwrap(model.version)
        _ = try env.tasks.addActivity(taskId: task.id, body: "늦게 추가한 지난주 근거", workDate: prior)
        model.checkStale(); XCTAssertTrue(model.isStale)
        await model.generate()
        XCTAssertNotEqual(model.version?.id, confirmed.id)
        XCTAssertEqual(try env.repo.reportVersion(id: confirmed.id)?.content, confirmed.content)
        XCTAssertEqual(try env.repo.reportVersion(id: confirmed.id)?.state, .confirmed)
    }
    @MainActor func testEvaluationProposalCreateGenerateAndConfirmUseFixedRange() async throws {
        let env = try environment(); let model = ReportsModel(environment: env)
        model.family = .performance; model.evaluationStart = prior; model.evaluationEnd = monday
        model.proposeEvaluation()
        let proposed = try XCTUnwrap(model.proposal)
        model.createEvaluation()
        XCTAssertEqual(model.evaluationPeriods.count, 1)
        await model.generate()
        XCTAssertEqual(model.report?.range, proposed.range)
        XCTAssertEqual(model.report?.periodType, .yearly)
        let periodId = try XCTUnwrap(model.evaluationPeriodId)
        model.confirm()
        XCTAssertEqual(try env.repo.evaluationPeriod(id: periodId)?.confirmedReportVersionId, model.version?.id)
        model.deriveEvaluationStart = true; model.evaluationEnd = env.calendar.adding(days: 8, to: monday)
        model.proposeEvaluation()
        XCTAssertEqual(model.proposal?.range.start, proposed.range.endExclusive)
        model.evaluationEnd = prior; XCTAssertNil(model.proposal)
    }
    @MainActor func testSubmissionInclusionIsExplicitAndDoesNotChangeTask() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "보고에서 제외할 업무", initialStatus: .inProgress, workDate: prior)
        let model = ReportsModel(environment: env); await model.generate()
        let draft = try XCTUnwrap(model.submissionDraft)
        XCTAssertFalse(draft.groups.flatMap(\.items).isEmpty)
        model.includedSubmissionIds = []; model.applySubmissionSelection()
        XCTAssertFalse(model.content.contains(task.title)); XCTAssertTrue(model.hasChanges)
        model.saveEdits(); model.confirm()
        XCTAssertFalse(try XCTUnwrap(model.version).content.contains(task.title))
        XCTAssertEqual(try env.tasks.currentStatus(taskId: task.id), .inProgress)
    }
}
