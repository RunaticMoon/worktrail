import Foundation
import WorkLogCore

/// 테스트 도우미: `Tests/WorkLogCoreTests/Fixtures/example_data.json`를 저장소에 적재한다.
/// 실제 제품 코드가 아니라 테스트에서만 쓰는 시더다. `FixtureLoader.swift`는 수정하지 않는다.
enum FixtureSeeder {

    /// projects, tasks, task_project, checklist, events, activity/memo 소스, work_link,
    /// memo_task_link, week_plan(+items), evidence_supplement를 픽스처 그대로 저장한다.
    static func seed(_ repo: WorkRepository, fixture: ExampleFixture) throws {
        try seedProjects(repo, fixture)

        let events = fixture.domainEvents()
        let creations = creationMeta(events)
        let fallbackNow = fixture.clock?.now.flatMap { FixtureLoader.date($0) }
            ?? Date(timeIntervalSince1970: 0)
        try seedTasks(repo, fixture, creations: creations, fallbackNow: fallbackNow)
        try seedChecklists(repo, fixture)

        try repo.appendEvents(events)

        let memoRecordedAt = try seedSources(repo, fixture)
        try seedMemoTaskLinks(repo, fixture, memoRecordedAt: memoRecordedAt)
        try seedWeekPlan(repo, fixture)
        try seedSupplements(repo, fixture)
    }

    // MARK: - 단계

    private struct CreationMeta {
        var recordedAt: Date
        var effectiveDate: WorkDate
    }

    /// Task별 생성 사건(recordedAt·effectiveDate). 가장 이른 기록을 쓴다.
    private static func creationMeta(_ events: [DomainEvent]) -> [String: CreationMeta] {
        var map: [String: CreationMeta] = [:]
        for event in events where event.scopeType == .task && event.kind == .created {
            let meta = CreationMeta(recordedAt: event.recordedAt, effectiveDate: event.effectiveDate)
            if let existing = map[event.taskId] {
                if event.recordedAt < existing.recordedAt { map[event.taskId] = meta }
            } else {
                map[event.taskId] = meta
            }
        }
        return map
    }

    private static func seedProjects(_ repo: WorkRepository, _ fixture: ExampleFixture) throws {
        for project in fixture.projects ?? [] {
            guard let id = project.id, let name = project.name else { continue }
            try repo.db.run("INSERT INTO project (id, name, archived_at) VALUES (?, ?, NULL)", [id, name])
        }
    }

    private static func seedTasks(_ repo: WorkRepository, _ fixture: ExampleFixture,
                                  creations: [String: CreationMeta], fallbackNow: Date) throws {
        for task in fixture.tasks ?? [] {
            guard let id = task.id, let title = task.title else { continue }
            let mode = task.projectTrackingMode.flatMap { ProjectTrackingMode(rawValue: $0) } ?? .shared
            let meta = creations[id]
            let createdAt = meta?.recordedAt ?? fallbackNow
            try repo.insertTask(WorkTask(id: id, title: title,
                                         dueOn: task.dueOn.flatMap { WorkDate($0) },
                                         createdAt: createdAt, projectTrackingMode: mode))
            let linkedOn = meta?.effectiveDate ?? repo.calendar.workDate(of: createdAt)
            for projectId in task.projectIds ?? [] {
                try repo.linkProject(taskId: id, projectId: projectId,
                                     trackingEnabled: mode == .perProject, linkedOn: linkedOn)
            }
        }
    }

    private static func seedChecklists(_ repo: WorkRepository, _ fixture: ExampleFixture) throws {
        var sortOrder = 0
        for checklist in fixture.checklists ?? [] {
            guard let id = checklist.id, let taskId = checklist.taskId, let text = checklist.text else {
                continue
            }
            try repo.insertChecklistItem(ChecklistItem(id: id, taskId: taskId, text: text,
                                                       sortOrder: sortOrder,
                                                       projectIds: checklist.projectIds ?? []))
            sortOrder += 1
        }
    }

    /// activity/memo 소스를 저장하고, memo source id → recordedAt 맵을 돌려준다.
    private static func seedSources(_ repo: WorkRepository,
                                    _ fixture: ExampleFixture) throws -> [String: Date] {
        var memoRecordedAt: [String: Date] = [:]
        for source in fixture.sources ?? [] {
            guard let id = source.id, let kind = source.kind else { continue }
            let recordedAt = source.recordedAt.flatMap { FixtureLoader.date($0) }
                ?? Date(timeIntervalSince1970: 0)
            let revision = source.revision ?? 1

            switch kind {
            case "activity":
                guard let taskId = source.taskId,
                      let workDate = source.workDate.flatMap({ WorkDate($0) }) else { continue }
                try repo.insertActivity(Activity(id: id, taskId: taskId, body: source.text ?? "",
                                                 workDate: workDate, recordedAt: recordedAt,
                                                 kind: .progress, projectIds: source.projectIds ?? [],
                                                 revision: revision))
                try seedLink(repo, ownerType: .activity, ownerId: id, source: source,
                             recordedAt: recordedAt)

            case "memo":
                guard let workDate = source.workDate.flatMap({ WorkDate($0) }) else { continue }
                try repo.insertMemo(Memo(id: id, body: source.text ?? "", workDate: workDate,
                                         recordedAt: recordedAt, revision: revision,
                                         projectIds: source.projectIds ?? []))
                memoRecordedAt[id] = recordedAt
                try seedLink(repo, ownerType: .memo, ownerId: id, source: source, recordedAt: recordedAt)

            default:
                continue
            }
        }
        return memoRecordedAt
    }

    private static func seedLink(_ repo: WorkRepository, ownerType: LinkOwnerType,
                                 ownerId: String, source: FixtureSource, recordedAt: Date) throws {
        guard let url = source.sourceUrl else { return }
        try repo.insertLink(WorkLink(id: repo.ids.make(), ownerType: ownerType, ownerId: ownerId,
                                     url: url, linkType: LinkType.classify(url), createdAt: recordedAt))
    }

    private static func seedMemoTaskLinks(_ repo: WorkRepository, _ fixture: ExampleFixture,
                                          memoRecordedAt: [String: Date]) throws {
        var index = 0
        for link in fixture.memoTaskLinks ?? [] {
            guard let memoId = link.memoSourceId, let taskId = link.taskId,
                  let statusRaw = link.status,
                  let status = MemoTaskLinkStatus(rawValue: statusRaw) else { continue }
            let createdAt = memoRecordedAt[memoId] ?? Date(timeIntervalSince1970: 0)
            let decidedAt: Date? = status == .accepted ? (memoRecordedAt[memoId] ?? createdAt) : nil
            try repo.upsertMemoTaskLink(MemoTaskLink(id: "fixture-memo-link-\(index)", memoId: memoId,
                                                     taskId: taskId, status: status, reason: "fixture",
                                                     sourceRevision: 1, createdAt: createdAt,
                                                     decidedAt: decidedAt))
            index += 1
        }
    }

    private static func seedWeekPlan(_ repo: WorkRepository, _ fixture: ExampleFixture) throws {
        let items = fixture.weekPlanItems ?? []
        guard !items.isEmpty else { return }
        let weekStart = fixture.reportContext?.currentWeekStart.flatMap { WorkDate($0) }
            ?? WorkDate("2026-10-05")!
        let planId = "plan-fixture"
        try repo.insertWeekPlan(WeekPlan(id: planId, weekStart: weekStart))
        for item in items {
            guard let id = item.id, let taskId = item.taskId,
                  let scopeType = mapScopeType(item.scopeType),
                  let state = item.status.flatMap({ PlanItemState(rawValue: $0) }) else { continue }
            try repo.insertWeekPlanItem(WeekPlanItem(id: id, weekPlanId: planId, taskId: taskId,
                                                     scopeType: scopeType, scopeId: item.scopeId,
                                                     label: item.text, state: state))
        }
    }

    private static func mapScopeType(_ raw: String?) -> PlanScopeType? {
        switch raw {
        case "whole_task": return .wholeTask
        case "task_project": return .taskProject
        case "checklist", "checklist_item": return .checklistItem
        default: return nil
        }
    }

    private static func seedSupplements(_ repo: WorkRepository, _ fixture: ExampleFixture) throws {
        for supplement in fixture.evidenceSupplements ?? [] {
            guard let id = supplement.id, let taskId = supplement.taskId,
                  let start = supplement.appliesStart.flatMap({ WorkDate($0) }),
                  let end = supplement.appliesEndExclusive.flatMap({ WorkDate($0) }),
                  let recordedAt = supplement.recordedAt.flatMap({ FixtureLoader.date($0) }) else {
                continue
            }
            try repo.insertSupplement(EvidenceSupplement(id: id, taskId: taskId, topicKey: "reason",
                                                         question: supplement.question ?? "",
                                                         answer: supplement.answer, outcome: .answered,
                                                         applies: DateRange(start: start, endExclusive: end),
                                                         sourceDigest: "fixture",
                                                         recordedAt: recordedAt))
        }
    }
}
