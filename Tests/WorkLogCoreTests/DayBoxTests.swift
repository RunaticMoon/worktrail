import XCTest
@testable import WorkLogCore

final class DayBoxTests: XCTestCase {

    private let calendar = WorkCalendar()
    private let monday = WorkDate("2026-09-28")!
    private let tuesday = WorkDate("2026-09-29")!
    private let wednesday = WorkDate("2026-09-30")!
    private let thursday = WorkDate("2026-10-01")!
    private let friday = WorkDate("2026-10-02")!

    private func instant(_ date: WorkDate, hour: Int = 9) -> Date {
        calendar.startOfDay(date).addingTimeInterval(TimeInterval(hour * 3600))
    }

    private func makeRepo(now: Date) throws -> (WorkRepository, TaskService, FixedClock) {
        let clock = FixedClock(now)
        let repo = try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator())
        return (repo, TaskService(repo: repo), clock)
    }

    // MARK: 1. 하루에 Memo·생성·시작·활동·완료

    func testSingleDayTimelineAndTaskRow() throws {
        let (repo, service, clock) = try makeRepo(now: instant(tuesday))
        _ = try service.captureMemo(body: "메모 본문", workDate: tuesday)
        clock.advance(by: 60)
        let task = try service.createTask(title: "작업 A", workDate: tuesday)
        clock.advance(by: 60)
        try service.changeTaskStatus(taskId: task.id, kind: .started, workDate: tuesday)
        clock.advance(by: 60)
        _ = try service.addActivity(taskId: task.id, body: "진행 기록", workDate: tuesday)
        clock.advance(by: 60)
        _ = try service.completeTask(taskId: task.id, workDate: tuesday, confirmRemaining: true)

        let box = try DayBoxService(repo: repo).dayBox(for: tuesday)

        XCTAssertEqual(box.timeline.map(\.kind),
                       [.memo, .taskCreated, .taskStatus, .activity, .taskStatus])
        XCTAssertEqual(box.timeline.count, 5)
        // 같은 날 시작·완료 두 항목 모두 남는다.
        XCTAssertEqual(box.timeline.filter { $0.kind == .taskStatus }.count, 2)

        XCTAssertEqual(box.tasks.count, 1)
        let row = try XCTUnwrap(box.tasks.first)
        XCTAssertEqual(row.taskId, task.id)
        XCTAssertTrue(row.startedOnDay)
        XCTAssertTrue(row.completedOnDay)
        XCTAssertTrue(row.hasActivityOnDay)
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(box.memos.count, 1)
    }

    // MARK: 2. 진행 중이지만 그날 활동 없는 Task → Task O, 타임라인 X

    func testInProgressTaskWithoutDayActivityAppearsOnlyInTaskColumn() throws {
        let (repo, service, clock) = try makeRepo(now: instant(tuesday))
        let task = try service.createTask(title: "진행 작업", workDate: monday)
        clock.advance(by: 60)
        try service.changeTaskStatus(taskId: task.id, kind: .started, workDate: monday)

        let box = try DayBoxService(repo: repo).dayBox(for: tuesday)

        XCTAssertEqual(box.tasks.map(\.taskId), [task.id])
        XCTAssertEqual(box.tasks.first?.status, .inProgress)
        XCTAssertFalse(box.tasks.first?.hasActivityOnDay ?? true)
        XCTAssertTrue(box.timeline.isEmpty)
    }

    // MARK: 3. 과거 날짜: 월요일 시작, 수요일 완료

    func testPastDayStatusSnapshotAcrossDays() throws {
        let (repo, service, clock) = try makeRepo(now: instant(thursday))
        let task = try service.createTask(title: "월요일 작업", workDate: monday)
        clock.advance(by: 60)
        try service.changeTaskStatus(taskId: task.id, kind: .started, workDate: monday)
        clock.advance(by: 60)
        _ = try service.completeTask(taskId: task.id, workDate: wednesday, confirmRemaining: true)

        let dayBox = DayBoxService(repo: repo)
        XCTAssertEqual(try dayBox.dayBox(for: tuesday).tasks.first?.status, .inProgress)
        XCTAssertEqual(try dayBox.dayBox(for: wednesday).tasks.first?.status, .completed)
        XCTAssertTrue(try dayBox.dayBox(for: thursday).tasks.isEmpty)
    }

    // MARK: 4. 늦은 입력: 목요일에 화요일 workDate로 활동 추가

    func testLateActivityBelongsToItsWorkDateNotRecordDay() throws {
        let (repo, service, clock) = try makeRepo(now: instant(monday))
        let task = try service.createTask(title: "작업", workDate: monday)

        clock.set(instant(thursday))
        _ = try service.addActivity(taskId: task.id, body: "늦게 입력한 화요일 기록", workDate: tuesday)

        let dayBox = DayBoxService(repo: repo)
        let tuesdayBox = try dayBox.dayBox(for: tuesday)
        XCTAssertTrue(tuesdayBox.timeline.contains { $0.kind == .activity && $0.detail == "늦게 입력한 화요일 기록" })

        let thursdayBox = try dayBox.dayBox(for: thursday)
        XCTAssertFalse(thursdayBox.timeline.contains { $0.kind == .activity })
    }

    // MARK: 5. knownAt: 기록 시점 이후 항목 제외

    func testKnownAtExcludesLaterRecords() throws {
        let (repo, service, clock) = try makeRepo(now: instant(monday))
        let task = try service.createTask(title: "작업", workDate: monday)
        clock.advance(by: 60)
        try service.changeTaskStatus(taskId: task.id, kind: .started, workDate: monday)

        let cutoff = clock.now()

        clock.advance(by: 60)
        _ = try service.captureMemo(body: "cutoff 이후 메모", workDate: monday)
        clock.advance(by: 60)
        _ = try service.completeTask(taskId: task.id, workDate: monday, confirmRemaining: true)

        let box = try DayBoxService(repo: repo).dayBox(for: monday, knownAt: cutoff)

        XCTAssertEqual(box.timeline.map(\.kind), [.taskCreated, .taskStatus])
        XCTAssertTrue(box.memos.isEmpty)
        XCTAssertEqual(box.tasks.first?.status, .inProgress)
        XCTAssertFalse(box.tasks.first?.completedOnDay ?? true)
    }

    // MARK: 6. 보류·취소 필터

    func testHeldAndCancelledFilter() throws {
        let (repo, service, clock) = try makeRepo(now: instant(monday))
        let held = try service.createTask(title: "보류 작업", workDate: monday)
        clock.advance(by: 60)
        try service.changeTaskStatus(taskId: held.id, kind: .paused, workDate: monday)
        clock.advance(by: 60)
        let cancelled = try service.createTask(title: "취소 작업", workDate: monday)
        clock.advance(by: 60)
        try service.changeTaskStatus(taskId: cancelled.id, kind: .cancelled, workDate: monday)

        let dayBox = DayBoxService(repo: repo)
        XCTAssertTrue(try dayBox.dayBox(for: monday).tasks.isEmpty)

        let included = try dayBox.dayBox(for: monday, includeHeldAndCancelled: true)
        XCTAssertEqual(included.tasks.count, 2)
        XCTAssertEqual(Set(included.tasks.map(\.status)), [.onHold, .cancelled])
    }

    // MARK: 7. 프로젝트 적용 사건 → .projectStatus

    func testProjectStatusEventAppearsWithProjectId() throws {
        let (repo, service, clock) = try makeRepo(now: instant(monday))
        let task = try service.createTask(title: "공통 인프라", workDate: monday,
                                          projectNames: ["프로젝트 J"], trackingMode: .perProject)
        clock.advance(by: 60)
        let projectId = try XCTUnwrap(try repo.projects().first?.id)
        try service.changeProjectStatus(taskId: task.id, projectId: projectId, kind: .started,
                                        workDate: monday)

        let box = try DayBoxService(repo: repo).dayBox(for: monday)
        let entry = try XCTUnwrap(box.timeline.first { $0.kind == .projectStatus })
        XCTAssertEqual(entry.projectId, projectId)
        XCTAssertEqual(entry.taskId, task.id)
        XCTAssertEqual(entry.eventKind, .started)
        XCTAssertEqual(entry.toStatus, .inProgress)
    }

    // MARK: 8. effectiveTime 없는 항목은 nil

    func testEntriesWithoutEffectiveTimeHaveNil() throws {
        let (repo, service, clock) = try makeRepo(now: instant(tuesday))
        _ = try service.captureMemo(body: "메모", workDate: tuesday)
        clock.advance(by: 60)
        let task = try service.createTask(title: "작업", workDate: tuesday)
        clock.advance(by: 60)
        _ = try service.addActivity(taskId: task.id, body: "활동", workDate: tuesday)

        let box = try DayBoxService(repo: repo).dayBox(for: tuesday)
        XCTAssertFalse(box.timeline.isEmpty)
        XCTAssertTrue(box.timeline.allSatisfy { $0.effectiveTime == nil })
    }

    // MARK: 9. isToday / isPast

    func testTodayAndPastFlags() throws {
        let (repo, _, _) = try makeRepo(now: instant(thursday))
        let dayBox = DayBoxService(repo: repo)

        let today = try dayBox.dayBox(for: thursday)
        XCTAssertTrue(today.isToday)
        XCTAssertFalse(today.isPast)

        let past = try dayBox.dayBox(for: wednesday)
        XCTAssertFalse(past.isToday)
        XCTAssertTrue(past.isPast)

        let future = try dayBox.dayBox(for: friday)
        XCTAssertFalse(future.isToday)
        XCTAssertFalse(future.isPast)
    }

    // MARK: 10. 결정성

    func testRepeatedCallsAreIdentical() throws {
        let (repo, service, clock) = try makeRepo(now: instant(tuesday))
        _ = try service.captureMemo(body: "메모", workDate: tuesday)
        clock.advance(by: 60)
        let task = try service.createTask(title: "작업", workDate: tuesday)
        clock.advance(by: 60)
        try service.changeTaskStatus(taskId: task.id, kind: .started, workDate: tuesday)
        clock.advance(by: 60)
        _ = try service.addActivity(taskId: task.id, body: "활동", workDate: tuesday)

        let dayBox = DayBoxService(repo: repo)
        XCTAssertEqual(try dayBox.dayBox(for: tuesday), try dayBox.dayBox(for: tuesday))
    }
}
