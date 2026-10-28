import XCTest
@testable import WorkLogCore

/// The sink has already built its payload when the existing task becomes protected.
/// All provider calls are in-memory; the first unrelated request holds the runner's FIFO lock.
final class MeetingDisclosureQueueTests: XCTestCase {
    private enum Sink {
        case submission, performance, groundedAnswer
        var jobType: AIJobType {
            switch self {
            case .submission: return .submissionWeekly
            case .performance: return .performanceReport
            case .groundedAnswer: return .groundedAnswer
            }
        }
    }

    func testQueuedSubmissionRechecksTaskDisclosureBeforeCreatingJobOrCallingProvider() async throws {
        try await assertQueuedProtection(sink: .submission)
    }

    func testQueuedPerformanceRechecksTaskDisclosureBeforeCreatingJobOrCallingProvider() async throws {
        try await assertQueuedProtection(sink: .performance)
    }

    func testQueuedGroundedAnswerRechecksTaskDisclosureBeforeCreatingJobOrCallingProvider() async throws {
        try await assertQueuedProtection(sink: .groundedAnswer)
    }

    private func assertQueuedProtection(sink: Sink) async throws {
        let calendar = WorkCalendar(), reportDate = WorkDate("2026-10-26")!, workDate = WorkDate("2026-10-23")!
        let clock = FixedClock(calendar.startOfDay(reportDate).addingTimeInterval(9 * 60 * 60))
        let repo = try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator(prefix: "disclosure-queue"))
        let taskMarker = "QUEUED_TASK_DISCLOSURE_CANARY"
        let activityMarker = "QUEUED_ACTIVITY_DISCLOSURE_CANARY"
        let tasks = TaskService(repo: repo)
        let task = try tasks.createTask(title: taskMarker, initialStatus: .inProgress, workDate: workDate)
        _ = try tasks.addActivity(taskId: task.id, body: activityMarker, workDate: workDate)
        let meeting = try MeetingService(repo: repo).create(title: "가짜 로컬 회의", workDate: workDate,
            notes: "가짜 근거 문장", localOnly: true)
        XCTAssertTrue(try TaskDisclosurePolicy(repo: repo).protectedTaskIDs().isEmpty)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-disclosure-queue-" + UUIDGenerator().make())
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = DisclosureQueueProvider()
        let runner = AIJobRunner(repo: repo, provider: provider, stagingRoot: root)
        let templates = TemplateStore(repo: repo)
        _ = try templates.seedDefaults()
        let periods = Periods(calendar: calendar)
        let builder = ReportFactsBuilder(repo: repo, periods: periods,
            planService: WeekPlanService(repo: repo, periods: periods))
        let reports = ReportService(repo: repo, periods: periods, factsBuilder: builder,
            store: ReportStore(repo: repo), templates: templates, runner: runner,
            evaluationPeriods: EvaluationPeriodService(repo: repo))
        let index = try SearchIndex(repo: repo)
        try index.rebuildAll()
        let grounded = GroundedAnswerService(index: index, runner: runner, templates: templates)

        // Establish that these are valid sources before changing policy, so an empty
        // report/evidence pool cannot make the test pass without exercising the queue.
        let initialFacts = try builder.submissionFacts(reportDate: reportDate, knownAt: clock.now())
        XCTAssertTrue(initialFacts.tasks.contains { $0.id == task.id })
        XCTAssertTrue(try StableJSON.string(initialFacts).contains(activityMarker))
        XCTAssertFalse(try grounded.collectEvidence(question: "DISCLOSURE_CANARY", scope: .init()).isEmpty)

        let occupying = Task {
            try await runner.submit(AIJobRequest(jobType: .meetingSummary, instructions: "fake occupying request",
                payloadJSON: #"{"unrelated":true}"#))
        }
        var queued: Task<Void, Error>?
        defer {
            occupying.cancel()
            queued?.cancel()
            Task { await provider.releaseFirst() }
        }
        try await waitFor("occupying request entered fake provider") { await provider.firstRunIsWaiting }

        queued = Task {
            switch sink {
            case .submission:
                _ = try await reports.generateSubmission(reportDate: reportDate, mode: .userRequested, useAI: true)
            case .performance:
                _ = try await reports.generatePerformance(periodType: .weekly, containing: workDate,
                    mode: .userRequested, useAI: true)
            case .groundedAnswer:
                _ = try await grounded.answer(question: "DISCLOSURE_CANARY", scope: .init())
            }
        }
        // The occupying request accounts for two reads. The third means this sink
        // passed its initial preflight and captured an account before FIFO suspension.
        try await waitFor("sink passed initial preflight and entered queue") { await provider.generationReads >= 3 }
        XCTAssertEqual(try repo.db.scalarInt("SELECT COUNT(*) FROM ai_job"), 1)
        XCTAssertEqual(try repo.db.scalarIntV("SELECT COUNT(*) FROM ai_job WHERE type = ?", sink.jobType.rawValue), 0)

        let link = try MeetingTaskService(repo: repo).confirm(meetingID: meeting.id,
            expectedRevision: meeting.revision, actionKey: "protect-queued-task", title: "",
            quote: "가짜 근거 문장", existingTaskID: task.id)
        XCTAssertTrue(link.localOnly)
        XCTAssertEqual(try repo.task(id: task.id)?.title, taskMarker)
        XCTAssertEqual(try tasks.currentStatus(taskId: task.id), .inProgress)

        await provider.releaseFirst()
        let occupiedResult = try await occupying.value
        XCTAssertEqual(occupiedResult.job.status, .succeeded)
        do {
            try await queued?.value
            XCTFail("A payload built before localOnly linking must be rejected after waiting")
        } catch let error as WorkLogError {
            switch (sink, error) {
            case (.groundedAnswer, .policyBlocked), (.submission, .validation), (.performance, .validation): break
            default: XCTFail("Expected disclosure rejection, got \(error)")
            }
        }

        let inputs = await provider.inputs
        XCTAssertEqual(inputs.count, 1, "Only the unrelated occupying request may reach the fake provider")
        XCTAssertEqual(inputs.first?.jobType, .meetingSummary)
        XCTAssertFalse(inputs.contains { $0.payloadJSON.contains(taskMarker) || $0.payloadJSON.contains(activityMarker) })
        XCTAssertEqual(try repo.db.scalarInt("SELECT COUNT(*) FROM ai_job"), 1)
        XCTAssertEqual(try repo.db.scalarIntV("SELECT COUNT(*) FROM ai_job WHERE id = ?", occupiedResult.job.id), 1)
        XCTAssertEqual(try repo.db.scalarIntV("SELECT COUNT(*) FROM ai_job WHERE type = ?", sink.jobType.rawValue), 0)
        XCTAssertEqual(try repo.db.scalarInt("SELECT COUNT(*) FROM report_version"), 0,
            "A rejected queued request must not persist an obsolete fallback report")
    }

    private func waitFor(_ stage: String, predicate: () async -> Bool) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while !(await predicate()) {
            guard clock.now < deadline else { throw WorkLogError.validation("Queue test timed out: " + stage) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor DisclosureQueueProvider: AIAccountGenerationProvider {
    private var firstRun: CheckedContinuation<Void, Never>?
    private(set) var generationReads = 0
    private(set) var inputs: [AIJobInput] = []
    var firstRunIsWaiting: Bool { firstRun != nil }

    func accountGeneration() async -> Int { generationReads += 1; return 0 }
    func releaseFirst() { firstRun?.resume(); firstRun = nil }
    func run(_ input: AIJobInput, expectedAccountGeneration: Int) async throws -> AIJobOutput {
        try await run(input)
    }
    func run(_ input: AIJobInput) async throws -> AIJobOutput {
        inputs.append(input)
        if inputs.count == 1 { await withCheckedContinuation { firstRun = $0 } }
        return AIJobOutput(rawJSON: "{}")
    }
    func checkCapabilities() async -> AICapabilities { AICapabilities(installed: true, protocolCompatible: true) }
    func getAccountStatus() async throws -> AIAccountState { .loggedOut }
    func beginOfficialLogin() async throws -> URL? { nil }
    func listAvailableSkills() async throws -> [DiscoveredSkill] { [] }
    func cancel(jobId: String) async { }
}
