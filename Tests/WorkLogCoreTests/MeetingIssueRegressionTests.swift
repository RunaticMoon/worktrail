import XCTest
@testable import WorkLogCore

/// Regression tests for #79 (task re-link), #80 (old manual versions in local search) and #81 (speaker filter across versions).
final class MeetingIssueRegressionTests: XCTestCase {
    private func repo() throws -> WorkRepository {
        try .inMemory(clock: FixedClock(Date(timeIntervalSince1970: 1_792_972_800)), ids: SequentialIDGenerator(prefix: "meeting-issue"))
    }

    // MARK: #79
    func testRelinkingSameActionToAnotherTaskConflictsAndKeepsOriginalLink() throws {
        let repo = try repo(), service = MeetingService(repo: repo), tasks = MeetingTaskService(repo: repo)
        let meeting = try service.create(title: "회의", notes: "배포 점검")
        let a = try TaskService(repo: repo).createTask(title: "업무 A")
        let b = try TaskService(repo: repo).createTask(title: "업무 B")
        let link = try tasks.confirm(meetingID: meeting.id, expectedRevision: 1, actionKey: "manual-action:배포 점검:배포 점검",
            title: "배포 점검", quote: "배포 점검", existingTaskID: a.id)
        XCTAssertEqual(try tasks.confirm(meetingID: meeting.id, expectedRevision: 1, actionKey: link.actionKey,
            title: "배포 점검", quote: "배포 점검", existingTaskID: a.id), link)
        XCTAssertThrowsError(try tasks.confirm(meetingID: meeting.id, expectedRevision: 1, actionKey: link.actionKey,
            title: "배포 점검", quote: "배포 점검", existingTaskID: b.id)) { error in
            guard case WorkLogError.conflict(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("업무 A"))
        }
        XCTAssertThrowsError(try tasks.confirm(meetingID: meeting.id, expectedRevision: 1, actionKey: link.actionKey,
            title: "새 업무", quote: "배포 점검"))
        XCTAssertEqual(try tasks.links(meetingID: meeting.id), [link])
        XCTAssertTrue(try tasks.links(taskID: b.id).isEmpty)
        XCTAssertEqual(try repo.tasks().count, 2)
    }

    func testRepeatedNewTaskRequestIsIdempotentButChangedInputConflicts() throws {
        let repo = try repo(), service = MeetingService(repo: repo), tasks = MeetingTaskService(repo: repo)
        let meeting = try service.create(title: "회의", notes: "배포 점검")
        let due = WorkDate(year: 2026, month: 11, day: 20)
        let link = try tasks.confirm(meetingID: meeting.id, expectedRevision: 1, actionKey: "k", title: " 배포 점검 ", dueOn: due, quote: "배포 점검")
        XCTAssertEqual(try tasks.confirm(meetingID: meeting.id, expectedRevision: 1, actionKey: "k", title: "배포 점검", dueOn: due, quote: "배포 점검"), link)
        XCTAssertThrowsError(try tasks.confirm(meetingID: meeting.id, expectedRevision: 1, actionKey: "k", title: "다른 제목", dueOn: due, quote: "배포 점검"))
        XCTAssertThrowsError(try tasks.confirm(meetingID: meeting.id, expectedRevision: 1, actionKey: "k", title: "배포 점검", dueOn: nil, quote: "배포 점검"))
        let other = try TaskService(repo: repo).createTask(title: "기존")
        XCTAssertThrowsError(try tasks.confirm(meetingID: meeting.id, expectedRevision: 1, actionKey: "k", title: "배포 점검", quote: "배포 점검", existingTaskID: other.id))
        XCTAssertEqual(try repo.tasks().count, 2)
        XCTAssertEqual(try tasks.links(meetingID: meeting.id), [link])
    }

    // MARK: #80
    func testLocalSearchFindsTextOnlyInPreservedManualVersion() throws {
        let repo = try repo(), service = MeetingService(repo: repo), store = MeetingAudioStore(repo: repo)
        let meeting = try service.create(title: "주간 회의", transcript: "이전 전용 키워드 포함 원문")
        let second = try service.update(id: meeting.id, expectedRevision: meeting.revision, title: meeting.title,
            workDate: meeting.workDate, transcript: "두 번째 원문", notes: "")
        let third = try service.update(id: meeting.id, expectedRevision: second.revision, title: meeting.title,
            workDate: meeting.workDate, transcript: "현재 원문 50%_완료", notes: "")
        let search = MeetingLocalSearchService(repo: repo)

        let old = try search.search("이전 전용 키워드")
        XCTAssertEqual(old.count, 1)
        let hit = try XCTUnwrap(old.first)
        XCTAssertEqual(hit.meetingID, meeting.id); XCTAssertNil(hit.segmentID)
        let run = try XCTUnwrap(store.run(id: try XCTUnwrap(hit.runID)))
        XCTAssertEqual(run.manualText, "이전 전용 키워드 포함 원문")
        XCTAssertNotEqual(run.id, third.activeTranscriptRunID)
        XCTAssertTrue(hit.snippet.contains("이전 전용 키워드"))
        XCTAssertEqual(try search.search("두 번째").map(\.runID).count, 1)

        // The active manual version is reported once, through the meeting body.
        let current = try search.search("현재 원문")
        XCTAssertEqual(current.count, 1); XCTAssertNil(current.first?.runID)
        // Literal wildcard characters stay escaped for manual versions too.
        XCTAssertEqual(try search.search("%_").count, 1)

        try service.delete(id: meeting.id, expectedRevision: third.revision)
        XCTAssertTrue(try search.search("이전 전용 키워드").isEmpty)
    }

    // MARK: #81
    func testSpeakerFilterFromAnotherVersionIsClearedButOtherCriteriaKept() throws {
        let repo = try repo(), service = MeetingService(repo: repo), store = MeetingAudioStore(repo: repo)
        let meeting = try service.create(title: "회의")
        let recording = try store.createRecording(meetingID: meeting.id)
        let runA = try store.createRun(meetingID: meeting.id, recordingID: recording.id, stage: .diarized, engine: "fake", modelIdentifier: "fake")
        let runB = try store.createRun(meetingID: meeting.id, recordingID: recording.id, stage: .diarized, engine: "fake", modelIdentifier: "fake")
        let a1 = try store.upsertSpeaker(runID: runA.id, sourceKey: "spk0", displayName: "화자 1")
        let b1 = try store.upsertSpeaker(runID: runB.id, sourceKey: "spk0", displayName: "화자 1")
        XCTAssertNotEqual(a1.id, b1.id)

        var filter = MeetingSegmentFilter()
        filter.speakerID = a1.id; filter.query = "배포"; filter.start = 10
        XCTAssertFalse(filter.restrictSpeaker(to: try store.speakers(runID: runA.id)))
        XCTAssertEqual(filter.speakerID, a1.id)
        // Same display name in another version is a different speaker.
        XCTAssertTrue(filter.restrictSpeaker(to: try store.speakers(runID: runB.id)))
        XCTAssertNil(filter.speakerID)
        XCTAssertEqual(filter.query, "배포"); XCTAssertEqual(filter.start, 10)

        filter.speakerID = b1.id
        XCTAssertTrue(filter.restrictSpeaker(to: []), "a version without speakers clears the speaker filter")
        XCTAssertNil(filter.speakerID)
        XCTAssertFalse(filter.restrictSpeaker(to: []))
    }
}
