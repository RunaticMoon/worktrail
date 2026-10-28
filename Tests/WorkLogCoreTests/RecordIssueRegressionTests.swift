import XCTest
@testable import WorkLogCore

final class RecordIssueRegressionTests: XCTestCase {
    private var roots: [URL] = []
    private let today = WorkDate("2026-10-05")!
    private let yesterday = WorkDate("2026-10-04")!
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) }; super.tearDown() }
    private func environment() throws -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecordIssues-\(UUID().uuidString)")
        roots.append(root)
        let paths = AppPaths(dataRoot: root, backupRoot: root.appendingPathComponent("backups"))
        var settings = AppSettings(); settings.aiEnabled = false
        try SettingsStore(fileURL: paths.settingsFile).save(settings)
        return try AppEnvironment.open(AppEnvironmentOptions(paths: paths, keyStore: InMemoryVaultKeyStore(),
            authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(),
            clock: FixedClock(WorkCalendar().startOfDay(today)), ids: SequentialIDGenerator()))
    }

    @MainActor func testMemoMetadataHistoryIsAtomicAndReindexesWithoutChangingIdentity() async throws {
        let env = try environment()
        let p = try env.repo.createProject(name: "원래 분류")
        let q = try env.repo.createProject(name: "새로운 분류")
        let tag = try env.repo.findOrCreateTag(name: "기존태그")
        let memo = Memo(id: "memo", body: "원래 본문", workDate: today, recordedAt: env.options.clock.now(), projectIds: [p.id], tagIds: [tag.id])
        try env.repo.insertMemo(memo)
        let task = try env.tasks.createTask(title: "업무", workDate: today)
        let related = try RecordLinkStore(repo: env.repo).add(between: RecordReference(kind: .memo, id: memo.id), and: RecordReference(kind: .task, id: task.id))
        let edited = try env.repo.updateMemo(id: memo.id, body: "수정한 본문", workDate: yesterday,
            projectIds: [q.id], tagNames: ["새태그"], expectedRevision: 1)
        XCTAssertEqual(edited.id, memo.id); XCTAssertEqual(edited.recordedAt, memo.recordedAt)
        XCTAssertTrue(try env.repo.memos(on: today).isEmpty)
        XCTAssertEqual(try env.repo.memos(on: yesterday).map(\.id), [memo.id])
        XCTAssertEqual(try RecordLinkStore(repo: env.repo).links(for: RecordReference(kind: .memo, id: memo.id)), [related])
        let history = try XCTUnwrap(env.repo.memoHistory(id: memo.id).first)
        XCTAssertEqual(history.memo, memo); XCTAssertTrue(history.classificationRecorded)
        XCTAssertNotNil(history.supersededAt); XCTAssertNotNil(try env.repo.memoUpdatedAt(id: memo.id))
        XCTAssertEqual(try env.search.search(SearchQuery(text: "수정한", projectIds: [q.id])).map(\.sourceId), [memo.id])
        XCTAssertTrue(try env.search.search(SearchQuery(text: "원래 본문")).isEmpty)
        XCTAssertThrowsError(try env.repo.updateMemo(id: memo.id, body: "실패", workDate: today, projectIds: ["missing"], tagNames: ["rollback"]))
        XCTAssertThrowsError(try env.repo.updateMemo(id: memo.id, body: "충돌", workDate: today, projectIds: [], tagNames: [], expectedRevision: 1))
        XCTAssertEqual(try env.repo.memo(id: memo.id), edited)
        XCTAssertEqual(try env.repo.memoHistory(id: memo.id).count, 1)
        XCTAssertFalse(try env.repo.tags().contains { $0.name == "rollback" })
    }

    @MainActor func testManualEvidenceDecisionWorksWithAIDisabledAndReapprovesCurrentRevision() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "근거 대상 업무", workDate: today)
        try env.repo.insertMemo(Memo(id: "memo", body: "원문", workDate: today, recordedAt: env.options.clock.now()))
        let detail = MemoDetailModel(environment: env); detail.load(id: "memo")
        XCTAssertFalse(detail.isAIAvailable)
        detail.connect(taskId: task.id)
        let link = try XCTUnwrap(detail.links.first)
        detail.connect(taskId: task.id)
        XCTAssertEqual(detail.links.count, 1)
        XCTAssertEqual(detail.links.first?.status, .accepted)
        XCTAssertTrue(try RecordLinkStore(repo: env.repo).links(for: RecordReference(kind: .memo, id: "memo")).isEmpty)
        try env.repo.updateMemoBody(id: "memo", body: "수정 원문", workDate: today)
        detail.load(id: "memo")
        XCTAssertEqual(detail.links.first?.sourceRevision, 1)
        detail.decide(linkId: link.id, status: .rejected)
        XCTAssertEqual(detail.links.first?.status, .rejected)
        XCTAssertTrue(try GraphRecordReader(repo: env.repo).read(range: nil).edges.filter { $0.kind == .acceptedMemoTask }.isEmpty)
        detail.decide(linkId: link.id, status: .deferred)
        XCTAssertEqual(detail.links.first?.status, .deferred)
        detail.decide(linkId: link.id, status: .accepted)
        XCTAssertEqual(detail.links.first?.sourceRevision, 2)
        XCTAssertEqual(try GraphRecordReader(repo: env.repo).read(range: nil).edges.filter { $0.kind == .acceptedMemoTask }.count, 1)
        let facts = try env.factsBuilder.build(family: .performance, periodType: .daily,
            range: DateRange(start: today, endExclusive: env.calendar.adding(days: 1, to: today)), knownAt: env.options.clock.now())
        XCTAssertEqual(facts.memoLinksAccepted.count, 1)
        XCTAssertEqual(try env.repo.tasks().count, 1)
        XCTAssertEqual(try env.tasks.currentStatus(taskId: task.id), .planned)
    }

    @MainActor func testBothCaptureDraftsSurviveNewSessionAndSuccessfulSaveClearsOnlyOne() async throws {
        let env = try environment()
        let task = try env.tasks.createTask(title: "기존 업무", workDate: today)
        let project = try env.repo.createProject(name: "프로젝트")
        let tag = try env.repo.findOrCreateTag(name: "태그")
        let session = CaptureSessionModel(environment: env)
        session.memoDraft.text = "메모 초안"; session.memoDraft.workDate = yesterday
        session.memoDraft.addProject(id: project.id); session.memoDraft.addTag(id: tag.id)
        session.memoDraft.relatedRecords = [RelatedRecordCandidate(reference: RecordReference(kind: .task, id: task.id), title: task.title)]
        session.taskDraft.text = "업무 초안"; session.taskDraft.taskQuery = "기존"
        session.taskDraft.taskSelection = .existing(task.id); session.taskDraft.taskAction = .changeStatus
        session.taskDraft.statusTarget = .inProgress; session.taskDraft.dueOn = today
        let memoSnapshot = session.memoDraft.checkpoint(), taskSnapshot = session.taskDraft.checkpoint()
        XCTAssertTrue(session.flushCheckpoints())
        let restored = CaptureSessionModel(environment: env)
        XCTAssertEqual(restored.memoDraft.checkpoint(), memoSnapshot)
        XCTAssertEqual(restored.taskDraft.checkpoint(), taskSnapshot)
        XCTAssertEqual(restored.recoveredKinds, [.memo, .task])
        XCTAssertTrue(try env.repo.memos(on: yesterday).isEmpty)
        XCTAssertEqual(try env.tasks.currentStatus(taskId: task.id), .planned)
        restored.select(.memo)
        XCTAssertFalse(restored.submitOrdinary(), "복구한 초안은 명시적으로 이어 쓰기 전까지 제출하지 않음")
        restored.continueRecoveredDraft()
        XCTAssertTrue(restored.submitOrdinary())
        let reopened = CaptureSessionModel(environment: env)
        XCTAssertEqual(reopened.memoDraft.text, "")
        XCTAssertEqual(reopened.taskDraft.checkpoint(), taskSnapshot)
        reopened.select(.task)
        XCTAssertTrue(reopened.startNewOrdinaryDraft())
        XCTAssertTrue(CaptureSessionModel(environment: env).recoveredKinds.isEmpty)
        XCTAssertEqual(try env.repo.memos(on: yesterday).count, 1)
        session.detach(); restored.detach(); reopened.detach()
    }

    @MainActor func testCheckpointCorruptionIsIsolatedAndMissingTaskDoesNotBecomeNewTask() async throws {
        let env = try environment()
        let session = CaptureSessionModel(environment: env)
        session.memoDraft.text = "정상 초안"
        session.taskDraft.text = "대상 보존"; session.taskDraft.taskSelection = .existing("deleted-task")
        XCTAssertTrue(session.flushCheckpoints())
        let directory = env.options.paths.dataRoot.appendingPathComponent("capture-drafts")
        try Data("broken".utf8).write(to: directory.appendingPathComponent("memo.json"))
        let restored = CaptureSessionModel(environment: env)
        XCTAssertTrue(restored.checkpointFailed)
        XCTAssertEqual(restored.taskDraft.text, "대상 보존")
        restored.select(.task); restored.continueRecoveredDraft()
        XCTAssertNotNil(restored.taskDraft.missingReferenceMessage)
        XCTAssertFalse(restored.submitOrdinary())
        XCTAssertTrue(try env.repo.tasks().isEmpty)
        let serialized = try String(contentsOf: directory.appendingPathComponent("task.json"), encoding: .utf8)
        XCTAssertFalse(serialized.lowercased().contains("secret"))
        session.detach(); restored.detach()
    }

    @MainActor func testCheckpointFlushFailureRetainsDraftAndCanRetry() async throws {
        let env = try environment()
        let location = env.options.paths.dataRoot.appendingPathComponent("capture-drafts")
        try Data("block directory".utf8).write(to: location)
        let session = CaptureSessionModel(environment: env)
        session.memoDraft.text = "실패해도 유지"
        XCTAssertFalse(session.flushCheckpoints())
        XCTAssertTrue(session.checkpointFailed)
        XCTAssertEqual(session.memoDraft.text, "실패해도 유지")
        XCTAssertFalse(session.startNewOrdinaryDraft())
        XCTAssertEqual(session.memoDraft.text, "실패해도 유지")
        try FileManager.default.removeItem(at: location)
        XCTAssertTrue(session.flushCheckpoints())
        XCTAssertEqual(CaptureSessionModel(environment: env).memoDraft.text, "실패해도 유지")
        session.detach()
    }

    @MainActor func testConfirmedReportsCreateRevisionWithoutChangingFrozenVersionForBothFamilies() async throws {
        let env = try environment()
        try env.repo.insertMemo(Memo(id: "memo", body: "보고서 근거", workDate: yesterday, recordedAt: env.options.clock.now()))
        for family in [ReportFamily.submission, .performance] {
            let model = ReportsModel(environment: env)
            model.family = family; model.useAI = false
            if family == .performance {
                model.evaluationStart = yesterday; model.evaluationEnd = today
                model.proposeEvaluation(); model.createEvaluation()
            }
            await model.generate()
            model.confirm()
            let original = try XCTUnwrap(model.version)
            XCTAssertEqual(original.state, .confirmed)
            let oldEvidence = try env.repo.reportEvidence(versionId: original.id)
            let originalPeriod = model.evaluationPeriodId
            let expectedNextStart = family == .performance
                ? try env.evaluationPeriods.propose(start: nil, endInclusive: env.calendar.adding(days: 7, to: today)).range.start : nil
            model.beginConfirmedRevision()
            model.saveEdits()
            XCTAssertEqual(try env.repo.reportVersions(reportId: original.reportId).count, 1, "변경 없이 새 버전을 만들지 않음")
            model.content += "\n오타 수정"
            model.discardEdits()
            XCTAssertEqual(model.content, original.content)
            model.beginConfirmedRevision(); model.content += "\n오타 수정"
            let pendingContent = model.content
            try env.repo.db.execute("CREATE TEMP TRIGGER fail_revision BEFORE INSERT ON report_version BEGIN SELECT RAISE(ABORT, 'test failure'); END;")
            model.saveEdits()
            XCTAssertEqual(model.content, pendingContent); XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(try env.repo.reportVersion(id: original.id), original)
            try env.repo.db.execute("DROP TRIGGER fail_revision;")
            model.saveEdits()
            let revision = try XCTUnwrap(model.version)
            XCTAssertEqual(revision.state, .edited)
            XCTAssertEqual(revision.basedOnVersionId, original.id)
            XCTAssertEqual(revision.sourceSnapshotId, original.sourceSnapshotId)
            XCTAssertEqual(revision.templateVersionId, original.templateVersionId)
            XCTAssertEqual(revision.skillRef, original.skillRef)
            XCTAssertEqual(revision.aiModel, original.aiModel)
            XCTAssertEqual(try env.repo.reportVersion(id: original.id), original)
            XCTAssertEqual(try env.repo.reportEvidence(versionId: revision.id).map(\.sourceRevision), oldEvidence.map(\.sourceRevision))
            XCTAssertEqual(model.evaluationPeriodId, originalPeriod)
            if let expectedNextStart {
                XCTAssertEqual(try env.evaluationPeriods.propose(start: nil,
                    endInclusive: env.calendar.adding(days: 7, to: today)).range.start, expectedNextStart)
            }
        }
    }

    @MainActor func testSearchPagesCoverBoundariesLikeFTSAndStableMixedTypeTies() async throws {
        for count in [0, 49, 50, 51, 120] {
            let env = try environment()
            for index in 0..<count {
                let id = String(format: "%04d", index / 2)
                if index.isMultiple(of: 2) {
                    try env.repo.insertMemo(Memo(id: id, body: "가 가나다 검색", workDate: today, recordedAt: env.options.clock.now()))
                } else { try env.repo.insertTask(WorkTask(id: id, title: "가 가나다 검색", createdAt: env.options.clock.now())) }
            }
            for query in ["가", "가나", "가나다"] {
                var all: [SearchHit] = [], offset = 0
                while true {
                    let page = try env.search.searchPage(SearchQuery(text: query, limit: 50, offset: offset))
                    XCTAssertEqual(page.hasMore, count > offset + 50)
                    all += page.hits
                    if !page.hasMore { break }
                    offset += page.hits.count
                }
                XCTAssertEqual(all.count, count)
                XCTAssertEqual(Set(all.map(\.key)).count, count)
            }
        }
    }

    @MainActor func testSearchLoadMoreRefreshesDeletionAndRestoresSelectionWithoutMixingQueries() async throws {
        let env = try environment()
        for index in 0..<120 {
            try env.repo.insertMemo(Memo(id: "m-\(index)", body: "검색대상", workDate: today, recordedAt: env.options.clock.now()))
        }
        let model = SearchModel(environment: env); model.text = "검색대상"; model.search()
        XCTAssertEqual(model.hits.count, 50); XCTAssertTrue(model.hasMore)
        model.loadMore(); model.select(model.hits[75])
        let state = model.snapshot(), selected = model.selectedKey
        try env.repo.softDeleteMemo(id: "m-0")
        model.loadMore()
        XCTAssertEqual(model.hits.count, 119); XCTAssertFalse(model.hasMore)
        XCTAssertEqual(model.selectedKey, selected)
        let second = SearchModel(environment: env); second.restore(state)
        XCTAssertEqual(second.hits.count, 100); XCTAssertEqual(second.selectedKey, selected)
        model.text = "없는검색어"; model.search()
        XCTAssertTrue(model.hits.isEmpty); XCTAssertEqual(model.loadedLimit, 50)
        XCTAssertEqual(second.hits.count, 100)
    }
    @MainActor func testDebouncedCheckpointAndInterruptedTemporaryFileRecoverLastSuccess() async throws {
        let env = try environment()
        let capture = CaptureSessionModel(environment: env)
        capture.memoDraft.text = "마지막 성공 체크포인트"
        try await Task.sleep(for: .milliseconds(600))
        let directory = env.options.paths.dataRoot.appendingPathComponent("capture-drafts")
        try Data("interrupted write".utf8).write(to: directory.appendingPathComponent(".memo-interrupted.tmp"))
        capture.memoDraft.text = "아직 저장되지 않은 변경"
        let restored = CaptureSessionModel(environment: env)
        XCTAssertEqual(restored.memoDraft.text, "마지막 성공 체크포인트")
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("memo.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        capture.detach(); restored.detach()
    }

    @MainActor func testLargeSearchFixtureMeasuresFirstAndAdditionalPage() async throws {
        let env = try environment()
        try env.repo.db.transaction {
            for index in 0..<5_000 {
                try env.repo.insertMemo(Memo(id: "perf-\(index)", body: "대량검색 가나다 검증 \(index)",
                    workDate: today, recordedAt: env.options.clock.now()))
            }
        }
        let timer = ContinuousClock()
        for query in ["가", "가나", "가나다"] {
            let start = timer.now
            let first = try env.search.searchPage(SearchQuery(text: query))
            let firstDuration = start.duration(to: timer.now)
            let nextStart = timer.now
            let next = try env.search.searchPage(SearchQuery(text: query, offset: 50))
            let nextDuration = nextStart.duration(to: timer.now)
            let prefixStart = timer.now
            let prefix = try env.search.searchPage(SearchQuery(text: query, limit: 100))
            let prefixDuration = prefixStart.duration(to: timer.now)
            XCTAssertEqual(first.hits.count, 50); XCTAssertEqual(next.hits.count, 50)
            XCTAssertEqual(prefix.hits.count, 100)
            print("SEARCH_BENCH rows=5000 termLength=\(query.count) trigram=\(env.search.usesTrigram) first=\(firstDuration) next=\(nextDuration) visiblePrefix=\(prefixDuration)")
        }
    }

}
