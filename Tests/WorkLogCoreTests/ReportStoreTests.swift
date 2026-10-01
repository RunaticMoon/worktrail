import XCTest
@testable import WorkLogCore

final class ReportStoreTests: XCTestCase {

    private var repo: WorkRepository!
    private var store: ReportStore!

    private let baseDate = Date(timeIntervalSince1970: 1_790_000_000)
    private let range = DateRange(start: WorkDate("2026-09-28")!, endExclusive: WorkDate("2026-10-05")!)

    private func makeStore() throws -> (ReportStore, WorkRepository) {
        let clock = FixedClock(baseDate)
        let repo = try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator(prefix: "r"))
        self.repo = repo
        self.store = ReportStore(repo: repo)
        return (store, repo)
    }

    private func makeFacts(sources: [FactSource] = [], metrics: ReportMetrics = ReportMetrics()) -> ReportFacts {
        ReportFacts(family: .submission, periodType: .weekly, timezone: "Asia/Seoul",
                    generatedAt: baseDate, range: range, statusCutoff: baseDate, knownAt: baseDate,
                    projects: [], tasks: [], sources: sources, metrics: metrics)
    }

    private func makeSource(id: String = "activity:a1", revision: Int = 3) -> FactSource {
        FactSource(id: id, kind: .activity, revision: revision, recordedAt: baseDate,
                   workDate: range.start, taskId: "t1", projectIds: [], text: "근거 본문")
    }

    private func makeDraft(content: String = "본문", evidence: [DraftEvidence] = []) -> GeneratedDraft {
        GeneratedDraft(content: content, structuredJSON: "{}", warnings: [], generator: "deterministic",
                       templateVersionId: "tv1", skillRef: "skill-1", evidence: evidence)
    }

    private func ensureSubmissionReport() throws -> Report {
        try store.ensureReport(family: .submission, periodType: .weekly, periodKey: "2026-10-05", range: range)
    }

    // MARK: 1 — ensureReport 멱등 · family 분리 (REP-T03)

    func testEnsureReportIsIdempotentAndSeparatesFamilies() throws {
        let (store, repo) = try makeStore()

        let first = try store.ensureReport(family: .submission, periodType: .weekly,
                                           periodKey: "2026-10-05", range: range)
        let second = try store.ensureReport(family: .submission, periodType: .weekly,
                                            periodKey: "2026-10-05", range: range)
        XCTAssertEqual(first.id, second.id)

        let performance = try store.ensureReport(family: .performance, periodType: .weekly,
                                                 periodKey: "2026-W40", range: range)
        XCTAssertNotEqual(first.id, performance.id)
        XCTAssertEqual(try repo.reports().count, 2)

        let submissionOnly = try repo.reports(family: .submission)
        XCTAssertEqual(submissionOnly.map(\.id), [first.id])
        XCTAssertEqual(try store.bundle(reportId: performance.id).report.family, .performance)
    }

    // MARK: 2 — 첫 생성

    func testFirstSaveCreatesDraftSnapshotAndEvidence() throws {
        let (store, repo) = try makeStore()
        let report = try ensureSubmissionReport()
        let facts = makeFacts(sources: [makeSource(revision: 3)], metrics: ReportMetrics(activityCount: 1))
        let draft = makeDraft(evidence: [DraftEvidence(itemId: "i1", taskId: "t1", sourceId: "activity:a1")])

        let outcome = try store.saveGenerated(reportId: report.id, facts: facts, draft: draft, mode: .automatic)
        guard case .created(let version) = outcome else { return XCTFail("created를 기대: \(outcome)") }
        XCTAssertEqual(version.version, 1)
        XCTAssertEqual(version.state, .draft)
        XCTAssertNil(version.basedOnVersionId)
        XCTAssertEqual(version.content, "본문")
        XCTAssertEqual(version.structuredJSON, "{}")
        XCTAssertEqual(version.generator, "deterministic")
        XCTAssertEqual(version.templateVersionId, "tv1")
        XCTAssertEqual(version.skillRef, "skill-1")

        let snapshot = try XCTUnwrap(try repo.sourceSnapshot(id: version.sourceSnapshotId))
        XCTAssertEqual(snapshot.digest, try ReportFactsBuilder.digest(facts))
        XCTAssertEqual(snapshot.range, range)

        let evidence = try repo.reportEvidence(versionId: version.id)
        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(evidence[0].itemId, "i1")
        XCTAssertEqual(evidence[0].taskId, "t1")
        XCTAssertEqual(evidence[0].sourceId, "activity:a1")
        XCTAssertEqual(evidence[0].sourceRevision, 3)

        let bundle = try store.bundle(reportId: report.id)
        XCTAssertEqual(bundle.latest?.id, version.id)
        XCTAssertNil(bundle.latestConfirmed)
    }

    // MARK: 3 — 자동 재생성, 원본 동일 → unchanged

    func testAutomaticSameFactsIsUnchanged() throws {
        let (store, repo) = try makeStore()
        let report = try ensureSubmissionReport()
        let facts = makeFacts(metrics: ReportMetrics(activityCount: 1))

        _ = try store.saveGenerated(reportId: report.id, facts: facts, draft: makeDraft(), mode: .automatic)
        let second = try store.saveGenerated(reportId: report.id, facts: facts, draft: makeDraft(), mode: .automatic)

        guard case .unchanged(let version) = second else { return XCTFail("unchanged를 기대: \(second)") }
        XCTAssertEqual(version.version, 1)
        XCTAssertEqual(try repo.reportVersions(reportId: report.id).count, 1)
        XCTAssertEqual(try repo.db.scalarInt("SELECT COUNT(*) FROM source_snapshot"), 1)
    }

    // MARK: 4 — 사용자 요청, 원본 동일 → 새 버전 + 이전 draft 대체

    func testUserRequestedSameFactsCreatesNewVersion() throws {
        let (store, repo) = try makeStore()
        let report = try ensureSubmissionReport()
        let facts = makeFacts(metrics: ReportMetrics(activityCount: 1))

        let first = try store.saveGenerated(reportId: report.id, facts: facts, draft: makeDraft(), mode: .automatic)
        guard case .created(let v1) = first else { return XCTFail() }
        let second = try store.saveGenerated(reportId: report.id, facts: facts, draft: makeDraft(content: "두 번째"),
                                             mode: .userRequested)
        guard case .created(let v2) = second else { return XCTFail() }

        XCTAssertEqual(v2.version, 2)
        XCTAssertNil(v2.basedOnVersionId, "대체된 draft에는 기반을 두지 않는다")

        let versions = try repo.reportVersions(reportId: report.id)
        XCTAssertEqual(versions.count, 2)
        XCTAssertEqual(versions[0].id, v1.id)
        XCTAssertEqual(versions[0].state, .superseded)
        XCTAssertEqual(versions[1].state, .draft)
        XCTAssertEqual(try repo.db.scalarInt("SELECT COUNT(*) FROM source_snapshot"), 2)
    }

    // MARK: 5 — 자동 재생성, 원본 변경 → 새 버전 + 이전 draft 대체

    func testAutomaticChangedFactsSupersedesDraft() throws {
        let (store, repo) = try makeStore()
        let report = try ensureSubmissionReport()

        let first = try store.saveGenerated(reportId: report.id, facts: makeFacts(metrics: ReportMetrics(activityCount: 1)),
                                            draft: makeDraft(), mode: .automatic)
        guard case .created(let v1) = first else { return XCTFail() }
        let second = try store.saveGenerated(reportId: report.id, facts: makeFacts(metrics: ReportMetrics(activityCount: 2)),
                                             draft: makeDraft(content: "변경"), mode: .automatic)
        guard case .created(let v2) = second else { return XCTFail() }

        XCTAssertEqual(v2.version, 2)
        XCTAssertNil(v2.basedOnVersionId)
        let versions = try repo.reportVersions(reportId: report.id)
        XCTAssertEqual(versions[0].id, v1.id)
        XCTAssertEqual(versions[0].state, .superseded)
        XCTAssertEqual(versions[1].state, .draft)
    }

    // MARK: 6 — REP-T12: 편집본은 자동 재생성으로 손실되지 않는다

    func testEditPreservedAcrossAutomaticRegeneration() throws {
        let (store, repo) = try makeStore()
        let report = try ensureSubmissionReport()

        let first = try store.saveGenerated(reportId: report.id, facts: makeFacts(metrics: ReportMetrics(activityCount: 1)),
                                            draft: makeDraft(content: "자동 초안"), mode: .automatic)
        guard case .created(let v1) = first else { return XCTFail() }

        let edited = try store.edit(versionId: v1.id, content: "사용자 편집")
        XCTAssertEqual(edited.id, v1.id, "draft 편집은 같은 행을 고친다")
        XCTAssertEqual(edited.state, .edited)
        XCTAssertEqual(edited.content, "사용자 편집")

        let second = try store.saveGenerated(reportId: report.id, facts: makeFacts(metrics: ReportMetrics(activityCount: 2)),
                                             draft: makeDraft(content: "새 초안"), mode: .automatic)
        guard case .created(let v2) = second else { return XCTFail() }
        XCTAssertEqual(v2.version, 2)
        XCTAssertEqual(v2.basedOnVersionId, v1.id)

        let reloaded = try XCTUnwrap(try repo.reportVersion(id: v1.id))
        XCTAssertEqual(reloaded.state, .edited)
        XCTAssertEqual(reloaded.content, "사용자 편집", "편집 손실 금지 (REP-T12)")
    }

    // MARK: 7 — REP-T11: 확정본 뒤 자동 재생성, 확정본 불변

    func testConfirmedPreservedAcrossAutomaticRegeneration() throws {
        let (store, repo) = try makeStore()
        let report = try ensureSubmissionReport()

        let first = try store.saveGenerated(reportId: report.id, facts: makeFacts(metrics: ReportMetrics(activityCount: 1)),
                                            draft: makeDraft(content: "확정 대상"), mode: .automatic)
        guard case .created(let v1) = first else { return XCTFail() }
        let confirmed = try store.confirm(versionId: v1.id)
        XCTAssertEqual(confirmed.state, .confirmed)
        XCTAssertNotNil(confirmed.confirmedAt)

        let second = try store.saveGenerated(reportId: report.id, facts: makeFacts(metrics: ReportMetrics(activityCount: 2)),
                                             draft: makeDraft(content: "새 초안"), mode: .automatic)
        guard case .created(let v2) = second else { return XCTFail() }
        XCTAssertEqual(v2.state, .draft)
        XCTAssertEqual(v2.basedOnVersionId, v1.id)

        let reloaded = try XCTUnwrap(try repo.reportVersion(id: v1.id))
        XCTAssertEqual(reloaded.state, .confirmed)
        XCTAssertEqual(reloaded.content, "확정 대상")

        // 확정본 본문 변경은 DB 트리거가 거부한다.
        var tampered = reloaded
        tampered.content = "변경 시도"
        XCTAssertThrowsError(try repo.updateReportVersion(tampered))
        XCTAssertEqual(try repo.reportVersion(id: v1.id)?.content, "확정 대상")
    }

    // MARK: 8 — 확정본 편집 → 새 edited 버전, 확정본 불변

    func testEditConfirmedCreatesNewEditedVersion() throws {
        let (store, repo) = try makeStore()
        let report = try ensureSubmissionReport()

        let first = try store.saveGenerated(reportId: report.id, facts: makeFacts(metrics: ReportMetrics(activityCount: 1)),
                                            draft: makeDraft(content: "확정 내용"), mode: .automatic)
        guard case .created(let v1) = first else { return XCTFail() }
        _ = try store.confirm(versionId: v1.id)

        let edited = try store.edit(versionId: v1.id, content: "확정 후 편집")
        XCTAssertNotEqual(edited.id, v1.id)
        XCTAssertEqual(edited.version, 2)
        XCTAssertEqual(edited.state, .edited)
        XCTAssertEqual(edited.basedOnVersionId, v1.id)
        XCTAssertEqual(edited.sourceSnapshotId, v1.sourceSnapshotId)
        XCTAssertEqual(edited.templateVersionId, v1.templateVersionId)
        XCTAssertEqual(edited.generator, v1.generator)

        let original = try XCTUnwrap(try repo.reportVersion(id: v1.id))
        XCTAssertEqual(original.state, .confirmed)
        XCTAssertEqual(original.content, "확정 내용")
    }

    // MARK: 9 — 두 번째 확정 → latestConfirmed, 이전 확정본 유지

    func testSecondConfirmKeepsPreviousConfirmed() throws {
        let (store, repo) = try makeStore()
        let report = try ensureSubmissionReport()

        let first = try store.saveGenerated(reportId: report.id, facts: makeFacts(metrics: ReportMetrics(activityCount: 1)),
                                            draft: makeDraft(), mode: .automatic)
        guard case .created(let v1) = first else { return XCTFail() }
        _ = try store.confirm(versionId: v1.id)

        let second = try store.saveGenerated(reportId: report.id, facts: makeFacts(metrics: ReportMetrics(activityCount: 2)),
                                             draft: makeDraft(content: "2차"), mode: .automatic)
        guard case .created(let v2) = second else { return XCTFail() }
        _ = try store.confirm(versionId: v2.id)

        let bundle = try store.bundle(reportId: report.id)
        XCTAssertEqual(bundle.latestConfirmed?.id, v2.id)
        XCTAssertEqual(bundle.versions.filter { $0.state == .confirmed }.map(\.id), [v1.id, v2.id])
        XCTAssertEqual(try repo.reportVersion(id: v1.id)?.state, .confirmed)

        // 이미 확정된 버전 confirm은 그대로 반환한다.
        XCTAssertEqual(try store.confirm(versionId: v2.id).id, v2.id)
    }

    // MARK: 10 — superseded 편집·확정 거부

    func testSupersededEditAndConfirmAreRejected() throws {
        let (store, _) = try makeStore()
        let report = try ensureSubmissionReport()
        let facts = makeFacts(metrics: ReportMetrics(activityCount: 1))

        let first = try store.saveGenerated(reportId: report.id, facts: facts, draft: makeDraft(), mode: .automatic)
        guard case .created(let v1) = first else { return XCTFail() }
        _ = try store.saveGenerated(reportId: report.id, facts: facts, draft: makeDraft(), mode: .userRequested)

        XCTAssertEqual(try repo.reportVersion(id: v1.id)?.state, .superseded)
        XCTAssertThrowsError(try store.edit(versionId: v1.id, content: "x")) { error in
            guard case WorkLogError.invalidTransition = error else { return XCTFail("invalidTransition 기대: \(error)") }
        }
        XCTAssertThrowsError(try store.confirm(versionId: v1.id)) { error in
            guard case WorkLogError.invalidTransition = error else { return XCTFail("invalidTransition 기대: \(error)") }
        }
    }

    // MARK: 11 — isStale

    func testIsStaleDetectsSourceChange() throws {
        let (store, _) = try makeStore()
        let report = try ensureSubmissionReport()
        let facts = makeFacts(metrics: ReportMetrics(activityCount: 1))

        let first = try store.saveGenerated(reportId: report.id, facts: facts, draft: makeDraft(), mode: .automatic)
        guard case .created(let v1) = first else { return XCTFail() }

        XCTAssertFalse(try store.isStale(versionId: v1.id, currentFacts: facts))
        XCTAssertTrue(try store.isStale(versionId: v1.id, currentFacts: makeFacts(metrics: ReportMetrics(activityCount: 9))))
    }

    // MARK: 12 — 알 수 없는 근거 제외 + 경고

    func testUnknownEvidenceSourceIsExcludedWithWarning() throws {
        let (store, repo) = try makeStore()
        let report = try ensureSubmissionReport()
        let facts = makeFacts(sources: [makeSource(revision: 4)], metrics: ReportMetrics(activityCount: 1))

        let draft = makeDraft(evidence: [
            DraftEvidence(itemId: "i1", taskId: "t1", sourceId: "activity:a1"),
            DraftEvidence(itemId: "i2", sourceId: "activity:missing"),
        ])
        let first = try store.saveGenerated(reportId: report.id, facts: facts, draft: draft, mode: .automatic)
        guard case .created(let version) = first else { return XCTFail() }

        XCTAssertTrue(version.warnings.contains("알 수 없는 근거 제외: activity:missing"))
        let evidence = try repo.reportEvidence(versionId: version.id)
        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(evidence[0].sourceId, "activity:a1")
        XCTAssertEqual(evidence[0].sourceRevision, 4)
    }

    // MARK: 13 — onSourceChanged 콜백

    func testOnSourceChangedIsCalledForSavedAndSupersededVersions() throws {
        let (store, repo) = try makeStore()
        let report = try ensureSubmissionReport()
        var calls: [(String, String)] = []
        repo.onSourceChanged = { calls.append(($0, $1)) }

        let facts = makeFacts(metrics: ReportMetrics(activityCount: 1))
        let first = try store.saveGenerated(reportId: report.id, facts: facts, draft: makeDraft(), mode: .automatic)
        guard case .created(let v1) = first else { return XCTFail() }
        XCTAssertTrue(calls.contains { $0.0 == "report" && $0.1 == v1.id })

        calls.removeAll()
        let second = try store.saveGenerated(reportId: report.id, facts: facts, draft: makeDraft(), mode: .userRequested)
        guard case .created(let v2) = second else { return XCTFail() }
        XCTAssertTrue(calls.contains { $0.0 == "report" && $0.1 == v2.id })
        XCTAssertTrue(calls.contains { $0.0 == "report" && $0.1 == v1.id }, "대체된 버전도 알린다")
    }

    // MARK: 14 — 확정본 편집(새 edited 버전)도 색인 콜백을 호출한다

    func testEditConfirmedNotifiesSourceChangedForNewVersion() throws {
        let (store, repo) = try makeStore()
        let report = try ensureSubmissionReport()
        var calls: [(String, String)] = []
        repo.onSourceChanged = { calls.append(($0, $1)) }

        let first = try store.saveGenerated(reportId: report.id, facts: makeFacts(metrics: ReportMetrics(activityCount: 1)),
                                            draft: makeDraft(content: "확정 내용"), mode: .automatic)
        guard case .created(let v1) = first else { return XCTFail() }
        _ = try store.confirm(versionId: v1.id)

        calls.removeAll()
        let edited = try store.edit(versionId: v1.id, content: "확정 후 편집")
        XCTAssertNotEqual(edited.id, v1.id)
        XCTAssertTrue(calls.contains { $0.0 == "report" && $0.1 == edited.id },
                      "확정본 편집으로 만든 새 버전도 검색 색인에 알린다: \(calls)")
    }
}
