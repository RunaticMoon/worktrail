import Foundation
import XCTest
@testable import WorkLogCore

// 메모리 가짜 Codex app-server. 실제 codex 바이너리·~/.codex 인증 파일을 전혀 사용하지 않는다.
// 테스트가 정한 응답·알림을 돌려주고, 클라이언트가 보낸 메시지를 기록한다.
final class FakeCodexServer: LineTransport, @unchecked Sendable {
    struct Script {
        var results: [String: JSONValue] = [:]
        var modelPages: [String: JSONValue] = [:]
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
                    "result": (method == "model/list"
                        ? snapshot.modelPages[message["params"]?["cursor"]?.stringValue ?? ""] : nil)
                        ?? snapshot.results[method] ?? defaultResult(for: method),
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
            return j(#"{"codexHome":"/tmp/codex","platformFamily":"unix","platformOs":"linux","userAgent":"codex-cli/0.163.0"}"#)
        }
        if method == "config/read" { return .object(["config": .object([:])]) }
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
        XCTAssertEqual(capabilities.version, "codex-cli/0.163.0")
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
        XCTAssertEqual(threadRequest["params"]?["environments"]?.arrayValue, [])
        XCTAssertEqual(threadRequest["params"]?["developerInstructions"]?.stringValue, "지침")
        let cwd = try XCTUnwrap(threadRequest["params"]?["cwd"]?.stringValue)
        XCTAssertTrue(cwd.hasPrefix(root.path), "cwd는 stagingRoot 하위여야 함")

        let turnRequest = try XCTUnwrap(server.messages(withMethod: "turn/start").first)
        let inputItems = turnRequest["params"]?["input"]?.arrayValue
        XCTAssertEqual(inputItems?.first?["type"]?.stringValue, "text")
        XCTAssertEqual(inputItems?.first?["text"]?.stringValue, #"{"facts":[]}"#)
    }

    func testRunAppendsVerifiedSkillAndCompletedItemTakesPrecedence() async throws {
        let server = FakeCodexServer()
        scriptSuccessfulTurn(server: server, followups: [
            delta(threadId: "thread-1", turnId: "turn-1", "partial"),
            agentMessageItem(threadId: "thread-1", turnId: "turn-1", text: #"{"final":true}"#),
            turnCompleted(threadId: "thread-1", turnId: "turn-1", status: "completed"),
        ])
        let provider = makeProvider(server: server)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("worklog-skill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let skillURL = root.appendingPathComponent("SKILL.md")
        try Data("Use concise fixture sentences.".utf8).write(to: skillURL)
        let skill = try XCTUnwrap(SkillBindingResolver.resolve(skillURL.path))
        let input = makeInput(skill: skill)
        let output = try await provider.run(input)
        XCTAssertEqual(output.rawJSON, #"{"final":true}"#)

        let turnRequest = try XCTUnwrap(server.messages(withMethod: "turn/start").first)
        let text = turnRequest["params"]?["input"]?.arrayValue?.first?["text"]?.stringValue
        XCTAssertEqual(text, "{\"facts\":[]}")
        let instructions = server.messages(withMethod: "thread/start").first?["params"]?["developerInstructions"]?.stringValue
        XCTAssertTrue(instructions?.contains("Use concise fixture sentences.") == true)
    }

    func testCLIArgumentsDisableFileAndExternalTools() {
        let arguments = CodexAppServerProvider.processArguments
        XCTAssertTrue(arguments.contains("features.shell_tool=false"))
        XCTAssertTrue(arguments.contains("features.apps=false"))
        XCTAssertTrue(arguments.contains("features.plugins=false"))
        XCTAssertTrue(arguments.contains("features.skip_host_skill_discovery=true"))
        XCTAssertTrue(arguments.contains("features.stable_environment_tools=false"))
        XCTAssertTrue(CodexAppServerProvider.fallbackDirectories.contains { $0.hasSuffix("/.local/bin") })
        XCTAssertTrue(CodexAppServerProvider.supportsEnvironmentIsolation("worklog/0.163.0 (macOS)"))
        XCTAssertFalse(CodexAppServerProvider.supportsEnvironmentIsolation("worklog/0.159.2"))
        XCTAssertFalse(CodexAppServerProvider.supportsEnvironmentIsolation(nil))
    }

    func testInheritedMCPServersAreDisabledWithoutForwardingTheirCredentials() async throws {
        let server = FakeCodexServer()
        server.script.mutate {
            $0.results["config/read"] = .object(["config": .object(["mcp_servers": .object([
                "fixture-private-server": .object(["url": .string("https://fixture.invalid"),
                    "http_headers": .object(["Authorization": .string("Bearer fake-private-key")])])
            ])])])
        }
        scriptSuccessfulTurn(server: server, followups: [
            agentMessageItem(threadId: "thread-1", turnId: "turn-1", text: "{}"),
            turnCompleted(threadId: "thread-1", turnId: "turn-1", status: "completed")
        ])
        _ = try await makeProvider(server: server).run(makeInput())
        let request = try XCTUnwrap(server.messages(withMethod: "thread/start").first)
        XCTAssertEqual(request["params"]?["config"]?["mcp_servers"]?["fixture-private-server"]?["enabled"]?.boolValue, false)
        let serialized = try JSONEncoder().encode(request)
        XCTAssertFalse(String(decoding: serialized, as: UTF8.self).contains("fake-private-key"))
    }

    func testSubmissionUsesStrictOutputSchemaAndRoundTripsDraft() async throws {
        let draft = SubmissionDraft(groups: [
            SubmissionGroup(heading: "공통 업무", items: [
                SubmissionItem(itemId: "line-1", category: .completed, text: "배포 검증 완료",
                               taskIds: ["task-1"], projectIds: ["project-1"],
                               evidenceIds: ["activity:activity-1"]),
                SubmissionItem(itemId: "line-2", category: .inProgress, text: "문서 정리",
                               taskIds: ["task-2"], projectIds: []),
                SubmissionItem(itemId: "line-3", category: .planned, text: "운영 점검",
                               taskIds: ["task-3"], projectIds: ["project-1"],
                               planItemIds: ["plan-1"]),
            ]),
        ], reviewNotes: ["보류 항목 검토"], warnings: ["결과 근거 확인 필요"])
        let server = FakeCodexServer()
        scriptSuccessfulTurn(server: server, followups: [
            agentMessageItem(threadId: "thread-1", turnId: "turn-1", text: try StableJSON.string(draft)),
            turnCompleted(threadId: "thread-1", turnId: "turn-1", status: "completed"),
        ])

        let output = try await makeProvider(server: server).run(makeInput())
        XCTAssertEqual(try StableJSON.decode(SubmissionDraft.self, from: output.rawJSON), draft)

        let turnRequest = try XCTUnwrap(server.messages(withMethod: "turn/start").first)
        let schema = try XCTUnwrap(turnRequest["params"]?["outputSchema"])
        try assertSchema(schema, matches: JSONValue.from(draft))
        XCTAssertEqual(schema["properties"]?["schemaVersion"]?["enum"], .array([.number(1)]))
        XCTAssertEqual(schema["properties"]?["jobType"]?["enum"], .array([.string("submission_weekly")]))
        let itemSchema = try XCTUnwrap(schema["properties"]?["groups"]?["items"]?["properties"]?["items"]?["items"])
        XCTAssertEqual(itemSchema["properties"]?["category"]?["enum"]?.arrayValue,
                       SubmissionCategory.allCases.map { .string($0.rawValue) })
        for field in ["taskIds", "projectIds", "planItemIds", "evidenceIds"] {
            XCTAssertEqual(itemSchema["properties"]?[field]?["type"]?.stringValue, "array")
            XCTAssertEqual(itemSchema["properties"]?[field]?["items"]?["type"]?.stringValue, "string")
        }
        XCTAssertEqual(itemSchema["properties"]?["taskIds"]?["minItems"], .number(1),
                       "제출용 항목은 실제 업무 ID를 하나 이상 지정해야 한다")
        for field in ["projectIds", "planItemIds", "evidenceIds"] {
            XCTAssertNil(itemSchema["properties"]?[field]?["minItems"],
                         "프로젝트·계획·활동 근거가 없는 실제 업무도 보고할 수 있다")
        }
        try assertSchema(schema, matches: JSONValue.from(SubmissionDraft(groups: [])))
    }

    func testOtherJobTypesDoNotUseSubmissionOutputSchema() async throws {
        for jobType in AIJobType.allCases where jobType != .submissionWeekly {
            let server = FakeCodexServer()
            scriptSuccessfulTurn(server: server, followups: [
                agentMessageItem(threadId: "thread-1", turnId: "turn-1", text: "{}"),
                turnCompleted(threadId: "thread-1", turnId: "turn-1", status: "completed"),
            ])

            _ = try await makeProvider(server: server).run(makeInput(type: jobType))

            let turnRequest = try XCTUnwrap(server.messages(withMethod: "turn/start").first)
            XCTAssertNil(turnRequest["params"]?["outputSchema"], jobType.rawValue)
        }
    }

    /// 실제 Codable 출력의 키와 자료형을 비교해 계약 필드 누락·선택 필드화를 잡는다.
    private func assertSchema(_ schema: JSONValue, matches value: JSONValue,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        switch value {
        case .object(let fields):
            XCTAssertEqual(schema["type"]?.stringValue, "object", file: file, line: line)
            XCTAssertEqual(schema["additionalProperties"]?.boolValue, false, file: file, line: line)
            let properties = try XCTUnwrap(schema["properties"]?.objectValue, file: file, line: line)
            XCTAssertEqual(Set(properties.keys), Set(fields.keys), file: file, line: line)
            XCTAssertEqual(Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []),
                           Set(fields.keys), file: file, line: line)
            for (key, child) in fields {
                try assertSchema(XCTUnwrap(properties[key], file: file, line: line),
                                 matches: child, file: file, line: line)
            }
        case .array(let elements):
            XCTAssertEqual(schema["type"]?.stringValue, "array", file: file, line: line)
            if let minimumCount = schema["minItems"]?.intValue {
                XCTAssertGreaterThanOrEqual(elements.count, minimumCount, file: file, line: line)
            }
            let itemSchema = try XCTUnwrap(schema["items"], file: file, line: line)
            for element in elements {
                try assertSchema(itemSchema, matches: element, file: file, line: line)
            }
        case .string:
            XCTAssertEqual(schema["type"]?.stringValue, "string", file: file, line: line)
        case .number:
            XCTAssertEqual(schema["type"]?.stringValue, "integer", file: file, line: line)
        case .null, .bool:
            XCTFail("제출용 계약에 없는 자료형", file: file, line: line)
        }
        if let allowed = schema["enum"]?.arrayValue {
            XCTAssertTrue(allowed.contains(value), file: file, line: line)
        }
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

    // MARK: - 실행 파일 탐색

    func testResolveExecutableFallsBackWhenPathLacksCodex() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("codex-resolve-\(UUID().uuidString)")
        let emptyDir = root.appendingPathComponent("empty")
        let fallbackDir = root.appendingPathComponent("fallback")
        try fm.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let fake = fallbackDir.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fake)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let found = CodexAppServerProvider.resolveExecutable(
            nil, environment: ["PATH": emptyDir.path], fallbackDirectories: [fallbackDir.path])
        XCTAssertEqual(found?.path, fake.path)

        XCTAssertNil(CodexAppServerProvider.resolveExecutable(
            nil, environment: [:], fallbackDirectories: [emptyDir.path]))
        // 명시 경로가 있으면 그 경로만 본다(대체 탐색 안 함).
        XCTAssertNil(CodexAppServerProvider.resolveExecutable(
            emptyDir.appendingPathComponent("codex").path,
            environment: ["PATH": fallbackDir.path], fallbackDirectories: [fallbackDir.path]))
    }
}
