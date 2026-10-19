import XCTest
@testable import WorkLogCore

/// 업무(Task) 원문 검색 색인이 체크리스트·프로젝트·태그 변경 뒤에도 최신인지 검증한다.
final class SearchTaskIndexTests: XCTestCase {

    private let monday = WorkDate("2026-10-05")!
    private let recordedAt = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeEnvironment() throws -> (WorkRepository, SearchIndex, TaskService) {
        let clock = FixedClock(recordedAt)
        let repo = try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator())
        let index = try SearchIndex(repo: repo)
        let service = TaskService(repo: repo)
        return (repo, index, service)
    }

    private func taskIds(_ index: SearchIndex, _ text: String) throws -> Set<String> {
        Set(try index.search(SearchQuery(text: text, types: [.task])).map(\.sourceId))
    }

    // MARK: 체크리스트 문구만으로 검색

    func testChecklistTextIsIndexedOnCreate() throws {
        let (_, index, service) = try makeEnvironment()
        let task = try service.createTask(title: "색인대상업무", workDate: monday,
                                          checklist: ["체크리스트고유문구"])
        XCTAssertEqual(try taskIds(index, "체크리스트고유문구"), [task.id])
    }

    // MARK: 프로젝트 이름만으로 검색

    func testProjectNameIsIndexedOnCreate() throws {
        let (_, index, service) = try makeEnvironment()
        let task = try service.createTask(title: "프로젝트색인업무", workDate: monday,
                                          projectNames: ["프로젝트고유이름"])
        XCTAssertEqual(try taskIds(index, "프로젝트고유이름"), [task.id])
    }

    // MARK: 체크리스트 수정·삭제 반영

    func testChecklistTextUpdateAndDeleteAreReindexed() throws {
        let (repo, index, service) = try makeEnvironment()
        let task = try service.createTask(title: "체크리스트변경업무", workDate: monday)
        let item = try service.addChecklistItem(taskId: task.id, text: "이전체크문구")
        XCTAssertEqual(try taskIds(index, "이전체크문구"), [task.id])

        try repo.updateChecklistText(id: item.id, text: "새로운체크문구")
        XCTAssertEqual(try taskIds(index, "새로운체크문구"), [task.id])
        XCTAssertTrue(try taskIds(index, "이전체크문구").isEmpty)

        try repo.softDeleteChecklistItem(id: item.id)
        XCTAssertTrue(try taskIds(index, "새로운체크문구").isEmpty)
    }

    // MARK: 프로젝트 연결 해제 반영

    func testUnlinkProjectRemovesProjectNameFromIndex() throws {
        let (repo, index, service) = try makeEnvironment()
        let task = try service.createTask(title: "연결해제업무", workDate: monday,
                                          projectNames: ["해제대상프로젝트"])
        XCTAssertEqual(try taskIds(index, "해제대상프로젝트"), [task.id])

        let project = try repo.findOrCreateProject(name: "해제대상프로젝트")
        try repo.unlinkProject(taskId: task.id, projectId: project.id, removedOn: monday)
        XCTAssertTrue(try taskIds(index, "해제대상프로젝트").isEmpty)
    }

    // MARK: 시작 시 오래된 문서만 복구

    /// 색인이 최신이면 repair는 0을 반환하고 DB에 쓰기가 일어나지 않는다.
    func testRepairStaleTaskDocsIsNoOpWhenUpToDate() throws {
        let (repo, index, service) = try makeEnvironment()
        let task = try service.createTask(title: "최신색인업무", workDate: monday,
                                          projectNames: ["최신색인프로젝트"],
                                          checklist: ["최신색인체크문구"])
        let before = try docRow(repo, taskId: task.id)
        let changesBefore = try repo.db.scalarInt("SELECT total_changes()")

        XCTAssertEqual(try index.repairStaleTaskDocs(), 0)

        XCTAssertEqual(try repo.db.scalarInt("SELECT total_changes()"), changesBefore,
                       "색인이 최신이면 repair가 DB에 쓰기를 하면 안 된다")
        let after = try docRow(repo, taskId: task.id)
        XCTAssertEqual(after?.text, before?.text)
        XCTAssertEqual(after?.workDate, before?.workDate)
    }

    /// 이전 버전처럼 제목만 색인된 문서를 repair가 체크리스트·프로젝트 문구까지 복구한다.
    func testRepairStaleTaskDocsRestoresTitleOnlyDoc() throws {
        let (repo, index, service) = try makeEnvironment()
        let task = try service.createTask(title: "복구대상업무", workDate: monday,
                                          projectNames: ["복구대상프로젝트"],
                                          checklist: ["복구대상체크문구"])
        try makeDocTitleOnly(repo, index: index, taskId: task.id, title: "복구대상업무")

        XCTAssertTrue(try taskIds(index, "복구대상체크문구").isEmpty)
        XCTAssertEqual(try index.repairStaleTaskDocs(), 1)

        XCTAssertEqual(try taskIds(index, "복구대상체크문구"), [task.id])
        XCTAssertEqual(try taskIds(index, "복구대상프로젝트"), [task.id])
        XCTAssertEqual(try taskIds(index, "복구대상업무"), [task.id])
        // 이미 최신이므로 다시 실행해도 쓰기가 없다.
        XCTAssertEqual(try index.repairStaleTaskDocs(), 0)
    }

    /// 삭제된 task의 남은 문서는 repair가 제거한다.
    func testRepairStaleTaskDocsRemovesDocOfDeletedTask() throws {
        let (repo, index, service) = try makeEnvironment()
        let task = try service.createTask(title: "삭제예정업무", workDate: monday)
        try repo.db.run("""
            UPDATE task SET deleted_at = ? WHERE id = ?
            """, [repo.clock.now(), task.id])

        XCTAssertEqual(try index.repairStaleTaskDocs(), 1)
        XCTAssertNil(try docRow(repo, taskId: task.id))
    }

    private func docRow(_ repo: WorkRepository, taskId: String) throws -> (text: String, workDate: WorkDate?)? {
        guard let row = try repo.db.queryOne("""
            SELECT text AS text, work_date AS work_date FROM search_doc
            WHERE source_type = 'task' AND source_id = ?
            """, [taskId]) else { return nil }
        return (row.string("text") ?? "", row.workDate("work_date"))
    }

    /// search_doc·search_fts를 제목만 있는 이전 버전 상태로 되돌린다.
    private func makeDocTitleOnly(_ repo: WorkRepository, index: SearchIndex, taskId: String, title: String) throws {
        let rowid = try repo.db.scalarInt("""
            SELECT rowid FROM search_doc WHERE source_type = 'task' AND source_id = ?
            """, [taskId])
        try repo.db.run("""
            UPDATE search_doc SET text = ? WHERE source_type = 'task' AND source_id = ?
            """, [title, taskId])
        if index.usesTrigram, rowid != 0 {
            try repo.db.run("UPDATE search_fts SET text = ? WHERE rowid = ?", [title, rowid])
        }
    }

    // MARK: rebuildAll 후에도 같은 결과

    func testRebuildAllKeepsTaskResultsConsistent() throws {
        let (_, index, service) = try makeEnvironment()
        let task = try service.createTask(title: "재색인업무", workDate: monday,
                                          projectNames: ["재색인프로젝트"],
                                          checklist: ["재색인체크문구"])
        try index.rebuildAll()

        XCTAssertEqual(try taskIds(index, "재색인프로젝트"), [task.id])
        XCTAssertEqual(try taskIds(index, "재색인체크문구"), [task.id])
        XCTAssertEqual(try taskIds(index, "재색인업무"), [task.id])
    }
}
