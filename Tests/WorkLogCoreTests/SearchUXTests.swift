import XCTest
@testable import WorkLogCore

/// UXFL-E55A C — 검색 Core: 결과의 프로젝트 이름, 선택 유지, 상태 복원, 빈 상태·AI 게이트.
final class SearchUXTests: XCTestCase {
    private let monday = WorkDate("2026-10-05")!
    private let tuesday = WorkDate("2026-10-06")!
    private let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private var roots: [URL] = []
    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func environment(provider: AIProvider? = nil, aiEnabled: Bool = true) throws -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchUXTests-\(UUID().uuidString)")
        roots.append(root)
        let paths = AppPaths(dataRoot: root.appendingPathComponent("data"),
                             backupRoot: root.appendingPathComponent("backups"))
        var settings = AppSettings(); settings.aiEnabled = aiEnabled
        try SettingsStore(fileURL: paths.settingsFile).save(settings)
        return try AppEnvironment.open(AppEnvironmentOptions(paths: paths, keyStore: InMemoryVaultKeyStore(),
            authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(), aiProvider: provider,
            clock: FixedClock(recordedAt), ids: SequentialIDGenerator()))
    }

    // MARK: - 1. 결과에 프로젝트 이름 채우기

    @MainActor func testSearchHitProjectNamesPerSourceType() async throws {
        let env = try environment()
        let alpha = try env.repo.createProject(name: "가나")
        let beta = try env.repo.createProject(name: "다라")
        let gamma = try env.repo.createProject(name: "감마")

        // memo → 연결 프로젝트(입력 순서와 무관하게 이름 오름차순·중복 제거)
        try env.repo.insertMemo(Memo(id: "memo-p", body: "프로젝트검색 메모", workDate: monday,
                                     recordedAt: recordedAt, projectIds: [beta.id, alpha.id]))

        // task → 제거되지 않은 연결 프로젝트
        try env.repo.insertTask(WorkTask(id: "task-p", title: "프로젝트검색 업무", createdAt: recordedAt))
        try env.repo.linkProject(taskId: "task-p", projectId: gamma.id, trackingEnabled: false, linkedOn: monday)

        // activity → 자체 프로젝트가 있으면 그것
        try env.repo.insertActivity(Activity(id: "act-own", taskId: "task-p", body: "프로젝트검색 진행 자체",
                                             workDate: monday, recordedAt: recordedAt, projectIds: [beta.id]))
        // activity → 자체 프로젝트가 없으면 소속 업무의 프로젝트
        try env.repo.insertActivity(Activity(id: "act-task", taskId: "task-p", body: "프로젝트검색 진행 업무",
                                             workDate: monday, recordedAt: recordedAt))

        // report → 항상 빈 배열
        try env.search.indexReport(versionId: "rv-p", text: "프로젝트검색 보고", workDate: monday)

        let hits = try env.search.search(SearchQuery(text: "프로젝트검색", limit: 50))
        let byId = Dictionary(uniqueKeysWithValues: hits.map { ($0.sourceId, $0) })
        XCTAssertEqual(byId["memo-p"]?.projectNames, ["가나", "다라"])
        XCTAssertEqual(byId["task-p"]?.projectNames, ["감마"])
        XCTAssertEqual(byId["act-own"]?.projectNames, ["다라"])
        XCTAssertEqual(byId["act-task"]?.projectNames, ["감마"])
        XCTAssertEqual(byId["rv-p"]?.projectNames, [])
    }

    @MainActor func testTaskProjectNamesExcludeRemovedLinks() async throws {
        let env = try environment()
        let kept = try env.repo.createProject(name: "남은프로젝트")
        let removed = try env.repo.createProject(name: "해제프로젝트")
        try env.repo.insertTask(WorkTask(id: "task-r", title: "해제검색 업무", createdAt: recordedAt))
        try env.repo.linkProject(taskId: "task-r", projectId: kept.id, trackingEnabled: false, linkedOn: monday)
        try env.repo.linkProject(taskId: "task-r", projectId: removed.id, trackingEnabled: false, linkedOn: monday)
        try env.repo.unlinkProject(taskId: "task-r", projectId: removed.id, removedOn: tuesday)

        let hit = try XCTUnwrap(try env.search.search(SearchQuery(text: "해제검색")).first)
        XCTAssertEqual(hit.projectNames, ["남은프로젝트"])
    }

    // MARK: - 2. 선택 유지 / 해제

    @MainActor func testSelectionKeptWhenSameHitRemainsAndClearedWhenGone() async throws {
        let env = try environment()
        try env.repo.insertMemo(Memo(id: "memo-1", body: "선택유지 배포 알파", workDate: monday, recordedAt: recordedAt))
        try env.repo.insertMemo(Memo(id: "memo-2", body: "선택유지 배포 베타", workDate: tuesday, recordedAt: recordedAt))
        let model = SearchModel(environment: env)
        model.text = "선택유지"; model.search()
        XCTAssertEqual(model.hits.count, 2)

        let second = try XCTUnwrap(model.hits.first { $0.sourceId == "memo-2" })
        model.select(second)
        XCTAssertEqual(model.selectedKey, second.key)
        XCTAssertEqual(model.selectedHit?.sourceId, "memo-2")

        // 갱신돼도 같은 결과가 남으면 선택 유지(다른 항목으로 자동 이동 없음)
        model.search()
        XCTAssertEqual(model.selectedHit?.sourceId, "memo-2")

        // 좁혀도 남으면 유지
        model.text = "선택유지 베타"; model.search()
        XCTAssertEqual(model.selectedHit?.sourceId, "memo-2")

        // 사라지면 해제
        model.text = "일치하는결과없음"; model.search()
        XCTAssertNil(model.selectedKey)
        XCTAssertNil(model.selectedHit)
    }

    @MainActor func testMoveSelectionFromNilAndClampsAtEnds() async throws {
        let env = try environment()
        for index in 1...3 {
            try env.repo.insertMemo(Memo(id: "move-\(index)", body: "이동테스트 \(index)번째",
                                         workDate: monday, recordedAt: recordedAt))
        }
        let model = SearchModel(environment: env)
        model.text = "이동테스트"; model.search()
        XCTAssertEqual(model.hits.count, 3)

        // nil에서 아래 → 첫 결과
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedHit?.sourceId, model.hits.first?.sourceId)
        // 아래로 이동
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedHit?.sourceId, model.hits[1].key.sourceId)
        // 끝에서 clamp
        model.moveSelection(by: 10)
        XCTAssertEqual(model.selectedHit?.sourceId, model.hits.last?.sourceId)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedHit?.sourceId, model.hits.last?.sourceId)
        // 위로 clamp
        model.moveSelection(by: -10)
        XCTAssertEqual(model.selectedHit?.sourceId, model.hits.first?.sourceId)

        // nil에서 위 → 마지막
        let fresh = SearchModel(environment: env)
        fresh.text = "이동테스트"; fresh.search()
        fresh.moveSelection(by: -1)
        XCTAssertEqual(fresh.selectedHit?.sourceId, fresh.hits.last?.sourceId)

        // 결과가 없으면 선택 없음
        fresh.text = "일치하는결과없음"; fresh.search()
        fresh.moveSelection(by: 1)
        XCTAssertNil(fresh.selectedKey)
    }

    @MainActor func testTogglePreviewRequiresSelection() async throws {
        let env = try environment()
        try env.repo.insertMemo(Memo(id: "preview-1", body: "미리보기검색 본문", workDate: monday, recordedAt: recordedAt))
        let model = SearchModel(environment: env)
        model.text = "미리보기검색"; model.search()
        model.togglePreview()
        XCTAssertFalse(model.isPreviewVisible)  // 선택 없으면 무시
        model.select(try XCTUnwrap(model.hits.first))
        model.togglePreview()
        XCTAssertTrue(model.isPreviewVisible)
        model.togglePreview()
        XCTAssertFalse(model.isPreviewVisible)
    }

    // MARK: - 3. 상태 복원

    @MainActor func testSnapshotRestoreRoundTripsFiltersAndSelectionWithoutAI() async throws {
        let provider = MockAIProvider()
        let env = try environment(provider: provider)
        let project = try env.repo.createProject(name: "복원프로젝트")
        try env.repo.insertMemo(Memo(id: "restore-1", body: "복원검색 알파", workDate: monday,
                                     recordedAt: recordedAt, projectIds: [project.id]))
        try env.repo.insertMemo(Memo(id: "restore-2", body: "복원검색 베타", workDate: tuesday, recordedAt: recordedAt))

        let model = SearchModel(environment: env)
        model.text = "복원검색"; model.types = [.memo]; model.projectIds = [project.id]
        model.search()
        XCTAssertEqual(model.hits.map(\.sourceId), ["restore-1"])
        model.select(try XCTUnwrap(model.hits.first))
        model.togglePreview()

        let state = model.snapshot()
        XCTAssertEqual(state.text, "복원검색")
        XCTAssertEqual(state.types, [.memo])
        XCTAssertEqual(state.projectIds, [project.id])
        XCTAssertEqual(state.selectedKey?.sourceId, "restore-1")
        XCTAssertTrue(state.isPreviewVisible)

        // 다른 상태로 흐트러뜨린 뒤 복원
        model.text = "다른검색어"; model.types = nil; model.projectIds = []; model.range = nil
        model.isPreviewVisible = false
        model.restore(state)

        XCTAssertEqual(model.text, "복원검색")
        XCTAssertEqual(model.types, [.memo])
        XCTAssertEqual(model.projectIds, [project.id])
        XCTAssertEqual(model.activeFilterCount, 2)
        XCTAssertEqual(model.hits.map(\.sourceId), ["restore-1"])
        XCTAssertEqual(model.selectedHit?.sourceId, "restore-1")
        XCTAssertTrue(model.isPreviewVisible)
        XCTAssertEqual(provider.runCount, 0)

        // 복원한 상태의 선택이 결과에 없으면 해제
        var stale = state
        stale.text = "일치하는결과없음"
        model.restore(stale)
        XCTAssertNil(model.selectedKey)
        XCTAssertNil(model.selectedHit)
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertEqual(provider.runCount, 0)
    }

    // MARK: - 4. 필터 개수·빈 상태

    @MainActor func testActiveFilterCountAndClearFilters() async throws {
        let env = try environment()
        let project = try env.repo.createProject(name: "필터프로젝트")
        let tag = try env.repo.findOrCreateTag(name: "필터태그")
        let model = SearchModel(environment: env)
        XCTAssertEqual(model.activeFilterCount, 0)

        model.types = [.memo]
        model.projectIds = [project.id]
        model.tagIds = [tag.id]
        model.range = DateRange(start: monday, endExclusive: tuesday)
        XCTAssertEqual(model.activeFilterCount, 4)

        model.clearFilters()
        XCTAssertEqual(model.activeFilterCount, 0)
        XCTAssertNil(model.types)
        XCTAssertTrue(model.projectIds.isEmpty)
        XCTAssertTrue(model.tagIds.isEmpty)
        XCTAssertNil(model.range)
    }

    @MainActor func testEmptyMessageReflectsQueryAndFilters() async throws {
        let env = try environment()
        let project = try env.repo.createProject(name: "빈상태프로젝트")
        let model = SearchModel(environment: env)

        // 검색어 없음 → nil
        XCTAssertNil(model.emptyMessage)

        model.text = "없는원문검색어"; model.search()
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertEqual(model.emptyMessage, "‘없는원문검색어’와 일치하는 원문이 없습니다")

        model.types = [.memo]; model.projectIds = [project.id]; model.search()
        XCTAssertEqual(model.activeFilterCount, 2)
        XCTAssertEqual(model.emptyMessage, "‘없는원문검색어’와 일치하는 원문이 없습니다 · 필터 2개 적용 중")

        // 결과가 생기면 nil
        try env.repo.insertMemo(Memo(id: "empty-1", body: "없는원문검색어 등장", workDate: monday,
                                     recordedAt: recordedAt, projectIds: [project.id]))
        model.search()
        XCTAssertFalse(model.hits.isEmpty)
        XCTAssertNil(model.emptyMessage)

        // 공백뿐인 검색어 → nil
        model.text = "   "; model.search()
        XCTAssertNil(model.emptyMessage)
    }

    // MARK: - 5. AI 게이트

    @MainActor func testCanAskAIConditionsAndSearchNeverInvokesProvider() async throws {
        let provider = MockAIProvider()
        let env = try environment(provider: provider)
        try env.repo.insertMemo(Memo(id: "ai-1", body: "AI호출검색 배포", workDate: monday, recordedAt: recordedAt))
        let tag = try env.repo.findOrCreateTag(name: "AI태그")
        let model = SearchModel(environment: env)

        XCTAssertTrue(model.isAIAvailable)
        XCTAssertFalse(model.canAskAI)  // 검색어 없음

        model.text = "AI호출검색"; model.search()
        XCTAssertEqual(provider.runCount, 0)  // search()는 제공자를 호출하지 않는다
        XCTAssertTrue(model.canAskAI)

        model.text = "일치하는결과없음"; model.search()
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertEqual(provider.runCount, 0)  // 결과 없음도 호출하지 않는다
        XCTAssertTrue(model.canAskAI)  // 검색어가 있으면 요청은 가능

        model.tagIds = [tag.id]
        XCTAssertFalse(model.canAskAI)  // 태그 필터가 있으면 불가
        await model.askAI()
        XCTAssertEqual(provider.runCount, 0)

        model.tagIds = []
        model.text = "   "
        XCTAssertFalse(model.canAskAI)
        await model.askAI()
        XCTAssertEqual(provider.runCount, 0)
        XCTAssertEqual(model.aiMessage, "질문할 내용을 입력하세요.")
    }

    @MainActor func testCanAskAIIsFalseWhenAIDisabled() async throws {
        let model = SearchModel(environment: try environment())
        XCTAssertFalse(model.isAIAvailable)
        model.text = "질문"
        XCTAssertFalse(model.canAskAI)
    }
}
