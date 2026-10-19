import Foundation
import XCTest
@testable import WorkLogCore

final class SubmissionAIContractTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_158_400)

    private func task(_ id: String, projects: [String] = []) -> FactTask {
        FactTask(id: id, title: "가짜 업무 \(id)", trackingMode: .shared,
                 statusAtStart: .planned, statusAtCutoff: .inProgress,
                 projectIds: projects, projectStatuses: [:], dueOn: nil, firstStartedOn: nil,
                 completionDatesInRange: [], reopenedInRange: false,
                 eventsInRange: [], checklist: [], activitySourceIds: [])
    }

    private func source(_ id: String, kind: FactSourceKind, taskId: String? = nil) -> FactSource {
        FactSource(id: id, kind: kind, revision: 1, recordedAt: now,
                   workDate: WorkDate("2026-10-01"), taskId: taskId,
                   projectIds: [], text: "가짜 근거")
    }

    private func facts() -> ReportFacts {
        ReportFacts(
            family: .submission, periodType: .weekly, timezone: "Asia/Seoul",
            generatedAt: now,
            range: DateRange(start: WorkDate("2026-09-28")!, endExclusive: WorkDate("2026-10-05")!),
            statusCutoff: now, knownAt: now,
            planRange: DateRange(start: WorkDate("2026-10-05")!, endExclusive: WorkDate("2026-10-12")!),
            projects: [FactProject(id: "p-a", name: "가짜 A"), FactProject(id: "p-b", name: "가짜 B")],
            tasks: [task("task-a", projects: ["p-a", "p-b"]), task("task-b", projects: ["p-b"])],
            sources: [
                source("activity:a", kind: .activity, taskId: "task-a"),
                source("activity:b", kind: .activity, taskId: "task-b"),
                source("supplement:a", kind: .supplement, taskId: "task-a"),
                source("memo:accepted-a", kind: .memo),
                source("memo:accepted-b", kind: .memo),
                source("memo:independent", kind: .memo),
            ],
            confirmedPlans: [
                FactPlanItem(planItemIds: ["plan-a-1", "plan-a-2"], taskId: "task-a",
                             scopeType: .wholeTask, scopeId: nil, labels: ["가짜 확인"]),
                FactPlanItem(planItemIds: ["plan-b"], taskId: "task-b",
                             scopeType: .wholeTask, scopeId: nil, labels: ["가짜 검증"]),
            ],
            memoLinksAccepted: [AcceptedMemoLink(memoId: "accepted-a", taskId: "task-a"),
                                AcceptedMemoLink(memoId: "accepted-b", taskId: "task-b")],
            metrics: ReportMetrics())
    }

    private func firstTaskAIndex(_ draft: SubmissionDraft) throws -> Int {
        try XCTUnwrap(draft.groups.flatMap(\.items).firstIndex {
            $0.taskIds == ["task-a"] && $0.category == .inProgress
        })
    }

    private func regroup(_ items: [SubmissionItem]) -> SubmissionDraft {
        SubmissionDraft(groups: [SubmissionGroup(heading: "다듬은 제목", items: items)])
    }

    func testFixtureDraftPassesUnchangedAndWithReorderedPresentation() throws {
        let fixture = try FixtureLoader.load()
        let fixtureNow = try XCTUnwrap(fixture.clock?.now.flatMap(FixtureLoader.date))
        let repo = try WorkRepository.inMemory(clock: FixedClock(fixtureNow), ids: SequentialIDGenerator())
        try FixtureSeeder.seed(repo, fixture: fixture)
        let periods = Periods()
        let builder = ReportFactsBuilder(repo: repo, periods: periods,
                                        planService: WeekPlanService(repo: repo, periods: periods))
        let input = try builder.submissionFacts(reportDate: WorkDate("2026-10-05")!, knownAt: fixtureNow)
        let seed = SubmissionComposer.compose(input)
        XCTAssertFalse(seed.groups.flatMap(\.items).isEmpty)
        XCTAssertTrue(SubmissionAIContract.validate(draft: seed, seed: seed, facts: input).isEmpty)

        let reordered = seed.groups.flatMap(\.items).reversed().map { original in
            var item = original
            item.text = "간결하게 다듬은 가짜 문장"
            item.taskIds.reverse()
            item.projectIds.reverse()
            item.planItemIds.reverse()
            item.evidenceIds.reverse()
            return item
        }
        XCTAssertTrue(SubmissionAIContract.validate(draft: regroup(reordered), seed: seed,
                                                     facts: input).isEmpty)
    }

    func testStatusOnlyTasksNeedNoActivityEvidence() {
        let input = facts()
        let seed = SubmissionComposer.compose(input)
        XCTAssertTrue(seed.groups.flatMap(\.items).allSatisfy { $0.evidenceIds.isEmpty })
        XCTAssertTrue(SubmissionAIContract.validate(draft: seed, seed: seed, facts: input).isEmpty)
    }

    func testRejectsAddedRemovedDuplicatedAndRenamedItems() throws {
        let input = facts()
        let seed = SubmissionComposer.compose(input)
        let original = seed.groups.flatMap(\.items)
        var added = try XCTUnwrap(original.first)
        added.itemId = "invented-line"
        var renamed = original
        renamed[0].itemId = "renamed-line"
        for items in [Array(original.dropFirst()), original + [added],
                      original + [original[0]], renamed, []] {
            let findings = SubmissionAIContract.validate(draft: regroup(items), seed: seed, facts: input)
            XCTAssertTrue(findings.contains { $0.code == "ai_submission_items_mismatch" && $0.severity == .error })
        }
    }

    func testRejectsSwappingKnownTaskProjectCategoryAndPlanBindings() throws {
        let input = facts()
        let seed = SubmissionComposer.compose(input)
        let original = seed.groups.flatMap(\.items)
        let index = try firstTaskAIndex(seed)
        let plannedIndex = try XCTUnwrap(original.firstIndex {
            $0.taskIds == ["task-a"] && $0.category == .planned
        })
        let mutations: [(inout [SubmissionItem]) -> Void] = [
            { $0[index].taskIds = ["task-b"] },
            { $0[index].projectIds = ["p-b"] },
            { $0[index].category = .completed },
            { $0[plannedIndex].planItemIds = ["plan-b"] },
            { $0[index].projectIds.append("p-a") },
            { $0[index].taskIds = [] },
        ]
        for mutate in mutations {
            var items = original
            mutate(&items)
            let findings = SubmissionAIContract.validate(draft: regroup(items), seed: seed, facts: input)
            XCTAssertTrue(findings.contains { $0.code == "ai_submission_binding_mismatch" && $0.severity == .error })
        }
    }

    func testAllowsOwnedActivitySupplementAndExplicitlyAcceptedMemo() throws {
        let input = facts()
        let seed = SubmissionComposer.compose(input)
        var items = seed.groups.flatMap(\.items)
        items[try firstTaskAIndex(seed)].evidenceIds = ["activity:a", "supplement:a", "memo:accepted-a"]
        XCTAssertTrue(SubmissionAIContract.validate(draft: regroup(items), seed: seed, facts: input).isEmpty)

        let withEvidence = regroup(items)
        items[try firstTaskAIndex(seed)].evidenceIds = []
        XCTAssertTrue(SubmissionAIContract.validate(draft: regroup(items), seed: withEvidence,
                                                     facts: input).isEmpty,
                      "문장을 다듬으면서 사용하지 않은 기존 근거를 빼는 것은 허용한다")
    }

    func testRejectsIndependentMemoAndOtherTasksEvidence() throws {
        let input = facts()
        let seed = SubmissionComposer.compose(input)
        let index = try firstTaskAIndex(seed)
        for sourceId in ["memo:independent", "activity:b", "memo:accepted-b"] {
            var items = seed.groups.flatMap(\.items)
            items[index].evidenceIds = [sourceId]
            let findings = SubmissionAIContract.validate(draft: regroup(items), seed: seed, facts: input)
            XCTAssertEqual(findings.map(\.code), ["ai_submission_unrelated_evidence"], sourceId)
            XCTAssertEqual(findings.first?.itemId, items[index].itemId)
            XCTAssertEqual(findings.first?.severity, .error)
        }
    }

    func testUnknownEvidenceRemainsGeneralValidatorsResponsibility() throws {
        let input = facts()
        let seed = SubmissionComposer.compose(input)
        var items = seed.groups.flatMap(\.items)
        items[try firstTaskAIndex(seed)].evidenceIds = ["activity:unknown"]
        let draft = regroup(items)
        XCTAssertTrue(SubmissionAIContract.validate(draft: draft, seed: seed, facts: input).isEmpty)
        XCTAssertTrue(SubmissionValidator.validate(draft, facts: input).contains { $0.code == "unknown_evidence" })
    }

    func testMemoAlwaysRequiresAcceptedLinkEvenIfSourceHasTaskID() throws {
        var input = facts()
        let memoIndex = try XCTUnwrap(input.sources.firstIndex { $0.id == "memo:independent" })
        input.sources[memoIndex].taskId = "task-a"
        let seed = SubmissionComposer.compose(input)
        var items = seed.groups.flatMap(\.items)
        items[try firstTaskAIndex(seed)].evidenceIds = ["memo:independent"]
        XCTAssertEqual(SubmissionAIContract.validate(draft: regroup(items), seed: seed,
                                                     facts: input).map(\.code),
                       ["ai_submission_unrelated_evidence"])
    }
}
