import Foundation
import XCTest
@testable import WorkLogCore

// 메모리 가짜 Codex app-server. 실제 codex 바이너리·~/.codex 인증 파일을 전혀 사용하지 않는다.
// 테스트가 정한 응답·알림을 돌려주고, 클라이언트가 보낸 메시지를 기록한다.
final class FakeCodexServer: LineTransport, @unchecked Sendable {
    struct Script {
        var results: [String: JSONValue] = [:]
        var errors: [String: (code: Int, message: String)] = [:]
        /// 응답 뒤에 이어서 보낼 알림/서버 요청(스크립트 메시지).
        var followups: [String: [JSONValue]] = [:]
    }

    let script = Locked<Script>(Script())

    private let lock = NSLock()
    private var _onLine: (@Sendable (String) -> Void)?
    private var _onClose: (@Sendable (TransportCloseReason) -> Void)?
    private var _messages: [JSONValue] = []
    private var _closed = false

    var messages: [JSONValue] {
        lock.lock(); defer { lock.unlock() }
        return _messages
    }

    var methods: [String] {
        messages.compactMap { $0["method"]?.stringValue }
    }

    func message(withId id: String) -> JSONValue? {
        messages.first { $0["id"]?.stringValue == id }
    }

    func messages(withMethod method: String) -> [JSONValue] {
        messages.filter { $0["method"]?.stringValue == method }
    }

    // MARK: - LineTransport

    func start(onLine: @escaping @Sendable (String) -> Void,
               onClose: @escaping @Sendable (TransportCloseReason) -> Void) throws {
        lock.lock()
        _onLine = onLine
        _onClose = onClose
        lock.unlock()
    }

    func send(line: String) throws {
        guard let data = line.data(using: .utf8),
              let message = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }

        lock.lock()
        _messages.append(message)
        let closed = _closed
        lock.unlock()
        guard !closed else { return }

        guard let method = message["method"]?.stringValue else { return }

        let snapshot = script.value
        var outgoing: [JSONValue] = []
        if let id = message["id"] {
            if let error = snapshot.errors[method] {
                outgoing.append(.object([
                    "id": id,
                    "error": .object([
                        "code": .number(Double(error.code)),
                        "message": .string(error.message),
                    ]),
                ]))
            } else {
                outgoing.append(.object([
                    "id": id,
                    "result": snapshot.results[method] ?? defaultResult(for: method),
                ]))
            }
        }
        if let followups = snapshot.followups[method] {
            outgoing.append(contentsOf: followups)
        }
        for item in outgoing { deliver(item) }
    }

    func close() {
        lock.lock(); _closed = true; lock.unlock()
    }

    func inject(_ line: String) {
        guard let data = line.data(using: .utf8),
              let message = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
        deliver(message)
    }

    func simulateClose(_ reason: TransportCloseReason) {
        lock.lock()
        _closed = true
        let handler = _onClose
        lock.unlock()
        handler?(reason)
    }

    private func deliver(_ message: JSONValue) {
        guard let line = try? message.encodedString() else { return }
        lock.lock()
        let handler = _onLine
        lock.unlock()
        handler?(line)
    }

    private func defaultResult(for method: String) -> JSONValue {
        if method == "initialize" {
            return j(#"{"codexHome":"/tmp/codex","platformFamily":"unix","platformOs":"linux","userAgent":"codex-cli/0.159.2"}"#)
        }
        return .object([:])
    }
}

// JSON 문자열을 JSONValue로. 테스트 픽스처 전용.
private func j(_ string: String) -> JSONValue {
    (try? JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))) ?? .null
}

final class CodexAppServerProviderTests: XCTestCase {

    // MARK: - 헬퍼

    private func makeProvider(server: FakeCodexServer,
                              model: String? = nil,
                              requestTimeout: TimeInterval = 5,
                              turnTimeout: TimeInterval = 5) -> CodexAppServerProvider {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wlog-ai-test-\(UUID().uuidString)", isDirectory: true)
        let config = CodexProviderConfig(executablePath: "/nonexistent/codex",
                                         stagingRoot: root,
                                         model: model,
                                         requestTimeout: requestTimeout,
                                         turnTimeout: turnTimeout)
        return CodexAppServerProvider(config: config, transportFactory: { server })
    }

    private func makeInput(jobId: String = "job-1",
                           type: AIJobType = .submissionWeekly,
                           instructions: String = "지침",
                           payload: String = #"{"facts":[]}"#,
                           skill: SkillRef? = nil) -> AIJobInput {
        AIJobInput(jobId: jobId, jobType: type, instructions: instructions,
                   payloadJSON: payload, skill: skill)
    }

    private func waitUntil(_ condition: @escaping () -> Bool,
                           iterations: Int = 800,
                           file: StaticString = #filePath,
                           line: UInt = #line) async throws {
        for _ in 0..<iterations {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("조건이 시간 안에 충족되지 않음", file: file, line: line)
        throw CancellationError()
    }

    private func capturedError(_ provider: CodexAppServerProvider, _ input: AIJobInput) async -> AIProviderError? {
        do {
            _ = try await provider.run(input)
            return nil
        } catch let error as AIProviderError {
            return error
        } catch {
            return AIProviderError(.unknown, "\(error)")
        }
    }

    private func turnCompleted(threadId: String, turnId: String, status: String, message: String? = nil) -> JSONValue {
        var turn: [String: JSONValue] = [
            "id": .string(turnId),
            "status": .string(status),
            "items": .array([]),
        ]
        if let message {
            turn["error"] = .object(["message": .string(message)])
        }
        return .object([
            "method": .string("turn/completed"),
            "params": .object(["threadId": .string(threadId), "turn": .object(turn)]),
        ])
    }

    private func delta(threadId: String, turnId: String, _ text: String) -> JSONValue {
        .object([
            "method": .string("item/agentMessage/delta"),
            "params": .object([
                "threadId": .string(threadId),
                "turnId": .string(turnId),
                "itemId": .string("item-1"),
                "delta": .string(text),
            ]),
        ])
    }

    private func agentMessageItem(threadId: String, turnId: String, text: String) -> JSONValue {
        .object([
            "method": .string("item/completed"),
            "params": .object([
                "threadId": .string(threadId),
                "turnId": .string(turnId),
                "completedAtMs": .number(0),
                "item": .object([
                    "id": .string("item-1"),
                    "type": .string("agentMessage"),
                    "text": .string(text),
                ]),
            ]),
        ])
    }

    /// 정상 thread/start·turn/start 응답을 준비한다.
    private func scriptSuccessfulTurn(server: FakeCodexServer, threadId: String = "thread-1",
                                      followups: [JSONValue]) {
        server.script.mutate {
            $0.results["thread/start"] = .object([
                "thread": .object(["id": .string(threadId)]),
                "model": .string("gpt-mock"),
            ])
            $0.results["turn/start"] = .object(["turn": .object(["id": .string("turn-1")])])
            $0.followups["turn/start"] = followups
        }
    }

    // MARK: - 1. checkCapabilities (AI-T01)

    func testCheckCapabilitiesWhenExecutableMissing() async {
        let config = CodexProviderConfig(executablePath: nil,
                                         stagingRoot: FileManager.default.temporaryDirectory)
        let provider = CodexAppServerProvider(config: config, transportFactory: {
            throw AIExecutableNotFoundError(path: "codex")
        })
        let capabilities = await provider.checkCapabilities()
        XCTAssertFalse(capabilities.installed)
        XCTAssertFalse(capabilities.protocolCompatible)
    }

    func testCheckCapabilitiesSuccessUsesUserAgent() async {
        let server = FakeCodexServer()
        let provider = makeProvider(server: server)
        let capabilities = await provider.checkCapabilities()
        XCTAssertTrue(capabilities.installed)
        XCTAssertTrue(capabilities.protocolCompatible)
        XCTAssertEqual(capabilities.version, "codex-cli/0.159.2")
        XCTAssertEqual(server.methods.first, "initialize")
        XCTAssertTrue(server.methods.contains("initialized"))
    }

    // MARK: - 2. getAccountStatus

    func testAccountStatusLoggedOut() async throws {
        let server = FakeCodexServer()
        server.script.mutate {
            $0.results["account/read"] = .object(["account": .null, "requiresOpenaiAuth": .bool(true)])
        }
        let provider = makeProvider(server: server)
        let state = try await provider.getAccountStatus()
        XCTAssertEqual(state, .loggedOut)

        let request = try XCTUnwrap(server.messages(withMethod: "account/read").first)
        XCTAssertEqual(request["params"]?["refreshToken"]?.boolValue, false)
    }

    func testAccountStatusLoggedInExtractsSafeFields() async throws {
        let server = FakeCodexServer()
        server.script.mutate {
            $0.results["account/read"] = j(#"{"account":{"type":"chatgpt","email":"a@b.c","planType":"business","accessToken":"SHOULD_NOT_BE_READ"},"requiresOpenaiAuth":false}"#)
        }
        let provider = makeProvider(server: server)
        let state = try await provider.getAccountStatus()
        XCTAssertEqual(state, .loggedIn(accountType: "chatgpt", email: "a@b.c", planType: "business"))
    }

    // MARK: - 3. beginOfficialLogin

    func testBeginOfficialLoginUsesChatgptType() async throws {
        let server = FakeCodexServer()
        server.script.mutate {
            $0.results["account/login/start"] = j(#"{"type":"chatgpt","authUrl":"https://chatgpt.com/auth/xyz","loginId":"login-1"}"#)
        }
        let provider = makeProvider(server: server)
        let url = try await provider.beginOfficialLogin()
        XCTAssertEqual(url?.absoluteString, "https://chatgpt.com/auth/xyz")

        let request = try XCTUnwrap(server.messages(withMethod: "account/login/start").first)
        XCTAssertEqual(request["params"]?["type"]?.stringValue, "chatgpt")
    }

    // MARK: - 4. listAvailableSkills (AI-T04)

    func testListAvailableSkillsParsesAndDoesNotWrite() async throws {
        let server = FakeCodexServer()
        server.script.mutate {
            $0.results["skills/list"] = j(#"{"data":[{"cwd":"/x","errors":[],"skills":[{"name":"weekly","description":"주간보고","enabled":true,"path":"/skills/weekly/SKILL.md","scope":"user"}]}]}"#)
        }
        let provider = makeProvider(server: server)
        let skills = try await provider.listAvailableSkills()
        XCTAssertEqual(skills.count, 1)
        XCTAssertEqual(skills.first?.name, "weekly")
        XCTAssertEqual(skills.first?.description, "주간보고")
        XCTAssertEqual(skills.first?.path, "/skills/weekly/SKILL.md")
        XCTAssertEqual(skills.first?.enabled, true)

        let forbidden = server.methods.contains { $0.contains("skills/config/write") || $0.contains("fs/writeFile") }
        XCTAssertFalse(forbidden, "스킬/파일 쓰기 메서드를 호출하면 안 됨")
    }

    // MARK: - 5. run 성공

    func testRunAccumulatesDeltasAndStripsCodeFence() async throws {
        let server = FakeCodexServer()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wlog-ai-test-\(UUID().uuidString)", isDirectory: true)
        scriptSuccessfulTurn(server: server, followups: [
            delta(threadId: "thread-1", turnId: "turn-1", "```json\n"),
            delta(threadId: "thread-1", turnId: "turn-1", #"{"answer":1}"#),
            delta(threadId: "thread-1", turnId: "turn-1", "\n```"),
            turnCompleted(threadId: "thread-1", turnId: "turn-1", status: "completed"),
        ])
        let config = CodexProviderConfig(stagingRoot: root, model: nil,
                                         requestTimeout: 5, turnTimeout: 5)
        let provider = CodexAppServerProvider(config: config, transportFactory: { server })

        let input = makeInput(jobId: "job-run-1")
        let output = try await provider.run(input)
        XCTAssertEqual(output.rawJSON, #"{"answer":1}"#)
        XCTAssertEqual(output.model, "gpt-mock")
        XCTAssertEqual(output.providerRef, "thread-1")

        let threadRequest = try XCTUnwrap(server.messages(withMethod: "thread/start").first)
        XCTAssertEqual(threadRequest["params"]?["sandbox"]?.stringValue, "read-only")
        XCTAssertEqual(threadRequest["params"]?["approvalPolicy"]?.stringValue, "never")
        XCTAssertEqual(threadRequest["params"]?["ephemeral"]?.boolValue, true)
        XCTAssertEqual(threadRequest["params"]?["developerInstructions"]?.stringValue, "지침")
        let cwd = try XCTUnwrap(threadRequest["params"]?["cwd"]?.stringValue)
        XCTAssertTrue(cwd.hasPrefix(root.path), "cwd는 stagingRoot 하위여야 함")

        let turnRequest = try XCTUnwrap(server.messages(withMethod: "turn/start").first)
        let inputItems = turnRequest["params"]?["input"]?.arrayValue
        XCTAssertEqual(inputItems?.first?["type"]?.stringValue, "text")
        XCTAssertEqual(inputItems?.first?["text"]?.stringValue, #"{"facts":[]}"#)
    }

    func testRunUsesSkillMentionAndCompletedItemTakesPrecedence() async throws {
        let server = FakeCodexServer()
        scriptSuccessfulTurn(server: server, followups: [
            delta(threadId: "thread-1", turnId: "turn-1", "partial"),
            agentMessageItem(threadId: "thread-1", turnId: "turn-1", text: #"{"final":true}"#),
            turnCompleted(threadId: "thread-1", turnId: "turn-1", status: "completed"),
        ])
        let provider = makeProvider(server: server)
        let input = makeInput(skill: SkillRef(name: "weekly-report"))
        let output = try await provider.run(input)
        XCTAssertEqual(output.rawJSON, #"{"final":true}"#)

        let turnRequest = try XCTUnwrap(server.messages(withMethod: "turn/start").first)
        let text = turnRequest["params"]?["input"]?.arrayValue?.first?["text"]?.stringValue
        XCTAssertEqual(text, "$weekly-report\n{\"facts\":[]}")
    }

    // MARK: - 6. 승인 요청 거절 (AI-T08)

    func testRunDeclinesCommandExecutionApproval() async throws {
        let server = FakeCodexServer()
        let approvalRequest = j(#"{"id":"srv-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","command":["rm","-rf","/"]}}"#)
        scriptSuccessfulTurn(server: server, followups: [
            approvalRequest,
            turnCompleted(threadId: "thread-1", turnId: "turn-1", status: "completed"),
        ])
        let provider = makeProvider(server: server)
        _ = try await provider.run(makeInput())

        let reply = try XCTUnwrap(server.message(withId: "srv-1"))
        XCTAssertEqual(reply["result"]?["decision"]?.stringValue, "decline")
    }

    // MARK: - 7. 오류 분류 (AI-T02, AI-T03)

    func testFailedTurnClassifiesErrors() async throws {
        let cases: [(String, AIErrorClass)] = [
            ("usage limit reached", .rateLimited),
            ("unauthorized request", .notLoggedIn),
            ("disabled by policy", .policyRestricted),
            ("token expired", .authExpired),
        ]
        for (message, expected) in cases {
            let server = FakeCodexServer()
            scriptSuccessfulTurn(server: server, followups: [
                turnCompleted(threadId: "thread-1", turnId: "turn-1", status: "failed", message: message),
            ])
            let provider = makeProvider(server: server)
            let error = await capturedError(provider, makeInput())
            XCTAssertEqual(error?.errorClass, expected, "메시지: \(message)")
        }
    }

    // MARK: - 8. 전송 종료 (AI-T06)

    func testTransportCloseFailsRunAndIgnoresMalformedLine() async throws {
        let server = FakeCodexServer()
        scriptSuccessfulTurn(server: server, followups: [])
        let provider = makeProvider(server: server)

        let task = Task { await capturedError(provider, makeInput()) }
        try await waitUntil { server.methods.contains("turn/start") }

        server.inject(#"{"id":1,"res"#) // 끊긴 JSON 줄
        server.simulateClose(.exited(137))

        let error = await task.value
        XCTAssertEqual(error?.errorClass, .network)
    }

    // MARK: - 9. 취소

    func testCancelSendsInterruptAndRunIsCancelled() async throws {
        let server = FakeCodexServer()
        scriptSuccessfulTurn(server: server, followups: [])
        let provider = makeProvider(server: server)

        let task = Task { await capturedError(provider, makeInput(jobId: "job-cancel")) }
        try await waitUntil { server.methods.contains("turn/start") }

        await provider.cancel(jobId: "job-cancel")
        let error = await task.value
        XCTAssertEqual(error?.errorClass, .cancelled)

        let interrupt = try XCTUnwrap(server.messages(withMethod: "turn/interrupt").first)
        XCTAssertEqual(interrupt["params"]?["threadId"]?.stringValue, "thread-1")
        XCTAssertEqual(interrupt["params"]?["turnId"]?.stringValue, "turn-1")
    }

    // MARK: - 오류 분류 단위

    func testErrorClassifierKeywords() {
        XCTAssertEqual(AIErrorClassifier.classify(JSONRPCErrorPayload(code: 401, message: "Unauthorized")), .notLoggedIn)
        XCTAssertEqual(AIErrorClassifier.classify(JSONRPCErrorPayload(code: -1, message: "usage limit")), .rateLimited)
        XCTAssertEqual(AIErrorClassifier.classify(JSONRPCErrorPayload(code: -32601, message: "Method not found")), .protocolMismatch)
        XCTAssertEqual(AIErrorClassifier.classify(JSONRPCErrorPayload(code: -1, message: "not allowed")), .policyRestricted)
        XCTAssertEqual(AIErrorClassifier.classify(JSONRPCClientError.timeout(method: "x")), .timeout)
        XCTAssertEqual(AIErrorClassifier.classify(JSONRPCClientError.cancelled), .cancelled)
        XCTAssertEqual(AIErrorClassifier.classify(JSONRPCClientError.closed(.exited(1))), .network)
        XCTAssertEqual(AIErrorClassifier.classify(AIExecutableNotFoundError(path: "codex")), .notInstalled)
    }

    // MARK: - 10. MockAIProvider

    func testMockProviderReturnsResponsesAndRecordsInputs() async throws {
        let provider = MockAIProvider(responses: [.submissionWeekly: #"{"ok":true}"#])
        let input = makeInput()
        let output = try await provider.run(input)
        XCTAssertEqual(output.rawJSON, #"{"ok":true}"#)
        XCTAssertEqual(provider.runCount, 1)
        XCTAssertEqual(provider.receivedInputs.count, 1)
        XCTAssertEqual(provider.receivedInputs.first, input)

        provider.failure = AIProviderError(.rateLimited, "한도")
        do {
            _ = try await provider.run(input)
            XCTFail("failure 설정 시 throw 되어야 함")
        } catch let error as AIProviderError {
            XCTAssertEqual(error.errorClass, .rateLimited)
        }
        XCTAssertEqual(provider.runCount, 2)

        provider.skills = [DiscoveredSkill(name: "weekly", description: nil, path: nil, enabled: true)]
        let skills = try await provider.listAvailableSkills()
        XCTAssertEqual(skills.map(\.name), ["weekly"])

        let state = try await provider.getAccountStatus()
        XCTAssertEqual(state, .loggedIn(accountType: "mock", email: nil, planType: nil))

        await provider.cancel(jobId: "job-1")
        XCTAssertEqual(provider.cancelledJobIds, ["job-1"])
    }
}
