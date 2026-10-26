import Foundation

@main struct ChatGPTLoopbackCheck {
    @MainActor static func main() async throws {
        let receiver = ChatGPTLoopbackListener(timeoutSeconds: 5)
        let redirect = try await receiver.start()
        guard redirect.host == "127.0.0.1", redirect.path == "/auth/callback", redirect.port != nil else { fatalError("Unexpected callback") }
        let callback = URL(string: redirect.absoluteString + "?state=fake-state&code=fake-code")!
        async let response = URLSession.shared.data(from: callback)
        let received = try await receiver.callback()
        let (_, http) = try await response
        guard received == callback, (http as? HTTPURLResponse)?.statusCode == 200 else { fatalError("Callback mismatch") }
        print("PASS: loopback listener accepts exact callback on a dynamic port")

        let timeout = ChatGPTLoopbackListener(timeoutSeconds: 0.05)
        _ = try await timeout.start()
        do { _ = try await timeout.callback(); fatalError("Expected timeout") }
        catch ChatGPTLoopbackError.timeout { print("PASS: timeout settles callback waiter") }

        let cancelled = ChatGPTLoopbackListener(timeoutSeconds: 5)
        _ = try await cancelled.start()
        cancelled.cancel()
        do { _ = try await cancelled.callback(); fatalError("Expected cancellation") }
        catch ChatGPTLoopbackError.cancelled { print("PASS: cancellation settles callback waiter") }
    }
}
