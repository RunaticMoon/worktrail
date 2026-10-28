import XCTest
@testable import WorkLogCore

final class MeetingTaskDisclosureTests: XCTestCase {
    private func fixture() throws -> (WorkRepository, Meeting, WorkTask) {
        let repo = try WorkRepository.inMemory(clock: FixedClock(Date(timeIntervalSince1970: 1_792_972_800)), ids: SequentialIDGenerator(prefix: "protection"))
        let meeting = try MeetingService(repo: repo).create(title: "가짜 회의", workDate: WorkDate("2026-10-26")!, notes: "LOCAL_MEETING_CANARY 확인")
        let link = try MeetingTaskService(repo: repo).confirm(meetingID: meeting.id, expectedRevision: meeting.revision,
            actionKey: "first", title: "LOCAL_TASK_CANARY", quote: "LOCAL_MEETING_CANARY")
        let task = try XCTUnwrap(repo.task(id: link.taskID))
        _ = try TaskService(repo: repo).addActivity(taskId: task.id, body: "LOCAL_ACTIVITY_CANARY", workDate: meeting.workDate)
        return (repo, meeting, task)
    }
    private func builder(_ repo: WorkRepository) -> ReportFactsBuilder {
        ReportFactsBuilder(repo: repo, periods: Periods(), planService: WeekPlanService(repo: repo, periods: Periods()))
    }
    func testLocalSearchKeepsTaskButExternalEvidenceAndPayloadExcludeIt() throws {
        let (repo, _, task) = try fixture()
        let index = try SearchIndex(repo: repo)
        try index.rebuildAll()
        XCTAssertFalse(try index.search(.init(text: "CANARY")).isEmpty)
        let runner = AIJobRunner(repo: repo, provider: MockAIProvider(), stagingRoot: FileManager.default.temporaryDirectory)
        let grounded = GroundedAnswerService(index: index, runner: runner, templates: TemplateStore(repo: repo))
        XCTAssertTrue(try grounded.collectEvidence(question: "CANARY", scope: .init()).isEmpty)
        let forced = EvidenceRef(id: "task:" + task.id, sourceType: .task, sourceId: task.id, workDate: nil, snippet: "LOCAL_TASK_CANARY")
        XCTAssertFalse(try grounded.buildPayload(question: "확인", evidence: [forced]).contains("CANARY"))
        let memo = try TaskService(repo: repo).captureMemo(body: "일반 메모", workDate: WorkDate("2026-10-26")!)
        let suggestions = MemoLinkSuggestionService(repo: repo, runner: runner, templates: TemplateStore(repo: repo))
        XCTAssertFalse(try suggestions.buildPayload(memoId: memo.id).contains("CANARY"))
    }
    func testSubmissionAndPerformanceNeverIncludeProtectedTaskOrActivity() throws {
        let (repo, meeting, task) = try fixture()
        let range = DateRange(start: meeting.workDate, endExclusive: repo.calendar.adding(days: 7, to: meeting.workDate))
        for family in [ReportFamily.submission, .performance] {
            let facts = try builder(repo).build(family: family, periodType: .weekly, range: range, knownAt: repo.clock.now())
            XCTAssertFalse(facts.tasks.contains { $0.id == task.id })
            XCTAssertFalse(try StableJSON.string(facts).contains("CANARY"))
        }
        try MeetingService(repo: repo).delete(id: meeting.id, expectedRevision: meeting.revision)
        XCTAssertNotNil(try repo.task(id: task.id))
        XCTAssertTrue(try TaskDisclosurePolicy(repo: repo).protectedTaskIDs().contains(task.id))
    }
    func testCachedFactsAreBlockedWhenExistingTaskBecomesProtected() throws {
        let repo = try WorkRepository.inMemory(clock: FixedClock(Date(timeIntervalSince1970: 1_792_972_800)), ids: SequentialIDGenerator())
        let date = WorkDate("2026-10-26")!
        let task = try TaskService(repo: repo).createTask(title: "기존 업무", workDate: date)
        let facts = try builder(repo).build(family: .performance, periodType: .weekly,
            range: .init(start: date, endExclusive: repo.calendar.adding(days: 7, to: date)), knownAt: repo.clock.now())
        XCTAssertTrue(facts.tasks.contains { $0.id == task.id })
        let meeting = try MeetingService(repo: repo).create(title: "로컬", notes: "연결 근거")
        _ = try MeetingTaskService(repo: repo).confirm(meetingID: meeting.id, expectedRevision: meeting.revision,
            actionKey: "link", title: "", quote: "연결 근거", existingTaskID: task.id)
        let runner = AIJobRunner(repo: repo, provider: MockAIProvider(), stagingRoot: FileManager.default.temporaryDirectory)
        XCTAssertThrowsError(try EvidenceQuizService(repo: repo, runner: runner, templates: TemplateStore(repo: repo)).buildPayload(facts: facts))
        XCTAssertThrowsError(try TaskDisclosurePolicy(repo: repo).requireDisclosable(facts))
    }
}
