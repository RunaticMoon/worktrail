import XCTest
@testable import WorkLogCore

final class SourceActivitySearchTests: XCTestCase {
    private let day = WorkDate("2026-10-28")!
    private let now = WorkCalendar().startOfDay(WorkDate("2026-10-28")!)

    private func setup() throws -> (WorkRepository, SearchIndex) {
        let repo = try WorkRepository.inMemory(clock: FixedClock(now), ids: SequentialIDGenerator())
        return (repo, try SearchIndex(repo: repo))
    }

    /// 과거 버전에서 이미 저장된 매핑을 만든다. 별도 지시 전에는 색인을 갱신하지 않는다.
    private func map(_ memoID: String, to source: ActivitySource, repo: WorkRepository) throws {
        try repo.db.runV("""
            INSERT INTO imported_activity
            (connection_key, external_id, source, memo_id, occurred_at, fetched_at, source_url)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, "fake-connection", memoID, source.rawValue, memoID, now, now,
            "https://example.invalid/\(source.rawValue)/\(memoID)")
    }

    func testImportsHaveDistinctTypesAndOrdinaryPrefixNeverChangesProvenance() throws {
        let (repo, index) = try setup()
        let ordinary = try TaskService(repo: repo).captureMemo(body: "[GitHub Enterprise] 통합수집 일반 메모")
        for source in ActivitySource.allCases {
            var connection = ActivityConnection(source: source)
            connection.baseURL = "https://example.invalid"
            connection.account = "fake-user"
            try repo.importActivities([ImportedActivity(id: source.rawValue, occurredAt: now,
                title: "통합수집 외부 작업", detail: "가짜 기록", url: "https://example.invalid/event")], connection: connection)
        }
        for query in ["통합수집", "수집"] { // FTS가 지원되면 trigram, 짧은 검색은 LIKE.
            let all = try index.search(SearchQuery(text: query))
            XCTAssertEqual(Set(all.map(\.sourceType)), [.memo, .github, .jira])
            XCTAssertEqual(try index.search(SearchQuery(text: query, types: [.memo])).map(\.sourceId), [ordinary.id])
            for type in [SearchSourceType.github, .jira] {
                let imported = try XCTUnwrap(index.search(SearchQuery(text: query, types: [type])).first)
                XCTAssertEqual(imported.sourceType, type)
                XCTAssertNotEqual(imported.sourceId, ordinary.id)
                XCTAssertNotNil(try repo.memo(id: imported.sourceId))
                XCTAssertEqual(imported.recordReference, RecordReference(kind: .memo, id: imported.sourceId))
            }
        }
        XCTAssertEqual(SearchSourceType.github.displayLabel, "GitHub")
        XCTAssertEqual(SearchSourceType.jira.displayLabel, "Jira")
        XCTAssertNotEqual(SearchSourceType.github.systemImage, SearchSourceType.jira.systemImage)
    }

    func testImportedProjectTagDateFiltersAndSourcePreservingEdits() throws {
        let (repo, index) = try setup()
        let project = try repo.createProject(name: "출처프로젝트")
        let other = try repo.createProject(name: "다른프로젝트")
        let tag = try repo.findOrCreateTag(name: "출처태그")
        for source in ActivitySource.allCases {
            let memo = Memo(id: source.rawValue, body: "원래수집 검색", workDate: day, recordedAt: now,
                            projectIds: [project.id], tagIds: [tag.id])
            try repo.insertMemo(memo)
            try map(memo.id, to: source, repo: repo)
            try index.reindex(sourceType: "memo", id: memo.id)
        }
        let range = DateRange(start: day, endExclusive: repo.calendar.adding(days: 1, to: day))
        for type in [SearchSourceType.github, .jira] {
            let hits = try index.search(SearchQuery(text: "검색", types: [type], projectIds: [project.id],
                tagIds: [tag.id], range: range))
            XCTAssertEqual(hits.map(\.sourceId), [type.rawValue])
            XCTAssertEqual(hits.first?.projectNames, [project.name])
            XCTAssertTrue(try index.search(SearchQuery(text: "검색", types: [type], projectIds: [other.id])).isEmpty)
            XCTAssertEqual(try index.search(SearchQuery(text: "출처태그", types: [type])).count, 1)
        }
        try repo.updateMemoBody(id: "github", body: "사용자가 고친본문", workDate: day)
        XCTAssertEqual(try index.search(SearchQuery(text: "고친본문", types: [.github])).map(\.sourceId), ["github"])
        XCTAssertTrue(try index.search(SearchQuery(text: "고친본문", types: [.memo])).isEmpty)
        try repo.softDeleteMemo(id: "github")
        XCTAssertTrue(try index.search(SearchQuery(text: "고친본문")).isEmpty)
        // 복원 경로도 기존 memo 식별자로 재색인한다.
        try repo.db.runV("UPDATE memo SET deleted_at = NULL WHERE id = ?", "github")
        try index.reindex(sourceType: "memo", id: "github")
        XCTAssertEqual(try index.search(SearchQuery(text: "고친본문")).first?.sourceType, .github)
    }

    func testStartupRepairsLegacyAndDuplicateDocsWithoutWritingWhenAlreadyCurrent() throws {
        let (repo, legacyIndex) = try setup()
        try repo.insertMemo(Memo(id: "legacy", body: "기존수집자료", workDate: day, recordedAt: now))
        try map("legacy", to: .github, repo: repo)
        // 매핑만 저장된 구버전 memo 문서는 일반 메모 결과에서도 즉시 제외한다.
        XCTAssertTrue(try legacyIndex.search(SearchQuery(text: "기존수집자료", types: [.memo])).isEmpty)
        try repo.db.runV("""
            INSERT INTO search_doc (source_type, source_id, work_date, text) VALUES (?, ?, ?, ?)
            """, "jira", "legacy", day, "중복색인")
        let repaired = try SearchIndex(repo: repo)
        for query in ["기존수집자료", "수집"] {
            let hits = try repaired.search(SearchQuery(text: query))
            XCTAssertEqual(hits.count, 1)
            XCTAssertEqual(hits.first?.sourceType, .github)
            XCTAssertEqual(hits.first?.sourceId, "legacy")
        }
        XCTAssertEqual(try repo.db.scalarIntV("SELECT COUNT(*) FROM search_doc WHERE source_id = ?", "legacy"), 1)
        let changes = try repo.db.scalarIntV("SELECT total_changes()")
        XCTAssertEqual(try repaired.repairImportedActivityDocs(), 0)
        XCTAssertEqual(try repo.db.scalarIntV("SELECT total_changes()"), changes)
    }

    func testRebuildAndRepairKeepDeletedImportsOutAndUnmappedMemosOrdinary() throws {
        let (repo, index) = try setup()
        for source in ActivitySource.allCases {
            try repo.insertMemo(Memo(id: source.rawValue, body: "재구축수집", workDate: day, recordedAt: now))
            try map(source.rawValue, to: source, repo: repo)
        }
        try repo.insertMemo(Memo(id: "ordinary", body: "[Jira Cloud] 재구축수집", workDate: day, recordedAt: now))
        try repo.softDeleteMemo(id: "jira")
        try index.rebuildAll()
        let hits = try index.search(SearchQuery(text: "재구축수집"))
        XCTAssertEqual(Set(hits.map(\.sourceType)), [.github, .memo])
        XCTAssertEqual(Set(hits.map(\.sourceId)), ["github", "ordinary"])
        XCTAssertEqual(try index.repairImportedActivityDocs(), 0)
    }

    func testSearchEvidenceAndGraphLinksKeepOriginalMemoIdentity() throws {
        let (repo, index) = try setup()
        try repo.insertMemo(Memo(id: "imported", body: "출처참조검색", workDate: day, recordedAt: now))
        try map("imported", to: .jira, repo: repo)
        try index.reindex(sourceType: "memo", id: "imported")
        let hit = try XCTUnwrap(index.search(SearchQuery(text: "출처참조검색")).first)
        let task = try TaskService(repo: repo).createTask(title: "연결할 업무")
        let linked = try RecordLinkStore(repo: repo).add(between: hit.recordReference,
                                                        and: RecordReference(kind: .task, id: task.id))
        XCTAssertTrue([linked.first, linked.second].contains(RecordReference(kind: .memo, id: "imported")))
        let graph = try GraphService(repo: repo).snapshot(query: GraphQuery())
        XCTAssertTrue(graph.nodes.contains { $0.id == GraphNodeID(kind: .memo, id: "imported") })
        XCTAssertTrue(graph.edges.contains { $0.kind == .manualRelated })

        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("SourceActivitySearch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let runner = AIJobRunner(repo: repo, provider: MockAIProvider(responses: [:]), stagingRoot: staging)
        let service = GroundedAnswerService(index: index, runner: runner, templates: TemplateStore(repo: repo))
        let evidence = try service.collectEvidence(question: "출처참조검색", scope: GroundedAnswerScope(types: [.jira]))
        XCTAssertEqual(evidence.map(\.id), ["memo:imported"])
        XCTAssertEqual(evidence.first?.sourceType, .jira)
        XCTAssertTrue(try service.collectEvidence(question: "출처참조검색", scope: GroundedAnswerScope(types: [.memo])).isEmpty)
    }
}
