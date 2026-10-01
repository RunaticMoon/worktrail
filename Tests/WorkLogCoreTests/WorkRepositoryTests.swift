import XCTest
@testable import WorkLogCore

final class WorkRepositoryTests: XCTestCase {

    private let monday = WorkDate("2026-10-05")!
    private let tuesday = WorkDate("2026-10-06")!

    private func makeRepo() throws -> WorkRepository {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_790_000_000))
        return try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator())
    }

    private func makeRepo(clock: FixedClock) throws -> WorkRepository {
        try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator())
    }

    // MARK: CAP-T05 — Memo 저장 후 원문 전체 재조회

    func testMemoRoundTripPreservesBodyPreviewAndLinks() throws {
        let repo = try makeRepo()
        let project = try repo.createProject(name: "대중교통 길찾기")
        let tag = try repo.findOrCreateTag(name: "버스")
        let body = "첫 줄 요약입니다\n둘째 줄 한글 본문\n\n넷째 줄도 남는다"
        let recordedAt = Date(timeIntervalSince1970: 1_790_000_100)

        let memo = Memo(id: "memo-1", body: body, workDate: monday, recordedAt: recordedAt,
                        projectIds: [project.id], tagIds: [tag.id])
        try repo.insertMemo(memo)

        let loaded = try XCTUnwrap(try repo.memo(id: "memo-1"))
        XCTAssertEqual(loaded.body, body)
        XCTAssertEqual(loaded.preview, "첫 줄 요약입니다")
        XCTAssertEqual(loaded.workDate, monday)
        XCTAssertEqual(loaded.recordedAt, recordedAt)
        XCTAssertEqual(loaded.revision, 1)
        XCTAssertEqual(loaded.projectIds, [project.id])
        XCTAssertEqual(loaded.tagIds, [tag.id])
        XCTAssertNil(loaded.deletedAt)
    }

    // MARK: CAP-T06 — 늦은 입력은 업무일 기준으로 귀속되고 입력 시각은 보존된다

    func testLateEntryBelongsToWorkDateAndKeepsRecordedAt() throws {
        let recordedAt = Date(timeIntervalSince1970: 1_790_100_000)
        let clock = FixedClock(recordedAt)
        let repo = try makeRepo(clock: clock)

        let memo = Memo(id: "memo-late", body: "화요일에 적은 월요일 기록",
                        workDate: monday, recordedAt: clock.now())
        try repo.insertMemo(memo)

        let mondayMemos = try repo.memos(on: monday)
        XCTAssertEqual(mondayMemos.count, 1)
        XCTAssertEqual(mondayMemos.first?.id, "memo-late")
        XCTAssertEqual(mondayMemos.first?.recordedAt, recordedAt)
        XCTAssertTrue(try repo.memos(on: tuesday).isEmpty)
    }

    // MARK: updateMemoBody — revision 증가와 이전 본문 보존

    func testUpdateMemoBodyCreatesRevision() throws {
        let repo = try makeRepo()
        let original = Memo(id: "memo-r", body: "원래 본문", workDate: monday,
                            recordedAt: Date(timeIntervalSince1970: 1_790_000_000))
        try repo.insertMemo(original)

        let updated = try repo.updateMemoBody(id: "memo-r", body: "고친 본문", workDate: tuesday)
        XCTAssertEqual(updated.revision, 2)
        XCTAssertEqual(updated.body, "고친 본문")
        XCTAssertEqual(updated.workDate, tuesday)

        let revisions = try repo.memoRevisions(id: "memo-r")
        XCTAssertEqual(revisions.count, 1)
        XCTAssertEqual(revisions.first?.revision, 1)
        XCTAssertEqual(revisions.first?.body, "원래 본문")
        XCTAssertEqual(revisions.first?.workDate, monday)

        let reloaded = try XCTUnwrap(try repo.memo(id: "memo-r"))
        XCTAssertEqual(reloaded.body, "고친 본문")
        XCTAssertEqual(reloaded.revision, 2)
    }

    // MARK: PROJ-T01 — 공백 있는 프로젝트 이름, 중복 conflict, findOrCreate 안정 ID

    func testProjectNameWithSpacesAndConflictAndFindOrCreate() throws {
        let repo = try makeRepo()
        let created = try repo.createProject(name: "대중교통 길찾기")
        XCTAssertEqual(created.name, "대중교통 길찾기")

        XCTAssertThrowsError(try repo.createProject(name: "대중교통 길찾기")) { error in
            guard case WorkLogError.conflict = error else {
                return XCTFail("conflict를 기대했으나 \(error)")
            }
        }

        let again = try repo.findOrCreateProject(name: "대중교통 길찾기")
        XCTAssertEqual(again.id, created.id)

        let created2 = try repo.findOrCreateProject(name: "  새 프로젝트  ")
        XCTAssertEqual(created2.name, "새 프로젝트")
        XCTAssertEqual(try repo.findOrCreateProject(name: "새 프로젝트").id, created2.id)

        XCTAssertEqual(try repo.projects().count, 2)
        XCTAssertEqual(try repo.project(id: created.id)?.name, "대중교통 길찾기")

        try repo.renameProject(id: created.id, to: "대중교통 경로 탐색")
        XCTAssertEqual(try repo.project(id: created.id)?.name, "대중교통 경로 탐색")
    }

    func testTagFindOrCreate() throws {
        let repo = try makeRepo()
        let tag = try repo.findOrCreateTag(name: "리팩터링")
        XCTAssertEqual(tag.name, "리팩터링")
        XCTAssertEqual(try repo.findOrCreateTag(name: "리팩터링").id, tag.id)
        XCTAssertEqual(try repo.tags().count, 1)
    }

    // MARK: PROJ-T02 — Task에 프로젝트 3개 연결, unlink는 soft

    func testTaskProjectLinksAndUnlink() throws {
        let repo = try makeRepo()
        let p1 = try repo.createProject(name: "G")
        let p2 = try repo.createProject(name: "J")
        let p3 = try repo.createProject(name: "K")

        let task = WorkTask(id: "task-1", title: "배포 준비", createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        try repo.insertTask(task)

        for project in [p1, p2, p3] {
            try repo.linkProject(taskId: task.id, projectId: project.id,
                                 trackingEnabled: true, linkedOn: monday)
        }

        XCTAssertEqual(try repo.tasks().count, 1)
        XCTAssertEqual(try repo.taskProjects(taskId: task.id).count, 3)

        // 이미 연결된 상태에서 다시 호출하면 기존 행을 반환한다(중복 생성 없음).
        try repo.linkProject(taskId: task.id, projectId: p1.id, trackingEnabled: true, linkedOn: monday)
        XCTAssertEqual(try repo.taskProjects(taskId: task.id).count, 3)

        try repo.unlinkProject(taskId: task.id, projectId: p1.id, removedOn: tuesday)
        let active = try repo.taskProjects(taskId: task.id)
        XCTAssertEqual(active.count, 2)
        XCTAssertFalse(active.contains { $0.projectId == p1.id })

        let withRemoved = try repo.taskProjects(taskId: task.id, includeRemoved: true)
        XCTAssertEqual(withRemoved.count, 3)
        XCTAssertTrue(withRemoved.contains { $0.projectId == p1.id && $0.removedOn == tuesday })
    }

    // MARK: PROJ-T06 — 한 활동이 여러 프로젝트에 걸린다

    func testActivityWithMultipleProjects() throws {
        let repo = try makeRepo()
        let projectA = try repo.createProject(name: "G")
        let projectB = try repo.createProject(name: "J")
        let task = WorkTask(id: "task-a", title: "조사", createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        try repo.insertTask(task)

        let activity = Activity(id: "activity-1", taskId: task.id, body: "두 프로젝트 공통 근거",
                                workDate: monday, recordedAt: Date(timeIntervalSince1970: 1_790_000_050),
                                kind: .progress, projectIds: [projectA.id, projectB.id])
        try repo.insertActivity(activity)

        let onMonday = try repo.activities(on: monday)
        XCTAssertEqual(onMonday.count, 1)
        XCTAssertEqual(Set(onMonday[0].projectIds), Set([projectA.id, projectB.id]))
        XCTAssertEqual(try repo.activities(taskId: task.id).count, 1)
        XCTAssertEqual(try repo.activities(in: DateRange(start: monday, endExclusive: tuesday)).count, 1)
    }

    // MARK: DomainEvent — append/조회 왕복, nextEffectiveOrder

    func testDomainEventAppendAndOrdering() throws {
        let repo = try makeRepo()
        let task = WorkTask(id: "task-e", title: "상태 이력", createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        try repo.insertTask(task)

        XCTAssertEqual(try repo.nextEffectiveOrder(taskId: task.id, on: monday), 1)

        let created = DomainEvent(id: "event-1", taskId: task.id, scopeType: .task, scopeId: task.id,
                                  kind: .created, toStatus: .planned, effectiveDate: monday,
                                  effectiveTime: nil, effectiveOrder: 1,
                                  recordedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                  note: "최초")
        try repo.appendEvent(created)
        XCTAssertEqual(try repo.nextEffectiveOrder(taskId: task.id, on: monday), 2)

        let started = DomainEvent(id: "event-2", taskId: task.id, scopeType: .task, scopeId: task.id,
                                  kind: .started, toStatus: .inProgress, effectiveDate: monday,
                                  effectiveTime: Date(timeIntervalSince1970: 1_790_003_600),
                                  effectiveOrder: 2,
                                  recordedAt: Date(timeIntervalSince1970: 1_790_000_100),
                                  activityId: "activity-1")
        try repo.appendEvents([started])

        let events = try repo.events(taskId: task.id)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0], created)
        XCTAssertEqual(events[1], started)
        XCTAssertNil(events[0].effectiveTime)               // nil 보존
        XCTAssertNotNil(events[1].effectiveTime)
        XCTAssertEqual(events[1].toStatus, .inProgress)
        XCTAssertEqual(events[1].activityId, "activity-1")

        XCTAssertEqual(try repo.allEvents().count, 2)
        XCTAssertEqual(try repo.events(onOrBefore: monday).count, 2)
        XCTAssertEqual(try repo.events(in: DateRange(start: monday, endExclusive: tuesday)).count, 2)
        XCTAssertEqual(try repo.events(in: DateRange(start: tuesday, endExclusive: WorkDate("2026-10-07")!)).count, 0)
    }

    // MARK: searchTasksByTitle — LIKE 와일드카드를 리터럴로

    func testSearchTasksByTitleTreatsWildcardsLiterally() throws {
        let repo = try makeRepo()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        try repo.insertTask(WorkTask(id: "t-percent", title: "완료 100%", createdAt: now))
        try repo.insertTask(WorkTask(id: "t-underscore", title: "밑줄_작업", createdAt: now))
        try repo.insertTask(WorkTask(id: "t-backslash", title: "역슬래시\\경로", createdAt: now))
        try repo.insertTask(WorkTask(id: "t-plain", title: "일반 작업", createdAt: now))

        func titles(_ text: String) throws -> [String] {
            try repo.searchTasksByTitle(text).map(\.id)
        }

        XCTAssertEqual(try titles("%"), ["t-percent"])
        XCTAssertEqual(try titles("_"), ["t-underscore"])
        XCTAssertEqual(try titles("\\"), ["t-backslash"])
        XCTAssertEqual(try titles("100%"), ["t-percent"])
        XCTAssertTrue(try titles("없는문자").isEmpty)
    }

    // MARK: onSourceChanged

    func testOnSourceChangedCalledForMemoActivityAndTask() throws {
        let repo = try makeRepo()
        var changes: [(String, String)] = []
        repo.onSourceChanged = { changes.append(($0, $1)) }

        try repo.insertMemo(Memo(id: "memo-c", body: "본문", workDate: monday,
                                 recordedAt: Date(timeIntervalSince1970: 1_790_000_000)))
        try repo.insertTask(WorkTask(id: "task-c", title: "원래 제목",
                                     createdAt: Date(timeIntervalSince1970: 1_790_000_000)))
        try repo.insertActivity(Activity(id: "activity-c", taskId: "task-c", body: "기록",
                                         workDate: monday, recordedAt: Date(timeIntervalSince1970: 1_790_000_010)))
        try repo.updateTaskTitle(id: "task-c", title: "바뀐 제목")
        try repo.updateMemoBody(id: "memo-c", body: "고침", workDate: monday)
        try repo.softDeleteMemo(id: "memo-c")

        XCTAssertTrue(changes.contains { $0 == ("memo", "memo-c") })
        XCTAssertTrue(changes.contains { $0 == ("task", "task-c") })
        XCTAssertTrue(changes.contains { $0 == ("activity", "activity-c") })
        XCTAssertEqual(changes.filter { $0 == ("memo", "memo-c") }.count, 3)
        XCTAssertEqual(changes.filter { $0 == ("task", "task-c") }.count, 2)
    }

    // MARK: soft delete

    func testMemoSoftDeleteHiddenByDefault() throws {
        let repo = try makeRepo()
        try repo.insertMemo(Memo(id: "memo-d", body: "지울 기록", workDate: monday,
                                 recordedAt: Date(timeIntervalSince1970: 1_790_000_000)))
        try repo.softDeleteMemo(id: "memo-d")

        XCTAssertNil(try repo.memo(id: "memo-d"))
        XCTAssertNotNil(try repo.memo(id: "memo-d", includeDeleted: true))
        XCTAssertTrue(try repo.memos(on: monday).isEmpty)
    }

    // MARK: Checklist / Link / Relation / MemoTaskLink 보조 계약

    func testChecklistActivityChecklistAndLinks() throws {
        let repo = try makeRepo()
        let project = try repo.createProject(name: "G")
        let task = WorkTask(id: "task-x", title: "정리", createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        try repo.insertTask(task)

        try repo.insertChecklistItem(ChecklistItem(id: "chk-1", taskId: task.id, text: "첫 항목",
                                                   sortOrder: 2, projectIds: [project.id]))
        try repo.insertChecklistItem(ChecklistItem(id: "chk-2", taskId: task.id, text: "둘째 항목",
                                                   sortOrder: 1))
        XCTAssertEqual(try repo.checklistItems(taskId: task.id).map(\.id), ["chk-2", "chk-1"])

        try repo.updateChecklistText(id: "chk-1", text: "고친 항목")
        XCTAssertEqual(try repo.checklistItem(id: "chk-1")?.text, "고친 항목")
        XCTAssertEqual(try repo.checklistItem(id: "chk-1")?.projectIds, [project.id])

        let activity = Activity(id: "activity-x", taskId: task.id, body: "체크리스트 진행",
                                workDate: monday, recordedAt: Date(timeIntervalSince1970: 1_790_000_020),
                                checklistItemIds: ["chk-2"])
        try repo.insertActivity(activity)
        XCTAssertEqual(try repo.activity(id: "activity-x")?.checklistItemIds, ["chk-2"])

        try repo.softDeleteChecklistItem(id: "chk-1")
        XCTAssertEqual(try repo.checklistItems(taskId: task.id).map(\.id), ["chk-2"])
        XCTAssertEqual(try repo.checklistItems(taskId: task.id, includeDeleted: true).count, 2)

        let link = WorkLink(id: "link-1", ownerType: .task, ownerId: task.id,
                            url: "https://example.com/pull/1", linkType: .githubPullRequest,
                            createdAt: Date(timeIntervalSince1970: 1_790_000_030))
        try repo.insertLink(link)
        XCTAssertEqual(try repo.links(ownerType: .task, ownerId: task.id), [link])

        let relation = TaskRelation(id: "rel-1", fromTaskId: task.id, toTaskId: task.id,
                                    type: .followUp, createdAt: Date(timeIntervalSince1970: 1_790_000_040))
        try repo.insertRelation(relation)
        XCTAssertEqual(try repo.relations(taskId: task.id), [relation])

        let memoLink = MemoTaskLink(id: "mtl-1", memoId: "memo-c", taskId: task.id, status: .proposed,
                                    reason: "관련", sourceRevision: 1,
                                    createdAt: Date(timeIntervalSince1970: 1_790_000_050))
        // memo-c는 만들지 않았으므로 FK 위반 없이 넣기 위해 memo를 먼저 만든다.
        try repo.insertMemo(Memo(id: "memo-c", body: "연결 메모", workDate: monday,
                                 recordedAt: Date(timeIntervalSince1970: 1_790_000_000)))
        try repo.upsertMemoTaskLink(memoLink)
        XCTAssertEqual(try repo.memoTaskLinks(memoId: "memo-c"), [memoLink])
        XCTAssertEqual(try repo.memoTaskLinks(taskId: task.id), [memoLink])
        XCTAssertEqual(try repo.memoTaskLinks(taskId: task.id, status: .accepted), [])
        XCTAssertEqual(try repo.memoTaskLinks(taskId: task.id, status: .proposed), [memoLink])
    }

    func testTaskFieldUpdates() throws {
        let repo = try makeRepo()
        let task = WorkTask(id: "task-u", title: "수정 대상",
                            createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        try repo.insertTask(task)

        try repo.updateTaskDue(id: task.id, dueOn: tuesday)
        try repo.setTaskTrackingMode(id: task.id, mode: .perProject)
        try repo.setTaskCachedStatus(id: task.id, status: .inProgress)

        let loaded = try XCTUnwrap(try repo.task(id: task.id))
        XCTAssertEqual(loaded.dueOn, tuesday)
        XCTAssertEqual(loaded.projectTrackingMode, .perProject)
        XCTAssertEqual(loaded.cachedStatus, .inProgress)
        XCTAssertEqual(loaded.revision, 1)

        try repo.setTaskCachedStatus(id: task.id, status: nil)
        XCTAssertNil(try repo.task(id: task.id)?.cachedStatus)
    }
}
