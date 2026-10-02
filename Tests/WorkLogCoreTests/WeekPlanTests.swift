import XCTest
@testable import WorkLogCore

final class WeekPlanTests: XCTestCase {

    private let monday = WorkDate("2026-10-05")!
    private let tuesday = WorkDate("2026-10-06")!

    private func makeRepo(now: Date) throws -> WorkRepository {
        try WorkRepository.inMemory(clock: FixedClock(now), ids: SequentialIDGenerator())
    }

    private func fixtureNow() -> Date {
        (try? FixtureLoader.load()).flatMap { $0.clock?.now }.flatMap(FixtureLoader.date)
            ?? Date(timeIntervalSince1970: 1_790_000_000)
    }

    /// 픽스처의 projects/tasks/checklists/events를 저장소에 적재한다.
    @discardableResult
    private func seedFixture(into repo: WorkRepository) throws -> ExampleFixture {
        let fixture = try FixtureLoader.load()

        for project in fixture.projects ?? [] {
            guard let id = project.id, let name = project.name else { continue }
            try repo.db.run("INSERT INTO project (id, name, archived_at) VALUES (?, ?, NULL)", [id, name])
        }

        var createdAt = fixtureNow()
        for task in fixture.tasks ?? [] {
            guard let id = task.id, let title = task.title else { continue }
            let mode = task.projectTrackingMode.flatMap(ProjectTrackingMode.init(rawValue:)) ?? .shared
            try repo.insertTask(WorkTask(id: id, title: title,
                                         dueOn: task.dueOn.flatMap { WorkDate($0) },
                                         createdAt: createdAt, projectTrackingMode: mode))
            createdAt = createdAt.addingTimeInterval(1)
            for projectId in task.projectIds ?? [] {
                try repo.linkProject(taskId: id, projectId: projectId,
                                     trackingEnabled: mode == .perProject, linkedOn: WorkDate("2026-09-28")!)
            }
        }

        for checklist in fixture.checklists ?? [] {
            guard let id = checklist.id, let taskId = checklist.taskId, let text = checklist.text else { continue }
            try repo.insertChecklistItem(ChecklistItem(id: id, taskId: taskId, text: text,
                                                       sortOrder: 0, projectIds: checklist.projectIds ?? []))
        }

        try repo.appendEvents(fixture.domainEvents())
        return fixture
    }

    private func assertValidation(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case WorkLogError.validation = error else {
            return XCTFail("validation 오류를 기대했으나 \(error)", file: file, line: line)
        }
    }

    // MARK: PLAN-T01 — 후보 생성만으로는 보고서 ‘예정’에 들어가지 않는다

    func testCandidatesDoNotAppearUntilConfirmed() throws {
        let repo = try makeRepo(now: fixtureNow())
        try seedFixture(into: repo)
        let service = WeekPlanService(repo: repo, periods: Periods())

        let candidates = try service.generateCandidates(weekStart: monday)
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy { $0.state == .candidate })

        XCTAssertEqual(try service.confirmedFacts(weekStart: monday), [])
    }

    // MARK: PLAN-T02 — 후보 중 확정한 범위만 이번 주 계획

    func testFixtureScenarioOnlyConfirmedSubsetAppears() throws {
        let repo = try makeRepo(now: fixtureNow())
        let fixture = try seedFixture(into: repo)
        let service = WeekPlanService(repo: repo, periods: Periods())
        let expected = try XCTUnwrap(fixture.expected)

        try repo.insertWeekPlan(WeekPlan(id: "plan-fixture", weekStart: monday))
        let items = [
            WeekPlanItem(id: "plan-J", weekPlanId: "plan-fixture", taskId: "task-A",
                         scopeType: .taskProject, scopeId: "task-A/project-J",
                         label: "J 적용 마무리", state: .candidate),
            WeekPlanItem(id: "plan-docs", weekPlanId: "plan-fixture", taskId: "task-A",
                         scopeType: .checklistItem, scopeId: "checklist-docs",
                         label: "공통 운영 문서 정리", state: .candidate),
            WeekPlanItem(id: "candidate-K", weekPlanId: "plan-fixture", taskId: "task-A",
                         scopeType: .taskProject, scopeId: "task-A/project-K",
                         label: "K 적용 착수", state: .candidate),
        ]
        for item in items { try repo.insertWeekPlanItem(item) }

        let updated = try service.confirm(weekStart: monday, itemIds: ["plan-J", "plan-docs"])
        XCTAssertEqual(updated.first { $0.id == "candidate-K" }?.state, .candidate)
        XCTAssertEqual(updated.first { $0.id == "plan-J" }?.state, .confirmed)
        XCTAssertNotNil(updated.first { $0.id == "plan-docs" }?.confirmedAt)

        let facts = try service.confirmedFacts(weekStart: monday)
        let planItemIds = Set(facts.flatMap(\.planItemIds))
        XCTAssertEqual(planItemIds, Set(try XCTUnwrap(expected.confirmedPlanIds)))
        XCTAssertTrue(planItemIds.isDisjoint(with: Set(expected.excludedCandidateIds ?? [])))
        XCTAssertTrue(facts.allSatisfy { $0.taskId == "task-A" })
        XCTAssertTrue(facts.contains { $0.labels.contains("J 적용 마무리") })
        XCTAssertTrue(facts.contains { $0.labels.contains("공통 운영 문서 정리") })
    }

    // MARK: PLAN-T03 — 계획 확정은 착수·상태 변경이 아니다

    func testConfirmingPlannedTaskDoesNotCreateEventsOrStart() throws {
        let now = fixtureNow()
        let repo = try makeRepo(now: now)
        let service = WeekPlanService(repo: repo, periods: Periods())

        try repo.insertTask(WorkTask(id: "task-P", title: "예정 작업", createdAt: now))
        try repo.appendEvent(DomainEvent(id: "event-P-create", taskId: "task-P", scopeType: .task,
                                         scopeId: "task-P", kind: .created, toStatus: .planned,
                                         effectiveDate: WorkDate("2026-09-28")!, effectiveOrder: 1,
                                         recordedAt: now))

        let candidates = try service.generateCandidates(weekStart: monday)
        let whole = try XCTUnwrap(candidates.first { $0.taskId == "task-P" && $0.scopeType == .wholeTask })
        XCTAssertEqual(whole.candidateReason, "지난주 미완료")

        let eventCountBefore = try repo.allEvents().count
        _ = try service.confirm(weekStart: monday, itemIds: [whole.id])

        XCTAssertEqual(try repo.allEvents().count, eventCountBefore)
        let states = StateReplay.replay(try repo.allEvents(), through: nil, knownAt: now)
        XCTAssertEqual(states.taskStatus("task-P"), .planned)
        XCTAssertNil(StateReplay.firstStartedOn(taskId: "task-P", try repo.allEvents(), knownAt: now))
    }

    // MARK: PLAN-T04 — Task 전체 + 세부 항목 동시 확정은 정규화로 중복 제거

    func testWholeTaskAndDetailsMergeIntoOneFactPlanItem() throws {
        let now = fixtureNow()
        let repo = try makeRepo(now: now)
        let service = WeekPlanService(repo: repo, periods: Periods())

        try repo.insertTask(WorkTask(id: "task-A", title: "공통 인프라", createdAt: now,
                                     projectTrackingMode: .perProject))
        try repo.insertChecklistItem(ChecklistItem(id: "checklist-docs", taskId: "task-A",
                                                   text: "공통 운영 문서 정리", sortOrder: 0))
        try repo.db.run("INSERT INTO project (id, name, archived_at) VALUES (?, ?, NULL)", ["project-J", "J"])

        let whole = try service.addItem(weekStart: monday, taskId: "task-A", scopeType: .wholeTask,
                                        scopeId: nil, label: "A 전체")
        let project = try service.addItem(weekStart: monday, taskId: "task-A", scopeType: .taskProject,
                                          scopeId: "task-A/project-J", label: "J 적용")
        let checklist = try service.addItem(weekStart: monday, taskId: "task-A", scopeType: .checklistItem,
                                            scopeId: "checklist-docs", label: "문서 정리")

        _ = try service.confirm(weekStart: monday, itemIds: [whole.id, project.id, checklist.id])

        let facts = try service.confirmedFacts(weekStart: monday)
        XCTAssertEqual(facts.count, 1)
        let fact = try XCTUnwrap(facts.first)
        XCTAssertEqual(fact.taskId, "task-A")
        XCTAssertEqual(fact.scopeType, .wholeTask)
        XCTAssertNil(fact.scopeId)
        XCTAssertEqual(Set(fact.planItemIds), Set([whole.id, project.id, checklist.id]))
        XCTAssertEqual(fact.labels, ["A 전체", "J 적용", "문서 정리"])
    }

    // MARK: PLAN-T05 — 보류·취소 Task는 자동 후보가 아니고 상태도 변하지 않는다

    func testOnHoldAndCancelledTasksAreNotAutoCandidates() throws {
        let now = fixtureNow()
        let repo = try makeRepo(now: now)
        let service = WeekPlanService(repo: repo, periods: Periods())

        try repo.insertTask(WorkTask(id: "task-H", title: "보류 작업", createdAt: now))
        try repo.insertTask(WorkTask(id: "task-C", title: "취소 작업", createdAt: now.addingTimeInterval(1)))
        try repo.appendEvents([
            DomainEvent(id: "event-H-create", taskId: "task-H", scopeType: .task, scopeId: "task-H",
                        kind: .created, toStatus: .planned, effectiveDate: WorkDate("2026-09-28")!,
                        effectiveOrder: 1, recordedAt: now),
            // 지난주엔 예정이었지만 이번 주에 보류됨 → 현재 상태 기준으로 제외.
            DomainEvent(id: "event-H-pause", taskId: "task-H", scopeType: .task, scopeId: "task-H",
                        kind: .paused, toStatus: .onHold, effectiveDate: monday, effectiveOrder: 1,
                        recordedAt: now),
            DomainEvent(id: "event-C-create", taskId: "task-C", scopeType: .task, scopeId: "task-C",
                        kind: .created, toStatus: .planned, effectiveDate: WorkDate("2026-09-28")!,
                        effectiveOrder: 1, recordedAt: now),
            DomainEvent(id: "event-C-cancel", taskId: "task-C", scopeType: .task, scopeId: "task-C",
                        kind: .cancelled, toStatus: .cancelled, effectiveDate: WorkDate("2026-10-02")!,
                        effectiveOrder: 2, recordedAt: now),
        ])

        let candidates = try service.generateCandidates(weekStart: monday)
        XCTAssertFalse(candidates.contains { $0.taskId == "task-H" })
        XCTAssertFalse(candidates.contains { $0.taskId == "task-C" })

        let states = StateReplay.replay(try repo.allEvents(), through: nil, knownAt: now)
        XCTAssertEqual(states.taskStatus("task-H"), .onHold)
        XCTAssertEqual(states.taskStatus("task-C"), .cancelled)

        // 사용자가 직접 추가하는 것은 허용된다.
        let manual = try service.addItem(weekStart: monday, taskId: "task-H", scopeType: .wholeTask,
                                         scopeId: nil, label: nil)
        XCTAssertEqual(manual.state, .candidate)
    }

    // MARK: PLAN-T06 — 같은 scope로 두 번 추가해도 정규화 결과는 1개

    func testDuplicateChecklistScopeNormalizesToOne() throws {
        let now = fixtureNow()
        let repo = try makeRepo(now: now)
        let service = WeekPlanService(repo: repo, periods: Periods())

        try repo.insertTask(WorkTask(id: "task-A", title: "공통 인프라", createdAt: now))
        try repo.db.run("INSERT INTO project (id, name, archived_at) VALUES (?, ?, NULL)", ["project-G", "G"])
        try repo.db.run("INSERT INTO project (id, name, archived_at) VALUES (?, ?, NULL)", ["project-J", "J"])
        try repo.insertChecklistItem(ChecklistItem(id: "checklist-docs", taskId: "task-A",
                                                   text: "공통 운영 문서 정리", sortOrder: 0,
                                                   projectIds: ["project-G", "project-J"]))

        let first = try service.addItem(weekStart: monday, taskId: "task-A", scopeType: .checklistItem,
                                        scopeId: "checklist-docs", label: "문서")
        let second = try service.addItem(weekStart: monday, taskId: "task-A", scopeType: .checklistItem,
                                         scopeId: "checklist-docs", label: "문서")
        XCTAssertNotEqual(first.id, second.id)

        _ = try service.confirm(weekStart: monday, itemIds: [first.id, second.id])

        let facts = try service.confirmedFacts(weekStart: monday)
        let checklistFacts = facts.filter { $0.scopeType == .checklistItem }
        XCTAssertEqual(checklistFacts.count, 1)
        XCTAssertEqual(Set(checklistFacts[0].planItemIds), Set([first.id, second.id]))
        XCTAssertEqual(checklistFacts[0].labels, ["문서"])
    }

    // MARK: 후보 생성 재호출 — 중복 없음, 확정 항목 유지

    func testGenerateCandidatesTwiceIsIdempotent() throws {
        let repo = try makeRepo(now: fixtureNow())
        try seedFixture(into: repo)
        let service = WeekPlanService(repo: repo, periods: Periods())

        let first = try service.generateCandidates(weekStart: monday)
        XCTAssertFalse(first.isEmpty)

        let wholeA = try XCTUnwrap(first.first { $0.taskId == "task-A" && $0.scopeType == .wholeTask })
        _ = try service.confirm(weekStart: monday, itemIds: [wholeA.id])

        let second = try service.generateCandidates(weekStart: monday)
        let keys = second.map { "\($0.taskId)|\($0.scopeType.rawValue)|\($0.scopeId ?? "")" }
        XCTAssertEqual(keys.count, Set(keys).count)
        XCTAssertEqual(second.first { $0.id == wholeA.id }?.state, .confirmed)
        XCTAssertEqual(second.count, first.count)
    }

    // MARK: 확정 취소 / 제외

    func testUnconfirmAndExclude() throws {
        let now = fixtureNow()
        let repo = try makeRepo(now: now)
        let service = WeekPlanService(repo: repo, periods: Periods())
        try repo.insertTask(WorkTask(id: "task-A", title: "작업", createdAt: now))

        let item = try service.addItem(weekStart: monday, taskId: "task-A", scopeType: .wholeTask,
                                       scopeId: nil, label: "작업")
        _ = try service.confirm(weekStart: monday, itemIds: [item.id])
        XCTAssertEqual(try service.confirmedFacts(weekStart: monday).count, 1)

        try service.unconfirm(itemId: item.id)
        XCTAssertEqual(try service.confirmedFacts(weekStart: monday), [])

        try service.exclude(itemId: item.id)
        let stored = try XCTUnwrap(try repo.weekPlanItem(id: item.id))
        XCTAssertEqual(stored.state, .excluded)
        XCTAssertEqual(try service.confirmedFacts(weekStart: monday), [])
    }

    // MARK: 라벨 미지정 확정 항목의 표시용 label

    func testConfirmedFactsFillDisplayLabels() throws {
        let now = fixtureNow()
        let repo = try makeRepo(now: now)
        let service = WeekPlanService(repo: repo, periods: Periods())
        try repo.insertTask(WorkTask(id: "task-A", title: "작업", createdAt: now, projectTrackingMode: .perProject))
        try repo.insertChecklistItem(ChecklistItem(id: "checklist-docs", taskId: "task-A",
                                                   text: "공통 운영 문서 정리", sortOrder: 0))
        try repo.db.run("INSERT INTO project (id, name, archived_at) VALUES (?, ?, NULL)", ["project-J", "J"])

        let project = try service.addItem(weekStart: monday, taskId: "task-A", scopeType: .taskProject,
                                          scopeId: "task-A/project-J", label: nil)
        let checklist = try service.addItem(weekStart: monday, taskId: "task-A", scopeType: .checklistItem,
                                            scopeId: "checklist-docs", label: nil)
        _ = try service.confirm(weekStart: monday, itemIds: [project.id, checklist.id])

        let facts = try service.confirmedFacts(weekStart: monday)
        let projectFact = try XCTUnwrap(facts.first { $0.scopeType == .taskProject })
        let checklistFact = try XCTUnwrap(facts.first { $0.scopeType == .checklistItem })
        XCTAssertEqual(projectFact.labels, ["J 적용"])
        XCTAssertEqual(checklistFact.labels, ["공통 운영 문서 정리"])
    }

    // MARK: 월요일 검증

    func testNonMondayWeekStartFailsValidation() throws {
        let repo = try makeRepo(now: fixtureNow())
        let service = WeekPlanService(repo: repo, periods: Periods())

        XCTAssertThrowsError(try service.plan(weekStart: tuesday)) { assertValidation($0) }
        XCTAssertThrowsError(try service.generateCandidates(weekStart: tuesday)) { assertValidation($0) }
        XCTAssertThrowsError(try service.addItem(weekStart: tuesday, taskId: "task-A",
                                                 scopeType: .wholeTask, scopeId: nil, label: nil)) { assertValidation($0) }
        XCTAssertThrowsError(try service.confirm(weekStart: tuesday, itemIds: [])) { assertValidation($0) }
        XCTAssertThrowsError(try service.confirmedFacts(weekStart: tuesday)) { assertValidation($0) }
    }

    // MARK: knownAt — 확정 시각이 knownAt 이후인 계획은 제외

    func testConfirmedFactsKnownAtFiltersFutureConfirmations() throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_790_000_000))
        let repo = try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator())
        let service = WeekPlanService(repo: repo, periods: Periods())

        try repo.insertTask(WorkTask(id: "task-A", title: "작업 A", createdAt: clock.now()))
        try repo.insertTask(WorkTask(id: "task-B", title: "작업 B", createdAt: clock.now().addingTimeInterval(1)))

        let first = try service.addItem(weekStart: monday, taskId: "task-A", scopeType: .wholeTask,
                                        scopeId: nil, label: "A 계획")
        let second = try service.addItem(weekStart: monday, taskId: "task-B", scopeType: .wholeTask,
                                         scopeId: nil, label: "B 계획")

        _ = try service.confirm(weekStart: monday, itemIds: [first.id])
        let knownAt = clock.now()
        clock.advance(by: 3600)
        _ = try service.confirm(weekStart: monday, itemIds: [second.id])

        // knownAt 시점엔 아직 확정하지 않은 B 계획은 제외된다.
        let before = try service.confirmedFacts(weekStart: monday, knownAt: knownAt)
        XCTAssertEqual(before.map(\.taskId), ["task-A"])

        // 이후 시점에는 둘 다 포함된다.
        let after = try service.confirmedFacts(weekStart: monday, knownAt: clock.now())
        XCTAssertEqual(Set(after.map(\.taskId)), Set(["task-A", "task-B"]))

        // 기존 시그니처(knownAt nil)는 필터 없이 모두 포함한다.
        XCTAssertEqual(Set(try service.confirmedFacts(weekStart: monday).map(\.taskId)),
                       Set(["task-A", "task-B"]))
    }

    // MARK: 저장소 왕복

    func testWeekPlanRepositoryRoundTrip() throws {
        let now = fixtureNow()
        let repo = try makeRepo(now: now)
        try repo.insertTask(WorkTask(id: "task-A", title: "작업", createdAt: now))

        XCTAssertNil(try repo.weekPlan(weekStart: monday))
        var plan = WeekPlan(id: "plan-1", weekStart: monday)
        try repo.insertWeekPlan(plan)
        XCTAssertEqual(try repo.weekPlan(weekStart: monday)?.id, "plan-1")

        try repo.insertWeekPlanItem(WeekPlanItem(id: "item-1", weekPlanId: "plan-1", taskId: "task-A",
                                                 scopeType: .wholeTask, state: .candidate,
                                                 candidateReason: "지난주 미완료"))
        try repo.insertWeekPlanItem(WeekPlanItem(id: "item-2", weekPlanId: "plan-1", taskId: "task-A",
                                                 scopeType: .taskProject, scopeId: "task-A/project-J",
                                                 label: "J 적용", state: .confirmed,
                                                 confirmedAt: now))
        XCTAssertEqual(try repo.weekPlanItems(planId: "plan-1").map(\.id), ["item-1", "item-2"])

        var item = try XCTUnwrap(try repo.weekPlanItem(id: "item-1"))
        item.state = .excluded
        try repo.updateWeekPlanItem(item)
        XCTAssertEqual(try repo.weekPlanItem(id: "item-1")?.state, .excluded)

        plan.revision = 2
        plan.confirmedAt = now
        try repo.updateWeekPlan(plan)
        let reloaded = try XCTUnwrap(try repo.weekPlan(weekStart: monday))
        XCTAssertEqual(reloaded.revision, 2)
        XCTAssertEqual(reloaded.confirmedAt, now)
    }
}
