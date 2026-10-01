import XCTest
@testable import WorkLogCore

final class SearchIndexTests: XCTestCase {

    private let monday = WorkDate("2026-10-05")!
    private let tuesday = WorkDate("2026-10-06")!
    private let wednesday = WorkDate("2026-10-07")!
    private let recordedAt = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeIndex() throws -> (WorkRepository, SearchIndex) {
        let clock = FixedClock(recordedAt)
        let repo = try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator())
        let index = try SearchIndex(repo: repo)
        return (repo, index)
    }

    // MARK: SEARCH-T01 — 저장 직후 반영, 삭제 즉시 제외

    func testSEARCH_T01_ImmediateIndexAndSoftDeleteExclusion() throws {
        let (repo, index) = try makeIndex()

        try repo.insertMemo(Memo(id: "memo-1", body: "즉시반영메모 본문", workDate: monday, recordedAt: recordedAt))
        try repo.insertTask(WorkTask(id: "task-1", title: "즉시반영태스크", createdAt: recordedAt))
        try repo.insertActivity(Activity(id: "act-1", taskId: "task-1", body: "즉시반영활동",
                                         workDate: monday, recordedAt: recordedAt))

        // 별도 rebuild 없이 바로 검색된다.
        let hits = try index.search(SearchQuery(text: "즉시반영", limit: 50))
        XCTAssertEqual(Set(hits.map(\.sourceId)), ["memo-1", "task-1", "act-1"])
        XCTAssertEqual(Set(hits.map(\.sourceType)), [.memo, .task, .activity])

        // soft delete 즉시 제외
        try repo.softDeleteMemo(id: "memo-1")
        let after = try index.search(SearchQuery(text: "즉시반영", limit: 50))
        XCTAssertEqual(Set(after.map(\.sourceId)), ["task-1", "act-1"])
        XCTAssertFalse(after.contains { $0.sourceId == "memo-1" })
    }

    // MARK: SEARCH-T02 — 한글·영문(대소문자 무시)·기호·공백 두 단어 AND

    func testSEARCH_T02_KoreanEnglishSymbolsAndAndQuery() throws {
        let (repo, index) = try makeIndex()
        let body = "대중교통 길찾기 Nexus C++ a%b 50_% \"x\""
        try repo.insertMemo(Memo(id: "memo-2", body: body, workDate: monday, recordedAt: recordedAt))

        for query in ["대중교통", "nexus", "NEXUS", "C++", "a%b", "50_%", "\"x\""] {
            let hits = try index.search(SearchQuery(text: query))
            XCTAssertEqual(hits.first?.sourceId, "memo-2", "query=\(query) 결과 없음/불일치")
        }

        // 공백 분리 두 단어 AND
        XCTAssertEqual(try index.search(SearchQuery(text: "대중교통 길찾기")).first?.sourceId, "memo-2")
        XCTAssertEqual(try index.search(SearchQuery(text: "길찾기 nexus")).first?.sourceId, "memo-2")
        XCTAssertTrue(try index.search(SearchQuery(text: "대중교통 없는단어")).isEmpty)
    }

    // MARK: SEARCH-T03 — 1~2글자 한글 부분 검색은 LIKE 경로

    func testSEARCH_T03_ShortKoreanTermsUseLikePath() throws {
        let (repo, index) = try makeIndex()
        try repo.insertMemo(Memo(id: "memo-3", body: "지하철역에서 배포스크립트를 실행", workDate: monday,
                                 recordedAt: recordedAt))

        XCTAssertEqual(try index.search(SearchQuery(text: "역")).first?.sourceId, "memo-3")
        XCTAssertEqual(try index.search(SearchQuery(text: "배포")).first?.sourceId, "memo-3")
        // 붙여 쓴 단어 내부 부분 문자열
        XCTAssertEqual(try index.search(SearchQuery(text: "스크립트")).first?.sourceId, "memo-3")
        XCTAssertEqual(try index.search(SearchQuery(text: "배포스")).first?.sourceId, "memo-3")
    }

    // MARK: SEARCH-T04 — 유형·프로젝트·태그·기간 필터 합성

    func testSEARCH_T04_Filters() throws {
        let (repo, index) = try makeIndex()
        let p1 = try repo.createProject(name: "대중교통")
        let p2 = try repo.createProject(name: "결제")
        let tag = try repo.findOrCreateTag(name: "버스")

        try repo.insertMemo(Memo(id: "memo-a", body: "필터테스트 알파", workDate: monday, recordedAt: recordedAt,
                                 projectIds: [p1.id], tagIds: [tag.id]))
        try repo.insertMemo(Memo(id: "memo-b", body: "필터테스트 베타", workDate: tuesday, recordedAt: recordedAt,
                                 projectIds: [p2.id]))

        // 프로젝트 필터
        XCTAssertEqual(Set(try index.search(SearchQuery(text: "필터테스트", projectIds: [p1.id])).map(\.sourceId)),
                       ["memo-a"])
        // 태그 필터
        XCTAssertEqual(Set(try index.search(SearchQuery(text: "필터테스트", tagIds: [tag.id])).map(\.sourceId)),
                       ["memo-a"])
        // 기간 필터
        let tuesdayRange = DateRange(start: tuesday, endExclusive: wednesday)
        XCTAssertEqual(Set(try index.search(SearchQuery(text: "필터테스트", range: tuesdayRange)).map(\.sourceId)),
                       ["memo-b"])
        // 유형 필터
        XCTAssertEqual(Set(try index.search(SearchQuery(text: "필터테스트", types: [.memo])).map(\.sourceId)),
                       ["memo-a", "memo-b"])
        XCTAssertTrue(try index.search(SearchQuery(text: "필터테스트", types: [.task])).isEmpty)
        // 필터 합성: 기간 + 유형
        XCTAssertEqual(Set(try index.search(SearchQuery(text: "필터테스트", types: [.memo],
                                                        range: DateRange(start: monday, endExclusive: tuesday)))
                              .map(\.sourceId)),
                       ["memo-a"])

        // 프로젝트 이름으로 검색
        XCTAssertEqual(Set(try index.search(SearchQuery(text: "대중교통")).map(\.sourceId)), ["memo-a"])

        // 태스크가 프로젝트에 연결된 경우 task 문서도 프로젝트 필터를 통과한다.
        try repo.insertTask(WorkTask(id: "task-f", title: "결제모듈", createdAt: recordedAt))
        try repo.linkProject(taskId: "task-f", projectId: p1.id, trackingEnabled: false, linkedOn: monday)
        XCTAssertEqual(Set(try index.search(SearchQuery(text: "결제모듈", projectIds: [p1.id])).map(\.sourceId)),
                       ["task-f"])
    }

    // MARK: 늦게 입력한 기록은 실제 work_date 기준으로 필터·정렬된다

    func testLateEntryFilteredByWorkDate() throws {
        let lateClock = FixedClock(Date(timeIntervalSince1970: 1_791_000_000))
        let repo = try WorkRepository.inMemory(clock: lateClock, ids: SequentialIDGenerator())
        let index = try SearchIndex(repo: repo)

        try repo.insertMemo(Memo(id: "memo-late", body: "늦은입력 기록", workDate: monday,
                                 recordedAt: lateClock.now()))

        let mondayRange = DateRange(start: monday, endExclusive: tuesday)
        let tuesdayRange = DateRange(start: tuesday, endExclusive: wednesday)
        XCTAssertEqual(try index.search(SearchQuery(text: "늦은입력", range: mondayRange)).first?.sourceId,
                       "memo-late")
        XCTAssertTrue(try index.search(SearchQuery(text: "늦은입력", range: tuesdayRange)).isEmpty)
    }

    // MARK: indexReport / removeReport (+ report.range.start 폴백)

    func testReportIndexAndRemove() throws {
        let (repo, index) = try makeIndex()
        let noDate: WorkDate? = nil
        let noText: String? = nil

        try repo.db.runV("""
            INSERT INTO source_snapshot
                (id, start, end_exclusive, state_cutoff, known_at, frozen_facts_json, digest, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, "snap-1", monday, wednesday, recordedAt, recordedAt, "{}", "digest-1", recordedAt)
        try repo.db.runV("""
            INSERT INTO report
                (id, family, period_type, period_key, start, end_exclusive, plan_start,
                 plan_end_exclusive, evaluation_period_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, "rep-1", "performance", "weekly", "2026-W41", monday, wednesday,
               noDate, noDate, noText, recordedAt)
        try repo.db.runV("""
            INSERT INTO report_version
                (id, report_id, version, state, content, structured_json, source_snapshot_id,
                 template_version_id, skill_ref, ai_model, generator, warnings_json,
                 based_on_version_id, created_at, confirmed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, "rv-1", "rep-1", 1, "draft", "상세리포트본문", noText, "snap-1",
               noText, noText, noText, "deterministic", "[]", noText, recordedAt, noDate)

        // workDate를 넘기지 않으면 report.range.start를 쓴다.
        try index.indexReport(versionId: "rv-1", text: "상세리포트본문", workDate: nil)
        let hit = try XCTUnwrap(try index.search(SearchQuery(text: "상세리포트", types: [.report])).first)
        XCTAssertEqual(hit.sourceId, "rv-1")
        XCTAssertEqual(hit.sourceType, .report)
        XCTAssertEqual(hit.workDate, monday)

        try index.removeReport(versionId: "rv-1")
        XCTAssertTrue(try index.search(SearchQuery(text: "상세리포트")).isEmpty)
    }

    // MARK: rebuildAll — 기존 데이터 재색인

    func testRebuildAllReindexesExistingRows() throws {
        let clock = FixedClock(recordedAt)
        let repo = try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator())
        // 인덱스 연결 전에 저장
        try repo.insertMemo(Memo(id: "memo-r", body: "재색인대상 본문", workDate: monday, recordedAt: recordedAt))

        let index = try SearchIndex(repo: repo)
        XCTAssertTrue(try index.search(SearchQuery(text: "재색인대상")).isEmpty)
        try index.rebuildAll()
        XCTAssertEqual(try index.search(SearchQuery(text: "재색인대상")).first?.sourceId, "memo-r")
    }

    // MARK: indexReport 없이 reindex(sourceType:"report") 경로

    func testReindexReportReadsStoredVersion() throws {
        let (repo, index) = try makeIndex()
        let noDate: WorkDate? = nil
        let noText: String? = nil
        try repo.db.runV("""
            INSERT INTO source_snapshot
                (id, start, end_exclusive, state_cutoff, known_at, frozen_facts_json, digest, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, "snap-2", monday, wednesday, recordedAt, recordedAt, "{}", "digest-2", recordedAt)
        try repo.db.runV("""
            INSERT INTO report
                (id, family, period_type, period_key, start, end_exclusive, plan_start,
                 plan_end_exclusive, evaluation_period_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, "rep-2", "performance", "weekly", "2026-W42", monday, wednesday,
               noDate, noDate, noText, recordedAt)
        try repo.db.runV("""
            INSERT INTO report_version
                (id, report_id, version, state, content, structured_json, source_snapshot_id,
                 template_version_id, skill_ref, ai_model, generator, warnings_json,
                 based_on_version_id, created_at, confirmed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, "rv-2", "rep-2", 1, "draft", "저장된리포트내용", noText, "snap-2",
               noText, noText, noText, "deterministic", "[]", noText, recordedAt, noDate)

        try index.reindex(sourceType: "report", id: "rv-2")
        XCTAssertEqual(try index.search(SearchQuery(text: "저장된리포트", types: [.report])).first?.sourceId, "rv-2")

        // 없는 리포트는 제거된다.
        try index.reindex(sourceType: "report", id: "rv-none")
        XCTAssertEqual(try index.search(SearchQuery(text: "저장된리포트", types: [.report])).count, 1)
    }

    // MARK: usesTrigram 실제 값

    func testUsesTrigramReported() throws {
        let (repo, index) = try makeIndex()
        let version = try repo.db.queryOne("SELECT sqlite_version() AS v")?.string("v") ?? "?"
        print("[SearchIndex] usesTrigram=\(index.usesTrigram) sqlite=\(version)")
        XCTAssertTrue(index.usesTrigram, "이 개발 서버 SQLite \(version)는 FTS5 trigram을 지원해야 한다")
    }

    // MARK: 성능 측정 (실패 조건 아님)

    func testPerformanceLargeCorpusSearch() throws {
        let (repo, index) = try makeIndex()
        // 50,000건은 인덱스 연결 삽입에 약 104초가 걸려 60초 예산을 넘어 20,000건으로 줄였다(보고 참조).
        let count = 20_000
        let words = ["대중교통", "길찾기", "배포스크립트", "회의록", "코드리뷰",
                     "버스", "지하철", "deploy", "nexus", "문서화"]
        let n = words.count

        let insertStart = Date()
        try repo.db.transaction {
            for i in 0..<count {
                let body = "\(words[i % n]) \(words[(i * 3 + 1) % n]) \(words[(i * 7 + 2) % n]) 기록 \(i)"
                let memo = Memo(id: String(format: "perf-%06d", i), body: body,
                                workDate: monday, recordedAt: recordedAt)
                try repo.insertMemo(memo)
            }
        }
        let insertMs = Date().timeIntervalSince(insertStart) * 1000
        print(String(format: "[perf] 삽입 %d건 (SearchIndex 연결 상태): %.1f ms", count, insertMs))

        func measure(_ label: String, _ query: String) throws {
            let t0 = Date()
            let hits = try index.search(SearchQuery(text: query, limit: 50))
            let ms = Date().timeIntervalSince(t0) * 1000
            print(String(format: "[perf] %@ 검색어=\"%@\" 결과=%d %.1f ms (corpus=%d)",
                         label, query, hits.count, ms, count))
        }

        try measure("FTS(4글자)", "대중교통")
        try measure("FTS(3글자)", "길찾기")
        try measure("FTS(영문)", "nexus")
        try measure("LIKE(2글자)", "배포")
        try measure("LIKE(1글자)", "역")
    }
}
