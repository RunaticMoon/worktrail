import XCTest
@testable import WorkLogCore

final class SourceActivityRecordTests: XCTestCase {
    private let day = WorkDate("2026-10-28")!
    private let instant = SQLDate.parse("2026-10-27T16:00:00Z")!

    private func connection(_ source: ActivitySource) -> ActivityConnection {
        var connection = ActivityConnection(source: source)
        connection.baseURL = source == .github ? "https://git.example.test" : "https://jira.example.test"
        connection.account = "fixture-user"
        return connection
    }

    private func activity(_ source: ActivitySource, display: ActivityDisplayMetadata? = nil) -> ImportedActivity {
        .init(id: "event-1", occurredAt: instant,
              title: source == .github ? "demo/repo PR #77: 개선" : "DEMO-12: 개선",
              detail: source == .github ? "PR merged" : "status: Open → Done",
              url: source == .github ? "https://git.example.test/demo/repo/pull/77" : "https://jira.example.test/browse/DEMO-12",
              display: display)
    }

    func testDaySeparatesSourcesFromMemosWithoutGuessingFromText() throws {
        let repo = try WorkRepository.inMemory(clock: FixedClock(instant), ids: SequentialIDGenerator())
        let memo = try TaskService(repo: repo).captureMemo(body: "[GitHub Enterprise] 직접 적은 일반 메모", workDate: day)
        try repo.importActivities([activity(.github)], connection: connection(.github))
        try repo.importActivities([activity(.jira)], connection: connection(.jira))

        let box = try DayBoxService(repo: repo).dayBox(for: day)
        XCTAssertEqual(box.memos.map(\.id), [memo.id])
        XCTAssertEqual(box.sourceActivities.count, 2)
        XCTAssertEqual(Set(box.sourceActivities.map(\.source)), [.github, .jira])
        XCTAssertEqual(box.timeline.filter { $0.kind == .memo }.count, 1)
        XCTAssertEqual(box.timeline.filter { $0.kind == .github }.count, 1)
        XCTAssertEqual(box.timeline.filter { $0.kind == .jira }.count, 1)
        XCTAssertEqual(box.timeline.first { $0.kind == .github }?.effectiveTime, instant)
        XCTAssertTrue(try DayBoxService(repo: repo).dayBox(for: day, knownAt: instant.addingTimeInterval(-1)).timeline.isEmpty)
        XCTAssertEqual(try repo.memos(in: DateRange(start: day, endExclusive: repo.calendar.adding(days: 1, to: day))).count, 1)
    }

    func testMetadataEnrichmentPreservesEditsRevisionsLinksAndTrash() throws {
        let repo = try WorkRepository.inMemory(clock: FixedClock(instant), ids: SequentialIDGenerator())
        let c = connection(.github)
        try repo.importActivities([activity(.github)], connection: c)
        let original = try XCTUnwrap(repo.importedActivityRecords(on: day).first)
        let links = try repo.links(ownerType: .memo, ownerId: original.id)
        _ = try repo.updateMemoBody(id: original.id, body: "사용자가 남긴 추가 설명", workDate: day)
        let legacy = try XCTUnwrap(repo.importedActivityRecord(id: original.id))
        XCTAssertEqual(legacy.display.number, 77)
        XCTAssertEqual(legacy.display.action, "merged")
        let display = ActivityDisplayMetadata(kind: .githubPullRequest, repository: "demo/repo", title: "개선", number: 77, action: "merged")
        XCTAssertEqual(try repo.importActivities([activity(.github, display: display)], connection: c), 0)
        let enriched = try XCTUnwrap(repo.importedActivityRecord(id: original.id))
        XCTAssertEqual(enriched.display, display)
        XCTAssertEqual(enriched.memo.body, "사용자가 남긴 추가 설명")
        XCTAssertEqual(enriched.memo.revision, 2)
        XCTAssertEqual(try repo.memoRevisions(id: original.id).first?.body, original.memo.body)
        XCTAssertEqual(try repo.links(ownerType: .memo, ownerId: original.id), links)
        try repo.softDeleteMemo(id: original.id)
        XCTAssertEqual(try repo.importActivities([activity(.github, display: display)], connection: c), 0)
        XCTAssertTrue(try repo.importedActivityRecords(on: day).isEmpty)
        XCTAssertNotNil(try repo.memo(id: original.id, includeDeleted: true)?.deletedAt)
    }

    func testV8UpgradeKeepsExistingRowsAndUsesLegacyPresentation() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try Migrator.migrate(db, migrations: WorkSchema.migrations.filter { $0.version <= 8 })
        let c = connection(.github)
        let body = "[GitHub Enterprise] demo/repo PR #77: 개선\nPR merged\nhttps://git.example.test/demo/repo/pull/77"
        try db.runV("INSERT INTO memo (id, body, work_date, recorded_at, revision) VALUES (?, ?, ?, ?, ?)", "old-import", body, day, instant, 3)
        try db.runV("INSERT INTO imported_activity (connection_key, external_id, source, memo_id, occurred_at, fetched_at, source_url) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    c.credentialAccount, "event-1", "github", "old-import", instant, instant, activity(.github).url)
        let repo = try WorkRepository(db: db, clock: FixedClock(instant), ids: SequentialIDGenerator())
        let record = try XCTUnwrap(repo.importedActivityRecord(id: "old-import"))
        XCTAssertEqual(record.memo.body, body)
        XCTAssertEqual(record.memo.revision, 3)
        XCTAssertEqual(record.display.repository, "demo/repo")
        XCTAssertEqual(record.display.number, 77)
        XCTAssertEqual(record.display.action, "merged")
        XCTAssertTrue(try repo.memos(on: day).isEmpty)
        XCTAssertEqual(try repo.importActivities([activity(.github)], connection: c), 0)
        try Migrator.migrate(db, migrations: WorkSchema.migrations)
        XCTAssertEqual(try repo.importedActivityRecords(on: day).map(\.id), ["old-import"])
        XCTAssertTrue(try db.integrityCheck())
    }

    func testReportsKeepEachSourceOnceWithStableEvidenceIDs() throws {
        let repo = try WorkRepository.inMemory(clock: FixedClock(instant), ids: SequentialIDGenerator())
        let memo = try TaskService(repo: repo).captureMemo(body: "일반 메모", workDate: day)
        try repo.importActivities([activity(.github)], connection: connection(.github))
        try repo.importActivities([activity(.jira)], connection: connection(.jira))
        let periods = Periods(calendar: repo.calendar)
        let builder = ReportFactsBuilder(repo: repo, periods: periods, planService: WeekPlanService(repo: repo, periods: periods))
        let facts = try builder.build(family: .performance, periodType: .daily,
            range: DateRange(start: day, endExclusive: repo.calendar.adding(days: 1, to: day)), knownAt: instant)
        XCTAssertEqual(facts.sources.count, 3)
        XCTAssertEqual(facts.sources.first { $0.id == "memo:\(memo.id)" }?.kind, .memo)
        XCTAssertEqual(facts.sources.filter { $0.kind == .github }.count, 1)
        XCTAssertEqual(facts.sources.filter { $0.kind == .jira }.count, 1)
        XCTAssertTrue(facts.sources.allSatisfy { $0.id.hasPrefix("memo:") })
        XCTAssertEqual(facts.sources.filter { $0.kind != .memo }.flatMap(\.sourceUrls).count, 2)
    }

    func testAcceptedSourceEvidenceValidatesForItsTasksSingleProject() throws {
        for source in ActivitySource.allCases {
            let fixture = try linkedActivityFacts(source: source, projectNames: ["담당 프로젝트"])
            let draft = PerformanceComposer.compose(fixture.facts)
            let evidence = try XCTUnwrap(draft.sections.flatMap(\.items).first {
                $0.evidenceIds == ["memo:\(fixture.record.id)"]
            })
            XCTAssertEqual(evidence.kind, .activity)
            XCTAssertEqual(evidence.taskIds, [fixture.task.id])
            XCTAssertEqual(evidence.projectIds, fixture.facts.task(fixture.task.id)?.projectIds)
            XCTAssertNil(fixture.facts.sources.first { $0.id == "memo:\(fixture.record.id)" }?.taskId)
            let findings = PerformanceValidator.validate(draft, facts: fixture.facts)
            XCTAssertFalse(PerformanceValidator.hasErrors(findings), "\(source): \(findings)")
            XCTAssertFalse(draft.missingEvidence.contains { $0.taskId == fixture.task.id && $0.field == "activity" })
            var unlinked = fixture.facts
            unlinked.memoLinksAccepted = []
            XCTAssertTrue(PerformanceComposer.compose(unlinked).missingEvidence.contains {
                $0.taskId == fixture.task.id && $0.field == "activity"
            })
        }
    }

    func testSourceProjectEvidenceRejectsMissingApprovalUnrelatedProjectsAndOtherTasks() throws {
        for source in ActivitySource.allCases {
            let fixture = try linkedActivityFacts(source: source, projectNames: ["담당 프로젝트"])
            let draft = PerformanceComposer.compose(fixture.facts)
            var unapproved = fixture.facts
            unapproved.memoLinksAccepted = []
            XCTAssertTrue(PerformanceValidator.validate(draft, facts: unapproved).contains {
                $0.code == "project_evidence_mismatch" && $0.severity == .error
            })

            for replaceProject in [true, false] {
                var modified = draft
                for sectionIndex in modified.sections.indices {
                    for itemIndex in modified.sections[sectionIndex].items.indices {
                        guard modified.sections[sectionIndex].items[itemIndex].evidenceIds == ["memo:\(fixture.record.id)"] else { continue }
                        if replaceProject {
                            modified.sections[sectionIndex].items[itemIndex].projectIds = [fixture.otherProject.id]
                        } else {
                            // A link to the original task cannot substantiate a different task's item.
                            modified.sections[sectionIndex].items[itemIndex].taskIds = [fixture.otherTask.id]
                        }
                    }
                }
                XCTAssertTrue(PerformanceValidator.validate(modified, facts: fixture.facts).contains {
                    $0.code == "project_evidence_mismatch" && $0.severity == .error
                }, "\(source), replaceProject=\(replaceProject)")
            }
        }
    }

    func testSourceEvidenceDoesNotExpandAcrossMultiProjectTask() throws {
        for source in ActivitySource.allCases {
            let fixture = try linkedActivityFacts(source: source, projectNames: ["프로젝트 A", "프로젝트 B"])
            var draft = PerformanceComposer.compose(fixture.facts)
            let evidence = try XCTUnwrap(draft.sections.flatMap(\.items).first {
                $0.evidenceIds == ["memo:\(fixture.record.id)"]
            })
            XCTAssertTrue(evidence.projectIds.isEmpty)
            XCTAssertFalse(PerformanceValidator.hasErrors(PerformanceValidator.validate(draft, facts: fixture.facts)))
            let projectIds = try XCTUnwrap(fixture.facts.task(fixture.task.id)?.projectIds)
            XCTAssertEqual(projectIds.count, 2)
            for sectionIndex in draft.sections.indices {
                for itemIndex in draft.sections[sectionIndex].items.indices {
                    if draft.sections[sectionIndex].items[itemIndex].itemId == evidence.itemId {
                        draft.sections[sectionIndex].items[itemIndex].projectIds = projectIds
                    }
                }
            }
            let rejected = PerformanceValidator.validate(draft, facts: fixture.facts)
                .filter { $0.code == "project_evidence_mismatch" && $0.itemId == evidence.itemId }
            XCTAssertEqual(rejected.count, 2, "Neither project has explicit source evidence")
        }
    }

    private func linkedActivityFacts(source: ActivitySource, projectNames: [String]) throws
        -> (facts: ReportFacts, task: WorkTask, record: ImportedActivityRecord, otherTask: WorkTask, otherProject: Project) {
        let repo = try WorkRepository.inMemory(clock: FixedClock(instant), ids: SequentialIDGenerator())
        let service = TaskService(repo: repo)
        let task = try service.createTask(title: "수집 근거를 연결한 업무", initialStatus: .inProgress,
            workDate: day, projectNames: projectNames)
        let otherProject = try repo.createProject(name: "관련 없는 프로젝트")
        let otherTask = try service.createTask(title: "다른 업무", initialStatus: .inProgress,
            workDate: day, projectNames: [otherProject.name])
        try repo.importActivities([activity(source)], connection: connection(source))
        let record = try XCTUnwrap(repo.importedActivityRecords(on: day).first)
        try repo.upsertMemoTaskLink(.init(id: "accepted-source-link", memoId: record.id, taskId: task.id,
            status: .accepted, reason: "사용자가 연결 승인", sourceRevision: record.memo.revision,
            createdAt: instant, decidedAt: instant))
        let periods = Periods(calendar: repo.calendar)
        let builder = ReportFactsBuilder(repo: repo, periods: periods, planService: WeekPlanService(repo: repo, periods: periods))
        let facts = try builder.build(family: .performance, periodType: .daily,
            range: DateRange(start: day, endExclusive: repo.calendar.adding(days: 1, to: day)), knownAt: instant)
        return (facts, task, record, otherTask, otherProject)
    }
}
