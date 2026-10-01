import XCTest
@testable import WorkLogCore

final class PresentationTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }
    private func environment(provider: AIProvider? = nil, aiEnabled: Bool = true) throws -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PresentationTests-\(UUID().uuidString)")
        roots.append(root)
        let paths = AppPaths(dataRoot: root.appendingPathComponent("data"), backupRoot: root.appendingPathComponent("backups"))
        var settings = AppSettings(); settings.aiEnabled = aiEnabled
        try SettingsStore(fileURL: paths.settingsFile).save(settings)
        return try AppEnvironment.open(AppEnvironmentOptions(paths: paths, keyStore: InMemoryVaultKeyStore(),
            authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(), aiProvider: provider,
            clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_000)), ids: SequentialIDGenerator()))
    }

    @MainActor func testMemoPreservesOriginalAndRefreshesDayAndSearch() async throws {
        let env = try environment()
        let capture = CaptureModel(environment: env)
        let day = DayViewModel(environment: env)
        capture.text = "  배포 확인\n두 번째 줄  "
        XCTAssertTrue(capture.submit())
        XCTAssertEqual(capture.text, "")
        day.load()
        XCTAssertEqual(day.box?.memos.first?.body, "  배포 확인\n두 번째 줄  ")
        XCTAssertEqual(day.box?.timeline.count, 1)
        XCTAssertNil(day.box?.timeline.first?.effectiveTime)
        let search = SearchModel(environment: env); search.text = "배포"; search.search()
        XCTAssertEqual(search.hits.count, 1)
    }

    @MainActor func testAutocompleteSupportsSpacesAndResolvesRenamedStableID() async throws {
        let env = try environment()
        let project = try env.repo.createProject(name: "공통 인프라")
        let tag = try env.repo.findOrCreateTag(name: "검증")
        let model = CaptureModel(environment: env)
        model.text = "기록 @공통 인"
        XCTAssertEqual(model.candidates.first?.id, project.id)
        model.select(try XCTUnwrap(model.candidates.first))
        model.text += "#검"
        XCTAssertEqual(model.candidates.first?.id, tag.id)
        model.select(try XCTUnwrap(model.candidates.first))
        try env.repo.renameProject(id: project.id, to: "공통 플랫폼")
        XCTAssertTrue(model.submit())
        let memo = try XCTUnwrap(env.repo.memo(id: try XCTUnwrap(model.lastSavedId)))
        XCTAssertEqual(memo.projectIds, [project.id]); XCTAssertEqual(memo.tagIds, [tag.id])
        XCTAssertEqual(try env.repo.projects().count, 1)
        model.text = "person@example.com"
        XCTAssertTrue(model.candidates.isEmpty)
    }

    @MainActor func testDateNavigationUsesInjectedCalendarAndHistoricalStatus() async throws {
        let env = try environment()
        let day = DayViewModel(environment: env)
        let today = day.selectedDate
        let yesterday = env.calendar.adding(days: -1, to: today)
        let task = try env.tasks.createTask(title: "검증", workDate: yesterday)
        try env.tasks.changeTaskStatus(taskId: task.id, kind: .started, workDate: today)
        day.move(days: -1)
        XCTAssertEqual(day.selectedDate, yesterday); XCTAssertEqual(day.box?.tasks.first?.status, .planned)
        day.move(days: 1)
        XCTAssertEqual(day.selectedDate, today); XCTAssertEqual(day.box?.tasks.first?.status, .inProgress)
        day.move(days: -10); day.showToday(); XCTAssertEqual(day.selectedDate, today)
    }

    @MainActor func testInvalidCaptureRetainsDraftAndActivityRequiresTarget() async throws {
        let env = try environment(); let model = CaptureModel(environment: env)
        XCTAssertFalse(model.submit()); XCTAssertNotNil(model.errorMessage)
        model.kind = .activity; model.text = "확인 기록"
        XCTAssertFalse(model.submit()); XCTAssertEqual(model.text, "확인 기록")
        let task = try env.tasks.createTask(title: "대상")
        model.targetTaskId = task.id
        XCTAssertTrue(model.submit())
        XCTAssertEqual(try env.tasks.detail(taskId: task.id).activities.count, 1)
        XCTAssertEqual(try env.tasks.currentStatus(taskId: task.id), .planned)
    }

    @MainActor func testTaskCreationDoesNotInventStartDate() async throws {
        let env = try environment(); let capture = CaptureModel(environment: env)
        capture.kind = .task; capture.initialStatus = .completed; capture.text = "완료 업무\n근거"
        XCTAssertTrue(capture.submit())
        let detail = try env.tasks.detail(taskId: try XCTUnwrap(capture.lastSavedId))
        XCTAssertNil(detail.firstStartedOn); XCTAssertEqual(detail.completionDates.count, 1)
    }

    @MainActor func testCompletionRequiresConfirmationAndHistoryIsReadOnly() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "업무", checklist: ["남은 범위"])
        let model = TaskDetailModel(environment: env); model.load(taskId: task.id)
        model.complete()
        XCTAssertEqual(model.completionCheck?.remainingChecklist.count, 1)
        XCTAssertEqual(try env.tasks.currentStatus(taskId: task.id), .planned)
        model.complete(confirmRemaining: true)
        XCTAssertEqual(model.detail?.status, .completed)
        XCTAssertEqual(model.detail?.checklist.first?.done, false)
        let today = env.calendar.workDate(of: env.options.clock.now())
        model.load(taskId: task.id, asOf: today); model.changeStatus(.reopened)
        model.setChecklist(itemId: try XCTUnwrap(model.detail?.checklist.first?.item.id), done: true)
        XCTAssertEqual(try env.tasks.currentStatus(taskId: task.id), .completed)
        XCTAssertEqual(try env.tasks.detail(taskId: task.id).checklist.first?.done, false)
    }

    @MainActor func testSearchFiltersAreLocalAndAnswerOnlyRunsOnExplicitRequest() async throws {
        let provider = MockAIProvider(responses: [.groundedAnswer: """
        {"schemaVersion":1,"jobType":"grounded_answer","paragraphs":[],"missingEvidence":[],"warnings":[]}
        """])
        let env = try environment(provider: provider)
        _ = try env.tasks.captureMemo(body: "배포 확인", projectNames: ["플랫폼"], tagNames: ["검증"])
        _ = try env.tasks.createTask(title: "배포 업무")
        let model = SearchModel(environment: env)
        model.text = "배포"; model.search(); XCTAssertEqual(model.hits.count, 2)
        model.types = [.memo]; model.search(); XCTAssertEqual(model.hits.count, 1)
        XCTAssertEqual(provider.runCount, 0)
        await model.askAI(); XCTAssertEqual(provider.runCount, 1); XCTAssertNotNil(model.answer)
        model.text = "없음"; XCTAssertNil(model.answer); model.search()
        await model.askAI(); XCTAssertEqual(provider.runCount, 1)
        XCTAssertFalse(try XCTUnwrap(model.answer).missingEvidence.isEmpty)
    }

    @MainActor func testDisabledAIWithNilProviderAndSettingsNeverInvokesProvider() async throws {
        let nilModel = SearchModel(environment: try environment())
        nilModel.text = "기록"; await nilModel.askAI()
        XCTAssertFalse(nilModel.isAIAvailable); XCTAssertNotNil(nilModel.aiMessage)
        let provider = MockAIProvider()
        let disabled = SearchModel(environment: try environment(provider: provider, aiEnabled: false))
        disabled.text = "기록"; disabled.search(); await disabled.askAI()
        XCTAssertEqual(provider.runCount, 0); XCTAssertNotNil(disabled.aiMessage)
    }

    @MainActor func testNewProjectAndTagCreationAndActivityProjectScope() async throws {
        let env = try environment(); let model = CaptureModel(environment: env)
        model.text = "업무 @새 프로젝트"
        let candidate = try XCTUnwrap(model.candidates.first); XCTAssertTrue(candidate.isNew)
        model.select(candidate)
        model.text += "#새 태그"; model.select(try XCTUnwrap(model.candidates.first))
        model.kind = .task; model.projectTrackingMode = .perProject
        XCTAssertTrue(model.submit())
        let id = try XCTUnwrap(model.lastSavedId)
        let detail = try env.tasks.detail(taskId: id)
        XCTAssertEqual(detail.projects.count, 1); XCTAssertTrue(detail.projects[0].link.trackingEnabled)
        model.kind = .activity; model.targetTaskId = id; model.text = "확인 @새"
        XCTAssertEqual(model.candidates.first?.id, detail.projects[0].project.id)
        model.select(try XCTUnwrap(model.candidates.first)); XCTAssertTrue(model.submit())
        XCTAssertEqual(try env.tasks.detail(taskId: id).activities.first?.projectIds, [detail.projects[0].project.id])
        XCTAssertEqual(try env.tasks.currentStatus(taskId: id), .planned)
    }

    @MainActor func testProjectAndChecklistChangesNeverCompleteGlobalTask() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "공통 업무", projectNames: ["플랫폼"], trackingMode: .perProject)
        let model = TaskDetailModel(environment: env); model.load(taskId: task.id)
        let projectId = try XCTUnwrap(model.detail?.projects.first?.project.id)
        model.changeProjectStatus(projectId: projectId, kind: .completed)
        model.checklistText = "확인"; model.addChecklistItem()
        let itemId = try XCTUnwrap(model.detail?.checklist.first?.item.id)
        model.setChecklist(itemId: itemId, done: true)
        XCTAssertEqual(model.detail?.projects.first?.status, .completed)
        XCTAssertEqual(model.detail?.checklist.first?.done, true)
        XCTAssertEqual(model.detail?.status, .planned)
    }

    @MainActor func testMemoSuggestionIsExplicitAndDecisionPreservesSourceAndStatus() async throws {
        let provider = MockAIProvider(); let env = try environment(provider: provider)
        let task = try env.tasks.createTask(title: "관련 업무")
        let memo = try env.tasks.captureMemo(body: "논의 내용")
        let model = MemoDetailModel(environment: env); model.load(id: memo.id)
        XCTAssertEqual(provider.runCount, 0)
        await model.suggest(); XCTAssertEqual(provider.runCount, 1)
        let link = MemoTaskLink(id: "fake-link", memoId: memo.id, taskId: task.id, status: .proposed,
            reason: "관련 논의", sourceRevision: memo.revision, createdAt: env.options.clock.now())
        try env.repo.upsertMemoTaskLink(link); model.load(id: memo.id)
        model.decide(linkId: link.id, status: .accepted)
        XCTAssertEqual(model.links.first?.status, .accepted)
        XCTAssertEqual(try env.repo.memo(id: memo.id)?.body, "논의 내용")
        XCTAssertEqual(try env.tasks.currentStatus(taskId: task.id), .planned)
        XCTAssertEqual(provider.runCount, 1)
    }
}
