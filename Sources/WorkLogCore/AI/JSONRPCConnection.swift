import Foundation

// 줄 단위 JSON-RPC 클라이언트 연결. Codex app-server 전용이 아니라 범용 전송/연결 계층이다.
// 한 줄 = 한 JSON-RPC 메시지(JSONL). "jsonrpc" 필드는 보내도 되고 없어도 된다.

/// 줄 단위 양방향 전송. 테스트에서는 메모리 구현을 주입한다.
public protocol LineTransport: AnyObject, Sendable {
    /// 수신 줄/종료 콜백을 등록하고 전송을 시작한다.
    func start(onLine: @escaping @Sendable (String) -> Void,
               onClose: @escaping @Sendable (TransportCloseReason) -> Void) throws
    /// 한 줄을 보낸다(끝의 개행은 구현이 붙인다).
    func send(line: String) throws
    func close()
}

/// 전송이 닫힌 이유.
public enum TransportCloseReason: Equatable, Sendable {
    case exited(Int32)
    case closedByClient
    case error(String)
}

/// JSON-RPC error 응답 바디.
public struct JSONRPCErrorPayload: Error, Codable, Equatable, Sendable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// 클라이언트 요청이 실패한 이유.
public enum JSONRPCClientError: Error, Equatable, Sendable {
    case rpc(JSONRPCErrorPayload)
    case timeout(method: String)
    case closed(TransportCloseReason)
    case cancelled
    case malformed(String)
}

/// 줄 단위 JSON-RPC 요청/응답 매칭, 알림 수신, 서버→클라이언트 요청 처리를 담당하는 연결.
public final class JSONRPCConnection: @unchecked Sendable {
    private final class Pending {
        let method: String
        let continuation: CheckedContinuation<JSONValue, Error>
        var timeoutTask: Task<Void, Never>?

        init(method: String, continuation: CheckedContinuation<JSONValue, Error>) {
            self.method = method
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private let transport: LineTransport
    private let defaultTimeout: TimeInterval

    private var nextId: Int64 = 1
    private var pending: [String: Pending] = [:]
    private var closedReason: TransportCloseReason?
    private var started = false

    private var _malformedLineCount = 0
    private var _onNotification: (@Sendable (String, JSONValue?) -> Void)?
    private var _onServerRequest: (@Sendable (String, JSONValue?) -> JSONValue?)?

    public init(transport: LineTransport, defaultTimeout: TimeInterval = 60) {
        self.transport = transport
        self.defaultTimeout = defaultTimeout
    }

    /// 서버가 보낸 알림(method, params) 수신 핸들러.
    public var onNotification: (@Sendable (String, JSONValue?) -> Void)? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _onNotification
        }
        set {
            lock.lock(); _onNotification = newValue; lock.unlock()
        }
    }

    /// 서버→클라이언트 요청(id + method) 핸들러. 반환값이 result로 회신된다.
    /// nil이면 error(-32601 method not found)로 회신.
    public var onServerRequest: (@Sendable (String, JSONValue?) -> JSONValue?)? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _onServerRequest
        }
        set {
            lock.lock(); _onServerRequest = newValue; lock.unlock()
        }
    }

    /// 파싱 불가 줄 수 (내용은 저장하지 않음 — 민감정보 가능).
    public var malformedLineCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _malformedLineCount
    }

    public func start() throws {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        do {
            try transport.start(
                onLine: { [weak self] line in self?.handleLine(line) },
                onClose: { [weak self] reason in self?.handleClose(reason) }
            )
        } catch {
            lock.lock()
            started = false
            lock.unlock()
            throw error
        }
    }

    /// id는 1부터 증가하는 정수. 응답의 result를 반환하거나 JSONRPCClientError를 throw.
    public func request(_ method: String, params: JSONValue?, timeout: TimeInterval? = nil) async throws -> JSONValue {
        let effectiveTimeout = timeout ?? defaultTimeout
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            lock.lock()
            if let reason = closedReason {
                lock.unlock()
                continuation.resume(throwing: JSONRPCClientError.closed(reason))
                return
            }
            let id = nextId
            nextId += 1
            let key = Self.requestKey(for: .number(Double(id)))
            pending[key] = Pending(method: method, continuation: continuation)
            lock.unlock()

            let line: String
            do {
                line = try Self.encodeRequest(id: id, method: method, params: params)
            } catch {
                failPending(key, .malformed("요청 인코딩 실패"))
                return
            }

            if effectiveTimeout > 0 {
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000_000))
                    if Task.isCancelled { return }
                    self?.failPending(key, .timeout(method: method))
                }
                lock.lock()
                pending[key]?.timeoutTask = timeoutTask
                lock.unlock()
            }

            do {
                try transport.send(line: line)
            } catch {
                failPendingAfterSendFailure(key, error: error)
            }
        }
    }

    public func notify(_ method: String, params: JSONValue?) throws {
        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params { object["params"] = params }
        try transport.send(line: try JSONValue.object(object).encodedString())
    }

    /// 진행 중 요청을 모두 cancelled로 끝낸다.
    public func cancelAll() {
        lock.lock()
        let all = pending
        pending.removeAll()
        lock.unlock()
        for item in all.values {
            item.timeoutTask?.cancel()
            item.continuation.resume(throwing: JSONRPCClientError.cancelled)
        }
    }

    public func close() {
        lock.lock()
        if closedReason == nil { closedReason = .closedByClient }
        let all = pending
        pending.removeAll()
        lock.unlock()
        for item in all.values {
            item.timeoutTask?.cancel()
            item.continuation.resume(throwing: JSONRPCClientError.closed(.closedByClient))
        }
        transport.close()
    }

    // MARK: - 수신 처리

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let object) = decoded else {
            incrementMalformed()
            return
        }

        let idValue = object["id"]
        let hasMethod = object["method"] != nil
        let hasResult = object["result"] != nil
        let hasError = object["error"] != nil

        if let idValue, hasResult || hasError {
            handleResponse(idValue: idValue, object: object, hasError: hasError)
        } else if let idValue, hasMethod {
            handleServerRequest(idValue: idValue, object: object)
        } else if let method = object["method"]?.stringValue {
            let handler = onNotification
            handler?(method, object["params"])
        } else {
            incrementMalformed()
        }
    }

    private func handleResponse(idValue: JSONValue, object: [String: JSONValue], hasError: Bool) {
        let key = Self.requestKey(for: idValue)
        if hasError, let errorObject = object["error"]?.objectValue {
            let payload = JSONRPCErrorPayload(
                code: errorObject["code"]?.intValue ?? 0,
                message: errorObject["message"]?.stringValue ?? "",
                data: errorObject["data"]
            )
            failPending(key, .rpc(payload))
        } else {
            fulfillPending(key, object["result"] ?? .null)
        }
    }

    private func handleServerRequest(idValue: JSONValue, object: [String: JSONValue]) {
        let method = object["method"]?.stringValue ?? ""
        let params = object["params"]
        let handler = onServerRequest
        if let result = handler?(method, params) {
            sendResponse(idValue: idValue, result: result)
        } else {
            sendErrorResponse(idValue: idValue, code: -32601, message: "Method not found")
        }
    }

    private func sendResponse(idValue: JSONValue, result: JSONValue) {
        let message = JSONValue.object(["id": idValue, "result": result])
        if let line = try? message.encodedString() {
            try? transport.send(line: line)
        }
    }

    private func sendErrorResponse(idValue: JSONValue, code: Int, message: String) {
        let payload = JSONValue.object([
            "code": .number(Double(code)),
            "message": .string(message),
        ])
        let message = JSONValue.object(["id": idValue, "error": payload])
        if let line = try? message.encodedString() {
            try? transport.send(line: line)
        }
    }

    private func handleClose(_ reason: TransportCloseReason) {
        lock.lock()
        if closedReason != nil {
            lock.unlock()
            return
        }
        closedReason = reason
        let all = pending
        pending.removeAll()
        lock.unlock()
        for item in all.values {
            item.timeoutTask?.cancel()
            item.continuation.resume(throwing: JSONRPCClientError.closed(reason))
        }
    }

    // MARK: - 대기 요청 정리 (continuation은 정확히 한 번만 resume)

    private func fulfillPending(_ key: String, _ value: JSONValue) {
        lock.lock()
        let item = pending.removeValue(forKey: key)
        lock.unlock()
        item?.timeoutTask?.cancel()
        item?.continuation.resume(returning: value)
    }

    private func failPending(_ key: String, _ error: JSONRPCClientError) {
        lock.lock()
        let item = pending.removeValue(forKey: key)
        lock.unlock()
        item?.timeoutTask?.cancel()
        item?.continuation.resume(throwing: error)
    }

    private func failPendingAfterSendFailure(_ key: String, error: Error) {
        lock.lock()
        let reason = closedReason
        lock.unlock()
        if let reason {
            failPending(key, .closed(reason))
        } else {
            failPending(key, .closed(.error(String(describing: error))))
        }
    }

    private func incrementMalformed() {
        lock.lock()
        _malformedLineCount += 1
        lock.unlock()
    }

    // MARK: - 직렬화

    private static func encodeRequest(id: Int64, method: String, params: JSONValue?) throws -> String {
        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
        ]
        if let params { object["params"] = params }
        return try JSONValue.object(object).encodedString()
    }

    /// 응답 id 매칭 키. 숫자/문자열 id를 모두 수용한다.
    static func requestKey(for id: JSONValue) -> String {
        switch id {
        case .number(let value):
            if let int = Int64(exactly: value) { return "n:\(int)" }
            return "n:\(value)"
        case .string(let value):
            return "s:\(value)"
        default:
            return "x:\(id)"
        }
    }
}
