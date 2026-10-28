import XCTest
@testable import WorkLogCore

final class MeetingPrivacyTransitionTests: XCTestCase {
    private func fixture() throws -> (WorkRepository, Meeting, MeetingTaskLink, Activity) {
        let repo = try WorkRepository.inMemory(
            clock: FixedClock(Date(timeIntervalSince1970: 1_792_972_800)),
            ids: SequentialIDGenerator(prefix: "privacy-transition"))
        let date = repo.calendar.workDate(of: repo.clock.now())
        let meeting = try MeetingService(repo: repo).create(title: "정책 전환 회의", workDate: date,
            notes: "TRANSITION_SOURCE_CANARY", localOnly: false)
        let link = try MeetingTaskService(repo: repo).confirm(meetingID: meeting.id,
            expectedRevision: meeting.revision, actionKey: "action", title: "TRANSITION_TASK_CANARY",
            quote: "TRANSITION_SOURCE_CANARY")
        let activity = try TaskService(repo: repo).addActivity(taskId: link.taskID,
            body: "TRANSITION_ACTIVITY_CANARY", workDate: date)
        return (repo, meeting, link, activity)
    }

    private func facts(_ repo: WorkRepository, family: ReportFamily) throws -> ReportFacts {
        let date = repo.calendar.workDate(of: repo.clock.now())
        let periods = Periods(calendar: repo.calendar)
        return try ReportFactsBuilder(repo: repo, periods: periods,
            planService: WeekPlanService(repo: repo, periods: periods)).build(family: family,
                periodType: .weekly, range: .init(start: date, endExclusive: repo.calendar.adding(days: 7, to: date)),
                knownAt: repo.clock.now())
    }

    func testTighteningExistingSourceProtectsTaskActivityReportsAndAIPayloads() throws {
        let (repo, meeting, link, activity) = try fixture()
        let policy = TaskDisclosurePolicy(repo: repo)
        XCTAssertFalse(link.localOnly)
        XCTAssertTrue(try policy.allows(.task, sourceID: link.taskID))
        let cachedFacts = try facts(repo, family: .performance)
        XCTAssertTrue(try StableJSON.string(cachedFacts).contains("TRANSITION_TASK_CANARY"))
        let index = try SearchIndex(repo: repo)
        try index.rebuildAll()

        let updated = try MeetingService(repo: repo).setLocalOnly(id: meeting.id,
            expectedRevision: meeting.revision, localOnly: true)
        XCTAssertTrue(updated.localOnly)
        XCTAssertEqual(updated.revision, meeting.revision + 1)
        let protectedLink = try XCTUnwrap(MeetingTaskService(repo: repo).links(taskID: link.taskID).first)
        XCTAssertTrue(protectedLink.localOnly)
        XCTAssertEqual(protectedLink.id, link.id)
        XCTAssertEqual(protectedLink.quote, link.quote)
        XCTAssertEqual(protectedLink.createdAt, link.createdAt)
        XCTAssertFalse(try policy.allows(.task, sourceID: link.taskID))
        XCTAssertFalse(try policy.allows(.activity, sourceID: activity.id))
        XCTAssertThrowsError(try policy.requireDisclosable(cachedFacts))
        for family in [ReportFamily.submission, .performance] {
            XCTAssertFalse(try StableJSON.string(facts(repo, family: family)).contains("CANARY"))
        }
        // Ordinary local lookup remains available; disclosure filtering is at the AI boundary.
        XCTAssertFalse(try index.search(.init(text: "CANARY")).isEmpty)
        let runner = AIJobRunner(repo: repo, provider: MockAIProvider(), stagingRoot: FileManager.default.temporaryDirectory)
        let templates = TemplateStore(repo: repo)
        let grounded = GroundedAnswerService(index: index, runner: runner, templates: templates)
        XCTAssertTrue(try grounded.collectEvidence(question: "CANARY", scope: .init()).isEmpty)
        let forced = EvidenceRef(id: "task:" + link.taskID, sourceType: .task, sourceId: link.taskID,
            workDate: meeting.workDate, snippet: "TRANSITION_TASK_CANARY")
        XCTAssertFalse(try grounded.buildPayload(question: "검토", evidence: [forced]).contains("CANARY"))
        XCTAssertThrowsError(try EvidenceQuizService(repo: repo, runner: runner, templates: templates).buildPayload(facts: cachedFacts))
        let memo = try TaskService(repo: repo).captureMemo(body: "일반 검토 메모", workDate: meeting.workDate)
        XCTAssertFalse(try MemoLinkSuggestionService(repo: repo, runner: runner, templates: templates)
            .buildPayload(memoId: memo.id).contains("CANARY"))
        XCTAssertEqual(try repo.db.scalarInt("SELECT COUNT(*) FROM ai_job"), 0)
    }

    func testProtectionSurvivesReallowingSourceAndMovingItToTrash() throws {
        let (repo, meeting, link, _) = try fixture()
        let service = MeetingService(repo: repo)
        let protected = try service.setLocalOnly(id: meeting.id, expectedRevision: meeting.revision, localOnly: true)
        let shared = try service.setLocalOnly(id: meeting.id, expectedRevision: protected.revision, localOnly: false)
        XCTAssertFalse(shared.localOnly)
        XCTAssertTrue(try TaskDisclosurePolicy(repo: repo).protectedTaskIDs().contains(link.taskID))
        try service.delete(id: meeting.id, expectedRevision: shared.revision)
        XCTAssertNotNil(try repo.task(id: link.taskID))
        XCTAssertTrue(try TaskDisclosurePolicy(repo: repo).protectedTaskIDs().contains(link.taskID))
        XCTAssertTrue(try MeetingTaskService(repo: repo).links(taskID: link.taskID).first!.localOnly)
    }

    func testRepeatedLocalOnlyRepairsPreviouslyUnprotectedLinksWithoutChangingMeetingRevision() throws {
        let (repo, meeting, link, _) = try fixture()
        // Reproduce a database made by the old policy setter, which changed only the source row.
        try repo.db.runV("UPDATE meeting SET local_only = 1 WHERE id = ?", meeting.id)
        let result = try MeetingService(repo: repo).setLocalOnly(id: meeting.id,
            expectedRevision: meeting.revision, localOnly: true)
        XCTAssertEqual(result.revision, meeting.revision)
        XCTAssertTrue(try TaskDisclosurePolicy(repo: repo).protectedTaskIDs().contains(link.taskID))
    }

    func testPolicyAndLinkChangesRollBackTogetherOnEitherWriteFailure() throws {
        for trigger in [
            "CREATE TRIGGER fail_privacy BEFORE UPDATE OF local_only ON meeting_task_link BEGIN SELECT RAISE(ABORT, 'injected link failure'); END;",
            "CREATE TRIGGER fail_privacy BEFORE UPDATE OF local_only ON meeting BEGIN SELECT RAISE(ABORT, 'injected source failure'); END;"
        ] {
            let (repo, meeting, link, activity) = try fixture()
            try repo.db.execute(trigger)
            XCTAssertThrowsError(try MeetingService(repo: repo).setLocalOnly(id: meeting.id,
                expectedRevision: meeting.revision, localOnly: true))
            let unchanged = try XCTUnwrap(MeetingService(repo: repo).meeting(id: meeting.id))
            XCTAssertFalse(unchanged.localOnly)
            XCTAssertEqual(unchanged.revision, meeting.revision)
            XCTAssertEqual(unchanged.updatedAt, meeting.updatedAt)
            XCTAssertEqual(try MeetingTaskService(repo: repo).links(taskID: link.taskID), [link])
            XCTAssertTrue(try TaskDisclosurePolicy(repo: repo).protectedTaskIDs().isEmpty)
            XCTAssertEqual(try repo.activity(id: activity.id), activity)
            try repo.db.execute("DROP TRIGGER fail_privacy")
            let retry = try MeetingService(repo: repo).setLocalOnly(id: meeting.id,
                expectedRevision: meeting.revision, localOnly: true)
            XCTAssertTrue(retry.localOnly)
            XCTAssertTrue(try TaskDisclosurePolicy(repo: repo).protectedTaskIDs().contains(link.taskID))
        }
    }

    func testPolicyChangeWhileReportIsInFlightPreventsResponseAndFallbackPersistence() async throws {
        for fails in [false, true] {
            let (repo, meeting, link, _) = try fixture()
            let provider = PrivacyTransitionProvider(fails: fails)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-in-flight-" + UUIDGenerator().make())
            defer { try? FileManager.default.removeItem(at: root) }
            let runner = AIJobRunner(repo: repo, provider: provider, stagingRoot: root)
            let periods = Periods(calendar: repo.calendar)
            let service = ReportService(repo: repo, periods: periods,
                factsBuilder: ReportFactsBuilder(repo: repo, periods: periods,
                    planService: WeekPlanService(repo: repo, periods: periods)),
                store: ReportStore(repo: repo), templates: TemplateStore(repo: repo), runner: runner,
                evaluationPeriods: EvaluationPeriodService(repo: repo))
            let pending = Task {
                try await service.generatePerformance(periodType: .weekly, containing: meeting.workDate,
                    mode: .userRequested, useAI: true)
            }
            defer { pending.cancel(); Task { await provider.release() } }
            let deadline = ContinuousClock().now.advanced(by: .seconds(5))
            while !(await provider.isWaiting) {
                guard ContinuousClock().now < deadline else { throw WorkLogError.validation("Fake report provider did not start") }
                try await Task.sleep(for: .milliseconds(5))
            }
            // This request was allowed when dispatched. A later policy change cannot
            // retract that input, but it must prevent storing any new report version.
            let inputs = await provider.inputs
            XCTAssertEqual(inputs.count, 1)
            XCTAssertTrue(inputs[0].payloadJSON.contains("TRANSITION_TASK_CANARY"))
            _ = try MeetingService(repo: repo).setLocalOnly(id: meeting.id,
                expectedRevision: meeting.revision, localOnly: true)
            await provider.release()
            do {
                _ = try await pending.value
                XCTFail("An in-flight protected report must not save an AI response or fallback")
            } catch let error as WorkLogError {
                guard case .validation = error else { return XCTFail("Expected disclosure validation, got \(error)") }
            }
            XCTAssertTrue(try TaskDisclosurePolicy(repo: repo).protectedTaskIDs().contains(link.taskID))
            XCTAssertEqual(try repo.db.scalarInt("SELECT COUNT(*) FROM report_version"), 0)
            XCTAssertEqual(try repo.db.scalarInt("SELECT COUNT(*) FROM source_snapshot"), 0)
        }
    }
}

private actor PrivacyTransitionProvider: AIProvider {
    let fails: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var inputs: [AIJobInput] = []
    var isWaiting: Bool { continuation != nil }
    init(fails: Bool) { self.fails = fails }
    func release() { continuation?.resume(); continuation = nil }
    func run(_ input: AIJobInput) async throws -> AIJobOutput {
        inputs.append(input)
        await withCheckedContinuation { continuation = $0 }
        if fails { throw AIProviderError(.cancelled, "fake cancellation") }
        return AIJobOutput(rawJSON: "{}")
    }
    func checkCapabilities() async -> AICapabilities { .init(installed: true, protocolCompatible: true) }
    func getAccountStatus() async throws -> AIAccountState { .loggedOut }
    func beginOfficialLogin() async throws -> URL? { nil }
    func listAvailableSkills() async throws -> [DiscoveredSkill] { [] }
    func cancel(jobId: String) async { release() }
}
