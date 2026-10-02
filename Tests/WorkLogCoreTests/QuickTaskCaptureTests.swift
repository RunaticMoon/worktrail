import XCTest
@testable import WorkLogCore

/// N: 빠른 입력 업무 탭 동작 — 검색·New task·기존 업무의 activity/status 명령.
///
/// - 업무 검색 필터·정렬·상한.
/// - 새 업무 생성 + 수동 관련 링크.
/// - 기존 업무 진행기록 추가(+링크, 프로젝트 검증).
/// - 상태 변경은 본문 없이 성공하고 입력된 본문을 보존한다.
/// - 허용되지 않은 전이·링크 실패 시 초안·선택 보존.
/// - 완료 시 남은 체크리스트 확인(pendingCompletion) → confirmCompletion/cancel.
/// - Secret 기본값이어도 메모 저장 가능.
final class QuickTaskCaptureTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func environment(defaultKind: CaptureKind = .memo) throws -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickTaskCaptureTests-\(UUID().uuidString)")
        roots.append(root)
        let paths = AppPaths(dataRoot: root.appendingPathComponent("data"),
                             backupRoot: root.appendingPathComponent("backups"))
        var settings = AppSettings()
        settings.aiEnabled = false
        settings.defaultCaptureKind = defaultKind
        try SettingsStore(fileURL: paths.settingsFile).save(settings)
        return try AppEnvironment.open(AppEnvironmentOptions(
            paths: paths, keyStore: InMemoryVaultKeyStore(),
            authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(),
            aiProvider: nil,
            clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_000)),
            ids: SequentialIDGenerator()))
    }

    private func ref(_ kind: RecordReferenceKind, _ id: String) -> RecordReference {
        RecordReference(kind: kind, id: id)
    }

    // MARK: - 검색·정렬

    @MainActor
    func testFilteredTasksSearchExcludesDeletedAndOrdersUnfinishedFirst() async throws {
        let env = try environment()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try env.repo.insertTask(WorkTask(id: "t-planned-old", title: "배포 계획",
                                         createdAt: base, cachedStatus: .planned))
        try env.repo.insertTask(WorkTask(id: "t-done-new", title: "배포 완료",
                                         createdAt: base.addingTimeInterval(100), cachedStatus: .completed))
        try env.repo.insertTask(WorkTask(id: "t-progress-new", title: "배포 진행",
                                         createdAt: base.addingTimeInterval(200), cachedStatus: .inProgress))
        try env.repo.insertTask(WorkTask(id: "t-cancelled-new", title: "배포 취소",
                                         createdAt: base.addingTimeInterval(300), cachedStatus: .cancelled))
        try env.repo.insertTask(WorkTask(id: "t-deleted", title: "배포 삭제",
                                         createdAt: base.addingTimeInterval(400),
                                         deletedAt: base, cachedStatus: .planned))
        try env.repo.insertTask(WorkTask(id: "t-other", title: "회의 정리",
                                         createdAt: base.addingTimeInterval(500)))

        let model = CaptureModel(environment: env)
        model.reloadCandidates()
        model.taskQuery = "배포"
        XCTAssertEqual(model.filteredTasks.map(\.id),
                       ["t-progress-new", "t-planned-old", "t-cancelled-new", "t-done-new"],
                       "미완료 우선 → 최근 순, 삭제 제외")

        model.taskQuery = "배포 완"
        XCTAssertEqual(model.filteredTasks.map(\.id), ["t-done-new"])

        model.taskQuery = ""
        XCTAssertEqual(model.filteredTasks.count, 5, "삭제된 업무는 제외")
        XCTAssertEqual(model.filteredTasks.first?.id, "t-other", "미완료 최근 순")
    }

    @MainActor
    func testFilteredTasksCapsAtFifty() async throws {
        let env = try environment()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<55 {
            try env.repo.insertTask(WorkTask(id: String(format: "bulk-%02d", index),
                                             title: "대량 업무 \(index)",
                                             createdAt: base.addingTimeInterval(Double(index)),
                                             cachedStatus: .planned))
        }
        let model = CaptureModel(environment: env)
        model.reloadCandidates()
        XCTAssertEqual(model.filteredTasks.count, 50)
        XCTAssertEqual(model.filteredTasks.first?.id, "bulk-54")
        XCTAssertFalse(model.filteredTasks.contains { $0.id == "bulk-00" })
    }

    // MARK: - 새 업무 + 링크

    @MainActor
    func testNewTaskCapturesWithRelatedLink() async throws {
        let env = try environment()
        let memo = try env.tasks.captureMemo(body: "관련 메모")
        let model = CaptureModel(environment: env)
        model.kind = .task
        XCTAssertEqual(model.taskSelection, .newTask)
        model.text = "새 업무\n본문 내용"
        model.relatedRecords = try model.searchRelated("관련 메모")
        XCTAssertEqual(model.relatedRecords.first?.reference, ref(.memo, memo.id))

        XCTAssertTrue(model.submit())
        let taskId = try XCTUnwrap(model.lastSavedId)
        XCTAssertEqual(try env.repo.task(id: taskId)?.title, "새 업무")
        XCTAssertEqual(try env.repo.activities(taskId: taskId).count, 1, "두 번째 줄은 진행 기록이 된다")

        let links = try RecordLinkStore(repo: env.repo).allLinks()
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(Set([links[0].first, links[0].second]),
                       Set([ref(.task, taskId), ref(.memo, memo.id)]))
        XCTAssertTrue(model.relatedRecords.isEmpty, "성공 후 관련 후보 초기화")
    }

    // MARK: - 기존 업무 진행기록 + 프로젝트 검증

    @MainActor
    func testExistingTaskActivityValidatesProjectAndLinks() async throws {
        let env = try environment()
        let platform = try env.repo.createProject(name: "플랫폼")
        _ = try env.repo.createProject(name: "다른")
        let task = try env.tasks.createTask(title: "대상 업무", projectNames: ["플랫폼"],
                                            trackingMode: .shared)
        let memo = try env.tasks.captureMemo(body: "근거 메모")

        let model = CaptureModel(environment: env)
        model.kind = .task
        model.taskSelection = .existing(task.id)
        model.taskAction = .addActivity

        // 연결되지 않은 프로젝트 → 프로젝트 검증 실패, 초안·선택 보존.
        model.text = "진행 상황 @다른"
        model.select(try XCTUnwrap(model.candidates.first))
        XCTAssertFalse(model.submit())
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(try env.tasks.detail(taskId: task.id).activities.isEmpty)
        XCTAssertEqual(model.taskSelection, .existing(task.id))
        XCTAssertFalse(model.text.isEmpty)

        // 연결된 프로젝트 → 성공 + 링크.
        model.removeProject(try XCTUnwrap(model.selectedProjectIds.first))
        model.text = "진행 상황 @플랫폼"
        model.select(try XCTUnwrap(model.candidates.first))
        XCTAssertEqual(model.selectedProjectIds, [platform.id])
        model.relatedRecords = try model.searchRelated("근거 메모")

        XCTAssertTrue(model.submit())
        let activityId = try XCTUnwrap(model.lastSavedId)
        let detail = try env.tasks.detail(taskId: task.id)
        XCTAssertEqual(detail.activities.count, 1)
        XCTAssertEqual(detail.activities.first?.projectIds, [platform.id])
        XCTAssertFalse(detail.activities.first?.body.isEmpty ?? true)

        let links = try RecordLinkStore(repo: env.repo).allLinks()
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(Set([links[0].first, links[0].second]),
                       Set([ref(.activity, activityId), ref(.memo, memo.id)]))
    }

    // MARK: - 상태 변경

    @MainActor
    func testChangeStatusWithoutBodySucceedsAndPreservesText() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "상태 업무")
        let model = CaptureModel(environment: env)
        model.kind = .task
        model.taskSelection = .existing(task.id)
        model.taskAction = .changeStatus
        XCTAssertEqual(model.availableStatusTargets(), [.inProgress, .onHold, .completed, .cancelled])

        model.text = "상태 변경 중에도 보존돼야 하는 본문"
        model.statusTarget = .inProgress
        XCTAssertTrue(model.submit())

        XCTAssertEqual(try env.tasks.currentStatus(taskId: task.id), .inProgress)
        XCTAssertEqual(model.text, "상태 변경 중에도 보존돼야 하는 본문", "상태 변경은 본문을 삭제하지 않는다")
        XCTAssertEqual(model.taskSelection, .newTask)
        XCTAssertNil(model.statusTarget)
        XCTAssertTrue(try env.tasks.detail(taskId: task.id).activities.isEmpty,
                      "상태 변경은 활동을 만들지 않는다")
    }

    @MainActor
    func testDisallowedStatusTransitionKeepsDraftAndSelection() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "완료 업무")
        _ = try env.tasks.completeTask(taskId: task.id, confirmRemaining: true)

        let model = CaptureModel(environment: env)
        model.kind = .task
        model.taskSelection = .existing(task.id)
        model.taskAction = .changeStatus
        XCTAssertEqual(model.availableStatusTargets(), [.inProgress], "완료에서 허용되는 전이는 재개뿐")

        model.statusTarget = .onHold
        model.text = "보존 초안"
        XCTAssertFalse(model.submit())
        XCTAssertEqual(try env.tasks.currentStatus(taskId: task.id), .completed)
        XCTAssertEqual(model.text, "보존 초안")
        XCTAssertEqual(model.taskSelection, .existing(task.id))
        XCTAssertEqual(model.statusTarget, .onHold)
        XCTAssertNotNil(model.errorMessage)
    }

    // MARK: - 완료 확인

    @MainActor
    func testCompletionConfirmationThenConfirmOrCancel() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "확인 업무", checklist: ["남은 항목"])
        let model = CaptureModel(environment: env)
        model.kind = .task
        model.taskSelection = .existing(task.id)
        model.taskAction = .changeStatus
        model.statusTarget = .completed

        XCTAssertFalse(model.submit(), "남은 항목이 있으면 먼저 확인이 필요하다")
        XCTAssertEqual(model.pendingCompletion?.remainingChecklist.count, 1)
        XCTAssertEqual(try env.tasks.currentStatus(taskId: task.id), .planned)

        model.cancelCompletion()
        XCTAssertNil(model.pendingCompletion)
        XCTAssertEqual(try env.tasks.currentStatus(taskId: task.id), .planned)
        XCTAssertEqual(model.taskSelection, .existing(task.id), "취소해도 선택은 유지")

        XCTAssertFalse(model.submit())
        XCTAssertNotNil(model.pendingCompletion)
        XCTAssertTrue(model.confirmCompletion())
        XCTAssertNil(model.pendingCompletion)
        XCTAssertEqual(try env.tasks.currentStatus(taskId: task.id), .completed)
        XCTAssertEqual(try env.tasks.detail(taskId: task.id).checklist.first?.done, false,
                       "남은 체크리스트를 자동 완료하지 않는다")
    }

    // MARK: - 메모 + 링크

    @MainActor
    func testMemoCapturesWithRelatedLink() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "연결 업무")
        let model = CaptureModel(environment: env)
        model.text = "메모 본문"
        model.relatedRecords = try model.searchRelated("연결 업무")
        XCTAssertEqual(model.relatedRecords.first?.reference, ref(.task, task.id))

        XCTAssertTrue(model.submit())
        let memoId = try XCTUnwrap(model.lastSavedId)
        XCTAssertEqual(try env.repo.memo(id: memoId)?.body, "메모 본문")
        let links = try RecordLinkStore(repo: env.repo).allLinks()
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(Set([links[0].first, links[0].second]),
                       Set([ref(.task, task.id), ref(.memo, memoId)]))
    }

    @MainActor
    func testMissingRelatedTargetRollsBackAndKeepsDraft() async throws {
        let env = try environment()
        let model = CaptureModel(environment: env)
        model.text = "롤백 메모"
        model.relatedRecords = [RelatedRecordCandidate(reference: ref(.task, "없는업무"),
                                                       title: "없는 업무")]
        XCTAssertFalse(model.submit())
        XCTAssertEqual(model.text, "롤백 메모", "실패 시 본문 보존")
        XCTAssertFalse(model.relatedRecords.isEmpty, "실패 시 관련 선택 보존")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(try env.repo.memos(on: env.calendar.workDate(of: env.options.clock.now())).isEmpty)
        XCTAssertTrue(try RecordLinkStore(repo: env.repo).allLinks().isEmpty)
    }

    // MARK: - Secret 기본값

    @MainActor
    func testSecretDefaultStillAllowsMemoSubmit() async throws {
        let env = try environment(defaultKind: .secret)
        let model = CaptureModel(environment: env)
        XCTAssertTrue(model.requiresSecretEditor)
        XCTAssertEqual(model.kind, .memo)
        model.text = "시크릿 기본값 메모"
        XCTAssertTrue(model.submit())
        let memoId = try XCTUnwrap(model.lastSavedId)
        XCTAssertEqual(try env.repo.memo(id: memoId)?.body, "시크릿 기본값 메모")
        let search = SearchModel(environment: env); search.text = "시크릿 기본값"; search.search()
        XCTAssertEqual(search.hits.count, 1)
    }
}
