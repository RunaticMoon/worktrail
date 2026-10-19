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
