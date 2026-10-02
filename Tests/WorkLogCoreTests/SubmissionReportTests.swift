import XCTest
@testable import WorkLogCore

/// 제출용 주간보고 결정적 분류·렌더·검증 (WLOG-45A3 N).
/// ReportFacts를 테스트 안에서 직접 구성한다. DB/AI/네트워크/Secret 접근 없음.
final class SubmissionReportTests: XCTestCase {

    // MARK: - 헬퍼

    private func wd(_ iso: String) -> WorkDate {
        guard let d = WorkDate(iso) else { fatalError("invalid date \(iso)") }
        return d
    }

    private func makeRange(_ start: String, _ endExclusive: String) -> DateRange {
        DateRange(start: wd(start), endExclusive: wd(endExclusive))
    }

    private func makeTask(
        _ id: String,
        title: String,
        statusAtCutoff: TaskStatus?,
        statusAtStart: TaskStatus? = nil,
        trackingMode: ProjectTrackingMode = .shared,
        projectIds: [String] = [],
        projectStatuses: [String: TaskStatus] = [:],
        completionDatesInRange: [WorkDate] = [],
        reopenedInRange: Bool = false,
        checklist: [FactChecklistItem] = [],
        activitySourceIds: [String] = []
    ) -> FactTask {
        FactTask(
            id: id, title: title, trackingMode: trackingMode, statusAtStart: statusAtStart,
            statusAtCutoff: statusAtCutoff, projectIds: projectIds, projectStatuses: projectStatuses,
            dueOn: nil, firstStartedOn: nil, completionDatesInRange: completionDatesInRange,
            reopenedInRange: reopenedInRange, eventsInRange: [], checklist: checklist,
            activitySourceIds: activitySourceIds
        )
    }

    private func makeFacts(
        projects: [FactProject] = [],
        tasks: [FactTask] = [],
        sources: [FactSource] = [],
        confirmedPlans: [FactPlanItem] = []
    ) -> ReportFacts {
        ReportFacts(
            family: .submission, periodType: .weekly, timezone: "Asia/Seoul",
            generatedAt: Date(timeIntervalSince1970: 0),
            range: makeRange("2026-09-28", "2026-10-05"),
            statusCutoff: Date(timeIntervalSince1970: 0),
            knownAt: Date(timeIntervalSince1970: 0),
            planRange: makeRange("2026-10-05", "2026-10-12"),
            projects: projects, tasks: tasks, sources: sources,
            confirmedPlans: confirmedPlans, metrics: ReportMetrics()
        )
    }

    private func makeSource(_ id: String, sourceUrls: [String] = []) -> FactSource {
        FactSource(
            id: id, kind: .activity, revision: 1, recordedAt: Date(timeIntervalSince1970: 0),
            workDate: wd("2026-09-30"), taskId: nil, projectIds: [], text: "원문",
            sourceUrls: sourceUrls
        )
    }

    private func makeDraft(
        _ items: [SubmissionItem],
        schemaVersion: Int = 1,
        jobType: String = "submission_weekly"
    ) -> SubmissionDraft {
        SubmissionDraft(
            schemaVersion: schemaVersion, jobType: jobType,
            groups: [SubmissionGroup(heading: "H", items: items)]
        )
    }

    private func codes(_ findings: [ValidationFinding]) -> [String] { findings.map(\.code) }

    private func allItems(_ draft: SubmissionDraft) -> [SubmissionItem] {
        draft.groups.flatMap(\.items)
    }

    // MARK: - 1. 지난주 분류

    func testPastCategoryClassification() {
        let done = makeTask("t-done", title: "완료업무", statusAtCutoff: .completed,
                            completionDatesInRange: [wd("2026-09-30")])
        let progressed = makeTask("t-prog", title: "진행업무", statusAtCutoff: .inProgress)
        let doneBeforeRange = makeTask("t-old", title: "이전완료", statusAtCutoff: .completed,
                                       completionDatesInRange: [])
        let planned = makeTask("t-plan", title: "예정업무", statusAtCutoff: .planned)
        let onHold = makeTask("t-hold", title: "보류업무", statusAtCutoff: .onHold)
        let cancelled = makeTask("t-cancel", title: "취소업무", statusAtCutoff: .cancelled)
        let noStatus = makeTask("t-nil", title: "상태없음", statusAtCutoff: nil)

        XCTAssertEqual(SubmissionComposer.expectedPastCategory(for: done), .completed)
        XCTAssertEqual(SubmissionComposer.expectedPastCategory(for: progressed), .inProgress)
        XCTAssertNil(SubmissionComposer.expectedPastCategory(for: doneBeforeRange))
        XCTAssertNil(SubmissionComposer.expectedPastCategory(for: planned))
        XCTAssertNil(SubmissionComposer.expectedPastCategory(for: onHold))
        XCTAssertNil(SubmissionComposer.expectedPastCategory(for: cancelled))
        XCTAssertNil(SubmissionComposer.expectedPastCategory(for: noStatus))

        // 기간 전 완료(완료 사건 없음)와 예정 Task는 초안에 나오지 않는다.
        let facts = makeFacts(tasks: [doneBeforeRange, planned])
        XCTAssertTrue(allItems(SubmissionComposer.compose(facts)).isEmpty)
    }

    // MARK: - 2. TIME-T02: 월요일 완료라도 지난주는 진행

    func testTimeT02MondayCompletionStaysInProgress() {
        let task = makeTask("t1", title: "일요일 진행 업무", statusAtCutoff: .inProgress,
                            statusAtStart: .inProgress, completionDatesInRange: [])
        XCTAssertEqual(SubmissionComposer.expectedPastCategory(for: task), .inProgress)

        let facts = makeFacts(tasks: [task])
        let items = allItems(SubmissionComposer.compose(facts))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].category, .inProgress)
    }

    // MARK: - 3. REP-T13: 완료 후 재개

    func testRepT13ReopenedStaysInProgressWithMarker() {
        let task = makeTask("t1", title: "재개된 업무", statusAtCutoff: .inProgress,
                            completionDatesInRange: [wd("2026-09-29")], reopenedInRange: true)
        XCTAssertEqual(SubmissionComposer.expectedPastCategory(for: task), .inProgress)

        let draft = SubmissionComposer.compose(makeFacts(tasks: [task]))
        let items = allItems(draft)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].category, .inProgress)
        XCTAssertEqual(items[0].text, "재개된 업무 (재개)")
    }

    // MARK: - 4. 보류·취소는 reviewNotes로

    func testOnHoldAndCancelledGoToReviewNotes() {
        let onHold = makeTask("t-hold", title: "보류업무", statusAtCutoff: .onHold)
        let cancelled = makeTask("t-cancel", title: "취소업무", statusAtCutoff: .cancelled)
        let facts = makeFacts(tasks: [onHold, cancelled])

        let draft = SubmissionComposer.compose(facts)
        XCTAssertTrue(draft.groups.isEmpty)
        XCTAssertEqual(draft.reviewNotes, ["보류: 보류업무", "취소: 취소업무"])
    }

    // MARK: - 5. REP-T02 / WEEK-03: 다중 프로젝트 공통 업무

    func testRepT02CommonTaskNotRepeated() {
        let projects = [
            FactProject(id: "G", name: "G"),
            FactProject(id: "J", name: "J"),
            FactProject(id: "K", name: "K"),
        ]
        let task = makeTask("A", title: "공통 인프라 설정 개선", statusAtCutoff: .inProgress,
                            trackingMode: .perProject, projectIds: ["G", "J", "K"],
                            projectStatuses: ["G": .completed, "J": .inProgress, "K": .planned])
        let facts = makeFacts(projects: projects, tasks: [task])

        let draft = SubmissionComposer.compose(facts)
        XCTAssertEqual(draft.groups.count, 1)
        XCTAssertEqual(draft.groups[0].heading, SubmissionComposer.commonHeading)
        XCTAssertEqual(draft.groups[0].items.count, 1)
        let item = draft.groups[0].items[0]
        XCTAssertEqual(item.category, .inProgress)
        XCTAssertEqual(item.text, "공통 인프라 설정 개선 — G 적용 완료, J 진행 중, K 예정")
    }

    func testCommonTaskPastAndPlannedCoexist() {
        let projects = [
            FactProject(id: "G", name: "G"),
            FactProject(id: "J", name: "J"),
            FactProject(id: "K", name: "K"),
        ]
        let task = makeTask("A", title: "공통 인프라 설정 개선", statusAtCutoff: .inProgress,
                            trackingMode: .perProject, projectIds: ["G", "J", "K"],
                            projectStatuses: ["G": .completed, "J": .inProgress, "K": .planned])
        let plans = [FactPlanItem(planItemIds: ["p1"], taskId: "A", scopeType: .wholeTask,
                                  scopeId: nil, labels: ["J 적용 마무리"])]
        let facts = makeFacts(projects: projects, tasks: [task], confirmedPlans: plans)

        let draft = SubmissionComposer.compose(facts)
        XCTAssertEqual(draft.groups.count, 1)
        let items = draft.groups[0].items
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.category), [.inProgress, .planned])
        XCTAssertEqual(items[1].text, "공통 인프라 설정 개선 — J 적용 마무리")
    }

    // MARK: - 6. 예정은 confirmedPlans만, 같은 Task 계획은 한 줄로

    func testPlannedOnlyFromConfirmedPlansAndMerged() {
        let project = FactProject(id: "P1", name: "P1")
        let plannedTask = makeTask("T", title: "문서 정리", statusAtCutoff: .planned, projectIds: ["P1"])
        let unplannedTask = makeTask("U", title: "계획에 없는 예정", statusAtCutoff: .planned)
        let plans = [
            FactPlanItem(planItemIds: ["pa"], taskId: "T", scopeType: .wholeTask, scopeId: nil, labels: ["A작업"]),
            FactPlanItem(planItemIds: ["pb"], taskId: "T", scopeType: .wholeTask, scopeId: nil, labels: ["B작업"]),
        ]
        let facts = makeFacts(projects: [project], tasks: [plannedTask, unplannedTask], confirmedPlans: plans)

        let draft = SubmissionComposer.compose(facts)
        let items = allItems(draft)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].category, .planned)
        XCTAssertEqual(items[0].planItemIds, ["pa", "pb"])
        XCTAssertEqual(items[0].text, "문서 정리 — A작업, B작업")
    }

    func testPlannedScopeFallbackForTaskProjectAndChecklist() {
        let project = FactProject(id: "P1", name: "프로젝트1")
        let checklist = FactChecklistItem(id: "c1", text: "체크 항목 정리", projectIds: ["P1"], doneAtCutoff: false)
        let task = makeTask("T", title: "문서 정리", statusAtCutoff: .planned,
                            projectIds: ["P1"], checklist: [checklist])
        let plans = [
            FactPlanItem(planItemIds: ["pa"], taskId: "T", scopeType: .taskProject,
                         scopeId: "T/P1", labels: []),
            FactPlanItem(planItemIds: ["pb"], taskId: "T", scopeType: .checklistItem,
                         scopeId: "c1", labels: []),
        ]
        let facts = makeFacts(projects: [project], tasks: [task], confirmedPlans: plans)

        let items = allItems(SubmissionComposer.compose(facts))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "문서 정리 — 프로젝트1 적용, 체크 항목 정리")
    }

    // MARK: - 7. 그룹 순서: 단일 프로젝트 → 공통 업무 → 기타

    func testGroupOrderingAndOtherHeading() {
        let projects = [
            FactProject(id: "P1", name: "P1"),
            FactProject(id: "P2", name: "P2"),
        ]
        let a = makeTask("a", title: "P1 완료", statusAtCutoff: .completed,
                         projectIds: ["P1"], completionDatesInRange: [wd("2026-09-30")])
        let b = makeTask("b", title: "P2 진행", statusAtCutoff: .inProgress, projectIds: ["P2"])
        let c = makeTask("c", title: "공통 프로젝트 업무", statusAtCutoff: .inProgress,
                         projectIds: ["P1", "P2"])
        let d = makeTask("d", title: "프로젝트 없는 업무", statusAtCutoff: .completed,
                         completionDatesInRange: [wd("2026-09-30")])
        let facts = makeFacts(projects: projects, tasks: [a, b, c, d])

        let draft = SubmissionComposer.compose(facts)
        XCTAssertEqual(draft.groups.map(\.heading),
                       ["P1", "P2", SubmissionComposer.commonHeading, SubmissionComposer.otherHeading])
        XCTAssertEqual(draft.groups[3].items.first?.taskIds, ["d"])
    }

    // MARK: - 8. render 양식 (REP-T01)

    func testRenderMatchesInitialFormat() {
        let project = FactProject(id: "p1", name: "대중교통 길찾기")
        let t1 = makeTask("t1", title: "Java 자동 포맷팅 도입", statusAtCutoff: .completed,
                          projectIds: ["p1"], completionDatesInRange: [wd("2026-09-30")])
        let t2 = makeTask("t2", title: "지하철 배포 스크립트 정리", statusAtCutoff: .inProgress,
                          projectIds: ["p1"])
        let t3 = makeTask("t3", title: "OpenViking 이미지 업데이트", statusAtCutoff: .completed,
                          completionDatesInRange: [wd("2026-09-30")])
        let facts = makeFacts(projects: [project], tasks: [t1, t2, t3])

        let rendered = SubmissionComposer.render(SubmissionComposer.compose(facts))
        let expected = """
        대중교통 길찾기
        완료 Java 자동 포맷팅 도입
        진행 지하철 배포 스크립트 정리

        기타
        완료 OpenViking 이미지 업데이트
        """
        XCTAssertEqual(rendered, expected)
    }

    // MARK: - 9. validate(compose) 통과

    func testValidateComposedDraftHasNoErrors() {
        let project = FactProject(id: "p1", name: "프로젝트1")
        let source = makeSource("activity:1")
        let t1 = makeTask("t1", title: "완료 업무", statusAtCutoff: .completed,
                          projectIds: ["p1"], completionDatesInRange: [wd("2026-09-30")],
                          activitySourceIds: ["activity:1", "missing:1"])
        let t2 = makeTask("t2", title: "진행 업무", statusAtCutoff: .inProgress, projectIds: ["p1"])
        let plans = [FactPlanItem(planItemIds: ["pl1"], taskId: "t2", scopeType: .wholeTask,
                                  scopeId: nil, labels: ["다음 단계"])]
        let facts = makeFacts(projects: [project], tasks: [t1, t2], sources: [source], confirmedPlans: plans)

        let draft = SubmissionComposer.compose(facts)
        // activitySourceIds 중 facts.sourceIds에 있는 것만 evidence로 남는다.
        let completed = allItems(draft).first { $0.category == .completed }
        XCTAssertEqual(completed?.evidenceIds, ["activity:1"])

        let findings = SubmissionValidator.validate(draft, facts: facts)
        XCTAssertFalse(SubmissionValidator.hasErrors(findings), "예상치 못한 오류: \(codes(findings))")
    }

    // MARK: - 10. validate 실패 케이스

    func testValidateUnknownTask() {
        let facts = makeFacts()
        let draft = makeDraft([
            SubmissionItem(itemId: "line-1", category: .completed, text: "x",
                           taskIds: ["ghost"], projectIds: [])
        ])
        let findings = SubmissionValidator.validate(draft, facts: facts)
        XCTAssertTrue(codes(findings).contains("unknown_task"))
        XCTAssertTrue(SubmissionValidator.hasErrors(findings))
    }

    func testValidateUnknownEvidence() {
        let task = makeTask("t1", title: "진행 업무", statusAtCutoff: .inProgress)
        let facts = makeFacts(tasks: [task])
        let draft = makeDraft([
            SubmissionItem(itemId: "line-1", category: .inProgress, text: "x",
                           taskIds: ["t1"], projectIds: [], evidenceIds: ["bad"])
        ])
        let findings = SubmissionValidator.validate(draft, facts: facts)
        XCTAssertTrue(codes(findings).contains("unknown_evidence"))
    }

    func testValidateUnknownProjectAndPlanItem() {
        let task = makeTask("t1", title: "진행 업무", statusAtCutoff: .inProgress)
        let facts = makeFacts(tasks: [task])
        let draft = makeDraft([
            SubmissionItem(itemId: "line-1", category: .inProgress, text: "x",
                           taskIds: ["t1"], projectIds: ["ghost"], planItemIds: ["ghost-plan"])
        ])
        let findings = SubmissionValidator.validate(draft, facts: facts)
        XCTAssertTrue(codes(findings).contains("unknown_project"))
        XCTAssertTrue(codes(findings).contains("unknown_plan_item"))
    }

    func testValidateUnknownURL() {
        let task = makeTask("t1", title: "진행 업무", statusAtCutoff: .inProgress)
        let facts = makeFacts(tasks: [task])
        let draft = makeDraft([
            SubmissionItem(itemId: "line-1", category: .inProgress, text: "참고 https://example.com/x",
                           taskIds: ["t1"], projectIds: [])
        ])
        let findings = SubmissionValidator.validate(draft, facts: facts)
        XCTAssertTrue(codes(findings).contains("unknown_url"))
    }

    func testValidateCategoryMismatchInProgressWrittenAsCompleted() {
        let task = makeTask("t1", title: "진행 업무", statusAtCutoff: .inProgress)
        let facts = makeFacts(tasks: [task])
        let draft = makeDraft([
            SubmissionItem(itemId: "line-1", category: .completed, text: "x",
                           taskIds: ["t1"], projectIds: [])
        ])
        let findings = SubmissionValidator.validate(draft, facts: facts)
        XCTAssertTrue(codes(findings).contains("category_mismatch"))
    }

    func testValidateCategoryMismatchCancelledWrittenAsInProgress() {
        let task = makeTask("t1", title: "취소 업무", statusAtCutoff: .cancelled)
        let facts = makeFacts(tasks: [task])
        let draft = makeDraft([
            SubmissionItem(itemId: "line-1", category: .inProgress, text: "x",
                           taskIds: ["t1"], projectIds: [])
        ])
        let findings = SubmissionValidator.validate(draft, facts: facts)
        XCTAssertTrue(codes(findings).contains("category_mismatch"))
    }

    func testValidateUnconfirmedPlanWithoutItems() {
        let task = makeTask("t1", title: "예정 업무", statusAtCutoff: .planned)
        let facts = makeFacts(tasks: [task])
        let draft = makeDraft([
            SubmissionItem(itemId: "line-1", category: .planned, text: "x",
                           taskIds: ["t1"], projectIds: [], planItemIds: [])
        ])
        let findings = SubmissionValidator.validate(draft, facts: facts)
        XCTAssertTrue(codes(findings).contains("unconfirmed_plan"))
    }

    func testValidateDuplicateInCategory() {
        let date = wd("2026-09-30")
        let task = makeTask("t1", title: "완료 업무", statusAtCutoff: .completed,
                            completionDatesInRange: [date])
        let facts = makeFacts(tasks: [task])
        let draft = makeDraft([
            SubmissionItem(itemId: "line-1", category: .completed, text: "x",
                           taskIds: ["t1"], projectIds: []),
            SubmissionItem(itemId: "line-2", category: .completed, text: "y",
                           taskIds: ["t1"], projectIds: []),
        ])
        let findings = SubmissionValidator.validate(draft, facts: facts)
        XCTAssertTrue(codes(findings).contains("duplicate_in_category"))
    }

    func testValidateDuplicateItemId() {
        let t1 = makeTask("t1", title: "진행 업무1", statusAtCutoff: .inProgress)
        let t2 = makeTask("t2", title: "진행 업무2", statusAtCutoff: .inProgress)
        let facts = makeFacts(tasks: [t1, t2])
        let draft = makeDraft([
            SubmissionItem(itemId: "line-1", category: .inProgress, text: "x",
                           taskIds: ["t1"], projectIds: []),
            SubmissionItem(itemId: "line-1", category: .inProgress, text: "y",
                           taskIds: ["t2"], projectIds: []),
        ])
        let findings = SubmissionValidator.validate(draft, facts: facts)
        XCTAssertTrue(codes(findings).contains("duplicate_item_id"))
    }

    func testValidateSchema() {
        let facts = makeFacts()
        let draft = makeDraft([], schemaVersion: 2)
        let findings = SubmissionValidator.validate(draft, facts: facts)
        XCTAssertTrue(codes(findings).contains("schema"))
        XCTAssertTrue(SubmissionValidator.hasErrors(findings))
    }

    func testValidateEmptyText() {
        let task = makeTask("t1", title: "진행 업무", statusAtCutoff: .inProgress)
        let facts = makeFacts(tasks: [task])
        let draft = makeDraft([
            SubmissionItem(itemId: "line-1", category: .inProgress, text: "   ",
                           taskIds: ["t1"], projectIds: [])
        ])
        let findings = SubmissionValidator.validate(draft, facts: facts)
        XCTAssertTrue(codes(findings).contains("empty_text"))
    }

    // MARK: - 11. missing_reportable warning

    func testMissingReportableIsWarning() {
        let task = makeTask("t1", title: "완료 업무", statusAtCutoff: .completed,
                            completionDatesInRange: [wd("2026-09-30")])
        let facts = makeFacts(tasks: [task])
        let draft = makeDraft([])

        let findings = SubmissionValidator.validate(draft, facts: facts)
        XCTAssertTrue(codes(findings).contains("missing_reportable"))
        XCTAssertFalse(SubmissionValidator.hasErrors(findings))
    }

    // MARK: - 13. unverified_number / unfetched_link_claim 경고

    func testValidateUnverifiedNumberWarns() {
        let task = makeTask("t1", title: "진행 업무", statusAtCutoff: .inProgress)
        let source = makeSource("activity:1") // text "원문"
        let facts = makeFacts(tasks: [task], sources: [source])
        let draft = makeDraft([
            SubmissionItem(itemId: "line-1", category: .inProgress, text: "응답 시간 30% 개선",
                           taskIds: ["t1"], projectIds: [], evidenceIds: ["activity:1"])
        ])
        let findings = SubmissionValidator.validate(draft, facts: facts)
        XCTAssertTrue(codes(findings).contains("unverified_number"))
        XCTAssertFalse(SubmissionValidator.hasErrors(findings))
    }

    func testValidateVerifiedNumberDoesNotWarn() {
        let task = makeTask("t1", title: "진행 업무", statusAtCutoff: .inProgress)
        let source = FactSource(id: "activity:1", kind: .activity, revision: 1,
                                recordedAt: Date(timeIntervalSince1970: 0), workDate: wd("2026-09-30"),
                                taskId: "t1", projectIds: [], text: "응답 시간 30% 개선")
        let facts = makeFacts(tasks: [task], sources: [source])
        let draft = makeDraft([
            SubmissionItem(itemId: "line-1", category: .inProgress, text: "응답 시간 30% 개선",
                           taskIds: ["t1"], projectIds: [], evidenceIds: ["activity:1"])
        ])
        let findings = SubmissionValidator.validate(draft, facts: facts)
        XCTAssertFalse(codes(findings).contains("unverified_number"))
    }

    func testValidateUnfetchedLinkClaimWarns() {
        let task = makeTask("t1", title: "진행 업무", statusAtCutoff: .inProgress)
        let source = makeSource("activity:1", sourceUrls: ["https://example.com/pr/1"])
        let facts = makeFacts(tasks: [task], sources: [source])
        let draft = makeDraft([
            SubmissionItem(itemId: "line-1", category: .inProgress, text: "링크 내용을 확인했습니다",
                           taskIds: ["t1"], projectIds: [], evidenceIds: ["activity:1"])
        ])
        let findings = SubmissionValidator.validate(draft, facts: facts)
        XCTAssertTrue(codes(findings).contains("unfetched_link_claim"))
        XCTAssertFalse(SubmissionValidator.hasErrors(findings))
    }

    func testValidateFetchedLinkClaimDoesNotWarn() {
        let task = makeTask("t1", title: "진행 업무", statusAtCutoff: .inProgress)
        let source = FactSource(id: "activity:1", kind: .activity, revision: 1,
                                recordedAt: Date(timeIntervalSince1970: 0), workDate: wd("2026-09-30"),
                                taskId: "t1", projectIds: [], text: "원문",
                                sourceUrls: ["https://example.com/pr/1"], urlBodyFetched: true)
        let facts = makeFacts(tasks: [task], sources: [source])
        let draft = makeDraft([
            SubmissionItem(itemId: "line-1", category: .inProgress, text: "링크 내용을 확인했습니다",
                           taskIds: ["t1"], projectIds: [], evidenceIds: ["activity:1"])
        ])
        let findings = SubmissionValidator.validate(draft, facts: facts)
        XCTAssertFalse(codes(findings).contains("unfetched_link_claim"))
    }

    // MARK: - 14. compose 결정성

    func testComposeIsDeterministic() {
        let project = FactProject(id: "p1", name: "프로젝트1")
        let t1 = makeTask("t1", title: "완료 업무", statusAtCutoff: .completed,
                          projectIds: ["p1"], completionDatesInRange: [wd("2026-09-30")])
        let t2 = makeTask("t2", title: "진행 업무", statusAtCutoff: .inProgress, projectIds: ["p1"])
        let plans = [FactPlanItem(planItemIds: ["pl1"], taskId: "t2", scopeType: .wholeTask,
                                  scopeId: nil, labels: ["다음 단계"])]
        let facts = makeFacts(projects: [project], tasks: [t1, t2], confirmedPlans: plans)

        XCTAssertEqual(SubmissionComposer.compose(facts), SubmissionComposer.compose(facts))
    }
}
