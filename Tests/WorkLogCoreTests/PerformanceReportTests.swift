import XCTest
@testable import WorkLogCore

/// 성과 축적용 상세 리포트의 결정적 생성·렌더·검증 테스트.
/// DB/AI/네트워크/Secret을 사용하지 않고 `ReportFacts`를 직접 구성한다.
final class PerformanceReportTests: XCTestCase {

    // MARK: - Helpers

    private func date(_ iso: String) -> WorkDate { WorkDate(iso)! }

    private func range(_ start: String, _ endExclusive: String) -> DateRange {
        DateRange(start: date(start), endExclusive: date(endExclusive))
    }

    private func instant(_ minutes: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(minutes * 60)) }

    private func project(_ id: String, _ name: String) -> FactProject { FactProject(id: id, name: name) }

    private func task(
        _ id: String,
        _ title: String,
        statusAtStart: TaskStatus? = nil,
        statusAtCutoff: TaskStatus? = .inProgress,
        projectIds: [String] = [],
        trackingMode: ProjectTrackingMode = .shared,
        projectStatuses: [String: TaskStatus] = [:],
        completionDatesInRange: [WorkDate] = [],
        reopenedInRange: Bool = false,
        activitySourceIds: [String] = []
    ) -> FactTask {
        FactTask(id: id, title: title, trackingMode: trackingMode, statusAtStart: statusAtStart,
                 statusAtCutoff: statusAtCutoff, projectIds: projectIds, projectStatuses: projectStatuses,
                 dueOn: nil, firstStartedOn: nil, completionDatesInRange: completionDatesInRange,
                 reopenedInRange: reopenedInRange, eventsInRange: [], checklist: [],
                 activitySourceIds: activitySourceIds)
    }

    private func source(
        _ id: String,
        _ kind: FactSourceKind,
        workDate: WorkDate?,
        taskId: String? = nil,
        projectIds: [String] = [],
        text: String,
        recordedAt: Date = Date(timeIntervalSince1970: 0),
        applies: DateRange? = nil,
        sourceUrls: [String] = [],
        urlBodyFetched: Bool = false
    ) -> FactSource {
        FactSource(id: id, kind: kind, revision: 1, recordedAt: recordedAt, workDate: workDate,
                   applies: applies, taskId: taskId, projectIds: projectIds, text: text,
                   sourceUrls: sourceUrls, urlBodyFetched: urlBodyFetched)
    }

    private func facts(
        periodType: PeriodType = .weekly,
        range periodRange: DateRange? = nil,
        timezone: String = "Asia/Seoul",
        projects: [FactProject] = [],
        tasks: [FactTask] = [],
        sources: [FactSource] = [],
        memoLinksAccepted: [AcceptedMemoLink] = []
    ) -> ReportFacts {
        let resolvedRange = periodRange ?? range("2026-09-28", "2026-10-05")
        return ReportFacts(family: .performance, periodType: periodType, locale: "ko-KR",
                           timezone: timezone, generatedAt: instant(0), range: resolvedRange,
                           statusCutoff: instant(0), knownAt: instant(0), projects: projects,
                           tasks: tasks, sources: sources, memoLinksAccepted: memoLinksAccepted,
                           metrics: ReportMetrics())
    }

    private func stateItems(_ draft: PerformanceDraft) -> [PerformanceItem] {
        draft.sections.flatMap { $0.items }.filter { $0.kind == .state }
    }

    private func codes(_ findings: [ValidationFinding]) -> [String] { findings.map(\.code) }

    // MARK: - 1. defaultTitle

    func testDefaultTitles() {
        XCTAssertEqual(
            PerformanceComposer.defaultTitle(for: facts(periodType: .daily, range: range("2026-10-01", "2026-10-02"))),
            "2026-10-01 Daily 업무 리포트")
        XCTAssertEqual(
            PerformanceComposer.defaultTitle(for: facts(periodType: .weekly, range: range("2026-09-28", "2026-10-05"))),
            "2026-09-28 ~ 2026-10-04 주간 상세 리포트")
        XCTAssertEqual(
            PerformanceComposer.defaultTitle(for: facts(periodType: .monthly, range: range("2026-09-01", "2026-10-01"))),
            "2026-09 월간 상세 리포트")
        XCTAssertEqual(
            PerformanceComposer.defaultTitle(for: facts(periodType: .quarterly, range: range("2026-07-01", "2026-10-01"))),
            "2026 Q3 분기 상세 리포트")
        XCTAssertEqual(
            PerformanceComposer.defaultTitle(for: facts(periodType: .yearly, range: range("2026-01-01", "2026-10-01"))),
            "2026-01-01 ~ 2026-09-30 평가 기간 상세 리포트")
    }

    // MARK: - 2. 섹션 배치

    func testSectionPlacementAndOrder() {
        let g = project("p1", "G")
        let j = project("p2", "J")
        let single = task("t1", "단일", projectIds: ["p1"])
        let common = task("t2", "공통", projectIds: ["p1", "p2"])
        let orphan = task("t3", "무소속")
        let input = facts(projects: [g, j], tasks: [single, common, orphan])

        let draft = PerformanceComposer.compose(input)

        XCTAssertEqual(draft.sections.map(\.heading), ["G", "공통 업무", "기타"])
        XCTAssertEqual(draft.sections[0].items.count, 1)
        XCTAssertEqual(draft.sections[1].items.count, 1) // 다중 프로젝트 Task는 state 1개만
        XCTAssertEqual(draft.sections[1].projectIds, ["p1", "p2"])
        XCTAssertEqual(draft.sections[1].items[0].taskIds, ["t2"])
        XCTAssertEqual(draft.sections[2].items.count, 1)
    }

    // MARK: - 3. state 텍스트

    func testStateTextVariants() {
        let g = project("p1", "G")
        let j = project("p2", "J")
        let t = task("t1", "결제 개선", statusAtStart: nil, statusAtCutoff: .inProgress,
                     projectIds: ["p1", "p2"], trackingMode: .perProject,
                     projectStatuses: ["p1": .completed, "p2": .inProgress],
                     completionDatesInRange: [date("2026-09-30")], reopenedInRange: true)
        let input = facts(projects: [g, j], tasks: [t])

        let items = stateItems(PerformanceComposer.compose(input))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(
            items[0].text,
            "결제 개선 — 상태: 신규 → 진행; 완료 2026-09-30; 기간 중 재개; 프로젝트별: G 적용 완료, J 진행 중")
        XCTAssertTrue(items[0].evidenceIds.isEmpty)
    }

    // MARK: - 4. 근거 아이템

    func testEvidenceItemsKindsOrderAndText() {
        let g = project("p1", "G")
        let t = task("t1", "T", projectIds: ["p1"])
        let laterActivity = source("activity:a1", .activity, workDate: date("2026-10-01"), taskId: "t1",
                                   projectIds: ["p1"], text: "나중")
        let earlyActivity = source("activity:a0", .activity, workDate: date("2026-09-29"), taskId: "t1",
                                   projectIds: ["p1"], text: "먼저\n둘째 줄")
        let memo = source("memo:m1", .memo, workDate: date("2026-09-30"), text: "메모 내용")
        let supplement = source("supplement:s1", .supplement, workDate: nil, taskId: "t1",
                                text: "보충 답변", applies: range("2026-09-28", "2026-10-05"))
        let longText = source("activity:a2", .activity, workDate: date("2026-10-02"), taskId: "t1",
                              projectIds: ["p1"], text: String(repeating: "가", count: 250))
        let input = facts(projects: [g], tasks: [t],
                          sources: [laterActivity, earlyActivity, memo, supplement, longText],
                          memoLinksAccepted: [AcceptedMemoLink(memoId: "m1", taskId: "t1")])

        let items = PerformanceComposer.compose(input).sections[0].items
        let evidence = items.filter { $0.kind != .state }

        let expectedKinds: [PerformanceItemKind] = [.activity, .discussion, .activity, .activity, .activity]
        XCTAssertEqual(evidence.map(\.kind), expectedKinds)
        XCTAssertEqual(evidence[0].text, "[2026-09-29] 먼저")
        XCTAssertEqual(evidence[0].evidenceIds, ["activity:a0"])
        XCTAssertEqual(evidence[1].text, "[2026-09-30] 메모 내용")
        XCTAssertEqual(evidence[2].text, "[2026-10-01] 나중")
        XCTAssertEqual(evidence[3].text.count, "[2026-10-02] ".count + 200)
        XCTAssertEqual(evidence[3].text, "[2026-10-02] " + String(repeating: "가", count: 200))
        XCTAssertEqual(evidence[4].text, "[보충 답변 2026-09-28~2026-10-05] 보충 답변")
    }

    func testTaskEvidenceIncludesSourceAssignedByTaskId() {
        let g = project("p1", "G")
        let t = task("t1", "T", projectIds: ["p1"])
        let byTaskId = source("activity:a1", .activity, workDate: date("2026-09-29"), taskId: "t1", text: "근거")
        let input = facts(projects: [g], tasks: [t], sources: [byTaskId])

        let evidence = PerformanceComposer.compose(input).sections[0].items.filter { $0.kind == .activity }
        XCTAssertEqual(evidence.map(\.evidenceIds), [["activity:a1"]])
        XCTAssertEqual(evidence[0].taskIds, ["t1"])
    }

    // MARK: - 5. missingEvidence

    func testMissingEvidence() {
        let g = project("p1", "G")
        let stateOnly = task("t1", "상태만", statusAtCutoff: .inProgress, projectIds: ["p1"])
        let completed = task("t2", "완료", statusAtCutoff: .completed, projectIds: ["p1"],
                             completionDatesInRange: [date("2026-09-30")])
        let activity = source("activity:a1", .activity, workDate: date("2026-09-29"), taskId: "t2",
                              projectIds: ["p1"], text: "수행")
        let input = facts(projects: [g], tasks: [stateOnly, completed], sources: [activity])

        let draft = PerformanceComposer.compose(input)
        XCTAssertTrue(draft.missingEvidence.contains { $0.taskId == "t1" && $0.field == "activity" })
        XCTAssertTrue(draft.missingEvidence.contains { $0.taskId == "t2" && $0.field == "result" })
        XCTAssertFalse(draft.missingEvidence.contains { $0.taskId == "t2" && $0.field == "activity" })
    }

    // MARK: - 6. 빈 입력

    func testEmptyFacts() {
        let draft = PerformanceComposer.compose(facts())
        XCTAssertEqual(draft.sections.count, 1)
        XCTAssertEqual(draft.sections[0].heading, "기록 없음")
        XCTAssertEqual(draft.sections[0].items.count, 1)
        XCTAssertEqual(draft.sections[0].items[0].kind, .unknown)
        XCTAssertEqual(draft.sections[0].items[0].text, "기록 없음")
        XCTAssertEqual(draft.warnings, ["기간 내 기록 없음"])
    }

    // MARK: - 7. compose → validate error 0

    func testComposedDraftHasNoErrors() {
        let g = project("p1", "G")
        let j = project("p2", "J")

        let single = task("t1", "단일", projectIds: ["p1"])
        let a1 = source("activity:a1", .activity, workDate: date("2026-09-29"), taskId: "t1",
                        projectIds: ["p1"], text: "코드 작성")
        let memoLinked = source("memo:m2", .memo, workDate: date("2026-09-30"), text: "논의")

        let common = task("t2", "공통", projectIds: ["p1", "p2"])
        let a2 = source("activity:a2", .activity, workDate: date("2026-09-30"), taskId: "t2",
                        projectIds: ["p1"], text: "공통 작업")

        let completed = task("t3", "완료", statusAtCutoff: .completed, projectIds: ["p1"],
                             completionDatesInRange: [date("2026-09-30")])
        let s1 = source("supplement:s1", .supplement, workDate: nil, taskId: "t3",
                        text: "결과 확인", applies: range("2026-09-28", "2026-10-05"))

        let orphanMemo = source("memo:m1", .memo, workDate: date("2026-09-29"), text: "무소속 메모")

        let input = facts(projects: [g, j], tasks: [single, common, completed],
                          sources: [a1, memoLinked, a2, s1, orphanMemo],
                          memoLinksAccepted: [AcceptedMemoLink(memoId: "m2", taskId: "t1")])

        let draft = PerformanceComposer.compose(input)
        let findings = PerformanceValidator.validate(draft, facts: input)
        XCTAssertTrue(findings.filter { $0.severity == .error }.isEmpty)
        XCTAssertFalse(PerformanceValidator.hasErrors(findings))
    }

    // MARK: - 8. validate 실패

    func testValidateSchemaMismatch() {
        let draft = PerformanceDraft(periodType: .daily, title: "x", sections: [])
        let findings = PerformanceValidator.validate(draft, facts: facts(periodType: .weekly))
        XCTAssertTrue(PerformanceValidator.hasErrors(findings))
        XCTAssertTrue(codes(findings).contains("schema"))
    }

    func testValidateUnknownEvidence() {
        let item = PerformanceItem(itemId: "item-1", taskIds: [], projectIds: [], kind: .activity,
                                   text: "x", evidenceIds: ["activity:nope"])
        let draft = PerformanceDraft(periodType: .weekly, title: "x",
                                     sections: [PerformanceSection(heading: "H", projectIds: [], items: [item])])
        let findings = PerformanceValidator.validate(draft, facts: facts())
        XCTAssertTrue(PerformanceValidator.hasErrors(findings))
        XCTAssertTrue(codes(findings).contains("unknown_evidence"))
    }

    func testValidateEvidenceOutOfRangeAndSupplementApplies() {
        let g = project("p1", "G")
        let t = task("t1", "T", projectIds: ["p1"])
        let outside = source("activity:out", .activity, workDate: date("2026-09-01"), projectIds: ["p1"], text: "밖")
        let overlapping = source("supplement:ok", .supplement, workDate: nil,
                                 text: "겹침", applies: range("2026-09-28", "2026-10-05"))
        let disjoint = source("supplement:no", .supplement, workDate: nil,
                              text: "안 겹침", applies: range("2026-08-01", "2026-08-15"))
        let input = facts(projects: [g], tasks: [t], sources: [outside, overlapping, disjoint])

        let bad = PerformanceItem(itemId: "item-1", taskIds: [], projectIds: [], kind: .activity,
                                  text: "x", evidenceIds: ["activity:out"])
        let badDraft = PerformanceDraft(periodType: .weekly, title: "x",
                                        sections: [PerformanceSection(heading: "H", projectIds: [], items: [bad])])
        XCTAssertTrue(codes(PerformanceValidator.validate(badDraft, facts: input)).contains("evidence_out_of_range"))

        let okSUPP = PerformanceItem(itemId: "item-1", taskIds: [], projectIds: [], kind: .activity,
                                     text: "x", evidenceIds: ["supplement:ok"])
        let okDraft = PerformanceDraft(periodType: .weekly, title: "x",
                                       sections: [PerformanceSection(heading: "H", projectIds: [], items: [okSUPP])])
        XCTAssertFalse(codes(PerformanceValidator.validate(okDraft, facts: input)).contains("evidence_out_of_range"))

        let noSUPP = PerformanceItem(itemId: "item-1", taskIds: [], projectIds: [], kind: .activity,
                                     text: "x", evidenceIds: ["supplement:no"])
        let noDraft = PerformanceDraft(periodType: .weekly, title: "x",
                                       sections: [PerformanceSection(heading: "H", projectIds: [], items: [noSUPP])])
        XCTAssertTrue(codes(PerformanceValidator.validate(noDraft, facts: input)).contains("evidence_out_of_range"))
    }

    func testValidateProjectEvidenceMismatch() {
        let g = project("p1", "G")
        let j = project("p2", "J")
        let t = task("t1", "공통", projectIds: ["p1", "p2"])
        let onlyG = source("activity:a1", .activity, workDate: date("2026-09-29"), taskId: "t1",
                           projectIds: ["p1"], text: "G 작업")
        let input = facts(projects: [g, j], tasks: [t], sources: [onlyG])

        // G 근거만 있는데 J 효과(item.projectIds = p2)를 주장
        let item = PerformanceItem(itemId: "item-1", taskIds: ["t1"], projectIds: ["p2"], kind: .activity,
                                   text: "J 효과", evidenceIds: ["activity:a1"])
        let draft = PerformanceDraft(periodType: .weekly, title: "x",
                                     sections: [PerformanceSection(heading: "공통 업무", projectIds: [], items: [item])])
        XCTAssertTrue(codes(PerformanceValidator.validate(draft, facts: input)).contains("project_evidence_mismatch"))
    }

    func testValidateDuplicateTaskState() {
        let g = project("p1", "G")
        let t = task("t1", "T", projectIds: ["p1"])
        let input = facts(projects: [g], tasks: [t])
        let items = [
            PerformanceItem(itemId: "item-1", taskIds: ["t1"], projectIds: ["p1"], kind: .state,
                            text: "상태 1", evidenceIds: []),
            PerformanceItem(itemId: "item-2", taskIds: ["t1"], projectIds: ["p1"], kind: .state,
                            text: "상태 2", evidenceIds: []),
        ]
        let draft = PerformanceDraft(periodType: .weekly, title: "x",
                                     sections: [PerformanceSection(heading: "G", projectIds: ["p1"], items: items)])
        XCTAssertTrue(codes(PerformanceValidator.validate(draft, facts: input)).contains("duplicate_task_state"))
    }

    func testValidateUnverifiedNumber() {
        let a1 = source("activity:a1", .activity, workDate: date("2026-09-29"), text: "3건 처리 완료")
        let input = facts(sources: [a1])
        let item = PerformanceItem(itemId: "item-1", taskIds: [], projectIds: [], kind: .activity,
                                   text: "성능 30% 개선, 3건 처리", evidenceIds: ["activity:a1"])
        let draft = PerformanceDraft(periodType: .weekly, title: "x",
                                     sections: [PerformanceSection(heading: "H", projectIds: [], items: [item])])
        let findings = PerformanceValidator.validate(draft, facts: input)
        let numbers = findings.filter { $0.code == "unverified_number" }
        XCTAssertEqual(numbers.count, 1)
        XCTAssertTrue(numbers[0].message.contains("30%"))
        XCTAssertFalse(PerformanceValidator.hasErrors(findings))
    }

    func testValidateUnknownURL() {
        let a1 = source("activity:a1", .activity, workDate: date("2026-09-29"),
                        text: "참고", sourceUrls: ["https://known.example/a"])
        let input = facts(sources: [a1])
        let item = PerformanceItem(itemId: "item-1", taskIds: [], projectIds: [], kind: .activity,
                                   text: "자세한 내용은 https://unknown.example/b 참조", evidenceIds: ["activity:a1"])
        let draft = PerformanceDraft(periodType: .weekly, title: "x",
                                     sections: [PerformanceSection(heading: "H", projectIds: [], items: [item])])
        XCTAssertTrue(codes(PerformanceValidator.validate(draft, facts: input)).contains("unknown_url"))
    }

    func testValidateUnfetchedLinkClaim() {
        let a1 = source("activity:a1", .activity, workDate: date("2026-09-29"), text: "참고",
                        sourceUrls: ["https://x.example/y"], urlBodyFetched: false)
        let input = facts(sources: [a1])
        let item = PerformanceItem(itemId: "item-1", taskIds: [], projectIds: [], kind: .activity,
                                   text: "PR 내용을 확인했다", evidenceIds: ["activity:a1"])
        let draft = PerformanceDraft(periodType: .weekly, title: "x",
                                     sections: [PerformanceSection(heading: "H", projectIds: [], items: [item])])
        let findings = PerformanceValidator.validate(draft, facts: input)
        XCTAssertTrue(codes(findings).contains("unfetched_link_claim"))
        XCTAssertFalse(PerformanceValidator.hasErrors(findings))
    }

    func testValidateStatusMisrepresented() {
        let g = project("p1", "G")
        let cancelled = task("t1", "취소 업무", statusAtCutoff: .cancelled, projectIds: ["p1"],
                             trackingMode: .perProject, projectStatuses: ["p1": .completed])
        let input = facts(projects: [g], tasks: [cancelled])

        let badItem = PerformanceItem(itemId: "item-1", taskIds: ["t1"], projectIds: ["p1"], kind: .state,
                                      text: "취소 업무 — 상태: 진행 → 취소; 작업 완료", evidenceIds: [])
        let badDraft = PerformanceDraft(periodType: .weekly, title: "x",
                                        sections: [PerformanceSection(heading: "G", projectIds: ["p1"], items: [badItem])])
        XCTAssertTrue(codes(PerformanceValidator.validate(badDraft, facts: input)).contains("status_misrepresented"))

        // "적용 완료"만 있는 경우는 오탐 아님
        let okItem = PerformanceItem(itemId: "item-1", taskIds: ["t1"], projectIds: ["p1"], kind: .state,
                                     text: "취소 업무 — 상태: 진행 → 취소; 프로젝트별: G 적용 완료", evidenceIds: [])
        let okDraft = PerformanceDraft(periodType: .weekly, title: "x",
                                       sections: [PerformanceSection(heading: "G", projectIds: ["p1"], items: [okItem])])
        XCTAssertFalse(codes(PerformanceValidator.validate(okDraft, facts: input)).contains("status_misrepresented"))
    }

    // MARK: - 9. render

    func testRenderMarkdown() {
        let draft = PerformanceDraft(
            periodType: .weekly, title: "T",
            sections: [
                PerformanceSection(heading: "P1", projectIds: ["p1"], items: [
                    PerformanceItem(itemId: "item-1", taskIds: ["t1"], projectIds: ["p1"], kind: .state,
                                    text: "A — 상태: 진행 → 완료", evidenceIds: []),
                    PerformanceItem(itemId: "item-2", taskIds: ["t1"], projectIds: ["p1"], kind: .activity,
                                    text: "[2026-09-29] 했다", evidenceIds: ["activity:a1", "activity:a2"]),
                ]),
            ],
            missingEvidence: [MissingEvidence(taskId: "t1", field: "result", reason: "확인 필요")],
            warnings: ["경고1"])

        let expected = """
        # T

        ## P1
        - A — 상태: 진행 → 완료
        - [2026-09-29] 했다 [근거: activity:a1, activity:a2]

        ## 확인 필요
        - t1: 확인 필요

        ## 경고
        - 경고1
        """
        XCTAssertEqual(PerformanceComposer.render(draft), expected)
    }

    // MARK: - 10. 결정성

    func testComposeIsDeterministic() {
        let g = project("p1", "G")
        let t = task("t1", "T", projectIds: ["p1"])
        let a = source("activity:a1", .activity, workDate: date("2026-09-29"), taskId: "t1",
                       projectIds: ["p1"], text: "근거")
        let input = facts(projects: [g], tasks: [t], sources: [a])
        XCTAssertEqual(PerformanceComposer.compose(input), PerformanceComposer.compose(input))
    }
}
