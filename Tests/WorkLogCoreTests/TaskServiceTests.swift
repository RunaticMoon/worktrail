import XCTest
@testable import WorkLogCore

final class TaskServiceTests: XCTestCase {

    private let monday = WorkDate("2026-10-05")!
    private let tuesday = WorkDate("2026-10-06")!
    private let wednesday = WorkDate("2026-10-07")!

    private func makeService() throws -> (service: TaskService, repo: WorkRepository, clock: FixedClock) {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_790_000_000))
        let repo = try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator())
        return (TaskService(repo: repo), repo, clock)
    }

    // MARK: - CAP-T05 / T06 / LINK-T01 — Memo, 업무일 귀속, URL 보관(fetch 없음)

    func testCaptureMemoStoresMultilineBodyAndLinksWithoutFetch() throws {
        let (service, repo, _) = try makeService()
        let body = "첫 줄 요약입니다\n둘째 줄 한글 본문\n\n"
            + "참고 https://example.com/pull/42 그리고 https://jira.example.com/browse/ABC-12"
        let memo = try service.captureMemo(body: body, workDate: monday,
                                           projectNames: ["대중교통"], tagNames: ["버스"])

        XCTAssertEqual(memo.body, body)
        XCTAssertEqual(memo.preview, "첫 줄 요약입니다")
        XCTAssertEqual(memo.workDate, monday)
        XCTAssertEqual(try repo.memos(on: monday).count, 1)
        XCTAssertEqual(memo.projectIds.count, 1)
        XCTAssertEqual(memo.tagIds.count, 1)

        let links = try repo.links(ownerType: .memo, ownerId: memo.id)
        XCTAssertEqual(links.map { $0.url },
                       ["https://example.com/pull/42", "https://jira.example.com/browse/ABC-12"])
        XCTAssertEqual(links.map { $0.linkType }, [.githubPullRequest, .jiraIssue])
    }

    func testCaptureMemoLateEntryBelongsToWorkDate() throws {
        let recordedAt = Date(timeIntervalSince1970: 1_790_500_000)
        let clock = FixedClock(recordedAt)
        let repo = try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator())
        let service = TaskService(repo: repo)

        let memo = try service.captureMemo(body: "화요일에 적은 월요일 기록", workDate: monday)
        XCTAssertEqual(memo.workDate, monday)
        XCTAssertEqual(memo.recordedAt, recordedAt)
        XCTAssertEqual(try repo.memos(on: monday).first?.id, memo.id)
        XCTAssertTrue(try repo.memos(on: tuesday).isEmpty)
    }

    func testLinkExtractorKeepsOrderAndRemovesDuplicates() {
        let text = "https://b.com/x, https://a.com/y 그리고 https://b.com/x."
        XCTAssertEqual(LinkExtractor.urls(in: text), ["https://b.com/x", "https://a.com/y"])
        XCTAssertEqual(LinkExtractor.urls(in: "http://only.dev/path"), ["http://only.dev/path"])
        XCTAssertTrue(LinkExtractor.urls(in: "URL 없음").isEmpty)
    }

    // MARK: - TASK-T01 — 완료로 바로 등록

    func testCreateCompletedTaskHasNoStartedOnAndOneCompletionDate() throws {
        let (service, repo, _) = try makeService()
        let task = try service.createTask(title: "완료로 등록", initialStatus: .completed, workDate: monday)

        XCTAssertEqual(try service.currentStatus(taskId: task.id), .completed)
        XCTAssertEqual(try repo.task(id: task.id)?.cachedStatus, .completed)

        let detail = try service.detail(taskId: task.id)
        XCTAssertNil(detail.firstStartedOn)
        XCTAssertEqual(detail.completionDates, [monday])
        XCTAssertTrue(detail.violations.isEmpty)
        XCTAssertEqual(try repo.tasks().count, 1)
    }

    func testCreateTaskRejectsBlankTitle() throws {
        let (service, repo, _) = try makeService()
        XCTAssertThrowsError(try service.createTask(title: "   ", workDate: monday)) { error in
            guard case WorkLogError.validation = error else {
                return XCTFail("validation 기대: \(error)")
            }
        }
        XCTAssertTrue(try repo.tasks().isEmpty)
    }

    func testCreateTaskNoteBecomesActivity() throws {
        let (service, repo, _) = try makeService()
        let task = try service.createTask(title: "T", initialStatus: .completed, workDate: monday,
                                          note: "완료 메모")
        let activities = try repo.activities(taskId: task.id)
        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(activities.first?.kind, .completion)
        XCTAssertEqual(activities.first?.workDate, monday)
    }

    func testCreateTaskLinksAreStoredAsTaskOwner() throws {
        let (service, repo, _) = try makeService()
        let task = try service.createTask(title: "T", workDate: monday,
                                          links: ["https://example.com/pr/7"])
        XCTAssertEqual(try repo.links(ownerType: .task, ownerId: task.id).map { $0.url },
                       ["https://example.com/pr/7"])
        XCTAssertEqual(try service.detail(taskId: task.id).links.map { $0.url },
                       ["https://example.com/pr/7"])
    }

    // MARK: - TASK-T02 — 진행 기록

    func testAddActivityAppearsOnceOnItsDateAndDoesNotChangeStatus() throws {
        let (service, repo, _) = try makeService()
        let task = try service.createTask(title: "T", workDate: monday)
        let activity = try service.addActivity(taskId: task.id, body: "진행 기록", workDate: tuesday)

        XCTAssertEqual(try repo.activities(taskId: task.id).map { $0.id }, [activity.id])
        XCTAssertEqual(try repo.activities(on: tuesday).count, 1)
        XCTAssertTrue(try repo.activities(on: monday).isEmpty)
        XCTAssertEqual(try service.currentStatus(taskId: task.id), .planned)
    }

    func testActivityBodyAndExplicitLinksAreStored() throws {
        let (service, repo, _) = try makeService()
        let task = try service.createTask(title: "T", workDate: monday)
        let activity = try service.addActivity(taskId: task.id, body: "참고 https://example.com/a",
                                               workDate: monday, links: ["https://example.com/b"])
        let urls = try repo.links(ownerType: .activity, ownerId: activity.id).map { $0.url }
        XCTAssertEqual(urls, ["https://example.com/a", "https://example.com/b"])
    }

    // MARK: - TASK-T03 — 진행→보류→재개 이력 보존

    func testProgressPauseResumeKeepsHistory() throws {
        let (service, repo, _) = try makeService()
        let task = try service.createTask(title: "T", workDate: monday)
        try service.changeTaskStatus(taskId: task.id, kind: .started, workDate: monday)
        try service.changeTaskStatus(taskId: task.id, kind: .paused, workDate: tuesday)
        try service.changeTaskStatus(taskId: task.id, kind: .resumed, workDate: wednesday)

        XCTAssertEqual(try service.currentStatus(taskId: task.id), .inProgress)
        XCTAssertEqual(try repo.events(taskId: task.id).map { $0.kind },
                       [.created, .started, .paused, .resumed])
        XCTAssertEqual(try repo.task(id: task.id)?.cachedStatus, .inProgress)
    }

    // MARK: - TASK-T04 — 취소해도 활동 유지, 완료 아님

    func testActivitySurvivesCancellationAndStatusIsNotCompleted() throws {
        let (service, repo, _) = try makeService()
        let task = try service.createTask(title: "T", workDate: monday)
        _ = try service.addActivity(taskId: task.id, body: "한 일", workDate: monday)
        try service.changeTaskStatus(taskId: task.id, kind: .cancelled, workDate: tuesday, note: "우선순위 하락")

        XCTAssertEqual(try service.currentStatus(taskId: task.id), .cancelled)
        XCTAssertEqual(try repo.activities(taskId: task.id).count, 1)
        XCTAssertTrue(try service.detail(taskId: task.id).completionDates.isEmpty)
    }

    // MARK: - TASK-T05 — 완료→재개→재완료

    func testCompleteReopenCompleteHasTwoCompletionDatesAndOneTask() throws {
        let (service, repo, _) = try makeService()
        let task = try service.createTask(title: "T", workDate: monday)
        _ = try service.completeTask(taskId: task.id, workDate: monday, confirmRemaining: true)
        try service.changeTaskStatus(taskId: task.id, kind: .reopened, workDate: tuesday)
        _ = try service.completeTask(taskId: task.id, workDate: wednesday, confirmRemaining: true)

        let detail = try service.detail(taskId: task.id)
        XCTAssertEqual(detail.status, .completed)
        XCTAssertEqual(detail.completionDates, [monday, wednesday])
        XCTAssertEqual(try repo.tasks().count, 1)
    }

    // MARK: - TASK-T06 — 후속 Task 생성, 기존 완료 유지

    func testCreateFollowUpTaskKeepsOriginalCompletion() throws {
        let (service, repo, _) = try makeService()
        let original = try service.createTask(title: "원래", workDate: monday)
        _ = try service.completeTask(taskId: original.id, workDate: monday, confirmRemaining: true)

        let followUp = try service.createFollowUpTask(from: original.id, title: "후속", workDate: tuesday)

        XCTAssertEqual(try repo.tasks().count, 2)
        XCTAssertEqual(try service.currentStatus(taskId: original.id), .completed)
        XCTAssertEqual(try service.detail(taskId: original.id).completionDates, [monday])
        XCTAssertEqual(try service.currentStatus(taskId: followUp.id), .planned)

        let relations = try repo.relations(taskId: original.id)
        XCTAssertEqual(relations.count, 1)
        XCTAssertEqual(relations.first?.fromTaskId, original.id)
        XCTAssertEqual(relations.first?.toTaskId, followUp.id)
        XCTAssertEqual(relations.first?.type, .followUp)
    }

    // MARK: - TASK-T07 / T08 — 체크리스트와 전체 완료

    func testAllChecklistDoneDoesNotCompleteTask() throws {
        let (service, _, _) = try makeService()
        let task = try service.createTask(title: "T", workDate: monday, checklist: ["a", "b", "c"])
        let items = try service.detail(taskId: task.id).checklist.map { $0.item }
        for item in items {
            try service.setChecklistItem(itemId: item.id, done: true, workDate: monday)
        }

        XCTAssertEqual(try service.currentStatus(taskId: task.id), .planned)
        XCTAssertTrue(try service.detail(taskId: task.id).checklist.allSatisfy { $0.done })
    }

    func testCompleteTaskWithRemainingRequiresConfirmation() throws {
        let (service, repo, _) = try makeService()
        let task = try service.createTask(title: "T", workDate: monday, checklist: ["a", "b", "c"])
        let items = try service.detail(taskId: task.id).checklist.map { $0.item }
        try service.setChecklistItem(itemId: items[0].id, done: true, workDate: monday)
        try service.setChecklistItem(itemId: items[1].id, done: true, workDate: monday)

        let eventsBefore = try repo.events(taskId: task.id).count
        let refused = try service.completeTask(taskId: task.id, workDate: tuesday, confirmRemaining: false)
        XCTAssertFalse(refused.completed)
        XCTAssertEqual(refused.remainingChecklist.map { $0.id }, [items[2].id])
        XCTAssertEqual(try repo.events(taskId: task.id).count, eventsBefore)
        XCTAssertEqual(try service.currentStatus(taskId: task.id), .planned)

        let confirmed = try service.completeTask(taskId: task.id, workDate: tuesday, confirmRemaining: true)
        XCTAssertTrue(confirmed.completed)
        XCTAssertEqual(confirmed.remainingChecklist.map { $0.id }, [items[2].id])
        XCTAssertEqual(try service.currentStatus(taskId: task.id), .completed)

        let detail = try service.detail(taskId: task.id)
        XCTAssertFalse(try XCTUnwrap(detail.checklist.first { $0.item.id == items[2].id }).done)
    }

    // MARK: - TASK-T09 — 체크리스트 완료가 프로젝트 상태 불변

    func testChecklistCompletionDoesNotChangeProjectStatus() throws {
        let (service, _, _) = try makeService()
        let task = try service.createTask(title: "T", workDate: monday, projectNames: ["G"],
                                          trackingMode: .perProject, checklist: ["a"])
        let project = try XCTUnwrap(try service.detail(taskId: task.id).projects.first)
        try service.changeProjectStatus(taskId: task.id, projectId: project.project.id,
                                        kind: .started, workDate: monday)
        let item = try XCTUnwrap(try service.detail(taskId: task.id).checklist.first?.item)
        try service.setChecklistItem(itemId: item.id, done: true, workDate: tuesday)

        XCTAssertEqual(try service.detail(taskId: task.id).projects.first?.status, .inProgress)
    }

    // MARK: - PROJ-T03 — 프로젝트별 적용 상태 독립

    func testPerProjectStatusesAreIndependent() throws {
        let (service, _, _) = try makeService()
        let task = try service.createTask(title: "T", workDate: monday,
                                          projectNames: ["G", "J", "K"], trackingMode: .perProject)
        try service.changeTaskStatus(taskId: task.id, kind: .started, workDate: monday)
        let ids = try projectIds(taskId: task.id, service: service)
        try service.changeProjectStatus(taskId: task.id, projectId: ids["G"]!, kind: .completed, workDate: tuesday)
        try service.changeProjectStatus(taskId: task.id, projectId: ids["J"]!, kind: .started, workDate: tuesday)

        let detail = try service.detail(taskId: task.id)
        let statuses = Dictionary(uniqueKeysWithValues: detail.projects.map {
            ($0.project.name, $0.status ?? .planned)
        })
        XCTAssertEqual(statuses["G"], .completed)
        XCTAssertEqual(statuses["J"], .inProgress)
        XCTAssertEqual(statuses["K"], .planned)
        XCTAssertEqual(detail.status, .inProgress)
    }

    // MARK: - PROJ-T04 — 모든 프로젝트 완료도 Task 자동 완료 없음

    func testAllProjectsCompletedDoesNotCompleteTask() throws {
        let (service, _, _) = try makeService()
        let task = try service.createTask(title: "T", workDate: monday,
                                          projectNames: ["G", "J"], trackingMode: .perProject)
        try service.changeTaskStatus(taskId: task.id, kind: .started, workDate: monday)
        let projects = try service.detail(taskId: task.id).projects
        for p in projects {
            try service.changeProjectStatus(taskId: task.id, projectId: p.project.id,
                                            kind: .completed, workDate: tuesday)
        }

        XCTAssertEqual(try service.currentStatus(taskId: task.id), .inProgress)

        let check = try service.completeTask(taskId: task.id, workDate: wednesday, confirmRemaining: true)
        XCTAssertTrue(check.unfinishedProjects.isEmpty)
        XCTAssertTrue(check.remainingChecklist.isEmpty)
        XCTAssertTrue(check.completed)
        XCTAssertEqual(try service.currentStatus(taskId: task.id), .completed)
    }

    // MARK: - PROJ-T05 — 한 프로젝트만 취소

    func testCancellingOneProjectLeavesOthersAndTaskUnchanged() throws {
        let (service, _, _) = try makeService()
        let task = try service.createTask(title: "T", workDate: monday,
                                          projectNames: ["G", "J", "K"], trackingMode: .perProject)
        try service.changeTaskStatus(taskId: task.id, kind: .started, workDate: monday)
        let ids = try projectIds(taskId: task.id, service: service)
        try service.changeProjectStatus(taskId: task.id, projectId: ids["G"]!, kind: .completed, workDate: tuesday)
        try service.changeProjectStatus(taskId: task.id, projectId: ids["J"]!, kind: .started, workDate: tuesday)
        try service.changeProjectStatus(taskId: task.id, projectId: ids["K"]!, kind: .cancelled, workDate: wednesday)

        let detail = try service.detail(taskId: task.id)
        let statuses = Dictionary(uniqueKeysWithValues: detail.projects.map {
            ($0.project.name, $0.status ?? .planned)
        })
        XCTAssertEqual(statuses["G"], .completed)
        XCTAssertEqual(statuses["J"], .inProgress)
        XCTAssertEqual(statuses["K"], .cancelled)
        XCTAssertEqual(detail.status, .inProgress)
    }

    // MARK: - PROJ-T07 — 공통 기록은 project scope 사건을 만들지 않음

    func testCommonActivityAddsNoProjectScopeEvent() throws {
        let (service, repo, _) = try makeService()
        let task = try service.createTask(title: "T", workDate: monday,
                                          projectNames: ["G", "J"], trackingMode: .perProject)
        let before = try repo.events(taskId: task.id).filter { $0.scopeType == .taskProject }.count
        _ = try service.addActivity(taskId: task.id, body: "공통 기록", workDate: tuesday)
        let after = try repo.events(taskId: task.id).filter { $0.scopeType == .taskProject }.count
        XCTAssertEqual(after, before)
    }

    func testSharedProjectHasNilStatusAndRejectsProjectStatusChange() throws {
        let (service, _, _) = try makeService()
        let task = try service.createTask(title: "T", workDate: monday, projectNames: ["G"],
                                          trackingMode: .shared)
        let detail = try service.detail(taskId: task.id)
        XCTAssertNil(detail.projects.first?.status)

        let projectId = try XCTUnwrap(detail.projects.first?.project.id)
        XCTAssertThrowsError(try service.changeProjectStatus(taskId: task.id, projectId: projectId,
                                                             kind: .started, workDate: monday)) { error in
            guard case WorkLogError.validation = error else {
                return XCTFail("validation 기대: \(error)")
            }
        }
    }

    // MARK: - CAP-T10 — 완료 후 전이 시도는 저장되지 않음

    func testPausedAfterCompletionIsRejectedWithoutSaving() throws {
        let (service, repo, _) = try makeService()
        let task = try service.createTask(title: "T", workDate: monday)
        _ = try service.completeTask(taskId: task.id, workDate: tuesday, confirmRemaining: true)

        let before = try repo.events(taskId: task.id).count
        XCTAssertThrowsError(try service.changeTaskStatus(taskId: task.id, kind: .paused,
                                                          workDate: wednesday)) { error in
            guard case WorkLogError.invalidTransition = error else {
                return XCTFail("invalidTransition 기대: \(error)")
            }
        }
        XCTAssertEqual(try repo.events(taskId: task.id).count, before)
        XCTAssertEqual(try service.currentStatus(taskId: task.id), .completed)
    }

    // MARK: - TIME-T06 — 늦게 입력한 시작 사건과 과거 조회

    func testLateRecordedStartBeforeLaterCompletion() throws {
        let (service, repo, clock) = try makeService()
        let task = try service.createTask(title: "T", workDate: monday)
        _ = try service.completeTask(taskId: task.id, workDate: tuesday, confirmRemaining: true)

        clock.advance(by: 3600)
        try service.changeTaskStatus(taskId: task.id, kind: .started, workDate: monday)

        XCTAssertEqual(try service.detail(taskId: task.id, asOf: monday).status, .inProgress)
        XCTAssertEqual(try service.currentStatus(taskId: task.id), .completed)

        let mondayEvents = try repo.events(onOrBefore: monday).filter { $0.scopeId == task.id }
        XCTAssertEqual(mondayEvents.map { $0.kind }, [.created, .started])
        XCTAssertEqual(mondayEvents.map { $0.effectiveOrder }, [1, 2])
    }

    // MARK: - detail(knownAt:) — 그 이후 기록 미반영

    func testDetailKnownAtIgnoresLaterRecords() throws {
        let (service, _, clock) = try makeService()
        let task = try service.createTask(title: "T", workDate: monday)
        try service.changeTaskStatus(taskId: task.id, kind: .started, workDate: monday)
        let knownAt = clock.now()

        clock.advance(by: 3600)
        _ = try service.addActivity(taskId: task.id, body: "나중 기록", workDate: monday)
        try service.changeTaskStatus(taskId: task.id, kind: .cancelled, workDate: monday)

        let earlier = try service.detail(taskId: task.id, knownAt: knownAt)
        XCTAssertEqual(earlier.status, .inProgress)
        XCTAssertTrue(earlier.activities.isEmpty)
        XCTAssertEqual(try service.currentStatus(taskId: task.id), .cancelled)
        XCTAssertEqual(try service.detail(taskId: task.id).activities.count, 1)
    }

    // MARK: - rebuildCachedStatuses

    func testRebuildCachedStatusesMatchesReplay() throws {
        let (service, repo, _) = try makeService()
        let task = try service.createTask(title: "T", workDate: monday)
        try service.changeTaskStatus(taskId: task.id, kind: .started, workDate: monday)
        try repo.setTaskCachedStatus(id: task.id, status: nil)

        try service.rebuildCachedStatuses()
        XCTAssertEqual(try repo.task(id: task.id)?.cachedStatus, .inProgress)
    }

    // MARK: - helper

    private func projectIds(taskId: String, service: TaskService) throws -> [String: String] {
        let detail = try service.detail(taskId: taskId)
        return Dictionary(uniqueKeysWithValues: detail.projects.map { ($0.project.name, $0.project.id) })
    }
}
