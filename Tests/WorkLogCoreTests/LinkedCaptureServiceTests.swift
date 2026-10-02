import XCTest
@testable import WorkLogCore

/// LinkedCaptureService: 일반 기록 생성 + 수동 링크 원자 저장.
///
/// - memo/task/activity 각각 생성 + 링크.
/// - related 비어 있음 → 원본만.
/// - 없는 대상 링크 → throw + 원본·FTS(search_doc) 롤백.
/// - 자기 참조·중복 대상 제거.
/// - 반환 RecordReference 정확성.
final class LinkedCaptureServiceTests: XCTestCase {

    private let monday = WorkDate("2026-10-05")!
    private let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeService() throws ->
        (service: LinkedCaptureService, repo: WorkRepository, tasks: TaskService, search: SearchIndex) {
        let clock = FixedClock(fixedNow)
        let repo = try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator())
        let search = try SearchIndex(repo: repo)
        let tasks = TaskService(repo: repo)
        return (LinkedCaptureService(repo: repo, tasks: tasks), repo, tasks, search)
    }

    /// search_doc에서 특정 source_type 행 수. FTS(search_fts)는 search_doc과 함께 유지된다.
    private func searchDocCount(_ repo: WorkRepository, _ search: SearchIndex,
                                type: String) throws -> Int {
        _ = search
        return try repo.db.scalarInt(
            "SELECT COUNT(*) FROM search_doc WHERE source_type = ?", [type])
    }

    private func taskRef(_ id: String) -> RecordReference { RecordReference(kind: .task, id: id) }
    private func memoRef(_ id: String) -> RecordReference { RecordReference(kind: .memo, id: id) }

    private func assertLinkConnects(_ repo: WorkRepository, _ a: RecordReference, _ b: RecordReference,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let links = try RecordLinkStore(repo: repo).allLinks()
        XCTAssertEqual(links.count, 1, file: file, line: line)
        guard let link = links.first else { return }
        let direct = link.first == a && link.second == b
        let reversed = link.first == b && link.second == a
        XCTAssertTrue(direct || reversed, "링크가 두 참조를 연결해야 한다: \(link)", file: file, line: line)
    }

    // MARK: - 1. 생성 + 링크

    func testCreateMemoWithRelatedStoresOriginalAndLink() throws {
        let (service, repo, tasks, search) = try makeService()
        let target = try tasks.createTask(title: "대상 업무", workDate: monday)

        let ref = try service.create(
            .memo(body: "메모 본문", workDate: monday, projectNames: [], tagNames: []),
            related: [taskRef(target.id)])

        XCTAssertEqual(ref, memoRef(ref.id))
        XCTAssertEqual(ref.kind, .memo)
        XCTAssertEqual(try repo.memo(id: ref.id)?.body, "메모 본문")
        try assertLinkConnects(repo, ref, taskRef(target.id))
        _ = search
    }

    func testCreateTaskWithNoteAndRelatedStoresOriginalAndLink() throws {
        let (service, repo, tasks, search) = try makeService()
        let target = try tasks.captureMemo(body: "대상 메모", workDate: monday)

        let ref = try service.create(
            .task(title: "새 업무", body: "본문 메모", initialStatus: .planned,
                  workDate: monday, effectiveTime: nil, dueOn: nil, projectNames: [],
                  trackingMode: .shared, tagNames: [], checklist: [], links: []),
            related: [memoRef(target.id)])

        XCTAssertEqual(ref.kind, .task)
        XCTAssertEqual(try repo.task(id: ref.id)?.title, "새 업무")
        XCTAssertEqual(try repo.activities(taskId: ref.id).count, 1, "note는 진행 기록이 된다")
        try assertLinkConnects(repo, ref, memoRef(target.id))
        _ = search
    }

    func testCreateActivityWithRelatedStoresOriginalAndLink() throws {
        let (service, repo, tasks, search) = try makeService()
        let owner = try tasks.createTask(title: "업무", workDate: monday)
        let target = try tasks.captureMemo(body: "대상 메모", workDate: monday)

        let ref = try service.create(
            .activity(taskId: owner.id, body: "진행 기록", workDate: monday, effectiveTime: nil,
                      projectIds: [], checklistItemIds: [], kind: .progress, links: []),
            related: [memoRef(target.id)])

        XCTAssertEqual(ref.kind, .activity)
        XCTAssertEqual(try repo.activity(id: ref.id)?.body, "진행 기록")
        XCTAssertEqual(try repo.activities(taskId: owner.id).count, 1)
        try assertLinkConnects(repo, ref, memoRef(target.id))
        _ = search
    }

    // MARK: - 2. related 비어 있음 → 원본만

    func testEmptyRelatedCreatesOriginalWithoutLinks() throws {
        let (service, repo, _, search) = try makeService()

        let ref = try service.create(
            .memo(body: "링크 없음", workDate: monday, projectNames: [], tagNames: []),
            related: [])

        XCTAssertEqual(try repo.memo(id: ref.id)?.body, "링크 없음")
        XCTAssertTrue(try RecordLinkStore(repo: repo).allLinks().isEmpty)
        _ = search
    }

    // MARK: - 3. 링크 실패 → 원본·FTS 롤백

    func testMissingTargetRollsBackMemoAndSearchDoc() throws {
        let (service, repo, _, search) = try makeService()

        XCTAssertThrowsError(try service.create(
            .memo(body: "롤백 메모 본문", workDate: monday, projectNames: [], tagNames: []),
            related: [taskRef("없는업무")])) { error in
            guard case WorkLogError.validation = error else {
                return XCTFail("validation 기대: \(error)")
            }
        }

        XCTAssertTrue(try repo.memos(on: monday).isEmpty, "원본 메모 행이 남으면 안 된다")
        XCTAssertEqual(try searchDocCount(repo, search, type: "memo"), 0,
                       "FTS/ search_doc 행이 남으면 안 된다")
        XCTAssertTrue(try RecordLinkStore(repo: repo).allLinks().isEmpty)
    }

    func testMissingTargetRollsBackTaskAndSearchDoc() throws {
        let (service, repo, _, search) = try makeService()

        XCTAssertThrowsError(try service.create(
            .task(title: "롤백 업무", body: nil, initialStatus: .planned, workDate: monday,
                  effectiveTime: nil, dueOn: nil, projectNames: [], trackingMode: .shared,
                  tagNames: [], checklist: [], links: []),
            related: [taskRef("없는업무")])) { error in
            guard case WorkLogError.validation = error else {
                return XCTFail("validation 기대: \(error)")
            }
        }

        XCTAssertTrue(try repo.tasks().isEmpty, "원본 업무 행이 남으면 안 된다")
        XCTAssertEqual(try searchDocCount(repo, search, type: "task"), 0,
                       "FTS/ search_doc 행이 남으면 안 된다")
        XCTAssertTrue(try RecordLinkStore(repo: repo).allLinks().isEmpty)
    }

    func testMissingTargetRollsBackActivityButKeepsOwnerTask() throws {
        let (service, repo, tasks, search) = try makeService()
        let owner = try tasks.createTask(title: "남는 업무", workDate: monday)

        XCTAssertThrowsError(try service.create(
            .activity(taskId: owner.id, body: "롤백 진행기록", workDate: monday, effectiveTime: nil,
                      projectIds: [], checklistItemIds: [], kind: .progress, links: []),
            related: [taskRef("없는업무")])) { error in
            guard case WorkLogError.validation = error else {
                return XCTFail("validation 기대: \(error)")
            }
        }

        XCTAssertTrue(try repo.activities(taskId: owner.id).isEmpty, "진행 기록이 남으면 안 된다")
        XCTAssertNotNil(try repo.task(id: owner.id), "기존 업무는 그대로 남는다")
        XCTAssertEqual(try searchDocCount(repo, search, type: "activity"), 0,
                       "FTS/ search_doc 진행기록 행이 남으면 안 된다")
        XCTAssertEqual(try searchDocCount(repo, search, type: "task"), 1, "기존 업무 색인은 유지된다")
        XCTAssertTrue(try RecordLinkStore(repo: repo).allLinks().isEmpty)
    }

    // MARK: - 4. 중복·자기 참조 제거

    func testDuplicateRelatedTargetsAreStoredOnce() throws {
        let (service, repo, tasks, search) = try makeService()
        let target = try tasks.createTask(title: "대상 업무", workDate: monday)
        let ref = taskRef(target.id)

        let created = try service.create(
            .memo(body: "중복 링크", workDate: monday, projectNames: [], tagNames: []),
            related: [ref, ref, ref])

        try assertLinkConnects(repo, created, ref)
        XCTAssertEqual(try RecordLinkStore(repo: repo).allLinks().count, 1)
        _ = search
    }

    /// 생성될 메모 id를 미리 알 수 있게 IDGenerator를 결정적으로 둔다.
    /// 대상 기록은 명시적 id로 직접 저장해 생성기 소비를 피한다(메모가 "s-1").
    func testSelfReferenceIsRemoved() throws {
        let clock = FixedClock(fixedNow)
        let repo = try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator(prefix: "s"))
        let search = try SearchIndex(repo: repo)
        let tasks = TaskService(repo: repo)
        let service = LinkedCaptureService(repo: repo, tasks: tasks)

        try repo.insertTask(WorkTask(id: "t1", title: "대상 업무", createdAt: clock.now()))
        let predictedSelf = memoRef("s-1")

        let created = try service.create(
            .memo(body: "자기 참조 제외", workDate: monday, projectNames: [], tagNames: []),
            related: [predictedSelf, taskRef("t1"), taskRef("t1")])

        XCTAssertEqual(created, predictedSelf, "첫 생성 id는 s-1")
        try assertLinkConnects(repo, created, taskRef("t1"))
        XCTAssertEqual(try RecordLinkStore(repo: repo).allLinks().count, 1)
        _ = search
    }
}
