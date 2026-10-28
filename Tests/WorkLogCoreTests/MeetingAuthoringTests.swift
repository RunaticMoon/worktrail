import XCTest
@testable import WorkLogCore

final class MeetingAuthoringTests: XCTestCase {
    private func repo() throws -> WorkRepository {
        try .inMemory(clock: FixedClock(Date(timeIntervalSince1970: 1_792_972_800)), ids: SequentialIDGenerator(prefix: "meeting-author"))
    }
    func testManualSummaryWithoutAIKeepsVersionsAndNoJobs() throws {
        let repo = try repo(), service = MeetingService(repo: repo)
        let meeting = try service.create(title: "로컬 회의", transcript: "별도 원문")
        let output = MeetingSummaryOutput(summary: [.init(text: "수동 요약", citations: [])],
            decisions: [.init(text: "직접 결정", citations: [])], actionItems: [.init(text: "다음 확인", citations: [])])
        let first = try service.saveManualSummary(meetingID: meeting.id, expectedMeetingRevision: meeting.revision,
            expectedSummaryRevision: nil, output: output)
        XCTAssertTrue(first.isManual); XCTAssertTrue(first.sources.isEmpty)
        XCTAssertTrue(try service.meeting(id: meeting.id)!.localOnly)
        XCTAssertEqual(try repo.db.scalarInt("SELECT COUNT(*) FROM ai_job"), 0)
        var revised = output; revised.summary = [.init(text: "수정 요약", citations: [])]
        let second = try service.saveManualSummary(meetingID: meeting.id, expectedMeetingRevision: meeting.revision,
            expectedSummaryRevision: first.revision, output: revised)
        XCTAssertEqual(second.version, 2)
        XCTAssertEqual(try service.summaryHistory(meetingID: meeting.id).last?.structuredOutput, output)
        XCTAssertEqual(try service.meeting(id: meeting.id)?.transcript, "별도 원문")
        XCTAssertThrowsError(try service.saveManualSummary(meetingID: meeting.id, expectedMeetingRevision: meeting.revision,
            expectedSummaryRevision: first.revision, output: output))
        _ = try service.update(id: meeting.id, expectedRevision: meeting.revision, title: meeting.title,
            workDate: meeting.workDate, transcript: "바뀐 원문", notes: "")
        XCTAssertTrue(try service.meeting(id: meeting.id)!.isSummaryStale)
    }
    func testManualCannotFabricateAICitationsAndAIEditRetainsHistory() throws {
        let repo = try repo(), service = MeetingService(repo: repo)
        let meeting = try service.create(title: "회의")
        XCTAssertThrowsError(try service.saveManualSummary(meetingID: meeting.id, expectedMeetingRevision: 1, expectedSummaryRevision: nil,
            output: .init(summary: [.init(text: "내용", citations: [.init(sourceID: "fake", quote: "fake")])])))
        let first = try service.saveManualSummary(meetingID: meeting.id, expectedMeetingRevision: 1, expectedSummaryRevision: nil,
            output: .init(summary: [.init(text: "내용", citations: [])]))
        _ = try service.editSummary(meetingID: meeting.id, expectedRevision: first.revision, content: "본문 수정")
        XCTAssertEqual(try repo.db.scalarInt("SELECT COUNT(*) FROM meeting_summary_edit"), 1)
    }
    func testMetadataPreservesSourceAndOptionalTimeAndUnavailableReferences() throws {
        let repo = try repo(), service = MeetingService(repo: repo)
        let a = try repo.createProject(name: "가"), b = try repo.createProject(name: "나")
        let tag = try repo.findOrCreateTag(name: "주간")
        let meeting = try service.create(title: "회의", transcript: "원문")
        let metadata = MeetingMetadata(projectIDs: [a.id, b.id], tagIDs: [tag.id], participants: ["담당자"], agenda: "안건")
        let updated = try service.updateMetadata(meetingID: meeting.id, expectedRevision: 1, metadata: metadata)
        XCTAssertEqual(updated.transcript, "원문"); XCTAssertNil(updated.metadata?.occurredAt)
        XCTAssertEqual(updated.workDate, meeting.workDate)
        var removed = metadata; removed.projectIDs = [b.id]
        let final = try service.updateMetadata(meetingID: meeting.id, expectedRevision: updated.revision, metadata: removed)
        XCTAssertEqual(final.metadata?.projectIDs, [b.id]); XCTAssertTrue(final.localOnly)
    }
    func testActionConfirmationIsIdempotentProtectedAndDoesNotMutateExistingTask() throws {
        let repo = try repo(), service = MeetingService(repo: repo), tasks = MeetingTaskService(repo: repo)
        let meeting = try service.create(title: "회의", notes: "검토할 업무")
        XCTAssertTrue(try repo.tasks().isEmpty)
        let link = try tasks.confirm(meetingID: meeting.id, expectedRevision: 1, actionKey: "action-1",
            title: "검토할 업무", quote: "검토할 업무")
        XCTAssertNil(link.owner); XCTAssertTrue(link.localOnly)
        XCTAssertNil(try repo.task(id: link.taskID)?.dueOn)
        let again = try tasks.confirm(meetingID: meeting.id, expectedRevision: 1, actionKey: "action-1",
            title: "검토할 업무", quote: "검토할 업무")
        XCTAssertEqual(link.id, again.id); XCTAssertEqual(try repo.tasks().count, 1)
        let existing = try TaskService(repo: repo).createTask(title: "기존 업무", initialStatus: .inProgress)
        _ = try tasks.confirm(meetingID: meeting.id, expectedRevision: 1, actionKey: "action-2", title: "무시", quote: "검토할 업무", existingTaskID: existing.id)
        XCTAssertEqual(try repo.task(id: existing.id)?.cachedStatus, .inProgress)
        try service.delete(id: meeting.id, expectedRevision: 1)
        XCTAssertNotNil(try repo.task(id: link.taskID))
        XCTAssertEqual(try tasks.links(taskID: link.taskID).first?.quote, "검토할 업무")
    }
    func testActionRejectsInvalidSourceAndRevision() throws {
        let repo = try repo(), service = MeetingService(repo: repo), tasks = MeetingTaskService(repo: repo)
        let meeting = try service.create(title: "회의", notes: "근거")
        XCTAssertThrowsError(try tasks.confirm(meetingID: meeting.id, expectedRevision: 2, actionKey: "one", title: "업무", quote: "근거"))
        XCTAssertThrowsError(try tasks.confirm(meetingID: meeting.id, expectedRevision: 1, actionKey: "one", title: "업무", quote: "없는 인용"))
        XCTAssertTrue(try repo.tasks().isEmpty)
    }
    func testLocalSearchLiteralWildcardAndPaginationNeverCreatesAIJobs() throws {
        let repo = try repo(), service = MeetingService(repo: repo)
        for i in 0..<8 { _ = try service.create(title: "회의 \(i)", notes: "진행률 50%_완료") }
        let search = MeetingLocalSearchService(repo: repo)
        XCTAssertEqual(try search.search("%_", limit: 3).count, 3)
        let first = try search.search("%_", limit: 3), next = try search.search("%_", limit: 3, offset: 3)
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: Set(next.map(\.id))))
        XCTAssertEqual(try search.search("없는 검색").count, 0)
        XCTAssertEqual(try repo.db.scalarInt("SELECT COUNT(*) FROM ai_job"), 0)
    }
    func testLargeLocalTranscriptSearchAndFilters() throws {
        let repo = try repo(), service = MeetingService(repo: repo), store = MeetingAudioStore(repo: repo)
        let meeting = try service.create(title: "장시간 fixture")
        let recording = try store.createRecording(meetingID: meeting.id)
        let track = try store.addTrack(recordingID: recording.id, kind: .microphone, relativePath: "fixture/audio.caf", sampleRate: 16000, channels: 1)
        let run = try store.createRun(meetingID: meeting.id, recordingID: recording.id, stage: .refined, engine: "fake", modelIdentifier: "fake")
        let inputs: [MeetingSegmentInput] = (0..<6000).map { i in
            let text = i % 10 == 0 ? "찾을 단어 \(i)" : "일반 구간 \(i)"
            return MeetingSegmentInput(trackID: track.id, sourceKey: "s\(i)", start: Double(i * 5),
                end: Double(i * 5 + 4), text: text, isFinal: i % 3 != 0)
        }
        _ = try store.upsertSegments(runID: run.id, segments: inputs)
        let started = ProcessInfo.processInfo.systemUptime
        let hits = try MeetingLocalSearchService(repo: repo).search("찾을 단어", limit: 50)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertEqual(hits.count, 50); XCTAssertNotNil(hits.first?.runID); XCTAssertNotNil(hits.first?.segmentID)
        print("MEETING_FIXTURE segments=6000 searchResults=50 searchSeconds=\(elapsed)")
        var filter = MeetingSegmentFilter(); filter.unconfirmedOnly = true; filter.unknownSpeakerOnly = true
        let segments = try store.segments(runID: run.id)
        XCTAssertEqual(segments.filter(filter.matches).count, 2000)
    }
}
