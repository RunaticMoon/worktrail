import XCTest
@testable import WorkLogCore

final class StateReplayTests: XCTestCase {

    // MARK: - Helpers

    private func fixture() throws -> ExampleFixture { try FixtureLoader.load() }

    private func date(_ iso: String) throws -> Date {
        try XCTUnwrap(FixtureLoader.date(iso), "날짜 파싱 실패: \(iso)")
    }

    private func workDate(_ iso: String) throws -> WorkDate {
        try XCTUnwrap(WorkDate(iso), "WorkDate 파싱 실패: \(iso)")
    }

    private func makeEvent(_ id: String, kind: DomainEventKind, status: TaskStatus? = nil,
                           date: String, order: Int = 1, recorded: String,
                           scope: EventScopeType = .task, scopeId: String? = nil,
                           taskId: String = "t1", supersedes: String? = nil) throws -> DomainEvent {
        DomainEvent(
            id: id,
            taskId: taskId,
            scopeType: scope,
            scopeId: scopeId ?? taskId,
            kind: kind,
            toStatus: status,
            effectiveDate: try workDate(date),
            effectiveOrder: order,
            recordedAt: try self.date(recorded),
            supersedesEventId: supersedes
        )
    }

    // MARK: - 1 ~ 5. 픽스처 기반

    func testFixtureKnownMondayThroughSunday() throws {
        let events = try fixture().domainEvents()
        let result = StateReplay.replay(events,
                                        through: try workDate("2026-10-04"),
                                        knownAt: try date("2026-10-05T10:30:00+09:00"))
        XCTAssertEqual(result.taskStatus("task-A"), .inProgress)
        XCTAssertEqual(result.taskStatus("task-B"), .inProgress)
        XCTAssertEqual(result.taskStatus("task-C"), .completed)
        XCTAssertTrue(result.violations.isEmpty, "\(result.violations)")
    }

    func testFixtureKnownSundayThroughSunday() throws {
        let events = try fixture().domainEvents()
        let result = StateReplay.replay(events,
                                        through: try workDate("2026-10-04"),
                                        knownAt: try date("2026-10-04T23:59:00+09:00"))
        XCTAssertEqual(result.taskStatus("task-A"), .inProgress)
        XCTAssertEqual(result.taskStatus("task-B"), .inProgress)
        XCTAssertNil(result.taskStatus("task-C"))
        XCTAssertTrue(result.violations.isEmpty, "\(result.violations)")
    }

    func testFixtureKnownMondayThroughNil() throws {
        let events = try fixture().domainEvents()
        let result = StateReplay.replay(events, through: nil,
                                        knownAt: try date("2026-10-05T10:30:00+09:00"))
        XCTAssertEqual(result.taskStatus("task-A"), .inProgress)
        XCTAssertEqual(result.taskStatus("task-B"), .completed)
        XCTAssertEqual(result.taskStatus("task-C"), .completed)
    }

    func testFixtureProjectStatesThroughSunday() throws {
        let events = try fixture().domainEvents()
        let result = StateReplay.replay(events,
                                        through: try workDate("2026-10-04"),
                                        knownAt: try date("2026-10-05T10:30:00+09:00"))
        XCTAssertEqual(result.projectStatus(taskId: "task-A", projectId: "project-G"), .completed)
        XCTAssertEqual(result.projectStatus(taskId: "task-A", projectId: "project-J"), .inProgress)
        XCTAssertEqual(result.projectStatus(taskId: "task-A", projectId: "project-K"), .planned)
        // 프로젝트 scope는 task 상태를 바꾸지 않는다.
        XCTAssertEqual(result.taskStatus("task-A"), .inProgress)
    }

    func testFixtureFirstStartedOn() throws {
        let events = try fixture().domainEvents()
        let knownAt = try date("2026-10-05T10:30:00+09:00")
        XCTAssertNil(StateReplay.firstStartedOn(taskId: "task-C", events, knownAt: knownAt))
        XCTAssertEqual(StateReplay.firstStartedOn(taskId: "task-A", events, knownAt: knownAt),
                       try workDate("2026-09-28"))
    }

    // MARK: - 6. TIME-T06 늦게 기록한 시작 사건

    func testLateRecordedStartDoesNotUndoLaterCompletion() throws {
        let events = [
            try makeEvent("c", kind: .created, status: .planned, date: "2026-09-30",
                          order: 1, recorded: "2026-09-30T09:00:00+09:00"),
            // 화요일 완료 기록 (먼저 기록됨)
            try makeEvent("done", kind: .completed, status: .completed, date: "2026-10-06",
                          order: 1, recorded: "2026-10-06T18:00:00+09:00"),
            // 월요일 시작을 늦게 기록 (recordedAt이 더 나중)
            try makeEvent("start", kind: .started, status: .inProgress, date: "2026-10-05",
                          order: 1, recorded: "2026-10-07T09:00:00+09:00")
        ]

        let current = StateReplay.replay(events, through: nil, knownAt: nil)
        XCTAssertEqual(current.taskStatus("t1"), .completed)

        let monday = StateReplay.replay(events, through: try workDate("2026-10-05"), knownAt: nil)
        XCTAssertEqual(monday.taskStatus("t1"), .inProgress)
    }

    // MARK: - 7. TASK-T03 진행→보류→재개

    func testPauseAndResumeHistory() throws {
        let events = [
            try makeEvent("c", kind: .created, status: .planned, date: "2026-10-01",
                          order: 1, recorded: "2026-10-01T09:00:00+09:00"),
            try makeEvent("s", kind: .started, status: .inProgress, date: "2026-10-01",
                          order: 2, recorded: "2026-10-01T09:10:00+09:00"),
            try makeEvent("p", kind: .paused, status: .onHold, date: "2026-10-02",
                          order: 1, recorded: "2026-10-02T09:00:00+09:00"),
            try makeEvent("r", kind: .resumed, status: .inProgress, date: "2026-10-03",
                          order: 1, recorded: "2026-10-03T09:00:00+09:00")
        ]
        let result = StateReplay.replay(events, through: nil, knownAt: nil)
        XCTAssertEqual(result.taskStatus("t1"), .inProgress)
        XCTAssertEqual(result.appliedEventIds, ["c", "s", "p", "r"])
        XCTAssertTrue(result.violations.isEmpty, "\(result.violations)")
    }

    // MARK: - 8. TASK-T05 완료→재개→재완료

    func testCompletionReopenCompletionHasTwoCompletionDates() throws {
        let events = [
            try makeEvent("c", kind: .created, status: .planned, date: "2026-10-01",
                          order: 1, recorded: "2026-10-01T09:00:00+09:00"),
            try makeEvent("done1", kind: .completed, status: .completed, date: "2026-10-02",
                          order: 1, recorded: "2026-10-02T09:00:00+09:00"),
            try makeEvent("reopen", kind: .reopened, status: .inProgress, date: "2026-10-03",
                          order: 1, recorded: "2026-10-03T09:00:00+09:00"),
            try makeEvent("done2", kind: .completed, status: .completed, date: "2026-10-04",
                          order: 1, recorded: "2026-10-04T09:00:00+09:00")
        ]
        let result = StateReplay.replay(events, through: nil, knownAt: nil)
        XCTAssertEqual(result.taskStatus("t1"), .completed)
        XCTAssertEqual(StateReplay.completionDates(taskId: "t1", events, knownAt: nil),
                       [try workDate("2026-10-02"), try workDate("2026-10-04")])
    }

    // MARK: - 9. 불가능한 전이

    func testImpossibleTransitionIsReportedNotThrown() throws {
        let events = [
            try makeEvent("c", kind: .created, status: .planned, date: "2026-10-01",
                          order: 1, recorded: "2026-10-01T09:00:00+09:00"),
            try makeEvent("done", kind: .completed, status: .completed, date: "2026-10-02",
                          order: 1, recorded: "2026-10-02T09:00:00+09:00"),
            try makeEvent("p", kind: .paused, status: .onHold, date: "2026-10-03",
                          order: 1, recorded: "2026-10-03T09:00:00+09:00")
        ]
        let result = StateReplay.replay(events, through: nil, knownAt: nil)
        XCTAssertEqual(result.taskStatus("t1"), .completed)
        XCTAssertEqual(result.violations.count, 1)
        XCTAssertEqual(result.violations.first?.eventId, "p")
        XCTAssertEqual(result.violations.first?.from, .completed)
        XCTAssertEqual(result.violations.first?.kind, .paused)
        XCTAssertFalse(result.appliedEventIds.contains("p"))
    }

    // MARK: - 10. voided 정정

    func testVoidedCorrectionAppliesOnlyAfterKnownAt() throws {
        let events = [
            try makeEvent("c", kind: .created, status: .planned, date: "2026-10-01",
                          order: 1, recorded: "2026-10-01T09:00:00+09:00"),
            try makeEvent("wrong", kind: .completed, status: .completed, date: "2026-10-02",
                          order: 1, recorded: "2026-10-02T09:00:00+09:00"),
            try makeEvent("void", kind: .voided, date: "2026-10-03", order: 2,
                          recorded: "2026-10-03T10:00:00+09:00", supersedes: "wrong")
        ]

        // 정정 이후 시점: 잘못된 완료가 제거되어 planned.
        let after = StateReplay.replay(events, through: nil,
                                       knownAt: try date("2026-10-03T12:00:00+09:00"))
        XCTAssertEqual(after.taskStatus("t1"), .planned)
        XCTAssertFalse(after.appliedEventIds.contains("wrong"))

        // 정정 이전 시점: 잘못된 완료가 남아 completed.
        let before = StateReplay.replay(events, through: nil,
                                        knownAt: try date("2026-10-02T23:00:00+09:00"))
        XCTAssertEqual(before.taskStatus("t1"), .completed)
    }

    // MARK: - 11. PROJ-T04 자동 전체 완료 없음

    func testAllProjectsCompletedDoesNotCompleteTask() throws {
        let taskId = "t1"
        var events: [DomainEvent] = [
            try makeEvent("c", kind: .created, status: .planned, date: "2026-10-01",
                          order: 1, recorded: "2026-10-01T09:00:00+09:00", taskId: taskId),
            try makeEvent("s", kind: .started, status: .inProgress, date: "2026-10-01",
                          order: 2, recorded: "2026-10-01T09:10:00+09:00", taskId: taskId)
        ]
        for (i, project) in ["pG", "pJ", "pK"].enumerated() {
            events.append(try makeEvent("done-\(project)", kind: .completed, status: .completed,
                                        date: "2026-10-02", order: i + 1,
                                        recorded: "2026-10-02T10:0\(i):00+09:00",
                                        scope: .taskProject, scopeId: "\(taskId)/\(project)",
                                        taskId: taskId))
        }

        let result = StateReplay.replay(events, through: nil, knownAt: nil)
        XCTAssertEqual(result.projectStatus(taskId: taskId, projectId: "pG"), .completed)
        XCTAssertEqual(result.projectStatus(taskId: taskId, projectId: "pJ"), .completed)
        XCTAssertEqual(result.projectStatus(taskId: taskId, projectId: "pK"), .completed)
        XCTAssertEqual(result.taskStatus(taskId), .inProgress)
    }

    // MARK: - 12. TASK-T07 체크리스트

    func testChecklistCompletionDoesNotChangeTaskAndCanReopen() throws {
        let events = [
            try makeEvent("c", kind: .created, status: .planned, date: "2026-10-01",
                          order: 1, recorded: "2026-10-01T09:00:00+09:00"),
            try makeEvent("s", kind: .started, status: .inProgress, date: "2026-10-01",
                          order: 2, recorded: "2026-10-01T09:10:00+09:00"),
            try makeEvent("cl-done", kind: .completed, status: .completed, date: "2026-10-02",
                          order: 1, recorded: "2026-10-02T09:00:00+09:00",
                          scope: .checklistItem, scopeId: "checklist-docs"),
            try makeEvent("cl-reopen", kind: .reopened, status: .planned, date: "2026-10-03",
                          order: 1, recorded: "2026-10-03T09:00:00+09:00",
                          scope: .checklistItem, scopeId: "checklist-docs")
        ]
        let result = StateReplay.replay(events, through: nil, knownAt: nil)
        XCTAssertEqual(result.checklistStatus("checklist-docs"), .planned)
        XCTAssertEqual(result.taskStatus("t1"), .inProgress)
        XCTAssertTrue(result.violations.isEmpty, "\(result.violations)")
    }

    // MARK: - 13. validateInsertion

    func testValidateInsertionRejectsStartedAfterCompletion() throws {
        let existing = [
            try makeEvent("c", kind: .created, status: .planned, date: "2026-10-01",
                          order: 1, recorded: "2026-10-01T09:00:00+09:00"),
            try makeEvent("done", kind: .completed, status: .completed, date: "2026-10-02",
                          order: 1, recorded: "2026-10-02T09:00:00+09:00")
        ]

        let lateStart = try makeEvent("late", kind: .started, status: .inProgress,
                                      date: "2026-10-03", order: 1,
                                      recorded: "2026-10-03T09:00:00+09:00")
        let violations = StateReplay.validateInsertion(lateStart, into: existing)
        XCTAssertEqual(violations.count, 1)
        XCTAssertEqual(violations.first?.eventId, "late")

        let allowedReopen = try makeEvent("reopen", kind: .reopened, status: .inProgress,
                                          date: "2026-10-03", order: 1,
                                          recorded: "2026-10-03T09:00:00+09:00")
        XCTAssertTrue(StateReplay.validateInsertion(allowedReopen, into: existing).isEmpty)
    }

    // MARK: - 14. TIME-T04 같은 날 effectiveOrder

    func testSameDayEffectiveOrderDecidesSequence() throws {
        let events = [
            try makeEvent("c", kind: .created, status: .planned, date: "2026-10-05",
                          order: 1, recorded: "2026-10-05T09:00:00+09:00"),
            try makeEvent("s", kind: .started, status: .inProgress, date: "2026-10-05",
                          order: 2, recorded: "2026-10-05T09:01:00+09:00"),
            try makeEvent("done", kind: .completed, status: .completed, date: "2026-10-05",
                          order: 3, recorded: "2026-10-05T09:02:00+09:00")
        ]
        let result = StateReplay.replay(events, through: nil, knownAt: nil)
        XCTAssertEqual(result.taskStatus("t1"), .completed)
        XCTAssertEqual(result.appliedEventIds, ["c", "s", "done"])
    }
}
