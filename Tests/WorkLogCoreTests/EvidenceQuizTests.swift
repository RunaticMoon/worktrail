import XCTest
@testable import WorkLogCore

// QUIZ-01 / QUIZ-02: 성과 보충 질문 생성·답변 저장 검증.
// 실제 codex 실행·네트워크는 없다. provider는 MockAIProvider만 사용한다.
final class EvidenceQuizTests: XCTestCase {

    private let reportStart = WorkDate("2026-09-28")!
    private let reportEnd = WorkDate("2026-10-05")!
    /// 월요일 고정 시각(입력일). KST 기준 날짜와 무관하게 결정적으로 쓴다.
    private let monday = Date(timeIntervalSince1970: 1_790_000_000)

    private var range: DateRange { DateRange(start: reportStart, endExclusive: reportEnd) }

    // MARK: - Helpers

    private func makeRepo() throws -> WorkRepository {
        try WorkRepository.inMemory(clock: FixedClock(monday), ids: SequentialIDGenerator())
    }

    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wlog-quiz-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeService(_ repo: WorkRepository, mock: MockAIProvider,
                             maxQuestions: Int = 3) -> EvidenceQuizService {
        let runner = AIJobRunner(repo: repo, provider: mock, stagingRoot: tempRoot())
        let templates = TemplateStore(repo: repo)
        return EvidenceQuizService(repo: repo, runner: runner, templates: templates,
                                   maxQuestions: maxQuestions)
    }

    @discardableResult
    private func makeTask(_ repo: WorkRepository, title: String = "결제 모듈 개선") throws -> WorkTask {
        try TaskService(repo: repo).createTask(title: title, initialStatus: .inProgress)
    }

    private func factTask(_ task: WorkTask, statusAtCutoff: TaskStatus? = .completed,
                          completionDates: [WorkDate] = [], activitySourceIds: [String] = []) -> FactTask {
        FactTask(id: task.id, title: task.title, trackingMode: .shared, statusAtStart: .inProgress,
                 statusAtCutoff: statusAtCutoff, projectIds: [], projectStatuses: [:], dueOn: nil,
                 firstStartedOn: nil, completionDatesInRange: completionDates, reopenedInRange: false,
                 eventsInRange: [], checklist: [], activitySourceIds: activitySourceIds)
    }

    private func makeSource(_ id: String, kind: FactSourceKind = .activity, taskId: String?,
                            text: String = "근거") -> FactSource {
        FactSource(id: id, kind: kind, revision: 1, recordedAt: monday, workDate: reportStart,
                   applies: nil, taskId: taskId, projectIds: [], text: text)
    }

    private func makeFacts(tasks: [FactTask], sources: [FactSource]) -> ReportFacts {
        ReportFacts(family: .submission, periodType: .weekly, timezone: "Asia/Seoul",
                    generatedAt: monday, range: range, statusCutoff: monday, knownAt: monday,
                    projects: [], tasks: tasks, sources: sources, metrics: ReportMetrics())
    }

    private func output(_ questions: [EvidenceQuizOutput.Question],
                        schemaVersion: Int = 1,
                        jobType: String = "evidence_quiz") throws -> String {
        try StableJSON.string(EvidenceQuizOutput(schemaVersion: schemaVersion, jobType: jobType,
                                                 questions: questions))
    }

    private func question(taskId: String, topicKey: String = "outcome",
                          text: String = "적용 후 확인한 결과가 있나요?",
                          context: String? = nil, evidenceIds: [String] = [],
                          applies: DateRange? = nil) -> EvidenceQuizOutput.Question {
        EvidenceQuizOutput.Question(taskId: taskId, topicKey: topicKey, question: text,
                                    context: context, evidenceIds: evidenceIds,
                                    appliesStart: applies?.start.iso,
                                    appliesEndExclusive: applies?.endExclusive.iso)
    }

    private func payloadObject(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    // MARK: 1. 정상 질문 2개

    func testGeneratesValidQuestions() async throws {
        let repo = try makeRepo()
        let task = try makeTask(repo)
        let s1 = makeSource("activity:1", taskId: task.id, text: "결제 모듈 변경")
        let s2 = makeSource("memo:1", kind: .memo, taskId: task.id, text: "결제 관련 메모")
        let taskFact = factTask(task, activitySourceIds: [s1.id, s2.id])
        let facts = makeFacts(tasks: [taskFact], sources: [s1, s2])

        let mock = MockAIProvider(responses: [.evidenceQuiz: try output([
            question(taskId: task.id, topicKey: "outcome", evidenceIds: [s1.id], applies: range),
            question(taskId: task.id, topicKey: "why", text: "왜 필요했나요?",
                     evidenceIds: [s2.id], applies: range),
        ])])
        let service = makeService(repo, mock: mock)

        let result = try await service.generate(facts: facts)

        XCTAssertEqual(result.jobStatus, .succeeded)
        XCTAssertEqual(result.questions.count, 2)
        XCTAssertEqual(result.questions.map(\.topicKey), ["outcome", "why"])
        XCTAssertTrue(result.warnings.isEmpty)

        let digest = try EvidenceQuizService.taskDigest(taskFact, facts: facts)
        XCTAssertEqual(result.questions[0].id, "quiz:\(task.id):outcome:\(digest.prefix(12))")
        XCTAssertEqual(result.questions[0].applies, range)
        XCTAssertEqual(result.questions[1].applies, range)
    }

    // MARK: 2. 4개 반환 → 3개 제한

    func testLimitsToMaxQuestions() async throws {
        let repo = try makeRepo()
        let task = try makeTask(repo)
        let s1 = makeSource("activity:1", taskId: task.id)
        let facts = makeFacts(tasks: [factTask(task, activitySourceIds: [s1.id])], sources: [s1])

        let mock = MockAIProvider(responses: [.evidenceQuiz: try output([
            question(taskId: task.id, topicKey: "outcome", evidenceIds: [s1.id], applies: range),
            question(taskId: task.id, topicKey: "why", evidenceIds: [s1.id], applies: range),
            question(taskId: task.id, topicKey: "role", evidenceIds: [s1.id], applies: range),
            question(taskId: task.id, topicKey: "result", evidenceIds: [s1.id], applies: range),
        ])])
        let service = makeService(repo, mock: mock)

        let result = try await service.generate(facts: facts)

        XCTAssertEqual(result.questions.count, 3)
        XCTAssertEqual(result.questions.map(\.topicKey), ["outcome", "why", "role"])
    }

    // MARK: 3. 탈락 케이스

    func testRejectsInvalidQuestions() async throws {
        let repo = try makeRepo()
        let task = try makeTask(repo)
        let s1 = makeSource("activity:1", taskId: task.id)
        let facts = makeFacts(tasks: [factTask(task, activitySourceIds: [s1.id])], sources: [s1])

        let mock = MockAIProvider(responses: [.evidenceQuiz: try output([
            question(taskId: task.id, topicKey: "outcome", evidenceIds: [s1.id], applies: range),
            question(taskId: "task-unknown", topicKey: "why", evidenceIds: [s1.id], applies: range),
            question(taskId: task.id, topicKey: "Outcome", evidenceIds: [s1.id], applies: range),
            question(taskId: task.id, topicKey: "empty_text", text: "   ", evidenceIds: [s1.id], applies: range),
            question(taskId: task.id, topicKey: "missing_evidence", evidenceIds: ["activity:missing"], applies: range),
            question(taskId: task.id, topicKey: "outcome", evidenceIds: [s1.id], applies: range),
        ])])
        let service = makeService(repo, mock: mock)

        let result = try await service.generate(facts: facts)

        XCTAssertEqual(result.questions.count, 1)
        XCTAssertEqual(result.questions[0].topicKey, "outcome")
    }

    // MARK: 4. applies 범위 밖/누락 → facts.range 보정

    func testCorrectsOutOfRangeApplies() async throws {
        let repo = try makeRepo()
        let task = try makeTask(repo)
        let s1 = makeSource("activity:1", taskId: task.id)
        let facts = makeFacts(tasks: [factTask(task, activitySourceIds: [s1.id])], sources: [s1])

        let inside = DateRange(start: WorkDate("2026-09-29")!, endExclusive: WorkDate("2026-10-01")!)
        let outside = DateRange(start: WorkDate("2026-09-01")!, endExclusive: WorkDate("2026-09-20")!)
        let mock = MockAIProvider(responses: [.evidenceQuiz: try output([
            question(taskId: task.id, topicKey: "inside", evidenceIds: [s1.id], applies: inside),
            question(taskId: task.id, topicKey: "outside", evidenceIds: [s1.id], applies: outside),
            question(taskId: task.id, topicKey: "none", evidenceIds: [s1.id], applies: nil),
        ])])
        let service = makeService(repo, mock: mock)

        let result = try await service.generate(facts: facts)

        XCTAssertEqual(result.questions.count, 3)
        XCTAssertEqual(result.questions[0].applies, inside)
        XCTAssertEqual(result.questions[1].applies, range)   // 범위 밖 → 보정
        XCTAssertEqual(result.questions[2].applies, range)   // 누락 → 보정
        XCTAssertEqual(result.warnings.filter { $0 == "적용 기간을 리포트 기간으로 보정" }.count, 2)
    }

    // MARK: 5. 답변 저장 — 입력일이 아니라 적용 기간에 귀속

    func testRecordAnsweredUsesAppliesPeriod() throws {
        let repo = try makeRepo()
        let task = try makeTask(repo)
        let s1 = makeSource("activity:1", taskId: task.id)
        let taskFact = factTask(task, activitySourceIds: [s1.id])
        let facts = makeFacts(tasks: [taskFact], sources: [s1])
        let digest = try EvidenceQuizService.taskDigest(taskFact, facts: facts)
        let service = makeService(repo, mock: MockAIProvider())

        let q = QuizQuestion(id: "quiz:x", taskId: task.id, topicKey: "outcome",
                             question: "결과가 있나요?", context: nil, evidenceIds: [s1.id],
                             applies: range, sourceDigest: digest)
        let saved = try service.record(q, outcome: .answered, answer: "결과 확인")

        XCTAssertEqual(saved.applies, range)          // 질문의 적용 기간(지난주)
        XCTAssertEqual(saved.recordedAt, monday)      // 입력한 날(월요일), 적용 기간과 분리
        XCTAssertEqual(saved.answer, "결과 확인")
        XCTAssertEqual(saved.outcome, .answered)

        let stored = try repo.supplements(taskId: task.id)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].applies, range)

        XCTAssertThrowsError(try service.record(q, outcome: .answered, answer: "   ")) { error in
            guard case WorkLogError.validation = error else {
                return XCTFail("빈 답변은 validation이어야 한다: \(error)")
            }
        }
    }

    // MARK: 6. answered 후 같은 digest로 재생성 → 제외, 같은 주제 재반환도 탈락

    func testAnsweredTopicExcludedOnRegenerate() async throws {
        let repo = try makeRepo()
        let task = try makeTask(repo)
        let s1 = makeSource("activity:1", taskId: task.id)
        let taskFact = factTask(task, activitySourceIds: [s1.id])
        let facts = makeFacts(tasks: [taskFact], sources: [s1])
        let digest = try EvidenceQuizService.taskDigest(taskFact, facts: facts)
        let service = makeService(repo, mock: MockAIProvider())

        let q = QuizQuestion(id: "quiz:x", taskId: task.id, topicKey: "outcome",
                             question: "결과가 있나요?", context: nil, evidenceIds: [s1.id],
                             applies: range, sourceDigest: digest)
        _ = try service.record(q, outcome: .answered, answer: "결과 확인")

        let mock = MockAIProvider(responses: [.evidenceQuiz: try output([
            question(taskId: task.id, topicKey: "outcome", evidenceIds: [s1.id], applies: range),
            question(taskId: task.id, topicKey: "why", evidenceIds: [s1.id], applies: range),
        ])])
        let service2 = makeService(repo, mock: mock)
        let result = try await service2.generate(facts: facts)

        XCTAssertEqual(result.questions.map(\.topicKey), ["why"])

        let payload = try XCTUnwrap(mock.receivedInputs.first?.payloadJSON)
        let object = try payloadObject(payload)
        let excluded = try XCTUnwrap(object["excludedTopics"] as? [[String: Any]])
        XCTAssertTrue(excluded.contains { $0["topicKey"] as? String == "outcome" })
    }

    // MARK: 7. later는 다시 묻고, excluded는 digest가 바뀌어도 제외

    func testLaterIsNotExcludedButExcludedSurvivesDigestChange() async throws {
        let repo = try makeRepo()
        let task = try makeTask(repo)
        let s1 = makeSource("activity:1", taskId: task.id)
        let taskFact = factTask(task, activitySourceIds: [s1.id])
        let facts = makeFacts(tasks: [taskFact], sources: [s1])
        let digest = try EvidenceQuizService.taskDigest(taskFact, facts: facts)
        let service = makeService(repo, mock: MockAIProvider())

        // later: 제외되지 않는다.
        let laterQuestion = QuizQuestion(id: "quiz:later", taskId: task.id, topicKey: "later_topic",
                                         question: "결과가 있나요?", context: nil, evidenceIds: [s1.id],
                                         applies: range, sourceDigest: digest)
        _ = try service.record(laterQuestion, outcome: .later, answer: nil)

        let mockLater = MockAIProvider(responses: [.evidenceQuiz: try output([
            question(taskId: task.id, topicKey: "later_topic", evidenceIds: [s1.id], applies: range),
        ])])
        let laterResult = try await makeService(repo, mock: mockLater).generate(facts: facts)
        XCTAssertEqual(laterResult.questions.map(\.topicKey), ["later_topic"])

        // excluded: digest가 바뀌어도 계속 제외된다.
        let excludedQuestion = QuizQuestion(id: "quiz:ex", taskId: task.id, topicKey: "excluded_topic",
                                            question: "결과가 있나요?", context: nil, evidenceIds: [s1.id],
                                            applies: range, sourceDigest: digest)
        _ = try service.record(excludedQuestion, outcome: .excluded, answer: nil)

        let s2 = makeSource("activity:2", taskId: task.id, text: "추가 근거")
        let changedFacts = makeFacts(tasks: [factTask(task, activitySourceIds: [s1.id, s2.id])],
                                     sources: [s1, s2])
        let changedDigest = try EvidenceQuizService.taskDigest(changedFacts.tasks[0], facts: changedFacts)
        XCTAssertNotEqual(changedDigest, digest)

        let mockExcluded = MockAIProvider(responses: [.evidenceQuiz: try output([
            question(taskId: task.id, topicKey: "excluded_topic", evidenceIds: [s1.id], applies: range),
            question(taskId: task.id, topicKey: "later_topic", evidenceIds: [s1.id], applies: range),
        ])])
        let excludedResult = try await makeService(repo, mock: mockExcluded).generate(facts: changedFacts)
        // excluded_topic만 탈락, later_topic은 새 digest라 다시 포함된다.
        XCTAssertEqual(excludedResult.questions.map(\.topicKey), ["later_topic"])
    }

    // MARK: 8. AI 실패·파싱 실패 → 예외 없이 상태/warning

    func testAIFailureAndParseFailure() async throws {
        let repo = try makeRepo()
        let task = try makeTask(repo)
        let s1 = makeSource("activity:1", taskId: task.id)
        let facts = makeFacts(tasks: [factTask(task, activitySourceIds: [s1.id])], sources: [s1])

        // provider 실패 → 상태 전달, 예외 없음.
        let failedMock = MockAIProvider()
        failedMock.failure = AIProviderError(.rateLimited, "quota")
        let failed = try await makeService(repo, mock: failedMock).generate(facts: facts)
        XCTAssertTrue(failed.questions.isEmpty)
        XCTAssertEqual(failed.jobStatus, .failed)

        // 파싱 실패 → warning.
        let badJSON = try await makeService(repo, mock: MockAIProvider(responses: [.evidenceQuiz: "not json"]))
            .generate(facts: facts)
        XCTAssertTrue(badJSON.questions.isEmpty)
        XCTAssertEqual(badJSON.jobStatus, .succeeded)
        XCTAssertFalse(badJSON.warnings.isEmpty)

        // schemaVersion 불일치 → warning.
        let badSchema = try await makeService(repo, mock: MockAIProvider(responses: [
            .evidenceQuiz: try output([question(taskId: task.id)], schemaVersion: 2),
        ])).generate(facts: facts)
        XCTAssertTrue(badSchema.questions.isEmpty)
        XCTAssertFalse(badSchema.warnings.isEmpty)
    }

    // MARK: 9. 지시문 치환·payload 금지 문자열

    func testInstructionsAndPayloadGuards() async throws {
        let repo = try makeRepo()
        let task = try makeTask(repo)
        let s1 = makeSource("activity:1", taskId: task.id, text: "결제 모듈 변경")
        let facts = makeFacts(tasks: [factTask(task, activitySourceIds: [s1.id])], sources: [s1])

        let mock = MockAIProvider(responses: [.evidenceQuiz: try output([])])
        let service = makeService(repo, mock: mock)

        _ = try await service.generate(facts: facts)

        let input = try XCTUnwrap(mock.receivedInputs.first)
        XCTAssertFalse(input.instructions.contains("{{maxQuestions}}"))
        XCTAssertTrue(input.instructions.contains("3"))

        let lowered = input.payloadJSON.lowercased()
        XCTAssertFalse(lowered.contains("vault"))
        XCTAssertFalse(lowered.contains("secret"))
        XCTAssertTrue(input.payloadJSON.contains("\"maxQuestions\":3"))
    }

    // MARK: 10. record가 Task 상태를 바꾸지 않음

    func testRecordDoesNotChangeTaskStatus() throws {
        let repo = try makeRepo()
        let task = try makeTask(repo)
        let s1 = makeSource("activity:1", taskId: task.id)
        let taskFact = factTask(task, activitySourceIds: [s1.id])
        let facts = makeFacts(tasks: [taskFact], sources: [s1])
        let digest = try EvidenceQuizService.taskDigest(taskFact, facts: facts)
        let service = makeService(repo, mock: MockAIProvider())
        let taskService = TaskService(repo: repo)

        let before = try taskService.currentStatus(taskId: task.id)

        let q = QuizQuestion(id: "quiz:x", taskId: task.id, topicKey: "outcome",
                             question: "결과가 있나요?", context: nil, evidenceIds: [s1.id],
                             applies: range, sourceDigest: digest)
        _ = try service.record(q, outcome: .answered, answer: "결과 확인")

        XCTAssertEqual(try taskService.currentStatus(taskId: task.id), before)
        XCTAssertEqual(before, .inProgress)
    }

    // MARK: - buildPayload 직접 검증

    func testBuildPayloadContract() throws {
        let repo = try makeRepo()
        let task = try makeTask(repo)
        let s1 = makeSource("activity:1", taskId: task.id, text: "결제 모듈 변경")
        let facts = makeFacts(tasks: [factTask(task, activitySourceIds: [s1.id])], sources: [s1])
        let service = makeService(repo, mock: MockAIProvider())

        let object = try payloadObject(service.buildPayload(facts: facts))

        XCTAssertEqual(object["jobType"] as? String, "evidence_quiz")
        XCTAssertEqual(object["maxQuestions"] as? Int, 3)
        let rangeObject = try XCTUnwrap(object["range"] as? [String: Any])
        XCTAssertEqual(rangeObject["start"] as? String, "2026-09-28")
        XCTAssertEqual(rangeObject["endExclusive"] as? String, "2026-10-05")
        XCTAssertEqual((object["excludedTopics"] as? [Any])?.count, 0)
    }
}
