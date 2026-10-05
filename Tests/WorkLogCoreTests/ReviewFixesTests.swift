import XCTest
@testable import WorkLogCore

/// UXFL-E55A N — 리뷰 L 경미 지적 수정의 회귀 테스트.
///
/// - SecretsModel: 불릿/가림 문자만 있는 값은 길이와 무관하게 저장을 거부하고,
///   일반 문자로도 쓰이는 `*`는 허용한다. 거부 시 다른 행·입력은 보존한다.
/// - CaptureModel.confirmCompletion: 완료 확인 성공 시에만 업무일을 오늘로 되돌린다.
/// - SearchIndex.search: 행별 프로젝트 이름 조회 실패가 전체 검색 실패로 번지지 않는다.
///
/// 모든 값은 테스트용 가짜 값이다.
final class ReviewFixesTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func environment(defaultKind: CaptureKind = .memo) throws -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewFixesTests-\(UUID().uuidString)")
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

    // MARK: - SecretsModel 가림 문자 판정

    @MainActor
    func testShortBulletMaskIsRejectedAndInputPreserved() async throws {
        let env = try environment()
        let model = SecretsModel(environment: env)
        await model.unlock()
        model.title = "마스크 테스트"
        model.addRow()
        model.rows[0].key = "MASKED"
        let rowId = model.rows[0].id

        for mask in ["••", "•", "●", "∙"] {
            model.rows[0].value = mask
            XCTAssertFalse(model.save(), "가림 문자만 있는 값은 거부해야 한다: \(mask)")
            XCTAssertEqual(model.maskedRowIds, Set([rowId]))
            XCTAssertEqual(model.rows[0].value, mask, "거부해도 입력은 보존한다")
            XCTAssertTrue(model.titles.isEmpty)
        }
    }

    @MainActor
    func testAsteriskOnlyValueIsSaved() async throws {
        let env = try environment()
        let model = SecretsModel(environment: env)
        await model.unlock()
        model.title = "별표 테스트"
        model.addRow()
        model.rows[0].key = "FLAG"
        model.rows[0].value = "***"

        XCTAssertTrue(model.save(), "일반 문자로 쓰이는 *는 저장을 허용한다")
        XCTAssertTrue(model.maskedRowIds.isEmpty)
        XCTAssertEqual(model.titles.map(\.title), ["별표 테스트"])
    }

    @MainActor
    func testMixedBulletValueIsSaved() async throws {
        let env = try environment()
        let model = SecretsModel(environment: env)
        await model.unlock()
        model.title = "혼합 테스트"
        model.addRow()
        model.rows[0].key = "K"
        model.rows[0].value = "a•b"

        XCTAssertTrue(model.save(), "불릿이 섞여도 다른 문자가 있으면 저장한다")
        XCTAssertTrue(model.maskedRowIds.isEmpty)
    }

    @MainActor
    func testRejectionPreservesOtherRowsAndNotifiesOnlyMaskedRow() async throws {
        let env = try environment()
        let model = SecretsModel(environment: env)
        await model.unlock()
        model.title = "보존 테스트"
        model.addRow()
        model.rows[0].key = "GOOD"
        model.rows[0].value = "real-value"
        model.addRow()
        model.rows[1].key = "MASK"
        model.rows[1].value = "●"
        let goodId = model.rows[0].id
        let maskId = model.rows[1].id

        XCTAssertFalse(model.save())
        XCTAssertEqual(model.rows.map(\.id), [goodId, maskId], "행을 지우지 않는다")
        XCTAssertEqual(model.rows[0].value, "real-value")
        XCTAssertEqual(model.rows[1].value, "●")
        XCTAssertEqual(model.maskedRowIds, Set([maskId]))
        XCTAssertTrue(model.titles.isEmpty)

        model.rows[1].value = "fixed"
        XCTAssertTrue(model.save())
        XCTAssertTrue(model.maskedRowIds.isEmpty)
    }

    // MARK: - CaptureModel.confirmCompletion 업무일

    @MainActor
    func testConfirmCompletionSuccessResetsWorkDateToToday() throws {
        let env = try environment()
        let today = env.calendar.workDate(of: env.options.clock.now())
        let yesterday = env.calendar.adding(days: -1, to: today)
        let task = try env.tasks.createTask(title: "확인 업무", workDate: yesterday, checklist: ["남은 항목"])
        let model = CaptureModel(environment: env)
        model.kind = .task
        model.taskSelection = .existing(task.id)
        model.taskAction = .changeStatus
        model.statusTarget = .completed
        model.workDate = yesterday

        XCTAssertFalse(model.submit(), "남은 항목이 있으면 먼저 확인이 필요하다")
        XCTAssertNotNil(model.pendingCompletion)
        XCTAssertEqual(model.workDate, yesterday, "확인 대기 중에는 작업일을 유지한다")

        XCTAssertTrue(model.confirmCompletion())
        XCTAssertEqual(model.workDate, today, "완료 확인 성공 시 오늘로 되돌린다")
    }

    @MainActor
    func testConfirmCompletionFailureKeepsWorkDate() throws {
        let env = try environment()
        let today = env.calendar.workDate(of: env.options.clock.now())
        let yesterday = env.calendar.adding(days: -1, to: today)
        let task = try env.tasks.createTask(title: "실패 업무", workDate: yesterday, checklist: ["남은 항목"])
        let model = CaptureModel(environment: env)
        model.kind = .task
        model.taskSelection = .existing(task.id)
        model.taskAction = .changeStatus
        model.statusTarget = .completed
        model.workDate = yesterday

        XCTAssertFalse(model.submit())
        XCTAssertNotNil(model.pendingCompletion)

        // 대상 업무가 사라지면 completeTask가 실패한다. 실패 시 작업일을 바꾸지 않는다.
        try env.repo.db.run("DELETE FROM task WHERE id = ?", [task.id])
        XCTAssertFalse(model.confirmCompletion())
        XCTAssertEqual(model.workDate, yesterday, "실패하면 작업일을 유지한다")
        XCTAssertNotNil(model.pendingCompletion)
        XCTAssertNotNil(model.errorMessage)
    }

    // MARK: - SearchIndex.search 행별 조회 실패 격리

    func testSearchRowProjectNameFailureDoesNotFailWholeSearch() throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let repo = try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator())
        let index = try SearchIndex(repo: repo)
        let monday = WorkDate("2026-10-05")!
        try repo.insertMemo(Memo(id: "memo-x", body: "회복탄력성검색어", workDate: monday,
                                 recordedAt: clock.now()))

        // 프로젝트 조인 테이블을 없애 행별 projectNames 조회가 실패하게 만든다.
        // 검색 자체는 문서 테이블에서 조회하므로 결과가 사라지면 안 된다.
        try repo.db.run("DROP TABLE memo_project", [])

        let hits = try index.search(SearchQuery(text: "회복탄력성검색어"))
        XCTAssertEqual(hits.map(\.sourceId), ["memo-x"])
        XCTAssertEqual(hits.first?.projectNames, [])
    }
}
