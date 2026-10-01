import Foundation
import XCTest
@testable import WorkLogCore

// MemoLinkSuggestionService: MEM-02 Memo ↔ Task 연결 제안·승인.
// 실제 codex 실행·네트워크는 없다. provider는 MockAIProvider만 사용한다.
final class MemoLinkSuggestionTests: XCTestCase {

    private let baseDate = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - Helpers

    private func makeRepo(clock: FixedClock) throws -> WorkRepository {
        try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator())
    }

    private func makeTempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wlog-memolink-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeService(repo: WorkRepository, mock: MockAIProvider,
                             maxCandidates: Int = 30) -> MemoLinkSuggestionService {
        let runner = AIJobRunner(repo: repo, provider: mock, stagingRoot: makeTempRoot())
        return MemoLinkSuggestionService(repo: repo, runner: runner,
                                         templates: TemplateStore(repo: repo),
                                         maxCandidates: maxCandidates)
    }

    private func outputJSON(_ suggestions: [MemoTaskSuggestionOutput.Suggestion],
                            jobType: String = "memo_task_suggestions",
                            schemaVersion: Int = 1) throws -> String {
        try StableJSON.string(MemoTaskSuggestionOutput(schemaVersion: schemaVersion,
                                                        jobType: jobType,
                                                        suggestions: suggestions))
    }

    private func suggestion(memoId: String, taskId: String, reason: String,
                            evidenceIds: [String]) -> MemoTaskSuggestionOutput.Suggestion {
        MemoTaskSuggestionOutput.Suggestion(memoId: memoId, taskId: taskId,
                                             reason: reason, evidenceIds: evidenceIds)
    }

    private func payloadObject(_ json: String) throws -> [String: Any] {
        let data = Data(json.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XCTSkip("payload가 JSON 객체가 아님")
        }
        return object
    }

    // MARK: 1. 정상 제안 1건 → proposed 저장

    func testSuggestStoresSingleProposedLink() async throws {
        let clock = FixedClock(baseDate)
        let repo = try makeRepo(clock: clock)
        let taskService = TaskService(repo: repo)
        let task = try taskService.createTask(title: "로그인 API 수정")
        let activity = try taskService.addActivity(taskId: task.id, body: "토큰 만료 처리 추가",
                                                   workDate: WorkDate("2026-09-30"))
        let memo = try taskService.captureMemo(body: "로그인 실패 원인은 토큰 만료였다",
                                               workDate: WorkDate("2026-10-01"))

        let mock = MockAIProvider(responses: [.memoTaskSuggestions: try outputJSON([
            suggestion(memoId: memo.id, taskId: task.id, reason: "로그인 장애 배경 설명에 해당",
                       evidenceIds: ["memo:\(memo.id)", "activity:\(activity.id)"])
        ])])
        let service = makeService(repo: repo, mock: mock)

        let result = try await service.suggest(memoId: memo.id)

        XCTAssertEqual(result.jobStatus, .succeeded)
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
        XCTAssertEqual(result.links.count, 1)
        let link = try XCTUnwrap(result.links.first)
        XCTAssertEqual(link.memoId, memo.id)
        XCTAssertEqual(link.taskId, task.id)
        XCTAssertEqual(link.status, .proposed)
        XCTAssertEqual(link.reason, "로그인 장애 배경 설명에 해당")
        XCTAssertEqual(link.sourceRevision, memo.revision)
        XCTAssertNil(link.decidedAt)

        let stored = try repo.memoTaskLinks(memoId: memo.id)
        XCTAssertEqual(stored.map(\.id), [link.id])

        // Mock이 받은 지시문은 P-00 공통 문장으로 시작하고 payload에 Memo 본문이 있다.
        let input = try XCTUnwrap(mock.receivedInputs.first)
        XCTAssertTrue(input.instructions.hasPrefix(DefaultPrompts.commonInstructions))
        XCTAssertTrue(input.payloadJSON.contains(memo.body))
        XCTAssertEqual(input.jobType, .memoTaskSuggestions)
    }

    // MARK: 2. 검증 탈락 → warning

    func testInvalidSuggestionsAreRejectedWithWarnings() async throws {
        let clock = FixedClock(baseDate)
        let repo = try makeRepo(clock: clock)
        let taskService = TaskService(repo: repo)
        let taskA = try taskService.createTask(title: "Task A")
        let taskB = try taskService.createTask(title: "Task B")
        let memo = try taskService.captureMemo(body: "메모 본문")

        let mock = MockAIProvider(responses: [.memoTaskSuggestions: try outputJSON([
            suggestion(memoId: memo.id, taskId: "ghost-task", reason: "후보 아님",
                       evidenceIds: ["memo:\(memo.id)"]),
            suggestion(memoId: "other-memo", taskId: taskA.id, reason: "다른 메모",
                       evidenceIds: ["memo:\(memo.id)"]),
            suggestion(memoId: memo.id, taskId: taskA.id, reason: "   ",
                       evidenceIds: ["memo:\(memo.id)"]),
            suggestion(memoId: memo.id, taskId: taskB.id, reason: "근거 없음",
                       evidenceIds: ["activity:does-not-exist"])
        ])])
        let service = makeService(repo: repo, mock: mock)

        let result = try await service.suggest(memoId: memo.id)

        XCTAssertTrue(result.links.isEmpty)
        XCTAssertEqual(result.warnings.count, 4, "\(result.warnings)")
        XCTAssertTrue(try repo.memoTaskLinks(memoId: memo.id).isEmpty)
    }

    // MARK: 3. 파싱 실패·계약 불일치

    func testMalformedOutputStoresNothing() async throws {
        let clock = FixedClock(baseDate)
        let repo = try makeRepo(clock: clock)
        let taskService = TaskService(repo: repo)
        let memo = try taskService.captureMemo(body: "메모")

        let mock = MockAIProvider(responses: [.memoTaskSuggestions: "이건 JSON이 아님"])
        let service = makeService(repo: repo, mock: mock)

        let result = try await service.suggest(memoId: memo.id)

        XCTAssertEqual(result.jobStatus, .succeeded)
        XCTAssertTrue(result.links.isEmpty)
        XCTAssertEqual(result.warnings, ["AI 결과 형식 오류"])
        XCTAssertTrue(try repo.memoTaskLinks(memoId: memo.id).isEmpty)
    }

    func testJobTypeMismatchIsIgnoredEntirely() async throws {
        let clock = FixedClock(baseDate)
        let repo = try makeRepo(clock: clock)
        let taskService = TaskService(repo: repo)
        let task = try taskService.createTask(title: "Task")
        let memo = try taskService.captureMemo(body: "메모")

        let mock = MockAIProvider(responses: [.memoTaskSuggestions: try outputJSON([
            suggestion(memoId: memo.id, taskId: task.id, reason: "정상",
                       evidenceIds: ["memo:\(memo.id)"])
        ], jobType: "performance_report")])
        let service = makeService(repo: repo, mock: mock)

        let result = try await service.suggest(memoId: memo.id)

        XCTAssertTrue(result.links.isEmpty)
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertTrue(try repo.memoTaskLinks(memoId: memo.id).isEmpty)
    }

    // MARK: 4. AI 실패 → 상태 전달, 저장 없음, 예외 없음

    func testAIFailureReturnsStatusWithoutStoring() async throws {
        let clock = FixedClock(baseDate)
        let repo = try makeRepo(clock: clock)
        let taskService = TaskService(repo: repo)
        let memo = try taskService.captureMemo(body: "메모")

        let mock = MockAIProvider(responses: [.memoTaskSuggestions: "{}"])
        mock.failure = AIProviderError(.notLoggedIn, "로그인 필요")
        let service = makeService(repo: repo, mock: mock)

        let result = try await service.suggest(memoId: memo.id)

        XCTAssertEqual(result.jobStatus, .blockedAuth)
        XCTAssertTrue(result.links.isEmpty)
        XCTAssertTrue(try repo.memoTaskLinks(memoId: memo.id).isEmpty)
    }

    // MARK: 5. accepted 이후 같은 제안 → 새 링크 없음

    func testAcceptedLinkIsNotSuggestedAgain() async throws {
        let clock = FixedClock(baseDate)
        let repo = try makeRepo(clock: clock)
        let taskService = TaskService(repo: repo)
        let task = try taskService.createTask(title: "Task")
        let memo = try taskService.captureMemo(body: "메모")

        let mock = MockAIProvider(responses: [.memoTaskSuggestions: try outputJSON([
            suggestion(memoId: memo.id, taskId: task.id, reason: "연결 사유",
                       evidenceIds: ["memo:\(memo.id)"])
        ])])
        let service = makeService(repo: repo, mock: mock)

        let first = try await service.suggest(memoId: memo.id)
        let link = try XCTUnwrap(first.links.first)
        _ = try service.decide(linkId: link.id, status: .accepted)

        let second = try await service.suggest(memoId: memo.id)

        XCTAssertTrue(second.links.isEmpty)
        XCTAssertEqual(try repo.memoTaskLinks(memoId: memo.id).count, 1)
        XCTAssertEqual(try repo.memoTaskLinks(memoId: memo.id).first?.status, .accepted)
    }

    // MARK: 6. rejected 재제안 규칙

    func testRejectedLinkIsNotResuggestedUntilRevisionChanges() async throws {
        let clock = FixedClock(baseDate)
        let repo = try makeRepo(clock: clock)
        let taskService = TaskService(repo: repo)
        let task = try taskService.createTask(title: "Task")
        let memo = try taskService.captureMemo(body: "처음 본문")

        let mock = MockAIProvider(responses: [.memoTaskSuggestions: try outputJSON([
            suggestion(memoId: memo.id, taskId: task.id, reason: "연결 사유",
                       evidenceIds: ["memo:\(memo.id)"])
        ])])
        let service = makeService(repo: repo, mock: mock)

        let first = try await service.suggest(memoId: memo.id)
        let link = try XCTUnwrap(first.links.first)
        _ = try service.decide(linkId: link.id, status: .rejected)

        // 같은 revision → 재제안 없음
        let sameRevision = try await service.suggest(memoId: memo.id)
        XCTAssertTrue(sameRevision.links.isEmpty)
        XCTAssertEqual(try repo.memoTaskLinks(memoId: memo.id).count, 1)

        // 본문 수정으로 revision 증가 → 새 proposed
        let updated = try repo.updateMemoBody(id: memo.id, body: "수정된 본문", workDate: memo.workDate)
        XCTAssertEqual(updated.revision, memo.revision + 1)

        let afterRevision = try await service.suggest(memoId: memo.id)
        XCTAssertEqual(afterRevision.links.count, 1)
        XCTAssertEqual(afterRevision.links.first?.sourceRevision, updated.revision)
        XCTAssertEqual(try repo.memoTaskLinks(memoId: memo.id).count, 2)
    }

    // MARK: 7. decide(accepted)는 Task·Memo를 건드리지 않는다

    func testDecideDoesNotChangeTaskOrMemo() async throws {
        let clock = FixedClock(baseDate)
        let repo = try makeRepo(clock: clock)
        let taskService = TaskService(repo: repo)
        let task = try taskService.createTask(title: "Task")
        try taskService.changeTaskStatus(taskId: task.id, kind: .started)
        let memo = try taskService.captureMemo(body: "메모 본문")

        let mock = MockAIProvider(responses: [.memoTaskSuggestions: try outputJSON([
            suggestion(memoId: memo.id, taskId: task.id, reason: "연결 사유",
                       evidenceIds: ["memo:\(memo.id)"])
        ])])
        let service = makeService(repo: repo, mock: mock)

        let first = try await service.suggest(memoId: memo.id)
        let link = try XCTUnwrap(first.links.first)

        let tasksBefore = try repo.tasks()
        let statusBefore = try taskService.currentStatus(taskId: task.id)
        let memoBefore = try XCTUnwrap(try repo.memo(id: memo.id))

        clock.advance(by: 60)
        let decided = try service.decide(linkId: link.id, status: .accepted)

        XCTAssertEqual(decided.status, .accepted)
        XCTAssertEqual(decided.decidedAt, clock.now())
        XCTAssertEqual(try repo.tasks().count, tasksBefore.count)
        XCTAssertEqual(try taskService.currentStatus(taskId: task.id), statusBefore)
        XCTAssertEqual(try XCTUnwrap(repo.memo(id: memo.id)).body, memoBefore.body)
        XCTAssertEqual(try XCTUnwrap(repo.memo(id: memo.id)).revision, memoBefore.revision)
    }

    // MARK: 8. 취소 Task 제외, maxCandidates 적용

    func testCancelledTasksExcludedAndMaxCandidatesApplied() async throws {
        let clock = FixedClock(baseDate)
        let repo = try makeRepo(clock: clock)
        let taskService = TaskService(repo: repo)
        let task1 = try taskService.createTask(title: "Task 1")
        let task2 = try taskService.createTask(title: "Task 2")
        _ = try taskService.createTask(title: "Task 3")
        let cancelled = try taskService.createTask(title: "Task C")
        try taskService.changeTaskStatus(taskId: cancelled.id, kind: .cancelled)
        let memo = try taskService.captureMemo(body: "메모")

        let mock = MockAIProvider()
        let service = makeService(repo: repo, mock: mock, maxCandidates: 2)

        let payload = try service.buildPayload(memoId: memo.id)
        let object = try payloadObject(payload)
        let candidateTasks = try XCTUnwrap(object["candidateTasks"] as? [[String: Any]])
        let ids = candidateTasks.compactMap { $0["id"] as? String }

        XCTAssertEqual(ids.count, 2)
        XCTAssertFalse(ids.contains(cancelled.id))
        XCTAssertEqual(Set(ids), Set([task1.id, task2.id]))
    }

    // MARK: 9. payload 결정성·금지 문자열

    func testBuildPayloadIsDeterministicAndFreeOfSecretTerms() throws {
        let clock = FixedClock(baseDate)
        let repo = try makeRepo(clock: clock)
        let taskService = TaskService(repo: repo)
        let task = try taskService.createTask(title: "Task")
        _ = try taskService.addActivity(taskId: task.id, body: "활동 기록", workDate: WorkDate("2026-09-29"))
        let memo = try taskService.captureMemo(body: "메모 본문")

        let mock = MockAIProvider()
        let service = makeService(repo: repo, mock: mock)

        let first = try service.buildPayload(memoId: memo.id)
        let second = try service.buildPayload(memoId: memo.id)
        XCTAssertEqual(first, second)

        let lower = first.lowercased()
        XCTAssertFalse(lower.contains("vault"))
        XCTAssertFalse(lower.contains("secret"))
    }
}
