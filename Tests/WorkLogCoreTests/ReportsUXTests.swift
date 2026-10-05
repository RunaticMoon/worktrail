import XCTest
@testable import WorkLogCore

/// 작업 E(UXFL-E55A): 주간보고 자동 초안, 재생성 보호·비교, 복사·확정 문구, 성과 질문 한 장씩.
final class ReportsUXTests: XCTestCase {
    private var roots: [URL] = []
    private let monday = WorkDate("2026-10-05")!
    private let prior = WorkDate("2026-09-30")!

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []; super.tearDown()
    }

    private func environment(provider: AIProvider? = nil, aiEnabled: Bool = true) throws -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReportsUXTests-\(UUID().uuidString)")
        roots.append(root)
        let paths = AppPaths(dataRoot: root.appendingPathComponent("data"),
                             backupRoot: root.appendingPathComponent("backups"))
        var settings = AppSettings(); settings.aiEnabled = aiEnabled
        try SettingsStore(fileURL: paths.settingsFile).save(settings)
        return try AppEnvironment.open(AppEnvironmentOptions(
            paths: paths, keyStore: InMemoryVaultKeyStore(),
            authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(),
            aiProvider: provider, clock: FixedClock(WorkCalendar().startOfDay(monday)),
            ids: SequentialIDGenerator()))
    }

    private func versionCount(_ env: AppEnvironment, reportId: String) throws -> Int {
        try env.repo.reportVersions(reportId: reportId).count
    }

    // MARK: - 1. 기록 기반 초안 자동 준비

    @MainActor func testEnsureDraftCreatesDeterministicDraftOnceWithoutAI() async throws {
        let provider = MockAIProvider()
        let env = try environment(provider: provider)
        let task = try env.tasks.createTask(title: "자동 초안 대상", initialStatus: .inProgress, workDate: prior)
        _ = try env.tasks.addActivity(taskId: task.id, body: "수행 근거", workDate: prior)
        let model = ReportsModel(environment: env)
        XCTAssertTrue(model.useAI)

        await model.ensureDraftForCurrentPeriod()
        XCTAssertEqual(provider.runCount, 0, "자동 준비는 AI를 호출하지 않는다")
        let report = try XCTUnwrap(model.report)
        XCTAssertEqual(report.family, .submission)
        XCTAssertEqual(model.version?.state, .draft)
        XCTAssertEqual(model.version?.generator, "deterministic")
        XCTAssertEqual(try versionCount(env, reportId: report.id), 1)

        // 두 번 호출해도 버전이 늘지 않는다.
        await model.ensureDraftForCurrentPeriod()
        XCTAssertEqual(try versionCount(env, reportId: report.id), 1)
        XCTAssertEqual(provider.runCount, 0)
    }

    @MainActor func testEnsureDraftDoesNotTouchPerformanceAndLeavesExistingReport() async throws {
        let env = try environment()
        let model = ReportsModel(environment: env)
        model.family = .performance
        await model.ensureDraftForCurrentPeriod()
        XCTAssertTrue(try env.repo.reports(family: .performance).isEmpty, "성과자료는 자동 생성하지 않는다")

        // 이미 리포트가 있으면 create 없이 기존 선택만 한다.
        model.family = .submission
        await model.generate()
        let reportId = try XCTUnwrap(model.report?.id)
        await model.ensureDraftForCurrentPeriod()
        XCTAssertEqual(try versionCount(env, reportId: reportId), 1)
    }

    // MARK: - 2. 재생성 보호와 비교·적용/닫기

    @MainActor func testRegenerationKeepsEditedDisplayAndDefersNewVersion() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "재생성 보호", initialStatus: .inProgress, workDate: prior)
        _ = try env.tasks.addActivity(taskId: task.id, body: "검증 근거", workDate: prior)
        let model = ReportsModel(environment: env)
        await model.generate()
        model.content = "사용자가 손본 본문"
        model.saveEdits()
        let edited = try XCTUnwrap(model.version)
        XCTAssertEqual(edited.state, .edited)
        XCTAssertEqual(model.regenerateTitle, "새 초안 만들기(현재 본문 유지)")

        await model.generate()
        XCTAssertEqual(model.version?.id, edited.id, "화면은 기존 수정본을 유지한다")
        XCTAssertEqual(model.content, "사용자가 손본 본문")
        let pending = try XCTUnwrap(model.pendingRegeneration)
        XCTAssertNotEqual(pending.id, edited.id)
        XCTAssertEqual(pending.state, .draft)
        XCTAssertFalse(model.pendingDiff.isEmpty, "변경 비교 줄이 있어야 한다")
        XCTAssertTrue(model.pendingDiff.contains { $0.kind == .added || $0.kind == .removed })
        XCTAssertEqual(edited.state, .edited, "기존 수정본은 superseded 되지 않는다")
        XCTAssertEqual(try env.repo.reportVersion(id: edited.id)?.state, .edited)

        model.applyPendingRegeneration()
        XCTAssertEqual(model.version?.id, pending.id)
        XCTAssertNil(model.pendingRegeneration)
        XCTAssertEqual(model.content, pending.content)
    }

    @MainActor func testDismissLeavesDisplayedVersionAndKeepsNewVersionInHistory() async throws {
        let env = try environment()
        let model = ReportsModel(environment: env)
        await model.generate()
        model.content = "닫기 테스트 본문"
        model.saveEdits()
        let edited = try XCTUnwrap(model.version)
        await model.generate()
        let pending = try XCTUnwrap(model.pendingRegeneration)

        model.dismissPendingRegeneration()
        XCTAssertNil(model.pendingRegeneration)
        XCTAssertEqual(model.version?.id, edited.id)
        XCTAssertEqual(model.content, "닫기 테스트 본문")
        XCTAssertEqual(try versionCount(env, reportId: edited.reportId), 2)
        XCTAssertEqual(try env.repo.reportVersion(id: pending.id)?.state, .draft)
    }

    @MainActor func testConfirmedDisplayIsPreservedAndReadOnly() async throws {
        let env = try environment()
        let model = ReportsModel(environment: env)
        await model.generate()
        model.confirm()
        let confirmed = try XCTUnwrap(model.version)
        XCTAssertEqual(confirmed.state, .confirmed)

        await model.generate()
        XCTAssertEqual(model.version?.id, confirmed.id)
        XCTAssertEqual(model.version?.state, .confirmed)
        XCTAssertNotNil(model.pendingRegeneration)
        XCTAssertNotEqual(model.pendingRegeneration?.id, confirmed.id)
        XCTAssertFalse(model.canEdit)
        XCTAssertNotNil(model.readOnlyReason)
        XCTAssertEqual(model.regenerateTitle, "새 초안 만들기(현재 본문 유지)")
    }

    @MainActor func testSelectingAnotherVersionClearsPending() async throws {
        let env = try environment()
        let model = ReportsModel(environment: env)
        await model.generate()
        model.content = "편집본"; model.saveEdits()
        await model.generate()
        XCTAssertNotNil(model.pendingRegeneration)
        model.selectVersion(try XCTUnwrap(model.versions.first?.id))
        XCTAssertNil(model.pendingRegeneration)
    }

    // MARK: - 3. LineDiff

    func testLineDiffMarksSameAddedRemoved() {
        let diff = LineDiff.diff(old: "a\nb\nc", new: "a\nx\nc")
        XCTAssertEqual(diff, [
            DiffLine(kind: .same, text: "a"),
            DiffLine(kind: .removed, text: "b"),
            DiffLine(kind: .added, text: "x"),
            DiffLine(kind: .same, text: "c"),
        ])
        XCTAssertTrue(LineDiff.diff(old: "", new: "").isEmpty)
        XCTAssertEqual(LineDiff.diff(old: "", new: "새 줄"), [DiffLine(kind: .added, text: "새 줄")])
        XCTAssertEqual(LineDiff.diff(old: "옛 줄", new: ""), [DiffLine(kind: .removed, text: "옛 줄")])
    }

    func testLineDiffFallsBackForVeryLargeInput() {
        let old = (0..<(LineDiff.maxLCSLineCount + 1)).map { "o\($0)" }.joined(separator: "\n")
        let new = (0..<(LineDiff.maxLCSLineCount + 1)).map { "n\($0)" }.joined(separator: "\n")
        let diff = LineDiff.diff(old: old, new: new)
        XCTAssertEqual(diff.filter { $0.kind == .removed }.count, LineDiff.maxLCSLineCount + 1)
        XCTAssertEqual(diff.filter { $0.kind == .added }.count, LineDiff.maxLCSLineCount + 1)
        XCTAssertFalse(diff.contains { $0.kind == .same })
    }

    // MARK: - 4. 복사·확정·상태 라벨

    @MainActor func testMarkCopiedDoesNotChangeVersionState() async throws {
        let env = try environment()
        let model = ReportsModel(environment: env)
        await model.generate()
        let before = try XCTUnwrap(model.version)
        model.markCopied()
        XCTAssertEqual(model.statusMessage, "클립보드에 복사했습니다 · 제출 상태는 바뀌지 않습니다")
        XCTAssertEqual(model.version?.id, before.id)
        XCTAssertEqual(model.version?.state, .draft)
        XCTAssertEqual(try env.repo.reportVersion(id: before.id)?.state, .draft)
    }

    @MainActor func testConfirmMessageAndStateLabel() async throws {
        let env = try environment()
        let model = ReportsModel(environment: env)
        await model.generate()
        XCTAssertEqual(model.stateLabel, "초안 v1")
        model.confirm()
        XCTAssertEqual(model.version?.state, .confirmed)
        XCTAssertEqual(model.statusMessage, "확정본 v1 · 이후 수정은 새 버전으로 남습니다")
        XCTAssertEqual(model.stateLabel, "확정본 v1")
    }

    // MARK: - 5. 기간·양식 표시

    @MainActor func testPeriodAndPurposeLabels() async throws {
        let env = try environment()
        let model = ReportsModel(environment: env)
        XCTAssertEqual(model.periodType, .weekly)
        XCTAssertEqual(model.previousPeriodLabel,
                       "지난주 실적 9월 28일(월) ~ 10월 4일(일) · 일요일 종료 기준")
        XCTAssertEqual(model.planPeriodLabel, "이번 주 계획 10월 5일(월) ~ 10월 11일(일)")
        XCTAssertEqual(model.purposeLabel, "팀 제출용")
        model.family = .performance
        XCTAssertEqual(model.purposeLabel, "성과평가용 상세 기록")

        XCTAssertNil(model.templateLabel, "시드 전에는 활성 템플릿이 없다")
        _ = try env.templates.seedDefaults()
        XCTAssertEqual(model.templateLabel, "성과자료 v1")
        model.family = .submission
        XCTAssertEqual(model.templateLabel, "제출용 주간보고 v1")
    }

    // MARK: - 6. 성과 질문 한 장씩

    private func quizEnvironment(topicKeys: [String]) throws -> (AppEnvironment, MockAIProvider, String) {
        let taskId = "quiz-task"
        let questions = topicKeys.map {
            #"{"taskId":"\#(taskId)","topicKey":"\#($0)","question":"\#($0) 질문인가요?","evidenceIds":[]}"#
        }.joined(separator: ",")
        let provider = MockAIProvider(responses: [.evidenceQuiz:
            #"{"schemaVersion":1,"jobType":"evidence_quiz","questions":[\#(questions)]}"#])
        let env = try environment(provider: provider)
        let now = env.options.clock.now()
        try env.repo.insertTask(WorkTask(id: taskId, title: "성과 대상", createdAt: now))
        try env.repo.appendEvent(DomainEvent(id: "quiz-event", taskId: taskId, scopeType: .task,
            scopeId: taskId, kind: .created, toStatus: .inProgress, effectiveDate: prior,
            effectiveOrder: 1, recordedAt: now))
        return (env, provider, taskId)
    }

    @MainActor func testQuizShowsOneAtATimeAndAdvancesAfterRecord() async throws {
        let (env, provider, _) = try quizEnvironment(topicKeys: ["alpha", "beta", "gamma"])
        let quiz = QuizModel(environment: env)
        await quiz.generate(reportDate: monday)
        XCTAssertEqual(provider.runCount, 1)
        XCTAssertEqual(quiz.questions.count, 3)
        XCTAssertEqual(quiz.currentIndex, 0)
        XCTAssertEqual(quiz.remainingCount, 3)
        let first = try XCTUnwrap(quiz.currentQuestion)

        quiz.showNext()
        XCTAssertEqual(quiz.currentQuestion?.id, quiz.questions[1].id)
        quiz.showPrevious()
        XCTAssertEqual(quiz.currentQuestion?.id, first.id)

        quiz.record(first.id, outcome: .answered)
        XCTAssertEqual(quiz.remainingCount, 3, "답변 없이 저장하면 기록되지 않는다")
        quiz.answers[first.id] = "검증 결과를 확인했습니다."
        quiz.record(first.id, outcome: .answered)
        XCTAssertEqual(quiz.remainingCount, 2)
        XCTAssertEqual(quiz.currentQuestion?.id, quiz.questions[1].id, "기록 후 다음 질문으로 자동 이동")

        quiz.record(try XCTUnwrap(quiz.currentQuestion).id, outcome: .noResult)
        quiz.record(try XCTUnwrap(quiz.currentQuestion).id, outcome: .later)
        XCTAssertEqual(quiz.remainingCount, 0)
        XCTAssertNil(quiz.currentQuestion)
        quiz.showNext()
        XCTAssertNil(quiz.currentQuestion, "남은 질문이 없으면 이동하지 않는다")

        // reset 후 다시 0부터.
        quiz.reset()
        XCTAssertEqual(quiz.currentIndex, 0)
        XCTAssertEqual(quiz.remainingCount, 0)
    }

    @MainActor func testSkippingAllQuestionsDoesNotBlockCopyOrConfirm() async throws {
        let (env, _, _) = try quizEnvironment(topicKeys: ["alpha", "beta"])
        let reports = ReportsModel(environment: env)
        await reports.generate()
        let quiz = QuizModel(environment: env)
        await quiz.generate(reportDate: monday)
        for question in quiz.questions { quiz.record(question.id, outcome: .later) }
        XCTAssertEqual(quiz.remainingCount, 0)

        reports.markCopied()
        XCTAssertEqual(reports.version?.state, .draft)
        reports.confirm()
        XCTAssertEqual(reports.version?.state, .confirmed)
        XCTAssertEqual(try env.repo.supplements(taskId: "quiz-task").count, 2)
    }
}
