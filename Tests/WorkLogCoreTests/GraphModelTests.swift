import XCTest
@testable import WorkLogCore

/// I: 그래프 화면 Presentation 모델(GraphModel).
///
/// - 로딩·빈·오류·필터·선택·잘림 상태.
/// - 순수 DTO만 `GraphLayout`에 넘기고, 좌표 계산은 메인 액터 밖에서 비동기로 수행한다.
/// - `member`는 `reload()`가 돌려준 `Task`를 `await ...value`로 기다린 뒤 단언한다.
/// - 오래된 계산 결과 무시를 위한 generation 카운터와 detach를 검증한다.
final class GraphModelTests: XCTestCase {

    private var roots: [URL] = []
    private let today = WorkDate("2026-10-05")!

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    // MARK: - 픽스처

    /// 고정 시각이 오늘이 되도록 하는 AppEnvironment.
    private func makeEnvironment() throws -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphModelTests-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let paths = AppPaths(dataRoot: root.appendingPathComponent("data", isDirectory: true),
                             backupRoot: root.appendingPathComponent("backups", isDirectory: true))
        let now = WorkCalendar().startOfDay(today).addingTimeInterval(9 * 3600)
        return try AppEnvironment.open(AppEnvironmentOptions(
            paths: paths,
            keyStore: InMemoryVaultKeyStore(),
            authenticator: MockDeviceAuthenticator(),
            pasteboard: InMemoryPasteboard(),
            aiProvider: nil,
            clock: FixedClock(now),
            ids: SequentialIDGenerator(prefix: "g")))
    }

    private func at(_ env: AppEnvironment, _ date: WorkDate, hour: Int = 9) -> Date {
        env.calendar.startOfDay(date).addingTimeInterval(TimeInterval(hour * 3600))
    }

    @discardableResult
    private func seedMemo(_ env: AppEnvironment, id: String, body: String,
                          date: WorkDate) throws -> Memo {
        let memo = Memo(id: id, body: body, workDate: date, recordedAt: at(env, date))
        try env.repo.insertMemo(memo)
        return memo
    }

    @discardableResult
    private func seedTask(_ env: AppEnvironment, id: String, title: String,
                          date: WorkDate) throws -> WorkTask {
        let task = WorkTask(id: id, title: title, createdAt: at(env, date))
        try env.repo.insertTask(task)
        return task
    }

    @discardableResult
    private func seedActivity(_ env: AppEnvironment, id: String, taskId: String, body: String,
                              date: WorkDate) throws -> Activity {
        let activity = Activity(id: id, taskId: taskId, body: body, workDate: date,
                                recordedAt: at(env, date, hour: 10))
        try env.repo.insertActivity(activity)
        return activity
    }

    private func acceptMemoTask(_ env: AppEnvironment, id: String, memoId: String, taskId: String,
                                date: WorkDate) throws {
        try env.repo.upsertMemoTaskLink(MemoTaskLink(
            id: id, memoId: memoId, taskId: taskId, status: .accepted, reason: "",
            sourceRevision: 1, createdAt: at(env, date, hour: 11)))
    }

    private func relate(_ env: AppEnvironment, id: String, from: String, to: String,
                        date: WorkDate) throws {
        try env.repo.insertRelation(TaskRelation(
            id: id, fromTaskId: from, toTaskId: to, type: .related, createdAt: at(env, date, hour: 12)))
    }

    private func node(_ kind: GraphNodeKind, _ id: String) -> GraphNodeID {
        GraphNodeID(kind: kind, id: id)
    }

    @MainActor
    private func memoIDs(_ model: GraphModel) -> Set<String> {
        Set(model.snapshot.nodes.filter { $0.id.kind == .memo }.map(\.id.id))
    }

    // MARK: 1. reload 성공 → loaded, 모든 노드 좌표

    @MainActor
    func testReloadSuccessIsLoadedAndCoversAllNodes() async throws {
        let env = try makeEnvironment()
        try seedMemo(env, id: "m1", body: "메모", date: today)
        try seedTask(env, id: "t1", title: "업무", date: today)
        try seedActivity(env, id: "a1", taskId: "t1", body: "활동", date: today)

        let model = GraphModel(environment: env)
        XCTAssertEqual(model.phase, .idle)
        await model.reload().value

        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(Set(model.snapshot.nodes.map(\.id)),
                       [node(.memo, "m1"), node(.task, "t1"), node(.activity, "a1")])
        XCTAssertEqual(Set(model.positions.keys), Set(model.snapshot.nodes.map(\.id)))
        XCTAssertFalse(model.isTruncated)
        XCTAssertNil(model.selectedNodeID)
    }

    // MARK: 2. 데이터 없음 → empty

    @MainActor
    func testReloadWithoutDataIsEmpty() async throws {
        let env = try makeEnvironment()
        let model = GraphModel(environment: env)
        await model.reload().value

        XCTAssertEqual(model.phase, .empty)
        XCTAssertTrue(model.snapshot.nodes.isEmpty)
        XCTAssertTrue(model.positions.isEmpty)
        XCTAssertFalse(model.isTruncated)
    }

    // MARK: 3. 기간 프리셋별 조회 범위

    @MainActor
    func testRangePresetsFilterByWorkDate() async throws {
        let env = try makeEnvironment()
        let d0 = today
        let d10 = env.calendar.adding(days: -10, to: today)
        let d40 = env.calendar.adding(days: -40, to: today)
        let d100 = env.calendar.adding(days: -100, to: today)
        try seedMemo(env, id: "m0", body: "오늘", date: d0)
        try seedMemo(env, id: "m10", body: "10일 전", date: d10)
        try seedMemo(env, id: "m40", body: "40일 전", date: d40)
        try seedMemo(env, id: "m100", body: "100일 전", date: d100)

        let model = GraphModel(environment: env)

        model.rangePreset = .week
        await model.reload().value
        XCTAssertEqual(memoIDs(model), ["m0"])

        model.rangePreset = .month
        await model.reload().value
        XCTAssertEqual(memoIDs(model), ["m0", "m10"])

        model.rangePreset = .quarter
        await model.reload().value
        XCTAssertEqual(memoIDs(model), ["m0", "m10", "m40"])

        model.rangePreset = .all
        await model.reload().value
        XCTAssertEqual(memoIDs(model), ["m0", "m10", "m40", "m100"])

        XCTAssertEqual(model.phase, .loaded)
    }

    /// 프리셋 → DateRange 계약을 직접 확인한다. all은 nil(전체).
    @MainActor
    func testRangeHelperMatchesPresetContract() async throws {
        let env = try makeEnvironment()
        let calendar = env.calendar

        let week = try XCTUnwrap(GraphModel.range(for: .week, calendar: calendar, today: today))
        XCTAssertEqual(week.start, calendar.adding(days: -6, to: today))
        XCTAssertEqual(week.endExclusive, calendar.adding(days: 1, to: today))
        XCTAssertTrue(week.contains(today))

        let month = try XCTUnwrap(GraphModel.range(for: .month, calendar: calendar, today: today))
        XCTAssertEqual(month.start, calendar.adding(days: -29, to: today))
        XCTAssertTrue(month.contains(today))

        let quarter = try XCTUnwrap(GraphModel.range(for: .quarter, calendar: calendar, today: today))
        XCTAssertEqual(quarter.start, calendar.adding(days: -89, to: today))
        XCTAssertTrue(quarter.contains(today))

        XCTAssertNil(GraphModel.range(for: .all, calendar: calendar, today: today))

        XCTAssertEqual(GraphModel.RangePreset.allCases.map(\.label),
                       ["최근 7일", "최근 30일", "최근 90일", "전체"])
    }

    // MARK: 4. visibleKinds 반영

    @MainActor
    func testVisibleKindsFilterNodesAndEdges() async throws {
        let env = try makeEnvironment()
        try seedMemo(env, id: "m1", body: "메모", date: today)
        try seedTask(env, id: "t1", title: "업무", date: today)
        try seedActivity(env, id: "a1", taskId: "t1", body: "활동", date: today)

        let model = GraphModel(environment: env)
        XCTAssertEqual(model.visibleKinds,
                       [.memo, .task, .activity, .reportVersion, .project, .tag])

        model.visibleKinds = [.memo]
        await model.reload().value
        XCTAssertEqual(model.snapshot.nodes.map(\.id), [node(.memo, "m1")])
        XCTAssertTrue(model.snapshot.edges.isEmpty, "끝점이 빠지면 소속 엣지도 사라진다")

        model.visibleKinds = [.memo, .task, .activity]
        await model.reload().value
        XCTAssertEqual(Set(model.snapshot.nodes.map(\.id)),
                       [node(.memo, "m1"), node(.task, "t1"), node(.activity, "a1")])
        XCTAssertEqual(model.snapshot.edges.map(\.kind), [.activityTask])
    }

    // MARK: 5. 선택 유지·소실

    @MainActor
    func testSelectionIsPreservedAndClearedWhenMissing() async throws {
        let env = try makeEnvironment()
        let m10 = env.calendar.adding(days: -10, to: today)
        try seedMemo(env, id: "m1", body: "오늘", date: today)
        try seedMemo(env, id: "m2", body: "10일 전", date: m10)

        let model = GraphModel(environment: env)
        model.rangePreset = .month
        await model.reload().value
        XCTAssertEqual(memoIDs(model), ["m1", "m2"])

        model.select(node(.memo, "m2"))
        XCTAssertEqual(model.selectedNodeID, node(.memo, "m2"))
        XCTAssertEqual(model.selectedNode?.id, node(.memo, "m2"))

        // 같은 데이터로 다시 불러오면 선택이 유지된다.
        await model.reload().value
        XCTAssertEqual(model.selectedNodeID, node(.memo, "m2"))

        // 범위를 좁혀 m2가 빠지면 선택이 지워진다.
        model.rangePreset = .week
        await model.reload().value
        XCTAssertNil(model.selectedNodeID)
        XCTAssertNil(model.selectedNode)
    }

    // MARK: 6. focus 2-hop 및 clear

    @MainActor
    func testFocusKeepsTwoHopsAndClearRestoresAll() async throws {
        let env = try makeEnvironment()
        try seedMemo(env, id: "m1", body: "중심 메모", date: today)
        try seedMemo(env, id: "m2", body: "고립 메모", date: today)
        try seedTask(env, id: "t1", title: "1홉", date: today)
        try seedTask(env, id: "t2", title: "2홉", date: today)
        try seedTask(env, id: "t3", title: "3홉", date: today)
        try acceptMemoTask(env, id: "l1", memoId: "m1", taskId: "t1", date: today)
        try relate(env, id: "r1", from: "t1", to: "t2", date: today)
        try relate(env, id: "r2", from: "t2", to: "t3", date: today)

        let model = GraphModel(environment: env)
        await model.reload().value
        XCTAssertEqual(model.snapshot.nodes.count, 5)

        model.select(node(.memo, "m1"))
        await model.focusOnSelection().value
        XCTAssertEqual(model.focus, node(.memo, "m1"))
        XCTAssertEqual(Set(model.snapshot.nodes.map(\.id)),
                       [node(.memo, "m1"), node(.task, "t1"), node(.task, "t2")])

        await model.clearFocus().value
        XCTAssertNil(model.focus)
        XCTAssertEqual(Set(model.snapshot.nodes.map(\.id)),
                       [node(.memo, "m1"), node(.memo, "m2"),
                        node(.task, "t1"), node(.task, "t2"), node(.task, "t3")])
    }

    // MARK: 7. neighbors 정렬·대응 노드

    @MainActor
    func testNeighborsAreEdgeKeySortedWithOppositeNode() async throws {
        let env = try makeEnvironment()
        try seedMemo(env, id: "m1", body: "메모", date: today)
        try seedTask(env, id: "t1", title: "업무", date: today)
        try seedActivity(env, id: "a1", taskId: "t1", body: "활동1", date: today)
        try seedActivity(env, id: "a2", taskId: "t1", body: "활동2", date: today)
        try acceptMemoTask(env, id: "l1", memoId: "m1", taskId: "t1", date: today)

        let model = GraphModel(environment: env)
        await model.reload().value

        let neighbors = model.neighbors(of: node(.task, "t1"))
        XCTAssertEqual(neighbors.count, 3)
        XCTAssertEqual(neighbors.map(\.edge.key), neighbors.map(\.edge.key).sorted())
        XCTAssertEqual(Set(neighbors.map(\.node.id)),
                       [node(.memo, "m1"), node(.activity, "a1"), node(.activity, "a2")])
        for pair in neighbors {
            XCTAssertTrue(pair.edge.from == node(.task, "t1") || pair.edge.to == node(.task, "t1"))
        }

        // 엣지가 없는 노드의 이웃은 비어 있다.
        XCTAssertTrue(model.neighbors(of: node(.activity, "a1")).count == 1)
    }

    // MARK: 8. listedNodes 검색·정렬

    @MainActor
    func testListedNodesFilterBySearchTextAndSortByKindThenTitle() async throws {
        let env = try makeEnvironment()
        try seedMemo(env, id: "m1", body: "알파", date: today)
        try seedMemo(env, id: "m2", body: "베타", date: today)
        try seedTask(env, id: "t1", title: "베타 업무", date: today)

        let model = GraphModel(environment: env)
        await model.reload().value
        // kind 순위(memo→task) 뒤 제목을 Swift 문자열 순서로 비교한다(결정적).
        XCTAssertEqual(model.listedNodes.map(\.title), ["베타", "알파", "베타 업무"])

        model.searchText = "베타"
        XCTAssertEqual(model.listedNodes.map(\.title), ["베타", "베타 업무"])

        model.searchText = "  "
        XCTAssertEqual(model.listedNodes.count, 3, "공백뿐인 검색어는 필터하지 않는다")

        model.searchText = "없는제목"
        XCTAssertTrue(model.listedNodes.isEmpty)
    }

    // MARK: 9. 250개 상한과 잘림 표시

    @MainActor
    func testReloadMarksTruncationAtNodeLimit() async throws {
        let env = try makeEnvironment()
        for index in 0..<251 {
            try seedMemo(env, id: String(format: "m%03d", index), body: "메모 \(index)", date: today)
        }

        let model = GraphModel(environment: env)
        model.layoutConfiguration = GraphLayoutConfiguration(iterations: 1, width: 100, height: 100)
        await model.reload().value

        XCTAssertEqual(model.phase, .loaded)
        XCTAssertTrue(model.isTruncated)
        XCTAssertEqual(model.snapshot.nodes.count, GraphModel.nodeLimit)
        XCTAssertEqual(model.positions.count, GraphModel.nodeLimit)
    }

    // MARK: 10. detach 후 reload 무해

    @MainActor
    func testDetachThenReloadIsHarmless() async throws {
        let env = try makeEnvironment()
        try seedMemo(env, id: "m1", body: "메모", date: today)

        let model = GraphModel(environment: env)
        await model.reload().value
        XCTAssertEqual(model.phase, .loaded)

        model.detach()
        await model.reload().value
        XCTAssertEqual(model.phase, .loaded, "detach 후 reload는 상태를 바꾸지 않는다")
        XCTAssertTrue(model.snapshot.nodes.contains { $0.id == node(.memo, "m1") })
    }

    // MARK: 10b. 빠른 연속 reload → 마지막 결과만 반영

    @MainActor
    func testRapidReloadAppliesOnlyLastResult() async throws {
        let env = try makeEnvironment()
        let d10 = env.calendar.adding(days: -10, to: today)
        try seedMemo(env, id: "m0", body: "오늘", date: today)
        try seedMemo(env, id: "m10", body: "10일 전", date: d10)

        let model = GraphModel(environment: env)

        // 첫 reload(week)의 결과가 나중에 도착해도, 두 번째 reload(all)가
        // 이미 세대를 올렸으므로 반영되지 않아야 한다.
        model.rangePreset = .week
        let first = model.reload()
        model.rangePreset = .all
        let second = model.reload()

        await first.value
        await second.value

        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(memoIDs(model), ["m0", "m10"], "마지막 reload의 결과만 반영된다")
    }

    // MARK: 11. 라벨·심볼 헬퍼

    @MainActor
    func testLabelAndSymbolHelpers() async throws {
        XCTAssertEqual(GraphModel.label(for: .activityTask), "진행기록")
        XCTAssertEqual(GraphModel.label(for: .acceptedMemoTask), "승인된 메모 연결")
        XCTAssertEqual(GraphModel.label(for: .manualRelated), "직접 연결")
        XCTAssertEqual(GraphModel.label(for: .reportEvidence), "리포트 근거")
        XCTAssertEqual(GraphModel.label(for: .projectMembership), "프로젝트")
        XCTAssertEqual(GraphModel.label(for: .tagMembership), "태그")
        XCTAssertEqual(GraphModel.label(for: .taskRelated), "관련 업무")
        XCTAssertEqual(GraphModel.label(for: .taskFollowUp), "후속 업무")
        XCTAssertEqual(GraphModel.label(for: .supplementTask), "성과 보충")

        XCTAssertEqual(GraphModel.symbol(for: .memo), "note.text")
        XCTAssertEqual(GraphModel.symbol(for: .task), "checklist")
        XCTAssertEqual(GraphModel.symbol(for: .activity), "clock.arrow.circlepath")
        XCTAssertEqual(GraphModel.symbol(for: .reportVersion), "doc.text")
        XCTAssertEqual(GraphModel.symbol(for: .project), "folder")
        XCTAssertEqual(GraphModel.symbol(for: .tag), "number")
        XCTAssertEqual(GraphModel.symbol(for: .supplement), "star")
        XCTAssertEqual(GraphModel.symbol(for: .historicalSource), "clock.badge.questionmark")
    }
}
