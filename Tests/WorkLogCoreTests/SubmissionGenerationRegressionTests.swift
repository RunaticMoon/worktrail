import Foundation
import XCTest
@testable import WorkLogCore

/// 주간보고의 템플릿 → app-server → 로컬 검증 → 저장 경로. 실제 Codex나 인증은 사용하지 않는다.
final class SubmissionGenerationRegressionTests: XCTestCase {
    private let reportDate = WorkDate("2026-10-05")!

    private struct Harness {
        let repo: WorkRepository
        let templates: TemplateStore
        let server: FakeCodexServer
        let service: ReportService
        let validDraft: SubmissionDraft
    }

    private func makeHarness(
        seed: ((WorkRepository) throws -> Void)? = nil,
        output: ((SubmissionDraft) throws -> String)? = nil
    ) throws -> Harness {
        let fixture = try FixtureLoader.load()
        let now = try XCTUnwrap(fixture.clock?.now.flatMap(FixtureLoader.date))
        let repo = try WorkRepository.inMemory(clock: FixedClock(now), ids: SequentialIDGenerator())
        if let seed {
            try seed(repo)
        } else {
            try FixtureSeeder.seed(repo, fixture: fixture)
        }
        let periods = Periods()
        let builder = ReportFactsBuilder(repo: repo, periods: periods,
                                        planService: WeekPlanService(repo: repo, periods: periods))
        let facts = try builder.submissionFacts(reportDate: reportDate, knownAt: now)
        let validDraft = SubmissionComposer.compose(facts)
        let response = try output?(validDraft) ?? StableJSON.string(validDraft)

        let server = FakeCodexServer()
        scriptOutput(response, server: server)
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wlog-submission-regression-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: stagingRoot) }
        let config = CodexProviderConfig(executablePath: "/nonexistent/codex", stagingRoot: stagingRoot,
                                         requestTimeout: 5, turnTimeout: 5)
        let provider = CodexAppServerProvider(config: config, transportFactory: { server })
        let templates = TemplateStore(repo: repo)
        let service = ReportService(
            repo: repo, periods: periods, factsBuilder: builder, store: ReportStore(repo: repo),
            templates: templates,
            runner: AIJobRunner(repo: repo, provider: provider, stagingRoot: stagingRoot),
            evaluationPeriods: EvaluationPeriodService(repo: repo))
        return Harness(repo: repo, templates: templates, server: server, service: service,
                       validDraft: validDraft)
    }

    private func scriptOutput(_ response: String, server: FakeCodexServer) {
        server.script.mutate {
            $0.results["thread/start"] = .object([
                "thread": .object(["id": .string("thread-submission")]),
                "model": .string("fixture-model"),
            ])
            $0.results["turn/start"] = .object([
                "turn": .object(["id": .string("turn-submission")]),
            ])
            $0.followups["turn/start"] = [
                .object([
                    "method": .string("item/completed"),
                    "params": .object([
                        "threadId": .string("thread-submission"),
                        "turnId": .string("turn-submission"),
                        "item": .object([
                            "id": .string("item-submission"),
                            "type": .string("agentMessage"),
                            "text": .string(response),
                        ]),
                    ]),
                ]),
                .object([
                    "method": .string("turn/completed"),
                    "params": .object([
                        "threadId": .string("thread-submission"),
                        "turn": .object([
                            "id": .string("turn-submission"),
                            "status": .string("completed"),
                            "items": .array([]),
                        ]),
                    ]),
                ]),
            ]
        }
    }

    private func created(_ result: ReportGenerationResult,
                         file: StaticString = #filePath, line: UInt = #line) throws -> ReportVersion {
        guard case .created(let version) = result.outcome else {
            XCTFail("새 주간보고가 저장되어야 합니다: \(result.outcome)", file: file, line: line)
            throw WorkLogError.storage("report not created")
        }
        return version
    }

    private struct SubmissionRequestPayload: Decodable {
        let jobType: String
        let facts: ReportFacts
        let submissionDraft: SubmissionDraft
    }

    private func requestedPayload(_ h: Harness) throws -> SubmissionRequestPayload {
        let turn = try XCTUnwrap(h.server.messages(withMethod: "turn/start").first)
        let text = try XCTUnwrap(turn["params"]?["input"]?.arrayValue?.first?["text"]?.stringValue)
        return try StableJSON.decode(SubmissionRequestPayload.self, from: text)
    }

    func testStatusChangesWithoutActivityProduceTaskBackedRequestSeed() async throws {
        let workDate = WorkDate("2026-09-30")!
        var completedId = ""
        var inProgressId = ""
        let h = try makeHarness(seed: { repo in
            let tasks = TaskService(repo: repo)
            let completed = try tasks.createTask(title: "배포 점검", workDate: workDate)
            completedId = completed.id
            _ = try tasks.completeTask(taskId: completed.id, workDate: workDate, confirmRemaining: true)
            let inProgress = try tasks.createTask(title: "운영 문서 정리", workDate: workDate)
            inProgressId = inProgress.id
            try tasks.changeTaskStatus(taskId: inProgress.id, kind: .started, workDate: workDate)
        })

        let result = try await h.service.generateSubmission(reportDate: reportDate, mode: .userRequested,
                                                            useAI: true)

        let payload = try requestedPayload(h)
        XCTAssertEqual(payload.jobType, "submission_weekly")
        XCTAssertTrue(payload.facts.sources.isEmpty)
        XCTAssertEqual(Set(payload.facts.tasks.map(\.id)), Set([completedId, inProgressId]))
        XCTAssertTrue(payload.facts.tasks.allSatisfy { !$0.eventsInRange.isEmpty })
        XCTAssertTrue(payload.facts.tasks.allSatisfy { $0.activitySourceIds.isEmpty })
        let items = payload.submissionDraft.groups.flatMap(\.items)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first { $0.taskIds == [completedId] }?.category, .completed)
        XCTAssertEqual(items.first { $0.taskIds == [inProgressId] }?.category, .inProgress)
        XCTAssertTrue(items.allSatisfy { $0.evidenceIds.isEmpty })
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(try created(result).generator, "codex")
        XCTAssertEqual(h.server.messages(withMethod: "turn/start").count, 1)
    }

    func testStandaloneMemoRemainsContextWithoutCreatingSubmissionSeedItem() async throws {
        let workDate = WorkDate("2026-09-30")!
        let memoBody = "독립 메모: 다음 회의에서 배포 일정 논의"
        var taskId = ""
        var memoId = ""
        let h = try makeHarness(seed: { repo in
            let tasks = TaskService(repo: repo)
            let task = try tasks.createTask(title: "실제 진행 업무", workDate: workDate)
            taskId = task.id
            try tasks.changeTaskStatus(taskId: task.id, kind: .started, workDate: workDate)
            memoId = try tasks.captureMemo(body: memoBody, workDate: workDate).id
        })

        let result = try await h.service.generateSubmission(reportDate: reportDate, mode: .userRequested,
                                                            useAI: true)

        let payload = try requestedPayload(h)
        let memo = try XCTUnwrap(payload.facts.sources.first { $0.id == FactSource.memoId(memoId) })
        XCTAssertEqual(memo.text, memoBody)
        XCTAssertNil(memo.taskId)
        let items = payload.submissionDraft.groups.flatMap(\.items)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.taskIds, [taskId])
        XCTAssertEqual(items.first?.category, .inProgress)
        XCTAssertEqual(items.first?.evidenceIds, [])
        XCTAssertFalse(items.contains { $0.text.contains(memoBody) })
        XCTAssertFalse(result.usedFallback)
        XCTAssertFalse(try created(result).content.contains(memoBody))
    }

    func testNoEligibleTasksSkipsAIAndStoresExplicitNotice() async throws {
        let workDate = WorkDate("2026-09-30")!
        let scenarios = ["memo", "onHoldAndCancelled", "unconfirmedPlan"]
        for scenario in scenarios {
            let h = try makeHarness(seed: { repo in
                let tasks = TaskService(repo: repo)
                switch scenario {
                case "memo":
                    _ = try tasks.captureMemo(body: "업무와 연결하지 않은 일반 메모", workDate: workDate)
                case "onHoldAndCancelled":
                    let held = try tasks.createTask(title: "보류된 업무", workDate: workDate)
                    try tasks.changeTaskStatus(taskId: held.id, kind: .started, workDate: workDate)
                    try tasks.changeTaskStatus(taskId: held.id, kind: .paused, workDate: workDate)
                    let cancelled = try tasks.createTask(title: "취소된 업무", workDate: workDate)
                    try tasks.changeTaskStatus(taskId: cancelled.id, kind: .cancelled, workDate: workDate)
                default:
                    let task = try tasks.createTask(title: "미확정 계획 업무", workDate: workDate)
                    let plans = WeekPlanService(repo: repo, periods: Periods())
                    let candidate = try plans.addItem(weekStart: self.reportDate, taskId: task.id,
                                                       scopeType: .wholeTask, scopeId: nil,
                                                       label: "확정하지 않은 예정")
                    XCTAssertEqual(candidate.state, .candidate)
                }
            })

            let result = try await h.service.generateSubmission(reportDate: reportDate, mode: .userRequested,
                                                                useAI: true)

            XCTAssertTrue(h.server.messages.isEmpty, scenario)
            XCTAssertEqual(try h.repo.db.scalarInt("SELECT COUNT(*) FROM ai_job"), 0, scenario)
            XCTAssertNil(result.aiJobStatus, scenario)
            XCTAssertFalse(result.usedFallback, scenario)
            XCTAssertFalse(result.findings.contains { $0.severity == .error }, scenario)
            let version = try created(result)
            XCTAssertEqual(version.generator, "deterministic", scenario)
            XCTAssertTrue(version.content.isEmpty, scenario)
            XCTAssertTrue(version.warnings.contains {
                $0.contains("완료·진행 업무나 확정 계획이 없습니다")
            }, scenario)
            let draft = try StableJSON.decode(SubmissionDraft.self, from: XCTUnwrap(version.structuredJSON))
            XCTAssertTrue(draft.groups.isEmpty, scenario)
            XCTAssertEqual(version.warnings, draft.warnings, scenario)
            if scenario == "memo" {
                XCTAssertTrue(version.warnings.contains {
                    $0.contains("메모는 제출용 업무로 자동 변환하지 않습니다")
                })
            }
            if scenario == "onHoldAndCancelled" {
                XCTAssertEqual(Set(draft.reviewNotes), Set(["보류: 보류된 업무", "취소: 취소된 업무"]))
            }
            XCTAssertEqual(try h.repo.reportVersion(id: version.id), version, scenario)
        }
    }

    func testEmptyTaskIdentityAndNoticePlaceholderAreStillRejected() async throws {
        for placeholder in [false, true] {
            let h = try makeHarness(output: { validDraft in
                var forged = validDraft
                forged.groups[0].items[0].taskIds = []
                if placeholder {
                    forged.groups[0].items[0].text = "해당 기간에 보고할 업무가 없습니다."
                }
                return try StableJSON.string(forged)
            })

            let result = try await h.service.generateSubmission(reportDate: reportDate, mode: .userRequested,
                                                                useAI: true)

            XCTAssertTrue(result.usedFallback)
            XCTAssertEqual(result.aiJobStatus, .succeeded)
            XCTAssertTrue(result.findings.contains { $0.code == "missing_task" && $0.severity == .error })
            XCTAssertFalse(result.findings.contains { $0.code == "ai_output_invalid" })
            let version = try created(result)
            XCTAssertEqual(version.generator, "deterministic")
            XCTAssertEqual(version.content, SubmissionComposer.render(h.validDraft))
            XCTAssertFalse(version.content.contains("해당 기간에 보고할 업무가 없습니다."))
        }
    }

    func testChangedTaskBindingAndUnrelatedMemoEvidenceFallBack() async throws {
        let workDate = WorkDate("2026-09-30")!
        for expectedCode in ["ai_submission_binding_mismatch", "ai_submission_unrelated_evidence"] {
            var taskIds: [String] = []
            var memoSourceId = ""
            let h = try makeHarness(seed: { repo in
                let tasks = TaskService(repo: repo)
                for title in ["배포 점검", "운영 문서 정리"] {
                    let task = try tasks.createTask(title: title, workDate: workDate)
                    try tasks.changeTaskStatus(taskId: task.id, kind: .started, workDate: workDate)
                    taskIds.append(task.id)
                }
                let memo = try tasks.captureMemo(body: "업무와 연결하지 않은 회의 메모", workDate: workDate)
                memoSourceId = FactSource.memoId(memo.id)
            }, output: { validDraft in
                var forged = validDraft
                if expectedCode == "ai_submission_binding_mismatch" {
                    let otherTask = try XCTUnwrap(taskIds.first {
                        !forged.groups[0].items[0].taskIds.contains($0)
                    })
                    forged.groups[0].items[0].taskIds = [otherTask]
                } else {
                    forged.groups[0].items[0].evidenceIds = [memoSourceId]
                }
                return try StableJSON.string(forged)
            })

            let result = try await h.service.generateSubmission(reportDate: reportDate, mode: .userRequested,
                                                                useAI: true)

            XCTAssertTrue(result.usedFallback, expectedCode)
            XCTAssertEqual(result.aiJobStatus, .succeeded)
            XCTAssertTrue(result.findings.contains { $0.code == expectedCode && $0.severity == .error })
            XCTAssertFalse(result.findings.contains { $0.code == "unknown_task" || $0.code == "unknown_evidence" },
                           "존재하는 ID라도 원래 업무와 연결되지 않으면 거부해야 합니다")
            let version = try created(result)
            XCTAssertEqual(version.generator, "deterministic")
            XCTAssertEqual(version.content, SubmissionComposer.render(h.validDraft))
            let stored = try StableJSON.decode(SubmissionDraft.self, from: XCTUnwrap(version.structuredJSON))
            XCTAssertEqual(stored, h.validDraft)
        }
    }

    func testCodexReviewNotesPreserveHeldAndCancelledTasksWithoutDuplicates() async throws {
        let workDate = WorkDate("2026-09-30")!
        let heldNote = "보류: 보류된 업무"
        let cancelledNote = "취소: 취소된 업무"
        let additionalNote = "추가 확인: 배포 공지 대상"
        let h = try makeHarness(seed: { repo in
            let tasks = TaskService(repo: repo)
            let ongoing = try tasks.createTask(title: "진행 중인 업무", workDate: workDate)
            try tasks.changeTaskStatus(taskId: ongoing.id, kind: .started, workDate: workDate)
            let held = try tasks.createTask(title: "보류된 업무", workDate: workDate)
            try tasks.changeTaskStatus(taskId: held.id, kind: .started, workDate: workDate)
            try tasks.changeTaskStatus(taskId: held.id, kind: .paused, workDate: workDate)
            let cancelled = try tasks.createTask(title: "취소된 업무", workDate: workDate)
            try tasks.changeTaskStatus(taskId: cancelled.id, kind: .cancelled, workDate: workDate)
        }, output: { validDraft in
            var rewritten = validDraft
            rewritten.reviewNotes = [heldNote, heldNote, additionalNote, additionalNote]
            return try StableJSON.string(rewritten)
        })

        let result = try await h.service.generateSubmission(reportDate: reportDate, mode: .userRequested,
                                                            useAI: true)

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.aiJobStatus, .succeeded)
        let payload = try requestedPayload(h)
        XCTAssertEqual(Set(payload.submissionDraft.reviewNotes), Set([heldNote, cancelledNote]))
        let version = try created(result)
        XCTAssertEqual(version.generator, "codex")
        let saved = try XCTUnwrap(try h.repo.reportVersion(id: version.id))
        let draft = try StableJSON.decode(SubmissionDraft.self, from: XCTUnwrap(saved.structuredJSON))
        XCTAssertEqual(draft.reviewNotes.count, 3)
        XCTAssertEqual(Set(draft.reviewNotes), Set([heldNote, cancelledNote, additionalNote]))
        XCTAssertEqual(draft.groups, payload.submissionDraft.groups)
    }

    func testSavedPlainTextExampleUsesStructuredCodexOutputAndPersistsReport() async throws {
        let h = try makeHarness()
        try h.templates.seedDefaults()
        let template = try XCTUnwrap(try h.templates.preferredTemplate(for: .submissionWeekly))
        let style = "팀 양식에 맞춰 짧고 간결한 문장으로 정리한다."
        let example = "우리 팀\n완료 배포 점검\n진행 운영 문서 정리"
        let saved = try h.templates.saveNewVersion(templateId: template.id, instructions: style,
                                                    outputExample: example, skillRef: nil)
        let versionsBefore = try h.templates.versions(templateId: template.id)

        let result = try await h.service.generateSubmission(reportDate: reportDate, mode: .userRequested,
                                                            useAI: true)

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.aiJobStatus, .succeeded)
        XCTAssertFalse(result.findings.contains { $0.severity == .error })
        XCTAssertEqual(result.report.family, .submission)
        let version = try created(result)
        XCTAssertEqual(version.generator, "codex")
        XCTAssertEqual(version.aiModel, "fixture-model")
        XCTAssertEqual(version.templateVersionId, saved.id)
        XCTAssertEqual(version.content, SubmissionComposer.render(h.validDraft))
        let structured = try XCTUnwrap(version.structuredJSON)
        XCTAssertEqual(try StableJSON.decode(SubmissionDraft.self, from: structured), h.validDraft)
        XCTAssertEqual(try h.repo.reportVersion(id: version.id), version)
        XCTAssertEqual(try h.templates.activeVersion(templateId: template.id), saved)
        XCTAssertEqual(try h.templates.versions(templateId: template.id), versionsBefore)

        let thread = try XCTUnwrap(h.server.messages(withMethod: "thread/start").first)
        let instructions = try XCTUnwrap(thread["params"]?["developerInstructions"]?.stringValue)
        XCTAssertTrue(instructions.contains(style))
        XCTAssertTrue(instructions.contains("문체 참고용 출력 예시 (JSON 안의 문장에만 적용):\n" + example))
        let schemaText = try XCTUnwrap(instructions.components(separatedBy: "앱 필수 출력 JSON Schema:\n").last)
        let instructionsSchema = try JSONDecoder().decode(JSONValue.self, from: Data(schemaText.utf8))
        let turn = try XCTUnwrap(h.server.messages(withMethod: "turn/start").first)
        let outputSchema = try XCTUnwrap(turn["params"]?["outputSchema"])
        XCTAssertEqual(outputSchema, instructionsSchema)
        XCTAssertEqual(outputSchema["type"]?.stringValue, "object")
        XCTAssertEqual(Set(outputSchema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []),
                       Set(["schemaVersion", "jobType", "groups", "reviewNotes", "warnings"]))
    }

    func testMalformedProseAndMissingRequiredArraysStillSaveFallback() async throws {
        let invalidOutputs = [
            "우리 팀\n완료 배포 점검\n진행 운영 문서 정리",
            #"{"schemaVersion":1,"jobType":"submission_weekly","groups":[]}"#,
            #"{"schemaVersion":1,"jobType":"submission_weekly","groups":[{"heading":"공통 업무","items":[{"itemId":"line-1","category":"in_progress","text":"문서 정리","taskIds":["task-A"],"projectIds":[]}]}],"reviewNotes":[],"warnings":[]}"#,
        ]
        for output in invalidOutputs {
            let h = try makeHarness(output: { _ in output })
            let result = try await h.service.generateSubmission(reportDate: reportDate, mode: .userRequested,
                                                                useAI: true)

            XCTAssertTrue(result.usedFallback)
            XCTAssertEqual(result.aiJobStatus, .succeeded, "전송 성공과 출력 검증 실패를 구분한다")
            XCTAssertEqual(result.findings.map(\.code), ["ai_output_invalid"])
            let version = try created(result)
            XCTAssertEqual(version.generator, "deterministic")
            XCTAssertEqual(version.content, SubmissionComposer.render(h.validDraft))
            XCTAssertTrue(version.warnings.contains { $0.contains("ai_output_invalid") })
            XCTAssertEqual(try h.repo.reportVersion(id: version.id), version)
        }
    }

    func testUserRegenerationCreatesCodexVersionAndPreservesFallbackInHistory() async throws {
        let h = try makeHarness(output: { _ in "완료 배포 점검" })
        let first = try await h.service.generateSubmission(reportDate: reportDate, mode: .userRequested,
                                                           useAI: true)
        XCTAssertTrue(first.usedFallback)
        let fallback = try created(first)

        scriptOutput(try StableJSON.string(h.validDraft), server: h.server)
        let regenerated = try await h.service.generateSubmission(reportDate: reportDate,
                                                                 mode: .userRequested, useAI: true)

        XCTAssertFalse(regenerated.usedFallback)
        XCTAssertEqual(regenerated.aiJobStatus, .succeeded)
        let version = try created(regenerated)
        XCTAssertEqual(version.generator, "codex")
        XCTAssertEqual(version.reportId, fallback.reportId)
        XCTAssertNotEqual(version.id, fallback.id)
        XCTAssertEqual(version.version, fallback.version + 1)
        var historicalFallback = fallback
        historicalFallback.state = .superseded
        XCTAssertEqual(try h.repo.reportVersion(id: fallback.id), historicalFallback)
        XCTAssertEqual(h.server.messages(withMethod: "turn/start").count, 2)
    }

    func testStructuredOutputStillRejectsInventedCompletionAndEvidence() async throws {
        for expectedCode in ["category_mismatch", "unknown_evidence"] {
            let h = try makeHarness(output: { validDraft in
                var forged = validDraft
                let groupIndex = try XCTUnwrap(forged.groups.firstIndex {
                    $0.items.contains { $0.category == .inProgress }
                })
                let itemIndex = try XCTUnwrap(forged.groups[groupIndex].items.firstIndex {
                    $0.category == .inProgress
                })
                if expectedCode == "category_mismatch" {
                    forged.groups[groupIndex].items[itemIndex].category = .completed
                } else {
                    forged.groups[groupIndex].items[itemIndex].evidenceIds = ["activity:unknown-source"]
                }
                return try StableJSON.string(forged)
            })
            let result = try await h.service.generateSubmission(reportDate: reportDate, mode: .userRequested,
                                                                useAI: true)

            XCTAssertTrue(result.usedFallback)
            XCTAssertEqual(result.aiJobStatus, .succeeded)
            XCTAssertTrue(result.findings.contains { $0.code == expectedCode && $0.severity == .error })
            XCTAssertFalse(result.findings.contains { $0.code == "ai_output_invalid" })
            let version = try created(result)
            XCTAssertEqual(version.generator, "deterministic")
            XCTAssertEqual(version.content, SubmissionComposer.render(h.validDraft))
            XCTAssertEqual(try h.repo.reportVersion(id: version.id), version)
        }
    }
}
