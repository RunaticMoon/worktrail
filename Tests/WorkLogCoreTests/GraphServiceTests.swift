import XCTest
@testable import WorkLogCore

/// GraphService: 세 소스(D/E/F) 병합·필터·상한·고아 엣지 정리.
///
/// - 노드·엣지 중복 없음, records 우선 노드 병합.
/// - 수동 링크 엣지 계약(방향·sourceKey)과 끝점 없는 링크 제거.
/// - accepted 관계와 수동 링크가 같은 두 노드에서 공존.
/// - kinds / project / tag / focus 필터.
/// - nodeLimit 잘림·isTruncated·결정성, 고아 엣지 없음.
/// - Secret canary가 결과 어디에도 없음.
final class GraphServiceTests: XCTestCase {

    private let monday = WorkDate("2026-10-05")!
    private let tuesday = WorkDate("2026-10-06")!
    private let wednesday = WorkDate("2026-10-07")!
    private let week = DateRange(start: WorkDate("2026-10-05")!, endExclusive: WorkDate("2026-10-12")!)
    private let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - 픽스처

    private func makeRepo() throws -> WorkRepository {
        try WorkRepository.inMemory(clock: FixedClock(fixedNow),
                                    ids: SequentialIDGenerator())
    }

    private func at(_ repo: WorkRepository, _ date: WorkDate, hour: Int = 9) -> Date {
        repo.calendar.startOfDay(date).addingTimeInterval(TimeInterval(hour * 3600))
    }

    private func makeStore(_ repo: WorkRepository) -> RecordLinkStore {
        RecordLinkStore(repo: repo, clock: FixedClock(fixedNow), ids: SequentialIDGenerator(prefix: "rl"))
    }

    @discardableResult
    private func seedMemo(_ repo: WorkRepository, id: String, body: String = "메모",
                          date: WorkDate = WorkDate("2026-10-05")!,
                          projectIds: [String] = [], tagIds: [String] = []) throws -> Memo {
        let memo = Memo(id: id, body: body, workDate: date, recordedAt: at(repo, date),
                        projectIds: projectIds, tagIds: tagIds)
        try repo.insertMemo(memo)
        return memo
    }

    @discardableResult
    private func seedTask(_ repo: WorkRepository, id: String, title: String = "업무",
                          date: WorkDate = WorkDate("2026-10-05")!,
                          tagIds: [String] = []) throws -> WorkTask {
        let task = WorkTask(id: id, title: title, createdAt: at(repo, date), tagIds: tagIds)
        try repo.insertTask(task)
        return task
    }

    @discardableResult
    private func seedActivity(_ repo: WorkRepository, id: String, taskId: String,
                              body: String = "활동", date: WorkDate = WorkDate("2026-10-05")!,
                              projectIds: [String] = []) throws -> Activity {
        let activity = Activity(id: id, taskId: taskId, body: body, workDate: date,
                                recordedAt: at(repo, date, hour: 10), projectIds: projectIds)
        try repo.insertActivity(activity)
        return activity
    }

    private func acceptMemoTask(_ repo: WorkRepository, id: String, memoId: String, taskId: String,
                                date: WorkDate = WorkDate("2026-10-05")!) throws {
        try repo.upsertMemoTaskLink(MemoTaskLink(id: id, memoId: memoId, taskId: taskId,
                                                 status: .accepted, reason: "", sourceRevision: 1,
                                                 createdAt: at(repo, date)))
    }

    private func relate(_ repo: WorkRepository, id: String, from: String, to: String,
                        type: TaskRelationType = .related,
                        date: WorkDate = WorkDate("2026-10-05")!) throws {
        try repo.insertRelation(TaskRelation(id: id, fromTaskId: from, toTaskId: to,
                                             type: type, createdAt: at(repo, date)))
    }

    /// 리포트·스냅샷·버전·근거를 만든다. 근거 대상은 이미 존재하는 원본이어야 한다.
    @discardableResult
    private func seedReportVersion(_ repo: WorkRepository, reportId: String, versionId: String,
                                   evidence: [(itemId: String, sourceId: String)],
                                   createdAt: Date) throws -> ReportVersion {
        try repo.insertSourceSnapshot(SourceSnapshot(
            id: "snap-\(versionId)", range: week, stateCutoff: createdAt, knownAt: createdAt,
            frozenFactsJSON: "{}", digest: "digest-\(versionId)", createdAt: createdAt))
        try repo.insertReport(Report(id: reportId, family: .submission, periodType: .weekly,
                                     periodKey: "2026-W41", range: week, createdAt: createdAt))
        let version = ReportVersion(id: versionId, reportId: reportId, version: 1, state: .draft,
                                    content: "content", sourceSnapshotId: "snap-\(versionId)",
                                    generator: "deterministic", createdAt: createdAt)
        try repo.insertReportVersion(version)
        if !evidence.isEmpty {
            try repo.insertReportEvidence(evidence.map {
                ReportEvidenceRow(reportVersionId: versionId, itemId: $0.itemId, taskId: nil,
                                  sourceId: $0.sourceId, sourceRevision: 1)
            })
        }
        return version
    }

    private func nodeByID(_ snapshot: GraphSnapshot) -> [GraphNodeID: GraphNode] {
        Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
    }

    private func assertConsistent(_ snapshot: GraphSnapshot,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let ids = Set(snapshot.nodes.map(\.id))
        XCTAssertEqual(ids.count, snapshot.nodes.count, "중복 노드가 없다", file: file, line: line)
        XCTAssertEqual(snapshot.nodes.map(\.id.key), snapshot.nodes.map(\.id.key).sorted(),
                       "노드는 id.key 오름차순", file: file, line: line)
        let keys = Set(snapshot.edges.map(\.key))
        XCTAssertEqual(keys.count, snapshot.edges.count, "중복 엣지가 없다", file: file, line: line)
        XCTAssertEqual(snapshot.edges.map(\.key), snapshot.edges.map(\.key).sorted(),
                       "엣지는 key 오름차순", file: file, line: line)
        for edge in snapshot.edges {
            XCTAssertTrue(ids.contains(edge.from), "고아 엣지 from: \(edge.key)", file: file, line: line)
            XCTAssertTrue(ids.contains(edge.to), "고아 엣지 to: \(edge.key)", file: file, line: line)
        }
    }

    // MARK: 1. 세 소스 병합·중복 없음

    func testMergesRecordsEvidenceAndManualLinksWithoutDuplicates() throws {
        let repo = try makeRepo()
        try seedMemo(repo, id: "m1", body: "메모 본문")
        try seedTask(repo, id: "t1", title: "업무 제목")
        try acceptMemoTask(repo, id: "l1", memoId: "m1", taskId: "t1")
        try seedReportVersion(repo, reportId: "r1", versionId: "v1",
                              evidence: [("i1", "memo:m1"), ("i2", "task:t1")],
                              createdAt: at(repo, monday, hour: 18))
        try makeStore(repo).add(between: RecordReference(kind: .memo, id: "m1"),
                                and: RecordReference(kind: .task, id: "t1"))

        let snapshot = try GraphService(repo: repo).snapshot(query: GraphQuery())

        XCTAssertEqual(Set(snapshot.nodes.map(\.id)),
                       [GraphNodeID(kind: .memo, id: "m1"),
                        GraphNodeID(kind: .task, id: "t1"),
                        GraphNodeID(kind: .reportVersion, id: "v1")])
        XCTAssertTrue(Set(snapshot.edges.map(\.kind)).isSuperset(
            of: [.acceptedMemoTask, .manualRelated, .reportEvidence]))
        assertConsistent(snapshot)
    }

    // MARK: 2. 수동 링크 엣지 계약

    func testManualLinkEdgeContract() throws {
        let repo = try makeRepo()
        try seedMemo(repo, id: "m1")
        try seedTask(repo, id: "t1")
        let link = try makeStore(repo).add(between: RecordReference(kind: .memo, id: "m1"),
                                           and: RecordReference(kind: .task, id: "t1"))

        let snapshot = try GraphService(repo: repo).snapshot(query: GraphQuery())
        let manual = snapshot.edges.filter { $0.kind == .manualRelated }
        XCTAssertEqual(manual.count, 1)
        let edge = try XCTUnwrap(manual.first)
        XCTAssertEqual(edge.from, GraphNodeID(kind: .memo, id: "m1"))
        XCTAssertEqual(edge.to, GraphNodeID(kind: .task, id: "t1"))
        XCTAssertEqual(edge.sourceKey, "record_link:\(link.id)")
        XCTAssertFalse(edge.isDirected)
        XCTAssertNil(edge.evidence)
        assertConsistent(snapshot)
    }

    // MARK: 3. 끝점 없는 수동 링크 제거

    func testManualLinkWithOutOfRangeEndpointIsDropped() throws {
        let repo = try makeRepo()
        try seedMemo(repo, id: "m1", date: monday)
        // 범위 밖(금요일)에 생성된 업무. 링크는 저장 시점에는 양쪽이 살아 있다.
        try seedTask(repo, id: "t1", date: WorkDate("2026-10-09")!)
        try makeStore(repo).add(between: RecordReference(kind: .memo, id: "m1"),
                                and: RecordReference(kind: .task, id: "t1"))

        let query = GraphQuery(range: DateRange(start: monday, endExclusive: wednesday))
        let snapshot = try GraphService(repo: repo).snapshot(query: query)
        XCTAssertFalse(snapshot.edges.contains { $0.kind == .manualRelated },
                       "범위 밖 업무가 빠지면 수동 링크 엣지도 제거된다")
        XCTAssertFalse(snapshot.nodes.contains { $0.id == GraphNodeID(kind: .task, id: "t1") })
        XCTAssertTrue(snapshot.nodes.contains { $0.id == GraphNodeID(kind: .memo, id: "m1") })
        assertConsistent(snapshot)
    }

    // MARK: 4. accepted 관계와 수동 링크 동시 유지 (의미 병합 금지)

    func testAcceptedAndManualEdgesCoexistBetweenSameNodes() throws {
        let repo = try makeRepo()
        try seedMemo(repo, id: "m1")
        try seedTask(repo, id: "t1")
        try acceptMemoTask(repo, id: "l1", memoId: "m1", taskId: "t1")
        try makeStore(repo).add(between: RecordReference(kind: .memo, id: "m1"),
                                and: RecordReference(kind: .task, id: "t1"))

        let snapshot = try GraphService(repo: repo).snapshot(query: GraphQuery())
        let between = snapshot.edges.filter {
            $0.from == GraphNodeID(kind: .memo, id: "m1") && $0.to == GraphNodeID(kind: .task, id: "t1")
        }
        XCTAssertEqual(Set(between.map(\.kind)), [.acceptedMemoTask, .manualRelated])
        assertConsistent(snapshot)
    }

    // MARK: 5. kinds 필터 (project/tag 보조노드는 포함될 때만)

    func testKindsFilterKeepsOnlyRequestedKinds() throws {
        let repo = try makeRepo()
        let project = try repo.createProject(name: "프로젝트")
        try seedMemo(repo, id: "m1", projectIds: [project.id])
        try seedTask(repo, id: "t1")

        let memosOnly = try GraphService(repo: repo).snapshot(query: GraphQuery(kinds: [.memo]))
        XCTAssertEqual(memosOnly.nodes.map(\.id), [GraphNodeID(kind: .memo, id: "m1")])
        XCTAssertTrue(memosOnly.edges.isEmpty, "project 끝점이 빠지면 소속 엣지도 제거된다")
        assertConsistent(memosOnly)

        let withProject = try GraphService(repo: repo).snapshot(query: GraphQuery(kinds: [.memo, .project]))
        XCTAssertEqual(Set(withProject.nodes.map(\.id)),
                       [GraphNodeID(kind: .memo, id: "m1"),
                        GraphNodeID(kind: .project, id: project.id)])
        assertConsistent(withProject)
    }

    // MARK: 6. project 필터: 소속 기록 + 1-hop 이웃

    func testProjectFilterKeepsMembersAndOneHopNeighbors() throws {
        let repo = try makeRepo()
        let project = try repo.createProject(name: "P")
        try seedMemo(repo, id: "m1", projectIds: [project.id])
        try seedMemo(repo, id: "m2")
        try seedTask(repo, id: "t1")
        try acceptMemoTask(repo, id: "l1", memoId: "m1", taskId: "t1")

        let snapshot = try GraphService(repo: repo).snapshot(query: GraphQuery(projectIds: [project.id]))
        XCTAssertEqual(Set(snapshot.nodes.map(\.id)),
                       [GraphNodeID(kind: .memo, id: "m1"),
                        GraphNodeID(kind: .project, id: project.id),
                        GraphNodeID(kind: .task, id: "t1")])
        XCTAssertFalse(snapshot.nodes.contains { $0.id == GraphNodeID(kind: .memo, id: "m2") })
        assertConsistent(snapshot)
    }

    // MARK: 7. tag 필터: 태그 기록 + 1-hop 이웃

    func testTagFilterKeepsTaggedRecordsAndNeighbors() throws {
        let repo = try makeRepo()
        let tag = try repo.findOrCreateTag(name: "공유")
        try seedTask(repo, id: "t1", tagIds: [tag.id])
        try seedTask(repo, id: "t2")
        try relate(repo, id: "r1", from: "t1", to: "t2")
        try seedMemo(repo, id: "m1")

        let snapshot = try GraphService(repo: repo).snapshot(query: GraphQuery(tagIds: [tag.id]))
        XCTAssertEqual(Set(snapshot.nodes.map(\.id)),
                       [GraphNodeID(kind: .task, id: "t1"),
                        GraphNodeID(kind: .tag, id: tag.id),
                        GraphNodeID(kind: .task, id: "t2")])
        XCTAssertFalse(snapshot.nodes.contains { $0.id == GraphNodeID(kind: .memo, id: "m1") })
        assertConsistent(snapshot)
    }

    // MARK: 8. focus 필터: BFS 2-hop

    func testFocusFilterKeepsWithinTwoHops() throws {
        let repo = try makeRepo()
        try seedMemo(repo, id: "m1")
        for id in ["t1", "t2", "t3"] { try seedTask(repo, id: id) }
        try acceptMemoTask(repo, id: "l1", memoId: "m1", taskId: "t1")
        try relate(repo, id: "r1", from: "t1", to: "t2")
        try relate(repo, id: "r2", from: "t2", to: "t3")

        let snapshot = try GraphService(repo: repo).snapshot(
            query: GraphQuery(focus: GraphNodeID(kind: .memo, id: "m1")))
        XCTAssertEqual(Set(snapshot.nodes.map(\.id)),
                       [GraphNodeID(kind: .memo, id: "m1"),
                        GraphNodeID(kind: .task, id: "t1"),
                        GraphNodeID(kind: .task, id: "t2")])
        XCTAssertFalse(snapshot.edges.contains { $0.sourceKey == "task_relation:r2" })
        assertConsistent(snapshot)
    }

    func testFocusMissingNodeReturnsEmptySnapshot() throws {
        let repo = try makeRepo()
        try seedMemo(repo, id: "m1")
        try seedTask(repo, id: "t1")

        let snapshot = try GraphService(repo: repo).snapshot(
            query: GraphQuery(focus: GraphNodeID(kind: .task, id: "없음")))
        XCTAssertTrue(snapshot.nodes.isEmpty)
        XCTAssertTrue(snapshot.edges.isEmpty)
        XCTAssertFalse(snapshot.isTruncated)
    }

    // MARK: 9. nodeLimit: 차수 내림차순·결정성

    func testNodeLimitTruncatesByDegreeDeterministically() throws {
        let repo = try makeRepo()
        try seedTask(repo, id: "t1")
        for id in ["a1", "a2", "a3"] { try seedActivity(repo, id: id, taskId: "t1") }
        try seedMemo(repo, id: "m1")

        let query = GraphQuery(nodeLimit: 2)
        let first = try GraphService(repo: repo).snapshot(query: query)
        let second = try GraphService(repo: repo).snapshot(query: query)

        XCTAssertTrue(first.isTruncated)
        XCTAssertEqual(first, second, "잘림도 결정적이어야 한다")
        // 차수 3인 t1이 먼저, 나머지 차수 1은 id.key 오름차순.
        XCTAssertEqual(first.nodes.map(\.id.key), ["activity:a1", "task:t1"])
        assertConsistent(first)
    }

    func testNodeLimitWithFocusTruncatesByDistance() throws {
        let repo = try makeRepo()
        try seedMemo(repo, id: "m1")
        try seedTask(repo, id: "t1")
        try seedTask(repo, id: "t2")
        try acceptMemoTask(repo, id: "l1", memoId: "m1", taskId: "t1")
        try relate(repo, id: "r1", from: "t1", to: "t2")

        let snapshot = try GraphService(repo: repo).snapshot(
            query: GraphQuery(focus: GraphNodeID(kind: .memo, id: "m1"), nodeLimit: 2))
        XCTAssertTrue(snapshot.isTruncated)
        XCTAssertEqual(snapshot.nodes.map(\.id.key), ["memo:m1", "task:t1"])
        assertConsistent(snapshot)
    }

    func testNoTruncationAtOrUnderLimit() throws {
        let repo = try makeRepo()
        try seedMemo(repo, id: "m1")
        try seedTask(repo, id: "t1")

        let snapshot = try GraphService(repo: repo).snapshot(query: GraphQuery(nodeLimit: 250))
        XCTAssertFalse(snapshot.isTruncated)
        XCTAssertEqual(snapshot.nodes.count, 2)
        assertConsistent(snapshot)
    }

    // MARK: 10. 빈 저장소·Secret canary 부재

    func testEmptyRepositoryReturnsEmptySnapshot() throws {
        let repo = try makeRepo()
        let snapshot = try GraphService(repo: repo).snapshot(query: GraphQuery())
        XCTAssertEqual(snapshot, GraphSnapshot.empty)
    }

    func testSecretCanaryNeverAppearsInSnapshot() throws {
        let canary = "CANARY-SECRET-9f3a"

        // 가짜 vault에 canary 제목의 Secret을 만든다. vault는 work.sqlite와 다른 DB다.
        let vaultDB = try SQLiteDatabase(path: ":memory:")
        defer { vaultDB.close() }
        let vault = try SecretVault(db: vaultDB, keyStore: InMemoryVaultKeyStore(),
                                    clock: FixedClock(fixedNow))
        let meta = try vault.create(title: canary, groupName: "infra",
                                    rows: [SecretRowInput(key: "API_KEY", value: canary)])
        XCTAssertEqual(meta.title, canary)
        XCTAssertTrue(try vault.searchTitles(canary).contains { $0.title == canary },
                      "canary Secret이 vault에는 실제로 존재해야 한다")

        let repo = try makeRepo()
        try seedMemo(repo, id: "m1", body: "일반 메모")
        try seedTask(repo, id: "t1", title: "일반 업무")
        try acceptMemoTask(repo, id: "l1", memoId: "m1", taskId: "t1")
        try makeStore(repo).add(between: RecordReference(kind: .memo, id: "m1"),
                                and: RecordReference(kind: .task, id: "t1"))

        let snapshot = try GraphService(repo: repo).snapshot(query: GraphQuery())
        var strings: [String] = []
        for node in snapshot.nodes {
            strings.append(node.id.key)
            strings.append(node.title)
            if let subtitle = node.subtitle { strings.append(subtitle) }
        }
        for edge in snapshot.edges {
            strings.append(edge.key)
            strings.append(edge.sourceKey)
            if let evidence = edge.evidence {
                strings.append(evidence.reportVersionId)
                strings.append(evidence.sourceId)
                if let snapshotId = evidence.sourceSnapshotId { strings.append(snapshotId) }
            }
        }
        XCTAssertFalse(strings.contains { $0.contains(canary) },
                       "canary가 그래프 결과에 나타나면 안 된다")
    }

    // MARK: 11. 삭제된 기록은 노드·엣지 모두에서 빠진다

    func testDeletedRecordsExcludedEverywhere() throws {
        let repo = try makeRepo()
        try seedMemo(repo, id: "m1")
        try seedMemo(repo, id: "m2")
        try seedTask(repo, id: "t1")
        try acceptMemoTask(repo, id: "l1", memoId: "m1", taskId: "t1")
        try repo.softDeleteMemo(id: "m2")

        let snapshot = try GraphService(repo: repo).snapshot(query: GraphQuery())
        XCTAssertFalse(snapshot.nodes.contains { $0.id == GraphNodeID(kind: .memo, id: "m2") })
        XCTAssertTrue(snapshot.nodes.contains { $0.id == GraphNodeID(kind: .memo, id: "m1") })
        assertConsistent(snapshot)
    }
}
