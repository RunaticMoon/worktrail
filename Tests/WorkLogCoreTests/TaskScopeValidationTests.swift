import XCTest
@testable import WorkLogCore

/// Progress and checklist records must stay inside their own task (stale selections after switching tasks).
final class TaskScopeValidationTests: XCTestCase {
    private func setup() throws -> (WorkRepository, TaskService) {
        let repo = try WorkRepository.inMemory(clock: FixedClock(Date(timeIntervalSince1970: 1_792_972_800)),
                                               ids: SequentialIDGenerator(prefix: "scope"))
        return (repo, TaskService(repo: repo))
    }

    func testActivityRejectsProjectsAndChecklistItemsOfAnotherTask() throws {
        let (repo, tasks) = try setup()
        let t1 = try tasks.createTask(title: "업무 1", projectNames: ["가"])
        let t2 = try tasks.createTask(title: "업무 2", projectNames: ["나"])
        let p1 = try XCTUnwrap(repo.taskProjects(taskId: t1.id).first?.projectId)
        let p2 = try XCTUnwrap(repo.taskProjects(taskId: t2.id).first?.projectId)
        let c1 = try tasks.addChecklistItem(taskId: t1.id, text: "항목 1")
        let c2 = try tasks.addChecklistItem(taskId: t2.id, text: "항목 2")

        XCTAssertThrowsError(try tasks.addActivity(taskId: t1.id, body: "x", projectIds: [p2]))
        XCTAssertThrowsError(try tasks.addActivity(taskId: t1.id, body: "x", checklistItemIds: [c2.id]))
        XCTAssertTrue(try repo.activities(taskId: t1.id).isEmpty)

        let ok = try tasks.addActivity(taskId: t1.id, body: "정상", projectIds: [p1], checklistItemIds: [c1.id])
        XCTAssertEqual(try repo.activity(id: ok.id)?.projectIds, [p1])
        _ = try tasks.addActivity(taskId: t1.id, body: "공통")
    }

    func testDeletedChecklistItemOrTaskCannotBeChecked() throws {
        let (repo, tasks) = try setup()
        let task = try tasks.createTask(title: "업무")
        let item = try tasks.addChecklistItem(taskId: task.id, text: "삭제할 항목")
        try repo.softDeleteChecklistItem(id: item.id)
        let before = try repo.events(taskId: task.id).count
        XCTAssertThrowsError(try tasks.setChecklistItem(itemId: item.id, done: true)) { error in
            guard case WorkLogError.notFound = error else { return XCTFail("\(error)") }
        }

        let live = try tasks.addChecklistItem(taskId: task.id, text: "남은 항목")
        try repo.db.runV("UPDATE task SET deleted_at = ? WHERE id = ?", repo.clock.now(), task.id)
        XCTAssertThrowsError(try tasks.setChecklistItem(itemId: live.id, done: true))
        XCTAssertEqual(try repo.events(taskId: task.id).count, before)
    }
}
