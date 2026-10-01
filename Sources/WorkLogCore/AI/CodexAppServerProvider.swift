import Foundation

// 공식 Codex app-server 프로토콜(stdio JSONL)을 사용하는 AIProvider 구현.
//
// 실제 codex 바이너리 실행·~/.codex 인증 파일 읽기는 이 코드가 하지 않는다.
// 앱이 띄운 app-server 자식 프로세스와 JSON-RPC로만 대화하며, 토큰 필드는 읽거나 저장하지 않는다.
// 모든 작업은 stagingRoot 하위에서 읽기 전용·무승인으로 실행되고, 승인 요청은 항상 거절한다.

public struct CodexProviderConfig: Sendable {
    /// nil이면 PATH에서 "codex" 탐색.
    public var executablePath: String?
    /// AI 작업 전용 디렉터리(앱 데이터 루트/ai-jobs). thread cwd로 사용한다.
    public var stagingRoot: URL
    /// nil이면 서버 기본값.
    public var model: String?
    public var requestTimeout: TimeInterval
    public var turnTimeout: TimeInterval

    public init(executablePath: String? = nil, stagingRoot: URL, model: String? = nil,
                requestTimeout: TimeInterval = 60, turnTimeout: TimeInterval = 600) {
        self.executablePath = executablePath
        self.stagingRoot = stagingRoot
        self.model = model
        self.requestTimeout = requestTimeout
        self.turnTimeout = turnTimeout
    }
}

public final class CodexAppServerProvider: AIProvider, @unchecked Sendable {
    private let config: CodexProviderConfig
    private let transportFactory: (@Sendable () throws -> LineTransport)?
    private let state = CodexState()

    /// transportFactory: 테스트 주입용. 기본은 ProcessLineTransport(executable, ["app-server"]).
    public init(config: CodexProviderConfig,
                transportFactory: (@Sendable () throws -> LineTransport)? = nil) {
        self.config = config
        self.transportFactory = transportFactory
    }

    // MARK: - AIProvider

    public func checkCapabilities() async -> AICapabilities {
        if let cached = locked({ state.capabilities }) { return cached }
        do {
            let info = try await ensureConnectionInfo()
            let capabilities = AICapabilities(installed: true, version: info.userAgent,
                                              protocolCompatible: true)
            locked { state.capabilities = capabilities }
            return capabilities
        } catch {
            let errorClass = AIErrorClassifier.classify(error)
            if errorClass == .notInstalled {
                return AICapabilities(installed: false, protocolCompatible: false,
                                      notes: ["Codex 실행 파일을 찾을 수 없습니다."])
            }
            return AICapabilities(installed: true, protocolCompatible: false,
                                  notes: ["Codex 초기화 실패: \(errorClass.rawValue)"])
        }
    }

    public func getAccountStatus() async throws -> AIAccountState {
        let connection = try await ensureConnection()
        let result = try await send(connection, "account/read",
                                    .object(["refreshToken": .bool(false)]))
        guard let account = result["account"], account != .null else { return .loggedOut }
        // type/email/planType만 추출한다. 토큰 필드는 어떤 경우에도 읽지 않는다.
        return .loggedIn(accountType: account["type"]?.stringValue,
                         email: account["email"]?.stringValue,
                         planType: account["planType"]?.stringValue)
    }

    public func beginOfficialLogin() async throws -> URL? {
        let connection = try await ensureConnection()
        let result = try await send(connection, "account/login/start",
                                    .object(["type": .string("chatgpt")]))
        guard let authUrl = result["authUrl"]?.stringValue else { return nil }
        return URL(string: authUrl)
    }

    public func listAvailableSkills() async throws -> [DiscoveredSkill] {
        let connection = try await ensureConnection()
        let result = try await send(connection, "skills/list",
                                    .object(["cwds": .array([.string(config.stagingRoot.path)])]))
        var skills: [DiscoveredSkill] = []
        for entry in result["data"]?.arrayValue ?? [] {
            for skill in entry["skills"]?.arrayValue ?? [] {
                guard let name = skill["name"]?.stringValue else { continue }
                skills.append(DiscoveredSkill(
                    name: name,
                    description: skill["description"]?.stringValue,
                    path: skill["path"]?.stringValue,
                    enabled: skill["enabled"]?.boolValue ?? true
                ))
            }
        }
        return skills
    }

    public func run(_ input: AIJobInput) async throws -> AIJobOutput {
        let connection: JSONRPCConnection
        do {
            connection = try await ensureConnection()
        } catch {
            throw providerError(error)
        }

        let jobDirectory = config.stagingRoot.appendingPathComponent(input.jobId, isDirectory: true)
        try? FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)

        // 1) thread/start — 읽기 전용, 무승인, 임시 thread.
        var threadParams: [String: JSONValue] = [
            "cwd": .string(jobDirectory.path),
            "sandbox": .string("read-only"),
            "approvalPolicy": .string("never"),
            "ephemeral": .bool(true),
            "developerInstructions": .string(input.instructions),
        ]
        if let model = config.model { threadParams["model"] = .string(model) }

        let threadResult: JSONValue
        do {
            threadResult = try await send(connection, "thread/start", .object(threadParams))
        } catch {
            throw providerError(error)
        }
        guard let threadId = threadResult["thread"]?["id"]?.stringValue else {
            throw AIProviderError(.protocolMismatch, "thread/start 응답에 thread.id가 없습니다.")
        }

        let context = CodexRunContext(jobId: input.jobId, threadId: threadId,
                                 model: threadResult["model"]?.stringValue ?? config.model)
        register(context)
        defer { unregister(context) }

        // 2) turn/start — payloadJSON(+선택 스킬 언급)을 텍스트 입력으로 보낸다.
        var text = input.payloadJSON
        if let skill = input.skill, !skill.name.isEmpty {
            text = "$\(skill.name)\n\(text)"
        }
        let turnParams: JSONValue = .object([
            "threadId": .string(threadId),
            "input": .array([
                .object(["type": .string("text"), "text": .string(text)]),
            ]),
        ])

        do {
            let turnResult = try await send(connection, "turn/start", turnParams)
            if let turnId = turnResult["turn"]?["id"]?.stringValue {
                context.setTurnId(turnId)
            }
        } catch {
            // 알림(turn/completed 등)이 먼저 도착해 이미 결과가 있으면 그쪽을 우선한다.
            if let output = context.takePendingOutput() { return output }
            throw providerError(error)
        }

        // 3) 알림 수집 — turn/completed까지 대기, turnTimeout 초과 시 interrupt 후 timeout.
        return try await awaitCompletion(context, connection: connection)
    }

    public func cancel(jobId: String) async {
        guard let context = locked({ state.runByJob[jobId] }),
              let connection = locked({ state.connection }) else { return }
        let turnId = context.turnId
        if let turnId {
            _ = try? await connection.request(
                "turn/interrupt",
                params: .object(["threadId": .string(context.threadId), "turnId": .string(turnId)]),
                timeout: config.requestTimeout)
        }
        context.resolve(.failure(AIProviderError(.cancelled, "사용자가 취소했습니다.")))
    }

    // MARK: - 연결

    struct CodexConnectionInfo {
        let connection: JSONRPCConnection
        let transport: CodexObservedTransport
        let userAgent: String?
    }

    private func ensureConnection() async throws -> JSONRPCConnection {
        try await ensureConnectionInfo().connection
    }

    private func ensureConnectionInfo() async throws -> CodexConnectionInfo {
        if let existing = locked({ state.connectionInfo }) { return existing }

        let task: Task<CodexConnectionInfo, Error> = locked {
            if let running = state.connectTask { return running }
            let created = Task { try await self.makeConnection() }
            state.connectTask = created
            return created
        }

        do {
            let info = try await task.value
            locked {
                state.connectionInfo = info
                state.connectTask = nil
            }
            return info
        } catch {
            locked { state.connectTask = nil }
            throw error
        }
    }

    private func makeConnection() async throws -> CodexConnectionInfo {
        let transport = try makeTransport()
        let observed = CodexObservedTransport(inner: transport)
        let connection = JSONRPCConnection(transport: observed, defaultTimeout: config.requestTimeout)
        observed.onClose = { [weak self] reason in self?.handleTransportClose(reason) }
        connection.onNotification = { [weak self] method, params in
            self?.handleNotification(method: method, params: params)
        }
        connection.onServerRequest = { [weak self] method, params in
            self?.handleServerRequest(method: method, params: params)
        }

        try connection.start()

        let initParams = JSONValue.object([
            "clientInfo": .object([
                "name": .string("worklog"),
                "title": .string("WorkLog"),
                "version": .string("0.1.0"),
            ]),
        ])
        let initResult = try await connection.request("initialize", params: initParams,
                                                      timeout: config.requestTimeout)
        try? connection.notify("initialized", params: nil)

        let userAgent = initResult["userAgent"]?.stringValue
        return CodexConnectionInfo(connection: connection, transport: observed, userAgent: userAgent)
    }

    private func makeTransport() throws -> LineTransport {
        if let transportFactory { return try transportFactory() }
        guard let executable = Self.resolveExecutable(config.executablePath) else {
            throw AIExecutableNotFoundError(path: config.executablePath ?? "codex")
        }
        return ProcessLineTransport(executableURL: executable, arguments: ["app-server"])
    }

    /// executablePath가 있으면 그 경로만, 없으면 PATH에서 "codex"를 찾는다.
    static func resolveExecutable(_ explicitPath: String?) -> URL? {
        let fileManager = FileManager.default
        if let explicitPath, !explicitPath.isEmpty {
            return fileManager.isExecutableFile(atPath: explicitPath)
                ? URL(fileURLWithPath: explicitPath) : nil
        }
        guard let pathValue = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for directory in pathValue.split(separator: ":") {
            let candidate = String(directory) + "/codex"
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    // MARK: - 알림·서버 요청 처리

    private func handleNotification(method: String, params: JSONValue?) {
        let threadId = params?["threadId"]?.stringValue
        guard let threadId, let context = context(forThread: threadId) else { return }

        switch method {
        case "item/agentMessage/delta":
            if let delta = params?["delta"]?.stringValue { context.appendDelta(delta) }

        case "item/completed":
            if let item = params?["item"], item["type"]?.stringValue == "agentMessage",
               let text = item["text"]?.stringValue {
                context.setFinalText(text)
            }

        case "turn/completed":
            guard let turn = params?["turn"] else { return }
            switch turn["status"]?.stringValue {
            case "completed":
                let output = AIJobOutput(rawJSON: Self.stripCodeFence(context.text()),
                                         model: context.model, providerRef: context.threadId)
                context.resolve(.success(output))
            case "failed":
                let message = turn["error"]?["message"]?.stringValue ?? "Codex turn 실패"
                context.resolve(.failure(AIProviderError(
                    AIErrorClassifier.classifyMessage(message, code: nil), message)))
            case "interrupted":
                context.resolve(.failure(AIProviderError(.cancelled, "turn이 중단되었습니다.")))
            default:
                break
            }

        case "error":
            if params?["willRetry"]?.boolValue == true { return }
            let message = params?["error"]?["message"]?.stringValue ?? "Codex 오류"
            context.resolve(.failure(AIProviderError(
                AIErrorClassifier.classifyMessage(message, code: nil), message)))

        default:
            break
        }
    }

    /// 승인 요청은 예외 없이 거절한다(셸·파일 변경·권한 확대 금지).
    private func handleServerRequest(method: String, params: JSONValue?) -> JSONValue? {
        let lower = method.lowercased()
        if lower.contains("approval") || lower.contains("permissions") {
            return .object(["decision": .string("decline")])
        }
        return nil
    }

    private func handleTransportClose(_ reason: TransportCloseReason) {
        let contexts: [CodexRunContext] = locked {
            state.connectionInfo = nil
            state.connectTask = nil
            return Array(state.runsByThread.values)
        }
        let error = providerError(JSONRPCClientError.closed(reason))
        for context in contexts { context.resolve(.failure(error)) }
    }

    // MARK: - 실행 상태 등록

    private func register(_ context: CodexRunContext) {
        locked {
            state.runsByThread[context.threadId] = context
            state.runByJob[context.jobId] = context
        }
    }

    private func unregister(_ context: CodexRunContext) {
        locked {
            state.runsByThread.removeValue(forKey: context.threadId)
            if state.runByJob[context.jobId] === context {
                state.runByJob.removeValue(forKey: context.jobId)
            }
        }
    }

    private func context(forThread threadId: String) -> CodexRunContext? {
        locked { state.runsByThread[threadId] }
    }

    // MARK: - 완료 대기

    private func awaitCompletion(_ context: CodexRunContext, connection: JSONRPCConnection) async throws -> AIJobOutput {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AIJobOutput, Error>) in
            guard context.setContinuation(continuation) else { return }
            let timeoutTask = Task { [weak self] in
                guard let self else { return }
                let nanos = UInt64(max(0, self.config.turnTimeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { return }
                await self.handleTurnTimeout(context, connection: connection)
            }
            context.setTimeoutTask(timeoutTask)
        }
    }

    private func handleTurnTimeout(_ context: CodexRunContext, connection: JSONRPCConnection) async {
        let interrupted = context.resolve(.failure(AIProviderError(.timeout, "turn 응답 시간 초과")))
        guard interrupted, let turnId = context.turnId else { return }
        _ = try? await connection.request(
            "turn/interrupt",
            params: .object(["threadId": .string(context.threadId), "turnId": .string(turnId)]),
            timeout: config.requestTimeout)
    }

    // MARK: - 유틸

    private func send(_ connection: JSONRPCConnection, _ method: String, _ params: JSONValue?) async throws -> JSONValue {
        do {
            return try await connection.request(method, params: params, timeout: config.requestTimeout)
        } catch {
            throw providerError(error)
        }
    }

    private func providerError(_ error: Error) -> AIProviderError {
        if let provider = error as? AIProviderError { return provider }
        return AIProviderError(AIErrorClassifier.classify(error), Self.shortMessage(error))
    }

    private static func shortMessage(_ error: Error) -> String {
        if let rpc = error as? JSONRPCErrorPayload { return rpc.message }
        if let provider = error as? AIProviderError { return provider.message }
        if let client = error as? JSONRPCClientError {
            switch client {
            case .rpc(let payload): return payload.message
            case .timeout(let method): return "요청 시간 초과: \(method)"
            case .closed(let reason): return "연결 종료: \(reason)"
            case .cancelled: return "요청이 취소되었습니다."
            case .malformed(let message): return "프로토콜 오류: \(message)"
            }
        }
        if error is AIExecutableNotFoundError { return "Codex 실행 파일을 찾을 수 없습니다." }
        return String(describing: error)
    }

    /// 앞뒤 ```json 펜스가 있으면 제거한다.
    static func stripCodeFence(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("```") else { return value }
        if let newline = value.firstIndex(of: "\n") {
            value = String(value[value.index(after: newline)...])
        } else {
            value = String(value.dropFirst(3))
        }
        if let closing = value.range(of: "```", options: .backwards) {
            value = String(value[..<closing.lowerBound])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func locked<T>(_ body: () -> T) -> T {
        state.lock.lock()
        defer { state.lock.unlock() }
        return body()
    }
}

// MARK: - 내부 상태

private final class CodexState: @unchecked Sendable {
    let lock = NSLock()
    var connectionInfo: CodexAppServerProvider.CodexConnectionInfo?
    var connectTask: Task<CodexAppServerProvider.CodexConnectionInfo, Error>?
    var runsByThread: [String: CodexRunContext] = [:]
    var runByJob: [String: CodexRunContext] = [:]
    var capabilities: AICapabilities?

    var connection: JSONRPCConnection? { connectionInfo?.connection }
}

// MARK: - 종료 관찰 전송

/// 내부 전송의 종료 콜백을 가로채 provider에 알리는 얇은 래퍼.
final class CodexObservedTransport: LineTransport, @unchecked Sendable {
    private let inner: LineTransport
    var onClose: (@Sendable (TransportCloseReason) -> Void)?

    init(inner: LineTransport) { self.inner = inner }

    func start(onLine: @escaping @Sendable (String) -> Void,
               onClose: @escaping @Sendable (TransportCloseReason) -> Void) throws {
        try inner.start(onLine: onLine, onClose: { [weak self] reason in
            self?.onClose?(reason)
            onClose(reason)
        })
    }

    func send(line: String) throws { try inner.send(line: line) }
    func close() { inner.close() }
}

// MARK: - 진행 중 turn 상태

final class CodexRunContext: @unchecked Sendable {
    let jobId: String
    let threadId: String
    let model: String?

    private let lock = NSLock()
    private var _turnId: String?
    private var accumulated = ""
    private var finalText: String?
    private var continuation: CheckedContinuation<AIJobOutput, Error>?
    private var pendingResult: Result<AIJobOutput, Error>?
    private var resolved = false
    private var timeoutTask: Task<Void, Never>?

    init(jobId: String, threadId: String, model: String?) {
        self.jobId = jobId
        self.threadId = threadId
        self.model = model
    }

    var turnId: String? {
        lock.lock(); defer { lock.unlock() }
        return _turnId
    }

    func setTurnId(_ id: String) {
        lock.lock(); _turnId = id; lock.unlock()
    }

    func appendDelta(_ delta: String) {
        lock.lock(); accumulated += delta; lock.unlock()
    }

    func setFinalText(_ text: String) {
        lock.lock(); finalText = text; lock.unlock()
    }

    func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return finalText ?? accumulated
    }

    /// continuation을 등록한다. 이미 결과가 있으면 즉시 resume하고 false를 돌려준다.
    @discardableResult
    func setContinuation(_ continuation: CheckedContinuation<AIJobOutput, Error>) -> Bool {
        lock.lock()
        if let result = pendingResult {
            pendingResult = nil
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock(); timeoutTask = task; lock.unlock()
    }

    /// 정확히 한 번만 결과를 확정한다. 이미 확정됐으면 false.
    @discardableResult
    func resolve(_ result: Result<AIJobOutput, Error>) -> Bool {
        lock.lock()
        if resolved { lock.unlock(); return false }
        resolved = true
        let task = timeoutTask
        timeoutTask = nil
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { pendingResult = result }
        lock.unlock()
        task?.cancel()
        continuation?.resume(with: result)
        return true
    }

    /// 이미 확정된 결과가 있으면 꺼내온다(없으면 nil).
    func takePendingOutput() -> AIJobOutput? {
        lock.lock(); defer { lock.unlock() }
        guard case .success(let output)? = pendingResult else { return nil }
        pendingResult = nil
        return output
    }
}
