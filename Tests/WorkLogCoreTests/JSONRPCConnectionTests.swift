import Foundation
import XCTest
@testable import WorkLogCore

// 테스트용 메모리 전송. 보낸 줄을 기록하고, 테스트가 서버 줄/종료를 주입한다.
final class MemoryLineTransport: LineTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _sentLines: [String] = []
    private var _onLine: (@Sendable (String) -> Void)?
    private var _onClose: (@Sendable (TransportCloseReason) -> Void)?

    var sentLines: [String] {
        lock.lock(); defer { lock.unlock() }
        return _sentLines
    }

    func start(onLine: @escaping @Sendable (String) -> Void,
               onClose: @escaping @Sendable (TransportCloseReason) -> Void) throws {
        lock.lock()
        _onLine = onLine
        _onClose = onClose
        lock.unlock()
    }

    func send(line: String) throws {
        lock.lock()
        _sentLines.append(line)
        lock.unlock()
    }

    func close() {}

    func inject(_ line: String) {
        let handler: (@Sendable (String) -> Void)?
        lock.lock(); handler = _onLine; lock.unlock()
        handler?(line)
    }

    func simulateClose(_ reason: TransportCloseReason) {
        let handler: (@Sendable (TransportCloseReason) -> Void)?
        lock.lock(); handler = _onClose; lock.unlock()
        handler?(reason)
    }
}

// 테스트 스레드 간 공유 값을 안전하게 다루기 위한 잠금 상자.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    init(_ value: T) { _value = value }

    var value: T {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    func mutate(_ body: (inout T) -> Void) {
        lock.lock(); body(&_value); lock.unlock()
    }
}

final class JSONRPCConnectionTests: XCTestCase {
    private struct TimedOut: Error {}

    private func decodeJSON(_ line: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    }

    private func waitUntil(_ condition: @escaping () -> Bool,
                           iterations: Int = 600,
                           file: StaticString = #filePath,
                           line: UInt = #line) async throws {
        for _ in 0..<iterations {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("조건이 시간 안에 충족되지 않음", file: file, line: line)
        throw TimedOut()
    }

    private func makeConnection(defaultTimeout: TimeInterval = 5) -> (JSONRPCConnection, MemoryLineTransport) {
        let transport = MemoryLineTransport()
        let connection = JSONRPCConnection(transport: transport, defaultTimeout: defaultTimeout)
        return (connection, transport)
    }

    // 1. request → 응답 result 반환, 보낸 줄에 method/id/params 존재
    func testRequestReturnsResultAndSendsExpectedLine() async throws {
        let (connection, transport) = makeConnection()
        try connection.start()

        let task = Task { try await connection.request("do.thing", params: .object(["a": .number(1)])) }
        try await waitUntil { transport.sentLines.count == 1 }

        let sent = try decodeJSON(transport.sentLines[0])
        XCTAssertEqual(sent["method"]?.stringValue, "do.thing")
        XCTAssertEqual(sent["id"]?.numberValue, 1)
        XCTAssertEqual(sent["params"]?["a"]?.numberValue, 1)

        transport.inject(#"{"id":1,"result":{"ok":true}}"#)
        let result = try await task.value
        XCTAssertEqual(result, .object(["ok": .bool(true)]))
    }

    // 2. 동시 요청 2개, 응답 순서 반대로 와도 각각 올바른 결과
    func testConcurrentRequestsMatchedRegardlessOfResponseOrder() async throws {
        let (connection, transport) = makeConnection()
        try connection.start()

        let first = Task { try await connection.request("m1", params: nil) }
        let second = Task { try await connection.request("m2", params: nil) }
        try await waitUntil { transport.sentLines.count == 2 }

        var idByMethod: [String: Double] = [:]
        for line in transport.sentLines {
            let json = try decodeJSON(line)
            if let method = json["method"]?.stringValue, let id = json["id"]?.numberValue {
                idByMethod[method] = id
            }
        }
        let id1 = try XCTUnwrap(idByMethod["m1"])
        let id2 = try XCTUnwrap(idByMethod["m2"])

        transport.inject("{\"id\":\(Int(id2)),\"result\":\"two\"}")
        transport.inject("{\"id\":\(Int(id1)),\"result\":\"one\"}")

        let result1 = try await first.value
        let result2 = try await second.value
        XCTAssertEqual(result1, .string("one"))
        XCTAssertEqual(result2, .string("two"))
    }

    // 3. error 응답 → .rpc
    func testErrorResponseThrowsRPCError() async throws {
        let (connection, transport) = makeConnection()
        try connection.start()

        let task = Task { try await connection.request("boom", params: nil) }
        try await waitUntil { transport.sentLines.count == 1 }
        transport.inject(#"{"id":1,"error":{"code":-32000,"message":"boom"}}"#)

        do {
            _ = try await task.value
            XCTFail("에러 응답은 throw 되어야 함")
        } catch let error as JSONRPCClientError {
            XCTAssertEqual(error, .rpc(JSONRPCErrorPayload(code: -32000, message: "boom")))
        }
    }

    // 4. 알림 수신 → onNotification 호출
    func testNotificationInvokesHandler() async throws {
        let (connection, transport) = makeConnection()
        let received = Locked<[(String, JSONValue?)]>([])
        connection.onNotification = { method, params in
            received.mutate { $0.append((method, params)) }
        }
        try connection.start()

        transport.inject(#"{"method":"turn/started","params":{"turn":1}}"#)
        try await waitUntil { received.value.count == 1 }

        XCTAssertEqual(received.value.first?.0, "turn/started")
        XCTAssertEqual(received.value.first?.1?["turn"]?.numberValue, 1)
    }

    // 5a. 서버 요청 → onServerRequest 결과로 같은 id 회신
    func testServerRequestRepliesWithHandlerResult() async throws {
        let (connection, transport) = makeConnection()
        connection.onServerRequest = { _, params in
            .object(["echo": params ?? .null])
        }
        try connection.start()

        transport.inject(#"{"id":99,"method":"ask","params":{"q":1}}"#)
        try await waitUntil { transport.sentLines.contains { $0.contains("\"id\":99") } }

        let line = try XCTUnwrap(transport.sentLines.first { $0.contains("\"id\":99") })
        let response = try decodeJSON(line)
        XCTAssertEqual(response["id"]?.numberValue, 99)
        XCTAssertEqual(response["result"]?["echo"]?["q"]?.numberValue, 1)
    }

    // 5b. 핸들러 nil이면 -32601 error 회신
    func testServerRequestWithoutHandlerRepliesMethodNotFound() async throws {
        let (connection, transport) = makeConnection()
        try connection.start()

        transport.inject(#"{"id":7,"method":"ask"}"#)
        try await waitUntil { transport.sentLines.contains { $0.contains("\"id\":7") } }

        let line = try XCTUnwrap(transport.sentLines.first { $0.contains("\"id\":7") })
        let response = try decodeJSON(line)
        XCTAssertEqual(response["id"]?.numberValue, 7)
        XCTAssertEqual(response["error"]?["code"]?.numberValue, -32601)
    }

    // 6. 끊긴 JSON 줄 → malformedLineCount 1, 이후 정상 응답 처리
    func testMalformedLineIsCountedAndConnectionContinues() async throws {
        let (connection, transport) = makeConnection()
        try connection.start()

        let task = Task { try await connection.request("m", params: nil) }
        try await waitUntil { transport.sentLines.count == 1 }

        transport.inject(#"{"id":1,"res"#)
        try await waitUntil { connection.malformedLineCount == 1 }

        transport.inject(#"{"id":1,"result":"ok"}"#)
        let result = try await task.value
        XCTAssertEqual(result, .string("ok"))
        XCTAssertEqual(connection.malformedLineCount, 1)
    }

    // 7. 타임아웃(0.2초) → .timeout
    func testTimeoutFailsRequest() async throws {
        let (connection, _) = makeConnection()
        try connection.start()

        do {
            _ = try await connection.request("slow", params: nil, timeout: 0.2)
            XCTFail("타임아웃이 발생해야 함")
        } catch let error as JSONRPCClientError {
            XCTAssertEqual(error, .timeout(method: "slow"))
        }
    }

    // 8. 전송 종료 → 대기 요청 .closed
    func testTransportCloseFailsPendingRequests() async throws {
        let (connection, transport) = makeConnection()
        try connection.start()

        let task = Task { try await connection.request("m", params: nil) }
        try await waitUntil { transport.sentLines.count == 1 }

        transport.simulateClose(.exited(0))
        do {
            _ = try await task.value
            XCTFail("종료된 전송의 요청은 실패해야 함")
        } catch let error as JSONRPCClientError {
            XCTAssertEqual(error, .closed(.exited(0)))
        }
    }

    // 9. cancelAll → .cancelled
    func testCancelAllFailsPendingRequests() async throws {
        let (connection, transport) = makeConnection()
        try connection.start()

        let task = Task { try await connection.request("m", params: nil) }
        try await waitUntil { transport.sentLines.count == 1 }

        connection.cancelAll()
        do {
            _ = try await task.value
            XCTFail("취소된 요청은 실패해야 함")
        } catch let error as JSONRPCClientError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    // 10. 실제 프로세스: 한 줄 읽고 고정 응답 → request 성공
    func testProcessTransportRequestResponse() async throws {
        let script = "read line; printf '%s\\n' '{\"id\":1,\"result\":{\"ok\":true}}'"
        let transport = ProcessLineTransport(executableURL: URL(fileURLWithPath: "/bin/sh"),
                                             arguments: ["-c", script])
        let connection = JSONRPCConnection(transport: transport, defaultTimeout: 5)
        try connection.start()

        let result = try await connection.request("ping", params: nil)
        XCTAssertEqual(result, .object(["ok": .bool(true)]))
        connection.close()
    }

    // 11. 즉시 exit 3 하는 프로세스 → 요청이 .closed(.exited(3))
    func testProcessExitFailsRequest() async throws {
        let transport = ProcessLineTransport(executableURL: URL(fileURLWithPath: "/bin/sh"),
                                             arguments: ["-c", "exit 3"])
        let connection = JSONRPCConnection(transport: transport, defaultTimeout: 5)
        try connection.start()

        // 프로세스가 즉시 종료되므로 종료 이벤트가 반영될 시간을 준다.
        try await Task.sleep(nanoseconds: 500_000_000)

        do {
            _ = try await connection.request("x", params: nil)
            XCTFail("종료된 전송의 요청은 실패해야 함")
        } catch let error as JSONRPCClientError {
            XCTAssertEqual(error, .closed(.exited(3)))
        }
    }

    // 12. stderr 출력은 프로토콜에 영향 없음, stderrLineCount 증가
    func testStderrDoesNotAffectProtocol() async throws {
        let script = "printf 'oops\\n' 1>&2; read line; printf '%s\\n' '{\"id\":1,\"result\":\"pong\"}'"
        let transport = ProcessLineTransport(executableURL: URL(fileURLWithPath: "/bin/sh"),
                                             arguments: ["-c", script])
        let connection = JSONRPCConnection(transport: transport, defaultTimeout: 5)
        try connection.start()

        let result = try await connection.request("ping", params: nil)
        XCTAssertEqual(result, .string("pong"))
        try await waitUntil { transport.stderrLineCount >= 1 }
        connection.close()
    }
}
