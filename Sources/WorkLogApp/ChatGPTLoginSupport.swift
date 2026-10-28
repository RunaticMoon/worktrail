#if os(macOS)
import AppKit
import Foundation
import Network
import Observation
import Security
import WorkLogCore

/// Only this app's dedicated service/account is read; never imports Codex or company credentials.
final class ChatGPTKeychainCredentialStore: ChatGPTOAuthCredentialStore, @unchecked Sendable {
    private let service: String
    init(service: String) { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "chatgpt-oauth-registrations"]
    }
    func load() throws -> ChatGPTOAuthCredentials? {
        var request = query; request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = try KeychainInteraction.perform(allowUserInteraction: true) {
            SecItemCopyMatching(request as CFDictionary, &result)
        }
        record(status)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = try? JSONDecoder().decode(ChatGPTOAuthCredentials.self, from: data) else {
            throw AIProviderError(.notLoggedIn, "WorkLog의 ChatGPT 인증 저장소를 열 수 없습니다.")
        }
        return value
    }
    func save(_ credentials: ChatGPTOAuthCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        try KeychainInteraction.perform(allowUserInteraction: true) {
            let attributes: [String: Any] = [kSecValueData as String: data]
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var item = query; item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            }
            record(status)
            guard status == errSecSuccess else { throw AIProviderError(.notLoggedIn, "WorkLog의 ChatGPT 인증을 안전하게 저장할 수 없습니다.") }
        }
    }
    private func record(_ status: OSStatus) {
        let expected = status == errSecSuccess || status == errSecItemNotFound
        AppDiagnostics.shared.record(expected ? .operationSucceeded : .operationFailed, category: .keychain,
            level: expected ? .info : .error, fields: [.osStatus: .integer(Int(status))])
    }
}

struct ChatGPTJWKSIdentityValidator: ChatGPTIdentityValidator {
    let transport: ChatGPTHTTPTransport
    init(transport: ChatGPTHTTPTransport) { self.transport = transport }

    func validate(idToken: String, clientID: String, nonce: String, now: Date) async throws -> ChatGPTVerifiedIdentity {
        let response = try await transport.send(URLRequest(url: URL(string: "https://auth.openai.com/.well-known/jwks.json")!))
        guard response.status == 200 else { throw AIProviderError(.network, "ChatGPT 서명 키를 확인할 수 없습니다.") }
        do {
            let identity = try ChatGPTLoginIdentity.validate(idToken: idToken, jwks: response.body,
                clientID: clientID, nonce: nonce, now: now)
            return ChatGPTVerifiedIdentity(subject: identity.subject, email: identity.email)
        } catch {
            throw AIProviderError(.notLoggedIn, "ChatGPT 계정의 서명 또는 로그인 정보 검증에 실패했습니다.")
        }
    }
}

@Observable @MainActor
final class ChatGPTLoginCoordinator {
    private let session: ChatGPTOAuthSession
    private let cancelRequests: @Sendable () async -> Void
    private var listener: ChatGPTLoopbackListener?
    private(set) var isLoggingIn = false
    private(set) var message: String?
    init(session: ChatGPTOAuthSession, cancelRequests: @escaping @Sendable () async -> Void = {}) {
        self.session = session; self.cancelRequests = cancelRequests
    }

    func startLogin(addAccount: Bool = false) async {
        guard !isLoggingIn else { return }
        isLoggingIn = true; message = "브라우저에서 ChatGPT 로그인을 완료하세요."
        await cancelRequests()
        defer { listener?.cancel(); listener = nil; isLoggingIn = false }
        do {
            let receiver = ChatGPTLoopbackListener(); listener = receiver
            let redirect = try await receiver.start()
            let url = try await session.beginLogin(redirectURI: redirect, addAccount: addAccount)
            guard NSWorkspace.shared.open(url) else { throw AIProviderError(.notLoggedIn, "로그인 브라우저를 열 수 없습니다.") }
            let callback = try await receiver.callback()
            try await session.completeLogin(callbackURL: callback)
            message = try await session.hasPlanPermission()
                ? "ChatGPT에 연결했습니다. AI 요청은 ChatGPT 플랜을 사용합니다."
                : "계정에 로그인했지만 ChatGPT 플랜 사용 권한이 없습니다. 조직 정책과 지원 플랜을 확인하세요."
        } catch let error as AIProviderError { message = error.message }
        catch let error as ChatGPTLoopbackError { message = error.localizedDescription }
        catch { message = "ChatGPT 로그인을 완료하지 못했습니다. 다시 시도하세요." }
        await session.cancelLogin()
    }
    func cancel() {
        listener?.cancel()
        Task { await session.cancelLogin() }
    }
    func signOut() async {
        cancel()
        await cancelRequests()
        do {
            let revoked = try await session.signOut()
            message = revoked ? "ChatGPT 연결을 해제했습니다."
                : "이 앱에서 로그아웃했습니다. 원격 해제는 확인되지 않았습니다. ChatGPT 설정에서도 앱 연결을 해제하세요."
        } catch { message = "ChatGPT 인증 저장소에서 연결을 해제하지 못했습니다." }
    }
}

#endif
