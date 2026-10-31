import XCTest
@testable import WorkLogCore

final class TaskProjectIntervalRepositoryTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs = []
        super.tearDown()
    }

    private func makeRepo() throws -> WorkRepository {
        try WorkRepository.inMemory(clock: FixedClock(Date(timeIntervalSince1970: 1_790_000_000)),
                                   ids: SequentialIDGenerator())
    }

    private func day(_ iso: String) -> WorkDate {
        guard let date = WorkDate(iso) else { fatalError("invalid WorkDate fixture: \(iso)") }
        return date
    }

    private func makeTask(_ repo: WorkRepository) throws -> (WorkTask, Project) {
        let task = WorkTask(id: "task-1", title: "릴리스 준비",
                            createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        try repo.insertTask(task)
        let project = try repo.createProject(name: "P")
        return (task, project)
    }

    private func link(_ repo: WorkRepository, _ task: WorkTask, _ project: Project, _ iso: String) throws {
        try repo.linkProject(taskId: task.id, projectId: project.id,
                             trackingEnabled: true, linkedOn: day(iso))
    }

    private func unlink(_ repo: WorkRepository, _ task: WorkTask, _ project: Project, _ iso: String) throws {
        try repo.unlinkProject(taskId: task.id, projectId: project.id, removedOn: day(iso))
    }

    /// task_project.removed_on IS NULL ⇔ 열린 구간 정확히 1개.
    private func assertOpenSpanInvariant(_ repo: WorkRepository, taskId: String,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
        let activeRows = try repo.db.scalarIntV("""
            SELECT COUNT(*) FROM task_project WHERE task_id = ? AND removed_on IS NULL
            """, taskId)
        let openIntervals = try repo.db.scalarIntV("""
            SELECT COUNT(*) FROM task_project_interval i
            JOIN task_project tp ON tp.id = i.task_project_id
            WHERE tp.task_id = ? AND i.removed_on IS NULL
            """, taskId)
        XCTAssertEqual(activeRows, openIntervals, file: file, line: line)
        XCTAssertTrue(openIntervals == 0 || openIntervals == 1,
                      "open intervals: \(openIntervals)", file: file, line: line)
    }

    // MARK: 1 — 링크/해제 사이클의 구간 보존과 activeOn 멤버십

    func testIntervalsAndActiveMembershipAcrossRelinkCycle() throws {
        let repo = try makeRepo()
        let (task, project) = try makeTask(repo)
        try link(repo, task, project, "2026-10-22")
        try unlink(repo, task, project, "2026-10-23")
        try link(repo, task, project, "2026-10-26")
        try unlink(repo, task, project, "2026-10-28")

        let linkId = try XCTUnwrap(try repo.taskProjects(taskId: task.id, includeRemoved: true).first).id
        let intervals = try repo.taskProjectIntervals(taskProjectId: linkId)
        XCTAssertEqual(intervals.count, 2)
        XCTAssertEqual(intervals.map(\.taskProjectId), [linkId, linkId])
        XCTAssertEqual(intervals.map(\.linkedOn), [day("2026-10-22"), day("2026-10-26")])
        XCTAssertEqual(intervals.map(\.removedOn), [day("2026-10-23"), day("2026-10-28")])
        XCTAssertEqual(try repo.taskProjectIntervals(taskProjectId: linkId), intervals)

        for iso in ["2026-10-22", "2026-10-26", "2026-10-27"] {
            XCTAssertEqual(try repo.taskProjects(taskId: task.id, activeOn: day(iso)).map(\.id), [linkId],
                           "expected active on \(iso)")
        }
        for iso in ["2026-10-21", "2026-10-23", "2026-10-24", "2026-10-25", "2026-10-28", "2026-10-29"] {
            XCTAssertTrue(try repo.taskProjects(taskId: task.id, activeOn: day(iso)).isEmpty,
                          "expected inactive on \(iso)")
        }

        // 10-29 이후 재연결: 열린 구간 하나가 추가된다.
        try link(repo, task, project, "2026-10-30")
        let reopened = try repo.taskProjectIntervals(taskProjectId: linkId)
        XCTAssertEqual(reopened.count, 3)
        XCTAssertEqual(reopened.last?.linkedOn, day("2026-10-30"))
        XCTAssertNil(reopened.last?.removedOn)
        XCTAssertEqual(try repo.taskProjects(taskId: task.id, activeOn: day("2026-10-30")).map(\.id), [linkId])
        XCTAssertEqual(try repo.taskProjects(taskId: task.id, activeOn: day("2026-10-31")).map(\.id), [linkId])
        XCTAssertTrue(try repo.taskProjects(taskId: task.id, activeOn: day("2026-10-29")).isEmpty)
        try assertOpenSpanInvariant(repo, taskId: task.id)
    }

    // MARK: 2 — 같은 날 해제·재연결은 구간을 다시 열고, 같은 날 연결·해제는 멤버십이 없다

    func testSameDayUnlinkAndRelinkReopensTheInterval() throws {
        let repo = try makeRepo()
        let (task, project) = try makeTask(repo)
        try link(repo, task, project, "2026-10-22")
        try unlink(repo, task, project, "2026-10-23")
        try link(repo, task, project, "2026-10-23")

        let linkId = try XCTUnwrap(try repo.taskProjects(taskId: task.id, includeRemoved: true).first).id
        let intervals = try repo.taskProjectIntervals(taskProjectId: linkId)
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals.first?.linkedOn, day("2026-10-22"))
        XCTAssertNil(intervals.first?.removedOn)
        XCTAssertEqual(try repo.taskProjects(taskId: task.id, activeOn: day("2026-10-22")).map(\.id), [linkId])
        XCTAssertEqual(try repo.taskProjects(taskId: task.id, activeOn: day("2026-10-23")).map(\.id), [linkId])
        try assertOpenSpanInvariant(repo, taskId: task.id)
    }

    func testLinkAndUnlinkOnSameDayProduceNoMembership() throws {
        let repo = try makeRepo()
        let (task, project) = try makeTask(repo)
        try link(repo, task, project, "2026-10-24")
        try unlink(repo, task, project, "2026-10-24")

        let linkId = try XCTUnwrap(try repo.taskProjects(taskId: task.id, includeRemoved: true).first).id
        let intervals = try repo.taskProjectIntervals(taskProjectId: linkId)
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals.first?.linkedOn, day("2026-10-24"))
        XCTAssertEqual(intervals.first?.removedOn, day("2026-10-24"))
        XCTAssertTrue(try repo.taskProjects(taskId: task.id, activeOn: day("2026-10-24")).isEmpty)
        try assertOpenSpanInvariant(repo, taskId: task.id)
    }

    // MARK: 3 — 각 단계마다 활성 행과 열린 구간의 불변식

    func testOpenIntervalAndActiveRowStayInSyncThroughout() throws {
        let repo = try makeRepo()
        let (task, project) = try makeTask(repo)
        try assertOpenSpanInvariant(repo, taskId: task.id)

        try link(repo, task, project, "2026-10-22")
        try assertOpenSpanInvariant(repo, taskId: task.id)
        try unlink(repo, task, project, "2026-10-23")
        try assertOpenSpanInvariant(repo, taskId: task.id)
        try link(repo, task, project, "2026-10-26")
        try assertOpenSpanInvariant(repo, taskId: task.id)
        try link(repo, task, project, "2026-10-26") // 이미 활성: 변화 없음
        try assertOpenSpanInvariant(repo, taskId: task.id)
        try unlink(repo, task, project, "2026-10-28")
        try assertOpenSpanInvariant(repo, taskId: task.id)
        try link(repo, task, project, "2026-10-28") // 해제 당일 재연결: 기존 구간 재사용
        try assertOpenSpanInvariant(repo, taskId: task.id)
        XCTAssertEqual(try repo.taskProjectIntervals(
            taskProjectId: try XCTUnwrap(try repo.taskProjects(taskId: task.id).first).id).count, 2)
    }

    // MARK: 4 — 부분 유니크 인덱스는 열린 구간 2개를 막는다

    func testPartialUniqueIndexRejectsSecondOpenInterval() throws {
        let repo = try makeRepo()
        let (task, project) = try makeTask(repo)
        try link(repo, task, project, "2026-10-22")
        let linkId = try XCTUnwrap(try repo.taskProjects(taskId: task.id).first).id

        XCTAssertThrowsError(try repo.db.runV("""
            INSERT INTO task_project_interval (id, task_project_id, linked_on, removed_on)
            VALUES (?, ?, ?, NULL)
            """, "dup-open", linkId, day("2026-10-23"))) { error in
            guard let sqlite = error as? SQLiteError else { return XCTFail("unexpected error: \(error)") }
            XCTAssertEqual(sqlite.code, 19) // SQLITE_CONSTRAINT
        }
        // 기존 구간을 닫으면 새 열린 구간을 넣을 수 있다(부분 인덱스의 의도된 동작).
        try repo.db.runV("""
            UPDATE task_project_interval SET removed_on = ? WHERE task_project_id = ? AND removed_on IS NULL
            """, day("2026-10-23"), linkId)
        XCTAssertNoThrow(try repo.db.runV("""
            INSERT INTO task_project_interval (id, task_project_id, linked_on, removed_on)
            VALUES (?, ?, ?, NULL)
            """, "second-open", linkId, day("2026-10-24")))
        XCTAssertEqual(try repo.taskProjectIntervals(taskProjectId: linkId).count, 2)
    }

    // MARK: 5 — v13 backfill은 저장된 구간만 복사한다

    func testV13BackfillCopiesOnlyStoredSpans() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try Migrator.migrate(db, migrations: WorkSchema.migrations.filter { $0.version <= 12 })
        XCTAssertEqual(db.userVersion, 12)
        try db.runV("INSERT INTO task (id, title, created_at) VALUES (?, ?, ?)",
                    "task-old", "기존 업무", "2026-09-30T00:00:00.000Z")
        try db.runV("INSERT INTO project (id, name) VALUES (?, ?)", "proj-a", "기존 프로젝트 A")
        try db.runV("INSERT INTO project (id, name) VALUES (?, ?)", "proj-b", "기존 프로젝트 B")
        try db.runV("""
            INSERT INTO task_project (id, task_id, project_id, tracking_enabled, linked_on, removed_on)
            VALUES (?, ?, ?, 1, ?, NULL)
            """, "tp-active", "task-old", "proj-a", day("2026-10-01"))
        try db.runV("""
            INSERT INTO task_project (id, task_id, project_id, tracking_enabled, linked_on, removed_on)
            VALUES (?, ?, ?, 1, ?, ?)
            """, "tp-removed", "task-old", "proj-b", day("2026-10-02"), day("2026-10-05"))

        try Migrator.migrate(db, migrations: WorkSchema.migrations)
        XCTAssertEqual(db.userVersion, 13)

        let rows = try db.queryV("SELECT * FROM task_project_interval ORDER BY id ASC")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map { $0.string("id") }, ["tp-active:v13", "tp-removed:v13"])

        let active = try XCTUnwrap(rows.first { $0.string("id") == "tp-active:v13" })
        XCTAssertEqual(active.string("task_project_id"), "tp-active")
        XCTAssertEqual(active.workDate("linked_on"), day("2026-10-01"))
        XCTAssertNil(active.workDate("removed_on"))

        let removed = try XCTUnwrap(rows.first { $0.string("id") == "tp-removed:v13" })
        XCTAssertEqual(removed.string("task_project_id"), "tp-removed")
        XCTAssertEqual(removed.workDate("linked_on"), day("2026-10-02"))
        XCTAssertEqual(removed.workDate("removed_on"), day("2026-10-05"))

        // 재실행해도 backfill이 중복되지 않는다.
        try Migrator.migrate(db, migrations: WorkSchema.migrations)
        XCTAssertEqual(try db.scalarIntV("SELECT COUNT(*) FROM task_project_interval"), 2)
        XCTAssertTrue(try db.integrityCheck())
    }

    // MARK: 6 — 파일 DB를 닫았다 다시 열어도 구간과 activeOn 결과가 같다

    func testFileBackedReopenPreservesIntervals() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gh55-interval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        let path = dir.appendingPathComponent("work.sqlite").path
        let dates = ["2026-10-22", "2026-10-23", "2026-10-26", "2026-10-27"]

        let db = try SQLiteDatabase(path: path)
        let repo = try WorkRepository(db: db, clock: FixedClock(Date(timeIntervalSince1970: 1_790_000_000)),
                                      ids: SequentialIDGenerator())
        let (task, project) = try makeTask(repo)
        try link(repo, task, project, "2026-10-22")
        try unlink(repo, task, project, "2026-10-23")
        try link(repo, task, project, "2026-10-26")

        let linkId = try XCTUnwrap(try repo.taskProjects(taskId: task.id, includeRemoved: true).first).id
        let intervalsBefore = try repo.taskProjectIntervals(taskProjectId: linkId)
        let activeBefore = try dates.map { try repo.taskProjects(taskId: task.id, activeOn: day($0)).map(\.id) }
        XCTAssertEqual(intervalsBefore.count, 2)
        db.close()

        let reopenedDB = try SQLiteDatabase(path: path)
        defer { reopenedDB.close() }
        let reopened = try WorkRepository(db: reopenedDB,
                                          clock: FixedClock(Date(timeIntervalSince1970: 1_790_000_000)),
                                          ids: SequentialIDGenerator())
        XCTAssertEqual(try reopened.taskProjectIntervals(taskProjectId: linkId), intervalsBefore)
        let activeAfter = try dates.map {
            try reopened.taskProjects(taskId: task.id, activeOn: day($0)).map(\.id)
        }
        XCTAssertEqual(activeAfter, activeBefore)
        XCTAssertEqual(activeAfter, [[linkId], [], [linkId], [linkId]])
    }

    // MARK: 7 — 실패한 구간 기록은 task_project 변경까지 롤백한다

    func testFailedIntervalInsertRollsBackLink() throws {
        let repo = try makeRepo()
        let (task, existingProject) = try makeTask(repo)
        let newProject = try repo.createProject(name: "Q")
        try link(repo, task, existingProject, "2026-10-20")
        let linkId = try XCTUnwrap(try repo.taskProjects(taskId: task.id).first).id
        let intervalsBefore = try repo.taskProjectIntervals(taskProjectId: linkId)

        try repo.db.execute("""
            CREATE TRIGGER gh55_block_interval BEFORE INSERT ON task_project_interval
            BEGIN SELECT RAISE(ABORT, 'blocked'); END;
            """)
        XCTAssertThrowsError(try link(repo, task, newProject, "2026-10-22"))
        XCTAssertEqual(try repo.db.scalarIntV("SELECT COUNT(*) FROM task_project WHERE task_id = ?", task.id), 1)
        XCTAssertEqual(try repo.taskProjectIntervals(taskProjectId: linkId), intervalsBefore)
        XCTAssertEqual(try repo.taskProjects(taskId: task.id).map(\.projectId), [existingProject.id])

        try repo.db.execute("DROP TRIGGER gh55_block_interval")
        XCTAssertNoThrow(try link(repo, task, newProject, "2026-10-22"))
        XCTAssertEqual(try repo.taskProjects(taskId: task.id).map(\.projectId),
                       [existingProject.id, newProject.id])
    }

    func testOuterRollbackRevertsReactivationAndInterval() throws {
        let repo = try makeRepo()
        let (task, project) = try makeTask(repo)
        try link(repo, task, project, "2026-10-22")
        try unlink(repo, task, project, "2026-10-23")
        let linkId = try XCTUnwrap(try repo.taskProjects(taskId: task.id, includeRemoved: true).first).id
        let intervalsBefore = try repo.taskProjectIntervals(taskProjectId: linkId)

        XCTAssertThrowsError(try repo.db.transaction {
            try link(repo, task, project, "2026-10-24")
            throw WorkLogError.validation("forced rollback")
        })
        XCTAssertEqual(try repo.taskProjectIntervals(taskProjectId: linkId), intervalsBefore)
        let row = try XCTUnwrap(try repo.taskProjects(taskId: task.id, includeRemoved: true).first)
        XCTAssertEqual(row.removedOn, day("2026-10-23"))
        XCTAssertEqual(row.linkedOn, day("2026-10-22"))
    }

    // MARK: 8 — 과거 날짜 재연결은 기록된 구간을 고쳐 쓰지 않는다

    /// 구간 [10-01, 10-10)과 [10-15, 10-20)을 만들고 그 사이(10-10..10-14)가 미연결임을 확인한다.
    private func makeBackdatedSpans(_ repo: WorkRepository, _ task: WorkTask,
                                    _ project: Project) throws -> String {
        try link(repo, task, project, "2026-10-01")
        try unlink(repo, task, project, "2026-10-10")
        try link(repo, task, project, "2026-10-15")
        try unlink(repo, task, project, "2026-10-20")
        let linkId = try XCTUnwrap(try repo.taskProjects(taskId: task.id, includeRemoved: true).first).id
        XCTAssertEqual(try repo.taskProjectIntervals(taskProjectId: linkId).count, 2)
        return linkId
    }

    /// 어떤 두 구간도 겹치지 않는다: [linkedOn, removedOn ?? +∞).
    private func assertNoOverlappingSpans(_ spans: [TaskProjectInterval],
                                          file: StaticString = #filePath, line: UInt = #line) {
        let far = WorkDate(year: 9999, month: 12, day: 31)
        for (index, first) in spans.enumerated() {
            for second in spans[(index + 1)...] {
                let firstEnd = first.removedOn ?? far
                let secondEnd = second.removedOn ?? far
                XCTAssertFalse(first.linkedOn < secondEnd && second.linkedOn < firstEnd,
                               "겹치는 구간: \(first) / \(second)", file: file, line: line)
            }
        }
    }

    func testBackdatedRelinkKeepsRecordedSpansAndGap() throws {
        let repo = try makeRepo()
        let (task, project) = try makeTask(repo)
        let linkId = try makeBackdatedSpans(repo, task, project)

        _ = try TaskService(repo: repo).linkProjects(taskId: task.id, projectNames: [project.name],
                                                 trackingEnabled: true, workDate: day("2026-10-05"))

        let intervals = try repo.taskProjectIntervals(taskProjectId: linkId)
        XCTAssertEqual(intervals.count, 2)
        XCTAssertEqual(intervals.map(\.linkedOn), [day("2026-10-01"), day("2026-10-15")])
        XCTAssertEqual(intervals.map(\.removedOn), [day("2026-10-10"), nil])
        assertNoOverlappingSpans(intervals)

        // 미연결 기간(10-10..10-14)은 그대로 남는다.
        XCTAssertTrue(try repo.taskProjects(taskId: task.id, activeOn: day("2026-10-12")).isEmpty)
        for iso in ["2026-10-16", "2026-10-25"] {
            XCTAssertEqual(try repo.taskProjects(taskId: task.id, activeOn: day(iso)).map(\.id), [linkId],
                           "expected active on \(iso)")
        }
        try assertOpenSpanInvariant(repo, taskId: task.id)
    }

    func testBackdatedRelinkOnLastRemovalDateReopensLastSpan() throws {
        let repo = try makeRepo()
        let (task, project) = try makeTask(repo)
        let linkId = try makeBackdatedSpans(repo, task, project)

        _ = try TaskService(repo: repo).linkProjects(taskId: task.id, projectNames: [project.name],
                                                 trackingEnabled: true, workDate: day("2026-10-20"))

        let intervals = try repo.taskProjectIntervals(taskProjectId: linkId)
        XCTAssertEqual(intervals.count, 2)
        XCTAssertEqual(intervals.map(\.linkedOn), [day("2026-10-01"), day("2026-10-15")])
        XCTAssertEqual(intervals.map(\.removedOn), [day("2026-10-10"), nil])
        XCTAssertEqual(try repo.taskProjects(taskId: task.id, activeOn: day("2026-10-20")).map(\.id), [linkId])
        XCTAssertTrue(try repo.taskProjects(taskId: task.id, activeOn: day("2026-10-14")).isEmpty)
        assertNoOverlappingSpans(intervals)
        try assertOpenSpanInvariant(repo, taskId: task.id)
    }

    func testBackdatedRelinkAfterLastRemovalInsertsNewSpan() throws {
        let repo = try makeRepo()
        let (task, project) = try makeTask(repo)
        let linkId = try makeBackdatedSpans(repo, task, project)

        _ = try TaskService(repo: repo).linkProjects(taskId: task.id, projectNames: [project.name],
                                                 trackingEnabled: true, workDate: day("2026-10-22"))

        let intervals = try repo.taskProjectIntervals(taskProjectId: linkId)
        XCTAssertEqual(intervals.count, 3)
        XCTAssertEqual(intervals.map(\.linkedOn), [day("2026-10-01"), day("2026-10-15"), day("2026-10-22")])
        XCTAssertEqual(intervals.map(\.removedOn), [day("2026-10-10"), day("2026-10-20"), nil])
        XCTAssertEqual(try repo.taskProjects(taskId: task.id, activeOn: day("2026-10-22")).map(\.id), [linkId])
        XCTAssertTrue(try repo.taskProjects(taskId: task.id, activeOn: day("2026-10-21")).isEmpty)
        assertNoOverlappingSpans(intervals)
        try assertOpenSpanInvariant(repo, taskId: task.id)
    }

    func testIntervalIsActiveAgreesWithActiveOnQuery() throws {
        let repo = try makeRepo()
        let (task, project) = try makeTask(repo)
        let linkId = try makeBackdatedSpans(repo, task, project)

        _ = try TaskService(repo: repo).linkProjects(taskId: task.id, projectNames: [project.name],
                                                 trackingEnabled: true, workDate: day("2026-10-05"))

        let intervals = try repo.taskProjectIntervals(taskProjectId: linkId)
        let calendar = WorkCalendar()
        var date = day("2026-10-01")
        while date <= day("2026-10-31") {
            let expected = intervals.contains { $0.isActive(on: date) }
            let actual = try repo.taskProjects(taskId: task.id, activeOn: date).map(\.id) == [linkId]
            XCTAssertEqual(actual, expected, "isActive 불일치: \(date.iso)")
            date = calendar.adding(days: 1, to: date)
        }
    }
}
