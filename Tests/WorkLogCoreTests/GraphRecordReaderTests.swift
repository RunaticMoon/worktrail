import XCTest
@testable import WorkLogCore

/// GraphRecordReader: 일반 기록과 기존 관계를 그래프 DTO로 읽는 결정적 읽기 전용 리더.
final class GraphRecordReaderTests: XCTestCase {

    private let monday = WorkDate("2026-10-05")!
    private let tuesday = WorkDate("2026-10-06")!
    private let wednesday = WorkDate("2026-10-07")!
    private let friday = WorkDate("2026-10-09")!
    private let saturday = WorkDate("2026-10-10")!

    private func makeRepo() throws -> WorkRepository {
        try WorkRepository.inMemory(clock: FixedClock(Date(timeIntervalSince1970: 1_790_000_000)),
                                    ids: SequentialIDGenerator())
    }

    /// 해당 업무일의 지역 자정 기준 시각. created_at/work_date 대응을 명확히 한다.
    private func at(_ repo: WorkRepository, _ date: WorkDate, hour: Int = 9) -> Date {
        repo.calendar.startOfDay(date).addingTimeInterval(TimeInterval(hour * 3600))
    }

    private func nodesByID(_ result: (nodes: [GraphNode], edges: [GraphEdge])) -> [GraphNodeID: GraphNode] {
        Dictionary(uniqueKeysWithValues: result.nodes.map { ($0.id, $0) })
    }

    // MARK: 1. activity → task 직접 관계와 노드 표현

    func testActivityTaskEdgeAndNodes() throws {
        let repo = try makeRepo()
        try repo.insertTask(WorkTask(id: "t1", title: "길찾기", createdAt: at(repo, monday)))
        let longBody = String(repeating: "가", count: 50) + "\n둘째 줄"
        try repo.insertActivity(Activity(id: "a1", taskId: "t1", body: longBody,
                                         workDate: monday, recordedAt: at(repo, monday, hour: 10)))

        let result = try GraphRecordReader(repo: repo).read(range: nil)
        let byID = nodesByID(result)

        let activityNode = try XCTUnwrap(byID[GraphNodeID(kind: .activity, id: "a1")])
        XCTAssertEqual(activityNode.title, String(repeating: "가", count: 40))
        XCTAssertEqual(activityNode.subtitle, "길찾기")
        XCTAssertEqual(activityNode.record, RecordReference(kind: .activity, id: "a1"))
        XCTAssertEqual(activityNode.date, monday)

        let taskNode = try XCTUnwrap(byID[GraphNodeID(kind: .task, id: "t1")])
        XCTAssertEqual(taskNode.title, "길찾기")
        XCTAssertEqual(taskNode.record, RecordReference(kind: .task, id: "t1"))
        XCTAssertEqual(taskNode.date, monday)

        let edge = try XCTUnwrap(result.edges.first { $0.kind == .activityTask })
        XCTAssertEqual(edge.from, GraphNodeID(kind: .activity, id: "a1"))
        XCTAssertEqual(edge.to, GraphNodeID(kind: .task, id: "t1"))
        XCTAssertEqual(edge.sourceKey, "activity:a1")
        XCTAssertTrue(edge.isDirected)
    }

    func testMemoTitleIsFirstLinePrefix() throws {
        let repo = try makeRepo()
        try repo.insertMemo(Memo(id: "m1", body: "  첫 줄 요약입니다  \n둘째 줄",
                                 workDate: monday, recordedAt: at(repo, monday)))
        let result = try GraphRecordReader(repo: repo).read(range: nil)
        XCTAssertEqual(result.nodes.first { $0.id == GraphNodeID(kind: .memo, id: "m1") }?.title,
                       "첫 줄 요약입니다")
    }

    // MARK: 2. memo → task 는 accepted 만

    func testAcceptedMemoTaskLinkOnly() throws {
        let repo = try makeRepo()
        try repo.insertTask(WorkTask(id: "t1", title: "업무", createdAt: at(repo, monday)))
        try repo.insertMemo(Memo(id: "m1", body: "메모", workDate: monday, recordedAt: at(repo, monday)))

        let statuses: [MemoTaskLinkStatus] = [.proposed, .accepted, .rejected, .deferred]
        for (index, status) in statuses.enumerated() {
            try repo.upsertMemoTaskLink(MemoTaskLink(id: "l\(index)", memoId: "m1", taskId: "t1",
                                                     status: status, reason: "", sourceRevision: 1,
                                                     createdAt: at(repo, monday)))
        }

        let result = try GraphRecordReader(repo: repo).read(range: nil)
        let memoEdges = result.edges.filter { $0.kind == .acceptedMemoTask }
        XCTAssertEqual(memoEdges.count, 1)
        let edge = try XCTUnwrap(memoEdges.first)
        XCTAssertEqual(edge.from, GraphNodeID(kind: .memo, id: "m1"))
        XCTAssertEqual(edge.to, GraphNodeID(kind: .task, id: "t1"))
        XCTAssertEqual(edge.sourceKey, "memo_task_link:l1")
    }

    // MARK: 3. task → task 방향·유형 보존

    func testTaskRelationDirectionAndKinds() throws {
        let repo = try makeRepo()
        for id in ["t1", "t2", "t3"] {
            try repo.insertTask(WorkTask(id: id, title: id, createdAt: at(repo, monday)))
        }
        try repo.insertRelation(TaskRelation(id: "r1", fromTaskId: "t1", toTaskId: "t2",
                                             type: .followUp, createdAt: at(repo, monday)))
        try repo.insertRelation(TaskRelation(id: "r2", fromTaskId: "t3", toTaskId: "t1",
                                             type: .related, createdAt: at(repo, monday)))

        let result = try GraphRecordReader(repo: repo).read(range: nil)

        let followUp = try XCTUnwrap(result.edges.first { $0.kind == .taskFollowUp })
        XCTAssertEqual(followUp.from, GraphNodeID(kind: .task, id: "t1"))
        XCTAssertEqual(followUp.to, GraphNodeID(kind: .task, id: "t2"))
        XCTAssertEqual(followUp.sourceKey, "task_relation:r1")

        let related = try XCTUnwrap(result.edges.first { $0.kind == .taskRelated })
        XCTAssertEqual(related.from, GraphNodeID(kind: .task, id: "t3"))
        XCTAssertEqual(related.to, GraphNodeID(kind: .task, id: "t1"))
        XCTAssertEqual(related.sourceKey, "task_relation:r2")
    }

    // MARK: 4. 프로젝트·태그 경유 소속 (기록-기록 직접 엣지 금지)

    func testProjectAndTagMembershipWithoutDirectRecordEdges() throws {
        let repo = try makeRepo()
        let project = try repo.createProject(name: "대중교통")
        let sharedTag = try repo.findOrCreateTag(name: "공유")
        let unusedTag = try repo.findOrCreateTag(name: "미사용")

        try repo.insertMemo(Memo(id: "m1", body: "첫 메모", workDate: monday,
                                 recordedAt: at(repo, monday),
                                 projectIds: [project.id], tagIds: [sharedTag.id]))
        try repo.insertMemo(Memo(id: "m2", body: "둘째 메모", workDate: monday,
                                 recordedAt: at(repo, monday), tagIds: [sharedTag.id]))
        try repo.insertTask(WorkTask(id: "t1", title: "업무", createdAt: at(repo, monday),
                                     tagIds: [sharedTag.id]))
        try repo.linkProject(taskId: "t1", projectId: project.id, trackingEnabled: true, linkedOn: monday)
        try repo.insertActivity(Activity(id: "a1", taskId: "t1", body: "활동", workDate: monday,
                                         recordedAt: at(repo, monday), projectIds: [project.id]))

        let result = try GraphRecordReader(repo: repo).read(range: nil)
        let byID = nodesByID(result)

        XCTAssertEqual(byID[GraphNodeID(kind: .project, id: project.id)]?.title, "대중교통")
        XCTAssertEqual(byID[GraphNodeID(kind: .tag, id: sharedTag.id)]?.title, "공유")
        XCTAssertNil(byID[GraphNodeID(kind: .tag, id: unusedTag.id)], "참조되지 않은 태그는 노드가 아니다")

        let membershipEdges = Set(result.edges.filter { $0.kind == .projectMembership || $0.kind == .tagMembership })
        XCTAssertTrue(membershipEdges.contains(GraphEdge(
            from: GraphNodeID(kind: .memo, id: "m1"),
            to: GraphNodeID(kind: .project, id: project.id),
            kind: .projectMembership,
            sourceKey: "memo_project:m1:\(project.id)", isDirected: true)))
        XCTAssertTrue(membershipEdges.contains(GraphEdge(
            from: GraphNodeID(kind: .task, id: "t1"),
            to: GraphNodeID(kind: .tag, id: sharedTag.id),
            kind: .tagMembership,
            sourceKey: "task_tag:t1:\(sharedTag.id)", isDirected: true)))

        // 공유 태그/프로젝트로 기록-기록 직접 엣지를 만들지 않는다 (activityTask는 직접 관계라 예외).
        let directRecordEdges = result.edges.filter {
            $0.kind != .activityTask
                && $0.from.kind != .project && $0.from.kind != .tag
                && $0.to.kind != .project && $0.to.kind != .tag
        }
        XCTAssertTrue(directRecordEdges.isEmpty, "기록-기록 직접 엣지가 생기면 안 된다: \(directRecordEdges)")
    }

    // MARK: 5. 소프트 삭제 제외

    func testSoftDeletedRowsExcluded() throws {
        let repo = try makeRepo()
        let deletedAt = at(repo, tuesday)

        try repo.insertMemo(Memo(id: "m1", body: "살아있음", workDate: monday, recordedAt: at(repo, monday)))
        try repo.insertMemo(Memo(id: "m2", body: "삭제됨", workDate: monday,
                                 recordedAt: at(repo, monday), deletedAt: deletedAt))
        try repo.insertTask(WorkTask(id: "t1", title: "살아있음", createdAt: at(repo, monday)))
        try repo.insertTask(WorkTask(id: "t2", title: "삭제됨", createdAt: at(repo, monday),
                                     deletedAt: deletedAt))
        try repo.insertActivity(Activity(id: "a1", taskId: "t1", body: "살아있음",
                                         workDate: monday, recordedAt: at(repo, monday)))
        try repo.insertActivity(Activity(id: "a2", taskId: "t1", body: "삭제됨",
                                         workDate: monday, recordedAt: at(repo, monday),
                                         deletedAt: deletedAt))

        let result = try GraphRecordReader(repo: repo).read(range: nil)
        let ids = Set(result.nodes.map(\.id))
        XCTAssertTrue(ids.contains(GraphNodeID(kind: .memo, id: "m1")))
        XCTAssertFalse(ids.contains(GraphNodeID(kind: .memo, id: "m2")))
        XCTAssertFalse(ids.contains(GraphNodeID(kind: .task, id: "t2")))
        XCTAssertFalse(ids.contains(GraphNodeID(kind: .activity, id: "a2")))
        XCTAssertFalse(result.edges.contains { $0.sourceKey == "activity:a2" })
    }

    func testLiveActivityOnDeletedTaskHasNoEdge() throws {
        let repo = try makeRepo()
        try repo.insertTask(WorkTask(id: "t1", title: "삭제된 업무", createdAt: at(repo, monday),
                                     deletedAt: at(repo, tuesday)))
        try repo.insertActivity(Activity(id: "a1", taskId: "t1", body: "활동",
                                         workDate: monday, recordedAt: at(repo, monday)))

        let result = try GraphRecordReader(repo: repo).read(range: nil)
        let ids = Set(result.nodes.map(\.id))
        XCTAssertTrue(ids.contains(GraphNodeID(kind: .activity, id: "a1")))
        XCTAssertFalse(ids.contains(GraphNodeID(kind: .task, id: "t1")))
        XCTAssertFalse(result.edges.contains { $0.kind == .activityTask })
        let activityNode = result.nodes.first { $0.id == GraphNodeID(kind: .activity, id: "a1") }
        XCTAssertNil(activityNode?.subtitle)
        XCTAssertTrue(result.edges.allSatisfy { ids.contains($0.from) && ids.contains($0.to) })
    }

    // MARK: 6. 날짜 범위 필터

    func testDateRangeFilterIncludesCreatedAndActiveTasks() throws {
        let repo = try makeRepo()
        try repo.insertMemo(Memo(id: "m-mon", body: "월요일", workDate: monday, recordedAt: at(repo, monday)))
        try repo.insertMemo(Memo(id: "m-fri", body: "금요일", workDate: friday, recordedAt: at(repo, friday)))

        try repo.insertTask(WorkTask(id: "t-created", title: "범위 내 생성", createdAt: at(repo, monday)))
        try repo.insertTask(WorkTask(id: "t-out", title: "범위 밖 생성", createdAt: at(repo, friday)))
        try repo.insertTask(WorkTask(id: "t-active", title: "활동 있는 업무", createdAt: at(repo, friday)))

        try repo.insertActivity(Activity(id: "a-tue", taskId: "t-active", body: "범위 내 활동",
                                         workDate: tuesday, recordedAt: at(repo, tuesday)))
        try repo.insertActivity(Activity(id: "a-fri", taskId: "t-out", body: "범위 밖 활동",
                                         workDate: friday, recordedAt: at(repo, friday)))

        let range = DateRange(start: monday, endExclusive: wednesday)
        let result = try GraphRecordReader(repo: repo).read(range: range)
        let ids = Set(result.nodes.map(\.id))

        XCTAssertTrue(ids.contains(GraphNodeID(kind: .memo, id: "m-mon")))
        XCTAssertFalse(ids.contains(GraphNodeID(kind: .memo, id: "m-fri")))
        XCTAssertTrue(ids.contains(GraphNodeID(kind: .task, id: "t-created")))
        XCTAssertTrue(ids.contains(GraphNodeID(kind: .task, id: "t-active")))
        XCTAssertFalse(ids.contains(GraphNodeID(kind: .task, id: "t-out")))
        XCTAssertTrue(ids.contains(GraphNodeID(kind: .activity, id: "a-tue")))
        XCTAssertFalse(ids.contains(GraphNodeID(kind: .activity, id: "a-fri")))
        XCTAssertEqual(result.edges.filter { $0.kind == .activityTask }.count, 1)
        XCTAssertTrue(result.edges.allSatisfy { ids.contains($0.from) && ids.contains($0.to) })
    }

    // MARK: 7. 성과 보충

    func testSupplementTaskEdge() throws {
        let repo = try makeRepo()
        try repo.insertTask(WorkTask(id: "t1", title: "업무", createdAt: at(repo, monday)))
        try repo.insertSupplement(EvidenceSupplement(id: "s1", taskId: "t1", topicKey: "reason",
                                                     question: "왜?", answer: "때문에", outcome: .answered,
                                                     applies: DateRange(start: monday, endExclusive: tuesday),
                                                     sourceDigest: "d", recordedAt: at(repo, monday)))

        let result = try GraphRecordReader(repo: repo).read(range: nil)
        let byID = nodesByID(result)
        let node = try XCTUnwrap(byID[GraphNodeID(kind: .supplement, id: "s1")])
        XCTAssertEqual(node.title, "왜?")
        XCTAssertEqual(node.subtitle, "때문에")
        XCTAssertNil(node.record)
        XCTAssertEqual(node.date, monday)

        let edge = try XCTUnwrap(result.edges.first { $0.kind == .supplementTask })
        XCTAssertEqual(edge.from, GraphNodeID(kind: .supplement, id: "s1"))
        XCTAssertEqual(edge.to, GraphNodeID(kind: .task, id: "t1"))
        XCTAssertEqual(edge.sourceKey, "evidence_supplement:s1")
    }

    func testRangeOmitsSupplementOfOutOfRangeTask() throws {
        let repo = try makeRepo()
        try repo.insertTask(WorkTask(id: "t-in", title: "범위 내", createdAt: at(repo, monday)))
        try repo.insertTask(WorkTask(id: "t-out", title: "범위 밖", createdAt: at(repo, friday)))
        try repo.insertSupplement(EvidenceSupplement(id: "s-in", taskId: "t-in", topicKey: "reason",
                                                     question: "in", answer: nil, outcome: .answered,
                                                     applies: DateRange(start: monday, endExclusive: tuesday),
                                                     sourceDigest: "d", recordedAt: at(repo, monday)))
        try repo.insertSupplement(EvidenceSupplement(id: "s-out", taskId: "t-out", topicKey: "reason",
                                                     question: "out", answer: nil, outcome: .answered,
                                                     applies: DateRange(start: friday, endExclusive: saturday),
                                                     sourceDigest: "d", recordedAt: at(repo, friday)))

        let range = DateRange(start: monday, endExclusive: wednesday)
        let result = try GraphRecordReader(repo: repo).read(range: range)
        let ids = Set(result.nodes.map(\.id))
        XCTAssertTrue(ids.contains(GraphNodeID(kind: .supplement, id: "s-in")))
        XCTAssertFalse(ids.contains(GraphNodeID(kind: .supplement, id: "s-out")))
        XCTAssertTrue(result.edges.contains { $0.sourceKey == "evidence_supplement:s-in" })
        XCTAssertFalse(result.edges.contains { $0.sourceKey == "evidence_supplement:s-out" })
    }

    // MARK: 8. 정렬 결정성·중복 없음

    func testResultOrderingIsDeterministic() throws {
        let repo = try makeRepo()
        // 삽입 순서를 일부러 뒤섞는다.
        try repo.insertTask(WorkTask(id: "t5", title: "다섯", createdAt: at(repo, monday)))
        try repo.insertTask(WorkTask(id: "t1", title: "하나", createdAt: at(repo, monday)))
        try repo.insertMemo(Memo(id: "m2", body: "둘", workDate: monday, recordedAt: at(repo, monday)))
        try repo.insertMemo(Memo(id: "m1", body: "하나", workDate: monday, recordedAt: at(repo, monday)))
        try repo.insertActivity(Activity(id: "a1", taskId: "t1", body: "활동",
                                         workDate: monday, recordedAt: at(repo, monday)))

        let reader = GraphRecordReader(repo: repo)
        let first = try reader.read(range: nil)
        let second = try reader.read(range: nil)

        XCTAssertEqual(first.nodes.map(\.id.key), first.nodes.map(\.id.key).sorted())
        XCTAssertEqual(first.edges.map(\.key), first.edges.map(\.key).sorted())
        XCTAssertEqual(first.nodes, second.nodes)
        XCTAssertEqual(first.edges, second.edges)
        XCTAssertEqual(Set(first.nodes.map(\.id)).count, first.nodes.count, "중복 노드가 없다")
        XCTAssertEqual(Set(first.edges.map(\.key)).count, first.edges.count, "중복 엣지가 없다")
    }

    // MARK: 9. 모든 엣지 끝점 존재

    func testAllEdgeEndpointsExistWithMixedRelations() throws {
        let repo = try makeRepo()
        let project = try repo.createProject(name: "P")
        let tag = try repo.findOrCreateTag(name: "T")

        try repo.insertTask(WorkTask(id: "t1", title: "업무1", createdAt: at(repo, monday), tagIds: [tag.id]))
        try repo.insertTask(WorkTask(id: "t2", title: "업무2", createdAt: at(repo, monday)))
        try repo.linkProject(taskId: "t1", projectId: project.id, trackingEnabled: false, linkedOn: monday)
        try repo.insertActivity(Activity(id: "a1", taskId: "t1", body: "활동", workDate: monday,
                                         recordedAt: at(repo, monday), projectIds: [project.id]))
        try repo.insertMemo(Memo(id: "m1", body: "메모", workDate: monday, recordedAt: at(repo, monday),
                                 projectIds: [project.id], tagIds: [tag.id]))
        try repo.upsertMemoTaskLink(MemoTaskLink(id: "l1", memoId: "m1", taskId: "t1", status: .accepted,
                                                 reason: "", sourceRevision: 1, createdAt: at(repo, monday)))
        try repo.insertRelation(TaskRelation(id: "r1", fromTaskId: "t1", toTaskId: "t2",
                                             type: .related, createdAt: at(repo, monday)))
        try repo.insertSupplement(EvidenceSupplement(id: "s1", taskId: "t1", topicKey: "reason",
                                                     question: "질문", answer: "답", outcome: .answered,
                                                     applies: DateRange(start: monday, endExclusive: tuesday),
                                                     sourceDigest: "d", recordedAt: at(repo, monday)))

        let result = try GraphRecordReader(repo: repo).read(range: nil)
        let nodeKeys = Set(result.nodes.map(\.id))
        XCTAssertFalse(result.edges.isEmpty)
        for edge in result.edges {
            XCTAssertTrue(nodeKeys.contains(edge.from), "없는 from 끝점: \(edge)")
            XCTAssertTrue(nodeKeys.contains(edge.to), "없는 to 끝점: \(edge)")
        }
        // 기대한 종류가 모두 등장한다.
        let kinds = Set(result.edges.map(\.kind))
        XCTAssertTrue(kinds.isSuperset(of: [.activityTask, .acceptedMemoTask, .taskRelated,
                                            .projectMembership, .tagMembership, .supplementTask]))
    }
}
