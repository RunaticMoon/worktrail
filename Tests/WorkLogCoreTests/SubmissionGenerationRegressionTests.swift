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
        output: ((SubmissionDraft) throws -> String)? = nil
    ) throws -> Harness {
        let fixture = try FixtureLoader.load()
        let now = try XCTUnwrap(fixture.clock?.now.flatMap(FixtureLoader.date))
        let repo = try WorkRepository.inMemory(clock: FixedClock(now), ids: SequentialIDGenerator())
        try FixtureSeeder.seed(repo, fixture: fixture)
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
            let h = try makeHarness { validDraft in
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
            }
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
