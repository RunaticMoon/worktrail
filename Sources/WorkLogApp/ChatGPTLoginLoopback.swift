#if os(macOS)
import Foundation
import Network

enum ChatGPTLoopbackError: LocalizedError {
    case unavailable, timeout, cancelled
    var errorDescription: String? {
        switch self {
        case .unavailable: return "로그인 콜백을 열 수 없습니다."
        case .timeout: return "로그인 대기 시간이 만료되었습니다."
        case .cancelled: return "로그인을 취소했습니다."
        }
    }
}

/// Binds only 127.0.0.1. A single exact callback is accepted; the session validates state and PKCE.
@MainActor final class ChatGPTLoopbackListener {
    private let timeoutSeconds: Double
    init(timeoutSeconds: Double = 600) { self.timeoutSeconds = timeoutSeconds }
    private var listener: NWListener?
    private var callbackURI: URL?
    private var ready: CheckedContinuation<URL, Error>?
    private var completion: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private var timeout: Task<Void, Never>?
    private var connections: [NWConnection] = []

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener.port else { return }
                    let url = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!
                    self.callbackURI = url; self.ready?.resume(returning: url); self.ready = nil
                case .failed:
                    self.finish(.failure(ChatGPTLoopbackError.unavailable))
                default: break
                }
            }
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(self?.timeoutSeconds ?? 600)) } catch { return }
            self?.finish(.failure(ChatGPTLoopbackError.timeout))
        }
        return try await withCheckedThrowingContinuation { continuation in
            ready = continuation; listener.start(queue: .main)
        }
    }
    func callback() async throws -> URL {
        if let result { return try result.get() }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { completion = $0 }
        }, onCancel: { Task { @MainActor in self.cancel() } })
    }
    func cancel() { finish(.failure(ChatGPTLoopbackError.cancelled)) }
    private func finish(_ value: Result<URL, Error>) {
        guard result == nil else { return }
        result = value; completion?.resume(with: value); completion = nil
        ready?.resume(with: value); ready = nil
        timeout?.cancel(); listener?.cancel(); connections.forEach { $0.cancel() }; connections.removeAll()
    }
    private func accept(_ connection: NWConnection) {
        guard result == nil, connections.count < 8 else { connection.cancel(); return }
        connections.append(connection); connection.start(queue: .main)
        receive(connection, accumulated: Data())
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                let all = accumulated + (data ?? Data())
                guard all.count <= 16_384, error == nil else { self.close(connection); return }
                guard let text = String(data: all, encoding: .utf8), text.contains("\r\n\r\n") else {
                    if complete { self.close(connection) } else { self.receive(connection, accumulated: all) }
                    return
                }
                let request = text.components(separatedBy: "\r\n")[0].split(separator: " ")
                guard request.count == 3, request[0] == "GET", let base = self.callbackURI,
                      request[1].hasPrefix("/auth/callback?"),
                      let url = URL(string: String(request[1]), relativeTo: base)?.absoluteURL,
                      url.host == "127.0.0.1", url.port == base.port, url.path == base.path else {
                    self.close(connection); return
                }
                let body = "WorkLog is verifying your sign-in. You can return to the app."
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n" + body
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    Task { @MainActor in self.finish(.success(url)) }
                })
            }
        }
    }
    private func close(_ connection: NWConnection) {
        connection.cancel(); connections.removeAll { $0 === connection }
    }
}
#endif
