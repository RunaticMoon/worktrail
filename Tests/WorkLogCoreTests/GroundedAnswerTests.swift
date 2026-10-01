import Foundation
import XCTest
@testable import WorkLogCore

// GroundedAnswerService: 명시적 실행 기록 기반 AI 답변(SEARCH-02 / P-07).
// 실제 codex 실행·네트워크·vault는 없다. provider는 MockAIProvider만 사용한다.
final class GroundedAnswerTests: XCTestCase {

    private let monday = WorkDate("2026-10-05")!
    private let tuesday = WorkDate("2026-10-06")!
    private let wednesday = WorkDate("2026-10-07")!
    private let baseDate = Date(timeIntervalSince1970: 1_790_000_000)

    private struct Harness {
        let repo: WorkRepository
        let index: SearchIndex
        let templates: TemplateStore
        let provider: MockAIProvider
        let service: GroundedAnswerService
    }

    private struct DecodedPayload: Decodable {
        struct Source: Decodable {
            var id: String
            var sourceType: String
            var workDate: String?
            var text: String
        }
        var jobType: String
        var question: String
        var sources: [Source]
    }

    private func makeHarness(maxEvidence: Int = 20,
                             responses: [AIJobType: String] = [:]) throws -> Harness {
        let repo = try WorkRepository.inMemory(clock: FixedClock(baseDate), ids: SequentialIDGenerator())
        let index = try SearchIndex(repo: repo)
        let templates = TemplateStore(repo: repo)
        let provider = MockAIProvider(responses: responses)
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wlog-grounded-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let runner = AIJobRunner(repo: repo, provider: provider, stagingRoot: stagingRoot)
        let service = GroundedAnswerService(index: index, runner: runner, templates: templates,
                                            maxEvidence: maxEvidence)
        return Harness(repo: repo, index: index, templates: templates, provider: provider, service: service)
    }

    /// P-07 계약과 같은 JSON 문자열을 만든다.
    private func json(_ paragraphs: [(text: String, ids: [String])],
                      missing: [String] = [], warnings: [String] = [],
                      jobType: String = "grounded_answer", schemaVersion: Int = 1) -> String {
        let output = GroundedAnswerOutput(
            schemaVersion: schemaVersion, jobType: jobType,
            paragraphs: paragraphs.map { GroundedAnswerOutput.Paragraph(text: $0.text, evidenceIds: $0.ids) },
            missingEvidence: missing, warnings: warnings)
        return (try? StableJSON.string(output)) ?? "{}"
    }

    // MARK: 1 — 관련 기록 수집, AI 1회 호출, evidence 변환

    func testCollectsEvidenceAndCallsAIOnce() async throws {
        let harness = try makeHarness(responses: [.groundedAnswer: json([
            (text: "배포 스크립트 작업을 진행했습니다.", ids: ["memo:memo-1", "activity:act-1"])
        ])])
        try harness.repo.insertMemo(Memo(id: "memo-1", body: "배포 스크립트 개선",
                                         workDate: monday, recordedAt: baseDate))
        try harness.repo.insertTask(WorkTask(id: "task-1", title: "릴리스 준비", createdAt: baseDate))
        try harness.repo.insertActivity(Activity(id: "act-1", taskId: "task-1", body: "배포 자동화 적용",
                                                 workDate: monday, recordedAt: baseDate))

        let answer = try await harness.service.answer(question: "배포", scope: GroundedAnswerScope())

        XCTAssertEqual(harness.provider.runCount, 1)
        XCTAssertEqual(answer.jobStatus, .succeeded)
        XCTAssertEqual(answer.paragraphs.count, 1)
        XCTAssertEqual(answer.paragraphs.first?.evidence.map(\.id), ["memo:memo-1", "activity:act-1"])
        XCTAssertEqual(answer.paragraphs.first?.evidence.first?.id, "memo:memo-1")
        XCTAssertEqual(answer.paragraphs.first?.evidence.first?.sourceType, .memo)
        XCTAssertEqual(answer.paragraphs.first?.evidence.first?.sourceId, "memo-1")
        XCTAssertEqual(Set(answer.evidencePool.map(\.id)), ["memo:memo-1", "activity:act-1"])

        let input = try XCTUnwrap(harness.provider.receivedInputs.first)
        XCTAssertEqual(input.jobType, .groundedAnswer)
        XCTAssertFalse(input.instructions.contains("{{question}}"))
        XCTAssertTrue(input.instructions.contains("배포"))

        let payload = try StableJSON.decode(DecodedPayload.self, from: input.payloadJSON)
        XCTAssertEqual(payload.jobType, "grounded_answer")
        XCTAssertEqual(payload.question, "배포")
        XCTAssertEqual(Set(payload.sources.map(\.id)), ["memo:memo-1", "activity:act-1"])
        XCTAssertTrue(payload.sources.allSatisfy { !$0.text.isEmpty })
    }

    // MARK: 2 — 근거 없음 → AI 호출 0회

    func testNoEvidenceSkipsAI() async throws {
        let harness = try makeHarness(responses: [.groundedAnswer: json([])])

        let answer = try await harness.service.answer(question: "존재하지않는검색어입니다",
                                                      scope: GroundedAnswerScope())

        XCTAssertEqual(harness.provider.runCount, 0)
        XCTAssertNil(answer.jobStatus)
        XCTAssertTrue(answer.paragraphs.isEmpty)
        XCTAssertEqual(answer.missingEvidence, [GroundedAnswerService.missingEvidenceMessage])
        XCTAssertTrue(answer.evidencePool.isEmpty)
    }

    // MARK: 3 — scope range·types 필터

    func testScopeRangeAndTypeFilters() async throws {
        let harness = try makeHarness()
        try harness.repo.insertMemo(Memo(id: "memo-old", body: "범위테스트 이전 기록",
                                         workDate: monday, recordedAt: baseDate))
        try harness.repo.insertMemo(Memo(id: "memo-new", body: "범위테스트 이후 기록",
                                         workDate: tuesday, recordedAt: baseDate))
        try harness.repo.insertTask(WorkTask(id: "task-1", title: "범위테스트 태스크", createdAt: baseDate))

        let rangeOnly = try harness.service.collectEvidence(
            question: "범위테스트",
            scope: GroundedAnswerScope(range: DateRange(start: tuesday, endExclusive: wednesday)))
        XCTAssertEqual(Set(rangeOnly.map(\.sourceId)), ["memo-new"])

        let typeOnly = try harness.service.collectEvidence(
            question: "범위테스트",
            scope: GroundedAnswerScope(types: [.task]))
        XCTAssertEqual(Set(typeOnly.map(\.sourceId)), ["task-1"])
    }

    // MARK: 4 — 알 수 없는 evidenceId 제거 + warning

    func testUnknownEvidenceIdsRemovedWithWarning() async throws {
        let harness = try makeHarness(responses: [.groundedAnswer: json([
            (text: "근거 기반 문장", ids: ["memo:memo-1", "memo:ghost"])
        ])])
        try harness.repo.insertMemo(Memo(id: "memo-1", body: "근거테스트 본문",
                                         workDate: monday, recordedAt: baseDate))

        let answer = try await harness.service.answer(question: "근거테스트", scope: GroundedAnswerScope())

        XCTAssertEqual(answer.paragraphs.first?.evidence.map(\.id), ["memo:memo-1"])
        XCTAssertTrue(answer.warnings.contains("알 수 없는 근거 제거: memo:ghost"))
    }

    // MARK: 5 — HTML 태그 제거, 근거에 없는 URL 치환, 근거에 있는 URL 유지

    func testHTMLRemovedAndUngroundedURLReplaced() async throws {
        let known = "https://known.example.com/docs"
        let unknown = "https://unknown.example.com/page"
        let harness = try makeHarness(responses: [.groundedAnswer: json([
            (text: "<b>링크테스트</b> 확인: \(known) 와 \(unknown)", ids: ["memo:memo-1"])
        ])])
        try harness.repo.insertMemo(Memo(id: "memo-1", body: "링크테스트 참고 \(known)",
                                         workDate: monday, recordedAt: baseDate))

        let answer = try await harness.service.answer(question: "링크테스트", scope: GroundedAnswerScope())
        let text = try XCTUnwrap(answer.paragraphs.first?.text)

        XCTAssertFalse(text.contains("<b>"))
        XCTAssertFalse(text.contains("</b>"))
        XCTAssertTrue(text.contains(known))
        XCTAssertFalse(text.contains(unknown))
        XCTAssertTrue(text.contains("[확인되지 않은 링크 제거]"))
        XCTAssertTrue(answer.warnings.contains { $0.contains("HTML") })
        XCTAssertTrue(answer.warnings.contains { $0.contains(unknown) })
    }

    // MARK: 6 — 형식 오류·jobType 불일치·schemaVersion 불일치·AI 실패 → 빈 문단, 예외 없음

    func testInvalidOutputsYieldEmptyParagraphsWithoutThrowing() async throws {
        // (a) JSON 파싱 실패
        do {
            let harness = try makeHarness(responses: [.groundedAnswer: "not json"])
            try harness.repo.insertMemo(Memo(id: "memo-1", body: "형식테스트 본문",
                                             workDate: monday, recordedAt: baseDate))
            let answer = try await harness.service.answer(question: "형식테스트", scope: GroundedAnswerScope())
            XCTAssertEqual(answer.jobStatus, .succeeded)
            XCTAssertTrue(answer.paragraphs.isEmpty)
            XCTAssertEqual(answer.warnings, [GroundedAnswerService.formatErrorMessage])
        }

        // (b) jobType 불일치
        do {
            let harness = try makeHarness(responses: [.groundedAnswer: json(
                [(text: "문단", ids: ["memo:memo-1"])], jobType: "performance_report")])
            try harness.repo.insertMemo(Memo(id: "memo-1", body: "형식테스트 본문",
                                             workDate: monday, recordedAt: baseDate))
            let answer = try await harness.service.answer(question: "형식테스트", scope: GroundedAnswerScope())
            XCTAssertTrue(answer.paragraphs.isEmpty)
            XCTAssertTrue(answer.warnings.contains(GroundedAnswerService.formatErrorMessage))
        }

        // (c) schemaVersion 불일치
        do {
            let harness = try makeHarness(responses: [.groundedAnswer: json(
                [(text: "문단", ids: ["memo:memo-1"])], schemaVersion: 2)])
            try harness.repo.insertMemo(Memo(id: "memo-1", body: "형식테스트 본문",
                                             workDate: monday, recordedAt: baseDate))
            let answer = try await harness.service.answer(question: "형식테스트", scope: GroundedAnswerScope())
            XCTAssertTrue(answer.paragraphs.isEmpty)
            XCTAssertTrue(answer.warnings.contains(GroundedAnswerService.formatErrorMessage))
        }

        // (d) provider 실패(.network)
        do {
            let harness = try makeHarness(responses: [.groundedAnswer: json(
                [(text: "문단", ids: ["memo:memo-1"])])])
            try harness.repo.insertMemo(Memo(id: "memo-1", body: "형식테스트 본문",
                                             workDate: monday, recordedAt: baseDate))
            harness.provider.failure = AIProviderError(.network, "down")
            let answer = try await harness.service.answer(question: "형식테스트", scope: GroundedAnswerScope())
            XCTAssertEqual(answer.jobStatus, .failed)
            XCTAssertTrue(answer.paragraphs.isEmpty)
            XCTAssertFalse(answer.evidencePool.isEmpty)
        }
    }

    // MARK: 7 — 빈 질문·500자 초과 질문 → validation

    func testQuestionValidation() async throws {
        let harness = try makeHarness()

        XCTAssertThrowsError(try harness.service.collectEvidence(question: "   ",
                                                                 scope: GroundedAnswerScope())) { error in
            XCTAssertEqual(error as? WorkLogError, .validation("질문이 비어 있습니다."))
        }

        let long = String(repeating: "가", count: 501)
        XCTAssertThrowsError(try harness.service.collectEvidence(question: long,
                                                                 scope: GroundedAnswerScope())) { error in
            guard let wl = error as? WorkLogError, case .validation = wl else {
                return XCTFail("validation이 아님: \(error)")
            }
        }

        do {
            _ = try await harness.service.answer(question: "", scope: GroundedAnswerScope())
            XCTFail("빈 질문은 validation이어야 한다")
        } catch let error as WorkLogError {
            guard case .validation = error else { return XCTFail("validation이 아님: \(error)") }
        }
    }

    // MARK: 8 — 지시문 {{question}} 치환, payload에 vault/secret 없음

    func testInstructionsAndPayloadExcludePlaceholderAndSecretWords() async throws {
        let harness = try makeHarness(responses: [.groundedAnswer: json([
            (text: "지침테스트 답변", ids: ["memo:memo-1"])
        ])])
        try harness.repo.insertMemo(Memo(id: "memo-1", body: "지침테스트 본문",
                                         workDate: monday, recordedAt: baseDate))
        _ = try await harness.service.answer(question: "지침테스트", scope: GroundedAnswerScope())

        let input = try XCTUnwrap(harness.provider.receivedInputs.first)
        XCTAssertFalse(input.instructions.contains("{{question}}"))
        XCTAssertTrue(input.instructions.contains("지침테스트"))

        let lowered = input.payloadJSON.lowercased()
        XCTAssertFalse(lowered.contains("vault"))
        XCTAssertFalse(lowered.contains("secret"))

        let pool = try harness.service.collectEvidence(question: "지침테스트", scope: GroundedAnswerScope())
        let payload = try harness.service.buildPayload(question: "지침테스트", evidence: pool)
        XCTAssertFalse(payload.lowercased().contains("vault"))
        XCTAssertFalse(payload.lowercased().contains("secret"))
    }

    // MARK: 9 — maxEvidence 제한

    func testMaxEvidenceLimit() async throws {
        let harness = try makeHarness(maxEvidence: 3)
        for index in 1...5 {
            try harness.repo.insertMemo(Memo(id: "memo-\(index)", body: "한도테스트 기록 \(index)",
                                             workDate: monday, recordedAt: baseDate))
        }

        let refs = try harness.service.collectEvidence(question: "한도테스트", scope: GroundedAnswerScope())
        XCTAssertEqual(refs.count, 3)
    }
}
