import XCTest
@testable import WorkLogCore

final class MeetingLocalOnlyTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_792_972_800)

    private func repository() throws -> WorkRepository {
        try WorkRepository.inMemory(clock: FixedClock(instant), ids: SequentialIDGenerator(prefix: "local-only"))
    }

    private func runner(_ repo: WorkRepository, _ provider: MeetingLocalNetworkSpy) -> AIJobRunner {
        AIJobRunner(repo: repo, provider: provider,
            stagingRoot: FileManager.default.temporaryDirectory.appendingPathComponent("meeting-local-only-fixture"))
    }

    func testDefaultLocalOnlyRejectsBeforeProviderOrAccountAccessAndBeforeCreatingAIJob() async throws {
        let repo = try repository(), provider = MeetingLocalNetworkSpy()
        let service = MeetingService(repo: repo, runner: runner(repo, provider))
        let meeting = try service.create(title: "외부 전송 금지", transcript: "로컬에만 남을 가짜 전사", notes: "로컬 메모")
        XCTAssertTrue(meeting.localOnly)
        do { _ = try await service.generateSummary(id: meeting.id); XCTFail("localOnly accepted") }
        catch let error as WorkLogError {
            guard case .policyBlocked = error else { return XCTFail("expected policy block") }
        }
        let networkCalls = await provider.runCount
        let accountReads = await provider.generationReads
        XCTAssertEqual(networkCalls, 0)
        XCTAssertEqual(accountReads, 0)
        XCTAssertEqual(try repo.db.scalarInt("SELECT COUNT(*) FROM ai_job"), 0)
        XCTAssertEqual(try service.meeting(id: meeting.id)?.transcript, meeting.transcript)
    }

    func testV5MeetingsAreAlsoBlockedAfterMigration() async throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try Migrator.migrate(db, migrations: WorkSchema.migrations.filter { $0.version <= 5 })
        try db.runV("""
            INSERT INTO meeting(id,title,work_date,transcript,created_at,updated_at) VALUES(?,?,?,?,?,?)
            """, "legacy", "이전 회의", "2026-10-26", "이전 전사", instant, instant)
        let repo = try WorkRepository(db: db, clock: FixedClock(instant)), provider = MeetingLocalNetworkSpy()
        let service = MeetingService(repo: repo, runner: runner(repo, provider))
        do { _ = try await service.generateSummary(id: "legacy"); XCTFail("legacy localOnly accepted") }
        catch let error as WorkLogError {
            guard case .policyBlocked = error else { return XCTFail("expected policy block") }
        }
        let count = await provider.runCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(try repo.db.scalarInt("SELECT COUNT(*) FROM ai_job"), 0)
    }

    func testLocalOnlyChangeWhileQueuedPreventsMeetingPayloadFromReachingProvider() async throws {
        let repo = try repository(), provider = MeetingLocalNetworkSpy(blockFirst: true)
        let runner = runner(repo, provider), service = MeetingService(repo: repo, runner: runner)
        let meeting = try service.create(title: "대기 중 정책 변경", transcript: "전송되면 안 되는 가짜 내용", localOnly: false)
        let occupying = Task {
            try await runner.submit(AIJobRequest(jobType: .submissionWeekly, instructions: "fixture", payloadJSON: #"{"unrelated":true}"#))
        }
        await provider.waitUntilFirstRun()
        let queued = Task { try await service.generateSummary(id: meeting.id) }
        // First job has two generation reads; third proves the meeting passed its initial preflight.
        await provider.waitUntilQueuedSnapshot()
        _ = try service.setLocalOnly(id: meeting.id, expectedRevision: meeting.revision, localOnly: true)
        await provider.releaseFirst()
        _ = try await occupying.value
        do { _ = try await queued.value; XCTFail("queued localOnly accepted") }
        catch let error as WorkLogError {
            guard case .policyBlocked = error else { return XCTFail("expected policy block") }
        }
        let inputs = await provider.inputs
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs.first?.jobType, .submissionWeekly)
        XCTAssertFalse(inputs.contains { $0.payloadJSON.contains(meeting.transcript) })
        XCTAssertNil(try service.meeting(id: meeting.id)?.summary)
        XCTAssertEqual(try repo.db.scalarIntV("SELECT COUNT(*) FROM ai_job WHERE type = ?", AIJobType.meetingSummary.rawValue), 0)
    }

    func testLocalOnlyPolicyChangeWhileSummaryInFlightDoesNotSaveResponse() async throws {
        let repo = try repository(), provider = MeetingLocalNetworkSpy(blockFirst: true)
        let service = MeetingService(repo: repo, runner: runner(repo, provider))
        let meeting = try service.create(title: "전송 후 정책 변경", transcript: "가짜 근거", localOnly: false)
        let pending = Task { try await service.generateSummary(id: meeting.id) }
        await provider.waitUntilFirstRun()
        _ = try service.setLocalOnly(id: meeting.id, expectedRevision: meeting.revision, localOnly: true)
        await provider.releaseFirst()
        do { _ = try await pending.value; XCTFail("localOnly result saved") }
        catch let error as WorkLogError {
            guard case .policyBlocked = error else { return XCTFail("expected policy block") }
        }
        XCTAssertNil(try service.meeting(id: meeting.id)?.summary)
        XCTAssertTrue(try service.summaryHistory(meetingID: meeting.id).isEmpty)
    }

    func testLocalOnlyChangeWhileProviderAccountCheckSuspendsPreventsNetworkCall() async throws {
        let repo = try repository(), provider = MeetingLocalNetworkSpy(blockAccountCheck: true)
        let service = MeetingService(repo: repo, runner: runner(repo, provider))
        let meeting = try service.create(title: "전송 직전 정책 변경", transcript: "가짜 근거", localOnly: false)
        let pending = Task { try await service.generateSummary(id: meeting.id) }
        await provider.waitUntilAccountCheck()
        _ = try service.setLocalOnly(id: meeting.id, expectedRevision: meeting.revision, localOnly: true)
        await provider.releaseAccountCheck()
        do { _ = try await pending.value; XCTFail("localOnly request sent") }
        catch { }
        let count = await provider.runCount
        XCTAssertEqual(count, 0)
        XCTAssertNil(try service.meeting(id: meeting.id)?.summary)
    }

    func testLocalMeetingDoesNotEnterGeneralSearchReportFactsOrGroundedAnswerPayload() async throws {
        let repo = try repository(), date = WorkDate("2026-10-26")!
        let privateMarker = "LOCAL_MEETING_ONLY_FIXTURE"
        _ = try MeetingService(repo: repo).create(title: "평가 회의", workDate: date,
            transcript: "평가 " + privateMarker, notes: privateMarker)
        try repo.insertMemo(Memo(id: "general", body: "평가 일반 메모", workDate: date, recordedAt: instant))
        let index = try SearchIndex(repo: repo)
        try index.rebuildAll()
        XCTAssertTrue(try index.search(SearchQuery(text: privateMarker)).isEmpty)
        let periods = Periods(calendar: repo.calendar)
        let facts = try ReportFactsBuilder(repo: repo, periods: periods,
            planService: WeekPlanService(repo: repo, periods: periods)).build(family: .submission, periodType: .daily,
                range: DateRange(start: date, endExclusive: WorkDate("2026-10-27")!), knownAt: instant)
        let factsJSON = try StableJSON.string(facts)
        XCTAssertTrue(factsJSON.contains("평가 일반 메모"))
        XCTAssertFalse(factsJSON.contains(privateMarker))
        let output = GroundedAnswerOutput(schemaVersion: 1, jobType: "grounded_answer",
            paragraphs: [.init(text: "일반 근거만 확인", evidenceIds: ["memo:general"])], missingEvidence: [], warnings: [])
        let provider = MockAIProvider(responses: [.groundedAnswer: try StableJSON.string(output)])
        let runner = AIJobRunner(repo: repo, provider: provider,
            stagingRoot: FileManager.default.temporaryDirectory.appendingPathComponent("meeting-indirect-fixture"))
        let answer = try await GroundedAnswerService(index: index, runner: runner,
            templates: TemplateStore(repo: repo)).answer(question: "평가", scope: .init())
        XCTAssertEqual(answer.evidencePool.map(\.id), ["memo:general"])
        XCTAssertEqual(provider.runCount, 1)
        XCTAssertFalse(try XCTUnwrap(provider.receivedInputs.first).payloadJSON.contains(privateMarker))
    }
}

private actor MeetingLocalNetworkSpy: AIAccountGenerationProvider {
    private let blockFirst: Bool
    private let blockAccountCheck: Bool
    private var firstRun: CheckedContinuation<Void, Never>?
    private var runWaiter: CheckedContinuation<Void, Never>?
    private var queuedWaiter: CheckedContinuation<Void, Never>?
    private var accountCheck: CheckedContinuation<Void, Never>?
    private var accountWaiter: CheckedContinuation<Void, Never>?
    private(set) var generationReads = 0
    private(set) var inputs: [AIJobInput] = []
    var runCount: Int { inputs.count }
    init(blockFirst: Bool = false, blockAccountCheck: Bool = false) {
        self.blockFirst = blockFirst; self.blockAccountCheck = blockAccountCheck
    }

    func accountGeneration() async -> Int {
        generationReads += 1
        if generationReads >= 3 { queuedWaiter?.resume(); queuedWaiter = nil }
        if blockAccountCheck, generationReads == 2 {
            await withCheckedContinuation { continuation in
                accountCheck = continuation; accountWaiter?.resume(); accountWaiter = nil
            }
        }
        return 0
    }
    func waitUntilAccountCheck() async {
        if accountCheck != nil { return }
        await withCheckedContinuation { accountWaiter = $0 }
    }
    func releaseAccountCheck() { accountCheck?.resume(); accountCheck = nil }
    func waitUntilFirstRun() async {
        if firstRun != nil { return }
        await withCheckedContinuation { runWaiter = $0 }
    }
    func waitUntilQueuedSnapshot() async {
        if generationReads >= 3 { return }
        await withCheckedContinuation { queuedWaiter = $0 }
    }
    func releaseFirst() { firstRun?.resume(); firstRun = nil }
    func run(_ input: AIJobInput, expectedAccountGeneration: Int) async throws -> AIJobOutput { try await run(input) }
    func run(_ input: AIJobInput) async throws -> AIJobOutput {
        inputs.append(input)
        if blockFirst, inputs.count == 1 {
            await withCheckedContinuation { continuation in
                firstRun = continuation; runWaiter?.resume(); runWaiter = nil
            }
        }
        if input.jobType != .meetingSummary { return AIJobOutput(rawJSON: "{}") }
        struct Payload: Decodable { let sources: [MeetingSummarySource] }
        let payload = try StableJSON.decode(Payload.self, from: input.payloadJSON)
        let items = payload.sources.map { source in
            MeetingSummaryItem(text: "근거 확인", citations: [.init(sourceID: source.id, quote: source.text)])
        }
        return AIJobOutput(rawJSON: try StableJSON.string(MeetingSummaryOutput(summary: items)))
    }
    func checkCapabilities() async -> AICapabilities { AICapabilities(installed: true, protocolCompatible: true) }
    func getAccountStatus() async throws -> AIAccountState { .loggedOut }
    func beginOfficialLogin() async throws -> URL? { nil }
    func listAvailableSkills() async throws -> [DiscoveredSkill] { [] }
    func cancel(jobId: String) async { }
}
