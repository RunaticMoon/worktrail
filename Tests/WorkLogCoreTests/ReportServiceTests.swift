import XCTest
@testable import WorkLogCore

/// WLOG-45A3 V: 리포트 생성 파이프라인(결정적 + AI 검증 대체) 통합 테스트.
/// 제출용 주간보고와 상세 성과 리포트의 family·템플릿·본문·리포트 ID 분리, AI 성공/검증 실패/
/// 실패 대체, 자동 모드 생략(PERF-05), 확정본 보호(REP-T11), 평가 기간 리포트(REP-T07)를 확인한다.
final class ReportServiceTests: XCTestCase {

    private let reportDate = WorkDate("2026-10-05")!

    // MARK: - Harness

    private func fixtureNow() -> Date {
        (try? FixtureLoader.load()).flatMap { $0.clock?.now }.flatMap(FixtureLoader.date)
            ?? Date(timeIntervalSince1970: 1_790_000_000)
    }

    private func makeRepo(clock: FixedClock) throws -> WorkRepository {
        let repo = try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator())
        try FixtureSeeder.seed(repo, fixture: try FixtureLoader.load())
        return repo
    }

    private struct Harness {
        let repo: WorkRepository
        let periods: Periods
        let builder: ReportFactsBuilder
        let store: ReportStore
        let templates: TemplateStore
        let evaluationPeriods: EvaluationPeriodService
        let provider: MockAIProvider
        let stagingRoot: URL
        let service: ReportService
        let clock: FixedClock
    }

    @discardableResult
    private func makeHarness(responses: [AIJobType: String] = [:], useRunner: Bool = true,
                             now: Date? = nil, clock: FixedClock? = nil) throws -> Harness {
        let clock = clock ?? FixedClock(now ?? fixtureNow())
        let repo = try makeRepo(clock: clock)
        let periods = Periods()
        let builder = ReportFactsBuilder(repo: repo, periods: periods,
                                         planService: WeekPlanService(repo: repo, periods: periods))
        let store = ReportStore(repo: repo)
        let templates = TemplateStore(repo: repo)
        let evaluationPeriods = EvaluationPeriodService(repo: repo)
        let provider = MockAIProvider(responses: responses)
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wlog-report-service-tests-\(UUID().uuidString)", isDirectory: true)
        let runner = useRunner ? AIJobRunner(repo: repo, provider: provider, stagingRoot: stagingRoot) : nil
        let service = ReportService(repo: repo, periods: periods, factsBuilder: builder, store: store,
                                    templates: templates, runner: runner,
                                    evaluationPeriods: evaluationPeriods)
        return Harness(repo: repo, periods: periods, builder: builder, store: store, templates: templates,
                       evaluationPeriods: evaluationPeriods, provider: provider, stagingRoot: stagingRoot,
                       service: service, clock: clock)
    }

    private func created(_ result: ReportGenerationResult,
                         file: StaticString = #filePath, line: UInt = #line) throws -> ReportVersion {
        guard case .created(let version) = result.outcome else {
            XCTFail("created를 기대: \(result.outcome)", file: file, line: line)
            throw WorkLogError.storage("not created")
        }
        return version
    }

    // MARK: - 1. REP-T03: 제출용·성과용 동시 생성 분리

    func testSubmissionAndPerformanceAreSeparated() async throws {
        let h = try makeHarness(useRunner: false)

        let submission = try await h.service.generateSubmission(reportDate: reportDate, mode: .userRequested,
                                                                useAI: false)
        let performance = try await h.service.generatePerformance(
            periodType: .weekly, containing: WorkDate("2026-09-28")!, mode: .userRequested, useAI: false)

        XCTAssertNotEqual(submission.report.id, performance.report.id)
        XCTAssertEqual(submission.report.family, .submission)
        XCTAssertEqual(performance.report.family, .performance)
        XCTAssertEqual(submission.report.periodType, .weekly)
        XCTAssertEqual(performance.report.periodType, .weekly)

        let submissionVersion = try created(submission)
        let performanceVersion = try created(performance)

        XCTAssertTrue(submissionVersion.content.contains("완료 "))
        XCTAssertTrue(submissionVersion.content.contains("진행 "))
        XCTAssertTrue(submissionVersion.content.contains("예정 "))
        XCTAssertTrue(performanceVersion.content.hasPrefix("# "))
        XCTAssertEqual(submissionVersion.generator, "deterministic")
        XCTAssertEqual(try h.repo.reports().count, 2)
    }

    // MARK: - 2. 제출용 결정적 초안(픽스처)

    func testSubmissionDeterministicDraftFromFixture() async throws {
        let h = try makeHarness(useRunner: false)
        let result = try await h.service.generateSubmission(reportDate: reportDate, mode: .userRequested,
                                                            useAI: false)
        let version = try created(result)
        let content = version.content

        // REP-T02: task-A는 공통 업무 아래 진행 1줄 + 예정 1줄(프로젝트별 삼중 반복 없음).
        XCTAssertTrue(content.contains("공통 업무\n진행 공통 인프라 설정 개선"))
        XCTAssertEqual(content.components(separatedBy: "공통 인프라 설정 개선").count - 1, 2)

        // TIME-T02: 월요일 완료라도 지난주는 진행.
        XCTAssertTrue(content.contains("진행 배포 스크립트 정리"))

        // 예정은 확정 계획(plan-J, plan-docs)만, 후보 candidate-K 없음.
        XCTAssertTrue(content.contains("예정 공통 인프라 설정 개선 — J 적용 마무리, 공통 운영 문서 정리"))
        XCTAssertFalse(content.contains("K 적용"))
        XCTAssertFalse(content.contains("candidate-K"))
    }

    // MARK: - 3. AI 경로 성공

    func testAISuccessIsStoredAsCodex() async throws {
        let probe = try makeHarness(useRunner: false)
        let facts = try probe.builder.submissionFacts(reportDate: reportDate, knownAt: probe.repo.clock.now())
        let json = try StableJSON.string(SubmissionComposer.compose(facts))

        let h = try makeHarness(responses: [.submissionWeekly: json])
        let result = try await h.service.generateSubmission(reportDate: reportDate, mode: .userRequested,
                                                            useAI: true)

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.aiJobStatus, .succeeded)
        let version = try created(result)
        XCTAssertEqual(version.generator, "codex")
        XCTAssertEqual(version.aiModel, "mock")
        XCTAssertNotNil(version.templateVersionId)
        XCTAssertFalse(result.findings.contains { $0.severity == .error })
    }

    // MARK: - 4. AI 검증 실패 → 결정적 초안 대체

    func testAIValidationFailureFallsBackToDeterministic() async throws {
        let bad = SubmissionDraft(groups: [
            SubmissionGroup(heading: "공통 업무", items: [
                SubmissionItem(itemId: "line-1", category: .inProgress, text: "검증 실패",
                               taskIds: ["ghost-task"], projectIds: [])
            ])
        ])
        let json = try StableJSON.string(bad)
        let h = try makeHarness(responses: [.submissionWeekly: json])

        let result = try await h.service.generateSubmission(reportDate: reportDate, mode: .userRequested,
                                                            useAI: true)

        XCTAssertTrue(result.usedFallback)
        XCTAssertTrue(result.findings.contains { $0.code == "unknown_task" })
        let version = try created(result)
        XCTAssertEqual(version.generator, "deterministic")
        XCTAssertTrue(version.warnings.contains { $0.contains("AI 초안 검증 실패로 기록 기반 초안을 사용했습니다") })
    }

    // MARK: - 5. REP-T18: AI 실패해도 저장은 된다

    func testAIFailureStillStoresDeterministicDraft() async throws {
        let h = try makeHarness()
        h.provider.failure = AIProviderError(.notLoggedIn, "로그인 필요")

        let result = try await h.service.generateSubmission(reportDate: reportDate, mode: .userRequested,
                                                            useAI: true)

        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.aiJobStatus, .blockedAuth)
        let version = try created(result)
        XCTAssertEqual(version.generator, "deterministic")
        XCTAssertTrue(version.warnings.contains { $0.contains("AI 초안을 만들지 못해 기록 기반 초안을 사용했습니다") })
    }

    // MARK: - 6. PERF-05: 자동 모드 원본 동일 → AI 생략

    func testAutomaticModeSkipsUnchangedAIRequest() async throws {
        let h = try makeHarness()

        let first = try await h.service.generateSubmission(reportDate: reportDate, mode: .automatic, useAI: true)
        _ = try created(first)
        let runCountAfterFirst = h.provider.runCount
        XCTAssertEqual(runCountAfterFirst, 1)

        let second = try await h.service.generateSubmission(reportDate: reportDate, mode: .automatic, useAI: true)
        guard case .unchanged = second.outcome else { return XCTFail("unchanged를 기대: \(second.outcome)") }
        XCTAssertTrue(second.aiSkippedUnchanged)
        XCTAssertEqual(h.provider.runCount, runCountAfterFirst, "원본이 같으면 AI를 다시 부르지 않는다")
    }

    // MARK: - 6b. PERF-05 + 결함1: 시각이 지나도 digest는 안정
    // (knownAt이 digest에 들어가면 isStale이 항상 true가 되고 자동 생략이 깨진다)

    func testIsStaleIsStableWhenOnlyClockAdvances() async throws {
        let h = try makeHarness(useRunner: false)
        let first = try await h.service.generateSubmission(reportDate: reportDate, mode: .automatic,
                                                           useAI: false)
        let version = try created(first)
        XCTAssertFalse(try h.service.isStale(versionId: version.id))

        h.clock.advance(by: 5)
        XCTAssertFalse(try h.service.isStale(versionId: version.id),
                       "knownAt만 지나간 것으로는 stale이 되면 안 된다")
    }

    func testAutomaticModeSkipsUnchangedAIAfterClockAdvances() async throws {
        let h = try makeHarness()

        let first = try await h.service.generateSubmission(reportDate: reportDate, mode: .automatic,
                                                           useAI: true)
        _ = try created(first)
        let runCountAfterFirst = h.provider.runCount
        XCTAssertEqual(runCountAfterFirst, 1)

        h.clock.advance(by: 5)
        let second = try await h.service.generateSubmission(reportDate: reportDate, mode: .automatic,
                                                            useAI: true)
        guard case .unchanged = second.outcome else { return XCTFail("unchanged를 기대: \(second.outcome)") }
        XCTAssertTrue(second.aiSkippedUnchanged)
        XCTAssertEqual(h.provider.runCount, runCountAfterFirst,
                       "시각만 지나고 원본이 같으면 AI를 다시 부르지 않는다")
    }

    func testAIPayloadOmitsRunTimestampsAndFailureIsNotAutoRetriedWhenUnchanged() async throws {
        let h = try makeHarness()
        h.provider.failure = AIProviderError(.network, "offline")

        let first = try await h.service.generateSubmission(reportDate: reportDate, mode: .automatic,
                                                           useAI: true)
        XCTAssertTrue(first.usedFallback)
        XCTAssertEqual(h.provider.runCount, 1)
        // 실행 시각은 payload에서 고정값이라 같은 원본이면 같은 idempotency key가 된다.
        let payload = try XCTUnwrap(h.provider.receivedInputs.last?.payloadJSON)
        XCTAssertTrue(payload.contains("1970-01-01T00:00:00Z"))

        // 원본 변화가 없으면 자동 모드는 AI를 다시 부르지 않는다(PERF-05). 재시도는 사용자 재생성으로 한다.
        h.clock.advance(by: 600)
        let second = try await h.service.generateSubmission(reportDate: reportDate, mode: .automatic,
                                                            useAI: true)
        XCTAssertTrue(second.aiSkippedUnchanged)
        XCTAssertEqual(h.provider.runCount, 1)
        XCTAssertEqual(try h.repo.db.scalarInt("SELECT COUNT(*) FROM ai_job"), 1)
    }

    func testIsStaleDetectsNewActivityAfterClockAdvance() async throws {
        let h = try makeHarness(useRunner: false)
        let first = try await h.service.generateSubmission(reportDate: reportDate, mode: .automatic,
                                                           useAI: false)
        let version = try created(first)

        h.clock.advance(by: 5)
        let taskService = TaskService(repo: h.repo)
        _ = try taskService.addActivity(taskId: "task-A", body: "추가 활동",
                                        workDate: WorkDate("2026-10-02")!)

        XCTAssertTrue(try h.service.isStale(versionId: version.id))
    }

    // MARK: - 7. REP-T11: 확정 후 자동 재생성

    func testConfirmedPreservedWhenSourceChanges() async throws {
        let h = try makeHarness(useRunner: false)

        let first = try await h.service.generateSubmission(reportDate: reportDate, mode: .automatic, useAI: false)
        let v1 = try created(first)
        let confirmed = try h.service.confirm(versionId: v1.id)
        XCTAssertEqual(confirmed.state, .confirmed)

        let taskService = TaskService(repo: h.repo)
        _ = try taskService.addActivity(taskId: "task-A", body: "추가 활동", workDate: WorkDate("2026-10-02")!)

        let second = try await h.service.generateSubmission(reportDate: reportDate, mode: .automatic, useAI: false)
        let v2 = try created(second)
        XCTAssertEqual(v2.basedOnVersionId, v1.id)
        XCTAssertEqual(try h.repo.reportVersion(id: v1.id)?.state, .confirmed)
        XCTAssertEqual(try h.repo.reportVersion(id: v1.id)?.content, v1.content)
    }

    // MARK: - 8. REP-T07: 평가 기간 리포트 range 고정

    func testEvaluationReportRangeAndConfirm() async throws {
        let h = try makeHarness(useRunner: false)
        let evaluation = EvaluationPeriodService(repo: h.repo)
        let (period, _) = try evaluation.create(start: WorkDate("2026-01-01")!,
                                                endInclusive: WorkDate("2026-09-30")!)

        // clock(2026-10-05)이 기간 종료 이후여도 range를 생성일로 확장하지 않는다.
        let first = try await h.service.generateEvaluation(periodId: period.id, mode: .userRequested,
                                                           useAI: false)
        XCTAssertEqual(first.report.range, period.range)
        XCTAssertEqual(first.report.evaluationPeriodId, period.id)
        XCTAssertEqual(first.report.periodKey, period.id)
        XCTAssertEqual(first.report.periodType, .yearly)

        let v1 = try created(first)
        _ = try h.service.confirm(versionId: v1.id)
        XCTAssertEqual(try h.repo.evaluationPeriod(id: period.id)?.confirmedReportVersionId, v1.id)

        // 같은 기간의 두 번째 버전을 확정해도 range는 변하지 않는다.
        let second = try await h.service.generateEvaluation(periodId: period.id, mode: .userRequested,
                                                            useAI: false)
        let v2 = try created(second)
        _ = try h.service.confirm(versionId: v2.id)
        let reloaded = try XCTUnwrap(try h.repo.evaluationPeriod(id: period.id))
        XCTAssertEqual(reloaded.confirmedReportVersionId, v2.id)
        XCTAssertEqual(reloaded.range, period.range)
    }

    // MARK: - 9. yearly는 validation 오류

    func testYearlyPerformanceIsRejected() async throws {
        let h = try makeHarness(useRunner: false)
        do {
            _ = try await h.service.generatePerformance(periodType: .yearly,
                                                        containing: WorkDate("2026-09-28")!,
                                                        mode: .userRequested, useAI: false)
            XCTFail("validation 오류를 기대")
        } catch let error as WorkLogError {
            guard case .validation = error else { return XCTFail("validation을 기대: \(error)") }
        }
    }

    // MARK: - 10. isStale

    func testIsStaleDetectsSourceChange() async throws {
        let h = try makeHarness(useRunner: false)
        let first = try await h.service.generateSubmission(reportDate: reportDate, mode: .automatic, useAI: false)
        let version = try created(first)

        XCTAssertFalse(try h.service.isStale(versionId: version.id))

        let taskService = TaskService(repo: h.repo)
        _ = try taskService.addActivity(taskId: "task-A", body: "추가 활동", workDate: WorkDate("2026-10-02")!)

        XCTAssertTrue(try h.service.isStale(versionId: version.id))
    }

    // MARK: - 11. 지시문 플레이스홀더·문구

    func testInstructionsHaveNoPlaceholdersAndFamilySpecificNotes() async throws {
        let h = try makeHarness()

        _ = try await h.service.generateSubmission(reportDate: reportDate, mode: .userRequested, useAI: true)
        let submissionInput = try XCTUnwrap(h.provider.receivedInputs.last)
        XCTAssertFalse(submissionInput.instructions.contains("{{"))
        XCTAssertTrue(submissionInput.instructions.contains("상세 성과용 Weekly 리포트가 아니다"))
        XCTAssertEqual(submissionInput.jobType, .submissionWeekly)

        _ = try await h.service.generatePerformance(periodType: .weekly, containing: WorkDate("2026-09-28")!,
                                                    mode: .userRequested, useAI: true)
        let performanceInput = try XCTUnwrap(h.provider.receivedInputs.last)
        XCTAssertFalse(performanceInput.instructions.contains("{{"))
        XCTAssertTrue(performanceInput.instructions.contains("제출용 주간보고 형식으로 축약하지 않는다"))
        XCTAssertEqual(performanceInput.jobType, .performanceReport)
    }
}
