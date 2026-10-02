import XCTest
@testable import WorkLogCore

/// RecordLinkStore: 정규 순서 저장·대상 재검증·양방향 조회·후보 검색.
final class RecordLinkStoreTests: XCTestCase {

    private let monday = WorkDate("2026-10-05")!
    private let tuesday = WorkDate("2026-10-06")!
    private let wednesday = WorkDate("2026-10-07")!
    private let thursday = WorkDate("2026-10-08")!

    private let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeRepo() throws -> WorkRepository {
        try WorkRepository.inMemory(clock: FixedClock(fixedNow),
                                    ids: SequentialIDGenerator())
    }

    /// 해당 업무일의 지역 자정 기준 시각.
    private func at(_ repo: WorkRepository, _ date: WorkDate, hour: Int = 9) -> Date {
        repo.calendar.startOfDay(date).addingTimeInterval(TimeInterval(hour * 3600))
    }

    private func makeStore(_ repo: WorkRepository) -> RecordLinkStore {
        RecordLinkStore(repo: repo, clock: FixedClock(fixedNow), ids: SequentialIDGenerator())
    }

    @discardableResult
    private func seedMemo(_ repo: WorkRepository, id: String, body: String,
                          date: WorkDate) throws -> Memo {
        let memo = Memo(id: id, body: body, workDate: date, recordedAt: at(repo, date))
        try repo.insertMemo(memo)
        return memo
    }

    @discardableResult
    private func seedTask(_ repo: WorkRepository, id: String, title: String,
                          date: WorkDate) throws -> WorkTask {
        let task = WorkTask(id: id, title: title, createdAt: at(repo, date))
        try repo.insertTask(task)
        return task
    }

    @discardableResult
    private func seedActivity(_ repo: WorkRepository, id: String, taskId: String, body: String,
                              date: WorkDate) throws -> Activity {
        let activity = Activity(id: id, taskId: taskId, body: body, workDate: date,
                                recordedAt: at(repo, date, hour: 10))
        try repo.insertActivity(activity)
        return activity
    }

    /// 리포트·스냅샷·버전을 하나 만든다. candidates의 리포트 버전 검증에 쓴다.
    private func seedReportVersion(_ repo: WorkRepository, reportId: String, versionId: String,
                                   family: ReportFamily, periodKey: String, range: DateRange,
                                   version: Int, content: String,
                                   createdAt: Date) throws {
        try repo.insertSourceSnapshot(SourceSnapshot(
            id: "snap-\(versionId)", range: range, stateCutoff: createdAt, knownAt: createdAt,
            frozenFactsJSON: "{}", digest: "digest-\(versionId)", createdAt: createdAt))
        try repo.insertReport(Report(id: reportId, family: family, periodType: .weekly,
                                     periodKey: periodKey, range: range, createdAt: createdAt))
        try repo.insertReportVersion(ReportVersion(
            id: versionId, reportId: reportId, version: version, state: .draft, content: content,
            sourceSnapshotId: "snap-\(versionId)", generator: "deterministic", createdAt: createdAt))
    }

    private func assertValidation<T>(_ expression: @autoclosure () throws -> T,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case WorkLogError.validation = error else {
                return XCTFail("validation 오류가 아니다: \(error)", file: file, line: line)
            }
        }
    }

    // MARK: 1. 정규 순서 저장

    func testReversedInputStoresCanonicalOrderOnce() throws {
        let repo = try makeRepo()
        let store = makeStore(repo)
        try seedMemo(repo, id: "m1", body: "메모", date: monday)
        try seedTask(repo, id: "t1", title: "업무", date: monday)

        let forward = try store.add(between: RecordReference(kind: .task, id: "t1"),
                                    and: RecordReference(kind: .memo, id: "m1"))
        // kind는 "memo" < "task"이므로 정규 순서는 memo → task이다.
        XCTAssertEqual(forward.first, RecordReference(kind: .memo, id: "m1"))
        XCTAssertEqual(forward.second, RecordReference(kind: .task, id: "t1"))

        let reversed = try store.add(between: RecordReference(kind: .memo, id: "m1"),
                                     and: RecordReference(kind: .task, id: "t1"))
        XCTAssertEqual(reversed.id, forward.id, "역순 입력도 같은 링크여야 한다")
        XCTAssertEqual(forward.first, reversed.first)
        XCTAssertEqual(forward.second, reversed.second)

        let all = try store.allLinks()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first, forward)
    }

    func testDuplicateAddIsIdempotent() throws {
        let repo = try makeRepo()
        let store = makeStore(repo)
        try seedMemo(repo, id: "m1", body: "메모", date: monday)
        try seedTask(repo, id: "t1", title: "업무", date: monday)

        let first = try store.add(between: RecordReference(kind: .memo, id: "m1"),
                                  and: RecordReference(kind: .task, id: "t1"))
        let second = try store.add(between: RecordReference(kind: .memo, id: "m1"),
                                   and: RecordReference(kind: .task, id: "t1"))
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(try store.allLinks().count, 1)
    }

    // MARK: 2. 자기 연결·없는 대상·삭제된 대상 거절

    func testSelfLinkIsRejected() throws {
        let repo = try makeRepo()
        let store = makeStore(repo)
        try seedMemo(repo, id: "m1", body: "메모", date: monday)
        let ref = RecordReference(kind: .memo, id: "m1")

        assertValidation(try store.add(between: ref, and: ref))
        XCTAssertEqual(try store.allLinks().count, 0)
    }

    func testMissingTargetIsRejected() throws {
        let repo = try makeRepo()
        let store = makeStore(repo)
        try seedMemo(repo, id: "m1", body: "메모", date: monday)

        assertValidation(try store.add(between: RecordReference(kind: .memo, id: "m1"),
                                       and: RecordReference(kind: .task, id: "없는업무")))
        XCTAssertEqual(try store.allLinks().count, 0)
    }

    func testSoftDeletedTargetIsRejected() throws {
        let repo = try makeRepo()
        let store = makeStore(repo)
        try seedMemo(repo, id: "m1", body: "메모", date: monday)
        try seedTask(repo, id: "t1", title: "업무", date: monday)
        try repo.softDeleteMemo(id: "m1")

        assertValidation(try store.add(between: RecordReference(kind: .memo, id: "m1"),
                                       and: RecordReference(kind: .task, id: "t1")))
        XCTAssertEqual(try store.allLinks().count, 0)
    }

    // MARK: 3. 다중 add 원자성

    func testMultiAddRollsBackWholeBatchOnFailure() throws {
        let repo = try makeRepo()
        let store = makeStore(repo)
        try seedMemo(repo, id: "m1", body: "메모", date: monday)
        try seedTask(repo, id: "t1", title: "업무", date: monday)
        try seedTask(repo, id: "t2", title: "둘째 업무", date: monday)

        let source = RecordReference(kind: .memo, id: "m1")
        assertValidation(try store.add(from: source, to: [
            RecordReference(kind: .task, id: "t1"),
            RecordReference(kind: .task, id: "없는업무"),
        ]))
        XCTAssertEqual(try store.allLinks().count, 0, "하나라도 실패하면 전체 롤백돼야 한다")
    }

    // MARK: 4. 바깥 트랜잭션 롤백

    func testLinksRollBackWithOuterTransaction() throws {
        let repo = try makeRepo()
        let store = makeStore(repo)
        try seedMemo(repo, id: "m1", body: "메모", date: monday)
        try seedTask(repo, id: "t1", title: "업무", date: monday)

        struct Boom: Error {}
        XCTAssertThrowsError(try repo.db.transaction {
            _ = try store.add(between: RecordReference(kind: .memo, id: "m1"),
                              and: RecordReference(kind: .task, id: "t1"))
            throw Boom()
        })
        XCTAssertEqual(try store.allLinks().count, 0)
    }

    // MARK: 5. 양방향 조회·삭제

    func testLinksAreBidirectional() throws {
        let repo = try makeRepo()
        let store = makeStore(repo)
        try seedMemo(repo, id: "m1", body: "메모", date: monday)
        try seedTask(repo, id: "t1", title: "업무", date: monday)
        let memo = RecordReference(kind: .memo, id: "m1")
        let task = RecordReference(kind: .task, id: "t1")
        let link = try store.add(between: memo, and: task)

        XCTAssertEqual(try store.links(for: memo), [link])
        XCTAssertEqual(try store.links(for: task), [link])
        XCTAssertEqual(try store.links(for: RecordReference(kind: .memo, id: "다른메모")), [])
    }

    func testRemoveDeletesLink() throws {
        let repo = try makeRepo()
        let store = makeStore(repo)
        try seedMemo(repo, id: "m1", body: "메모", date: monday)
        try seedTask(repo, id: "t1", title: "업무", date: monday)
        let memo = RecordReference(kind: .memo, id: "m1")
        let task = RecordReference(kind: .task, id: "t1")
        try store.add(between: memo, and: task)

        try store.remove(between: task, and: memo)   // 역순으로 지워도 같은 행
        XCTAssertEqual(try store.allLinks().count, 0)
        try store.remove(between: memo, and: task)   // 없는 링크 삭제는 no-op
        XCTAssertEqual(try store.allLinks().count, 0)
    }

    // MARK: 6. 후보 조회

    func testCandidatesRecentFirstMixedAcrossKinds() throws {
        let repo = try makeRepo()
        let store = makeStore(repo)
        try seedTask(repo, id: "t1", title: "월요일 업무", date: monday)
        try seedMemo(repo, id: "m1", body: "수요일 메모", date: wednesday)
        try seedActivity(repo, id: "a1", taskId: "t1", body: "화요일 진행기록", date: tuesday)
        try seedMemo(repo, id: "m2", body: "목요일 메모", date: thursday)

        let candidates = try store.candidates(query: "", excluding: [], limit: 10)
        XCTAssertEqual(candidates.map(\.reference.id), ["m2", "m1", "a1", "t1"],
                       "업무일 내림차순으로 종류가 섞여야 한다")
        XCTAssertEqual(candidates[0].title, "목요일 메모")
        XCTAssertEqual(candidates[0].subtitle, "메모 2026-10-08")
        XCTAssertEqual(candidates[2].subtitle, "진행기록 2026-10-06")
        XCTAssertEqual(candidates[3].subtitle, "업무 2026-10-05")
    }

    func testCandidatesExcludingAndLimit() throws {
        let repo = try makeRepo()
        let store = makeStore(repo)
        try seedMemo(repo, id: "m1", body: "하나", date: monday)
        try seedMemo(repo, id: "m2", body: "둘", date: tuesday)
        try seedMemo(repo, id: "m3", body: "셋", date: wednesday)

        let excluded = try store.candidates(
            query: "", excluding: [RecordReference(kind: .memo, id: "m3")], limit: 10)
        XCTAssertEqual(excluded.map(\.reference.id), ["m2", "m1"])

        let limited = try store.candidates(query: "", excluding: [], limit: 2)
        XCTAssertEqual(limited.map(\.reference.id), ["m3", "m2"])
    }

    func testCandidatesSearchFindsTitleAndBody() throws {
        let repo = try makeRepo()
        let store = makeStore(repo)
        try seedMemo(repo, id: "m1", body: "오전 회의 준비", date: monday)
        try seedMemo(repo, id: "m2", body: "점심 약속", date: tuesday)
        try seedTask(repo, id: "t1", title: "회의 자료 정리", date: wednesday)

        let candidates = try store.candidates(query: "회의", excluding: [], limit: 10)
        XCTAssertEqual(Set(candidates.map(\.reference.id)), ["m1", "t1"])
        XCTAssertEqual(candidates.map(\.reference.id), ["t1", "m1"],
                       "검색 결과도 최근 순으로 정렬된다")
    }

    func testCandidatesLikeSpecialCharactersAreLiteral() throws {
        let repo = try makeRepo()
        let store = makeStore(repo)
        try seedMemo(repo, id: "pct", body: "진행률 100% 달성", date: monday)
        try seedMemo(repo, id: "score", body: "진행률 100점", date: tuesday)
        try seedMemo(repo, id: "under", body: "a_b 패턴", date: wednesday)
        try seedMemo(repo, id: "other", body: "axb 패턴", date: thursday)

        let percent = try store.candidates(query: "100%", excluding: [], limit: 10)
        XCTAssertEqual(percent.map(\.reference.id), ["pct"],
                       "%는 LIKE 와일드카드가 아니라 리터럴이어야 한다")

        let underscore = try store.candidates(query: "a_b", excluding: [], limit: 10)
        XCTAssertEqual(underscore.map(\.reference.id), ["under"],
                       "_는 LIKE 와일드카드가 아니라 리터럴이어야 한다")
    }

    func testCandidatesIncludeReportVersion() throws {
        let repo = try makeRepo()
        let store = makeStore(repo)
        let week = DateRange(start: monday, endExclusive: thursday)
        try seedReportVersion(repo, reportId: "r1", versionId: "rv1", family: .submission,
                              periodKey: "2026-W41", range: week, version: 2,
                              content: "제출용 주간보고 본문",
                              createdAt: at(repo, wednesday, hour: 18))

        let candidates = try store.candidates(query: "", excluding: [], limit: 10)
        XCTAssertEqual(candidates.count, 1)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.reference, RecordReference(kind: .reportVersion, id: "rv1"))
        XCTAssertEqual(candidate.title, "제출용 주간보고 2026-10-05~2026-10-07 v2")
        XCTAssertEqual(candidate.subtitle, "리포트 2026-10-05")
    }

    func testCandidatesDoNotReturnDeletedRecords() throws {
        let repo = try makeRepo()
        let store = makeStore(repo)
        try seedMemo(repo, id: "m1", body: "남는 메모", date: monday)
        try seedMemo(repo, id: "m2", body: "지울 메모", date: tuesday)
        try repo.softDeleteMemo(id: "m2")

        let candidates = try store.candidates(query: "", excluding: [], limit: 10)
        XCTAssertEqual(candidates.map(\.reference.id), ["m1"])
    }
}
