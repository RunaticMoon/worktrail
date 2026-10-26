import Foundation
import Crypto
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// App-owned credentials. Never include this value in work.sqlite, AI payloads or backups.
public struct ChatGPTOAuthRegistration: Codable, Sendable {
    public var clientID: String
    public var subject: String
    public var email: String?
    public var accessToken: String?
    public var refreshToken: String?
    public var idToken: String?
    public var scopes: [String]
    public var expiresAt: Date
    public init(clientID: String, subject: String, email: String? = nil,
                accessToken: String? = nil, refreshToken: String? = nil, idToken: String? = nil,
                scopes: [String] = [], expiresAt: Date) {
        self.clientID = clientID; self.subject = subject; self.email = email
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.idToken = idToken
        self.scopes = scopes; self.expiresAt = expiresAt
    }
}

public struct ChatGPTOAuthCredentials: Codable, Sendable {
    public var hostID: String
    public var registrations: [ChatGPTOAuthRegistration]
    public var activeClientID: String?
    public init(hostID: String, registrations: [ChatGPTOAuthRegistration] = [], activeClientID: String? = nil) {
        self.hostID = hostID; self.registrations = registrations; self.activeClientID = activeClientID
    }
}

public protocol ChatGPTOAuthCredentialStore: Sendable {
    func load() throws -> ChatGPTOAuthCredentials?
    func save(_ credentials: ChatGPTOAuthCredentials) throws
}

public struct ChatGPTHTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public var requestID: String?
    public init(status: Int, body: Data, requestID: String? = nil) {
        self.status = status; self.body = body; self.requestID = requestID
    }
}

public protocol ChatGPTHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> ChatGPTHTTPResponse
}

/// Bounded response collection and redirect rejection protect credentials and memory.
public struct ChatGPTURLSessionTransport: ChatGPTHTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> ChatGPTHTTPResponse {
        try await ChatGPTHTTPDownload(request: request).run()
    }
}

private final class ChatGPTHTTPDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ChatGPTHTTPResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var completed = false
    private var cancelled = false
    private let maximumBytes = 16 * 1_024 * 1_024
    init(request: URLRequest) { self.request = request }
    func run() async throws -> ChatGPTHTTPResponse {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: AIProviderError(.cancelled, "AI 요청을 취소했습니다."))
                    return
                }
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil; config.urlCache = nil
                config.timeoutIntervalForRequest = 600; config.timeoutIntervalForResource = 660
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                self.session = session; self.task = task; self.continuation = continuation
                lock.unlock()
                task.resume()
            }
        }, onCancel: { self.cancel() })
    }
    private func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(AIProviderError(.cancelled, "AI 요청을 취소했습니다.")))
    }
    private func finish(_ result: Result<ChatGPTHTTPResponse, Error>) {
        lock.lock()
        guard !completed, let continuation else { lock.unlock(); return }
        completed = true; self.continuation = nil
        let session = self.session; self.session = nil; self.task = nil
        data.removeAll(keepingCapacity: false)
        lock.unlock()
        session?.invalidateAndCancel()
        continuation.resume(with: result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, response.expectedContentLength <= maximumBytes else {
            completionHandler(.cancel)
            finish(.failure(AIProviderError(.protocolMismatch, "AI 응답 크기 또는 형식이 올바르지 않습니다.")))
            return
        }
        lock.lock(); self.response = http; lock.unlock()
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive newData: Data) {
        lock.lock()
        let tooLarge = data.count + newData.count > maximumBytes
        if !completed && !tooLarge { data.append(newData) }
        lock.unlock()
        if tooLarge { finish(.failure(AIProviderError(.protocolMismatch, "AI 응답이 허용 크기를 초과했습니다."))) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let code = (error as? URLError)?.code
            finish(.failure(AIProviderError(code == .cancelled ? .cancelled : code == .timedOut ? .timeout : .network,
                                            "OpenAI 연결을 완료하지 못했습니다.")))
            return
        }
        lock.lock()
        let result = response.map { ChatGPTHTTPResponse(status: $0.statusCode, body: data,
                                                        requestID: $0.value(forHTTPHeaderField: "x-request-id")) }
        lock.unlock()
        if let result { finish(.success(result)) }
        else { finish(.failure(AIProviderError(.protocolMismatch, "OpenAI HTTP 응답이 없습니다."))) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct ChatGPTVerifiedIdentity: Sendable {
    public var subject: String
    public var email: String?
    public init(subject: String, email: String? = nil) { self.subject = subject; self.email = email }
}

/// Implementations MUST verify the JWS signature and issuer/audience/expiry/nonce before returning.
public protocol ChatGPTIdentityValidator: Sendable {
    func validate(idToken: String, clientID: String, nonce: String, now: Date) async throws -> ChatGPTVerifiedIdentity
}

/// A request stays bound to one login generation and never borrows a newer account's token.
struct ChatGPTAuthorization: Sendable {
    var accessToken: String
    var generation: Int
}

public actor ChatGPTOAuthSession {
    public static let issuer = "https://auth.openai.com"
    public static let resource = "https://api.openai.com/v1"
    public static let requiredScopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    public let transport: ChatGPTHTTPTransport
    private let store: ChatGPTOAuthCredentialStore
    private let identityValidator: ChatGPTIdentityValidator
    private let clock: Clock
    private let ids: IDGenerator
    private let random: @Sendable () -> String
    private var credentials: ChatGPTOAuthCredentials?
    private var pending: PendingLogin?
    private var refreshTask: Task<ChatGPTOAuthRegistration, Error>?
    private var generation = 0

    public init(store: ChatGPTOAuthCredentialStore, transport: ChatGPTHTTPTransport,
                identityValidator: ChatGPTIdentityValidator, clock: Clock = SystemClock(),
                ids: IDGenerator = UUIDGenerator(), random: @escaping @Sendable () -> String = { ChatGPTOAuthSession.randomValue() }) {
        self.store = store; self.transport = transport; self.identityValidator = identityValidator
        self.clock = clock; self.ids = ids; self.random = random
    }

    public static func randomValue() -> String {
        var random = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) }))
    }
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func decodeBase64URL(_ text: String) -> Data? {
        let base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }

    /// Start the loopback listener first. No Codex token file or CLI is consulted.
    public func beginLogin(redirectURI: URL, addAccount: Bool = false) throws -> URL {
        guard redirectURI.scheme == "http", redirectURI.host == "127.0.0.1",
              redirectURI.path == "/auth/callback", redirectURI.port != nil,
              redirectURI.query == nil, redirectURI.fragment == nil else {
            throw AIProviderError(.protocolMismatch, "OAuth 콜백 주소가 올바르지 않습니다.")
        }
        let saved = try load()
        generation += 1
        let registration = addAccount ? nil : saved.registrations.first { $0.clientID == saved.activeClientID }
        let attempt = PendingLogin(state: random(), nonce: random(), verifier: random(),
                                   redirectURI: redirectURI, clientID: registration?.clientID,
                                   subject: registration?.subject, startedAt: clock.now())
        pending = attempt
        var query = [URLQueryItem(name: "client_id", value: attempt.clientID ?? "dynamic_agent_client"),
                     URLQueryItem(name: "ext_agent_host_id", value: saved.hostID),
                     URLQueryItem(name: "response_type", value: "code"),
                     URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
                     URLQueryItem(name: "scope", value: Self.requiredScopes),
                     URLQueryItem(name: "resource", value: Self.resource),
                     URLQueryItem(name: "state", value: attempt.state),
                     URLQueryItem(name: "nonce", value: attempt.nonce),
                     URLQueryItem(name: "code_challenge_method", value: "S256"),
                     URLQueryItem(name: "code_challenge", value: Self.base64URL(Data(SHA256.hash(data: Data(attempt.verifier.utf8)))))]
        if registration == nil { query.append(URLQueryItem(name: "agent_name_hint", value: "WorkLog")) }
        if let idToken = registration?.idToken { query.append(URLQueryItem(name: "id_token_hint", value: idToken)) }
        var components = URLComponents(string: Self.issuer + "/api/accounts/authorize")!
        components.queryItems = query
        return components.url!
    }

    public func cancelLogin() { pending = nil; generation += 1 }

    /// Token-free account boundary for work waiting in AIJobRunner's FIFO queue.
    public func accountGeneration() -> Int { generation }

    public func completeLogin(callbackURL: URL) async throws {
        guard let attempt = pending,
              clock.now().timeIntervalSince(attempt.startedAt) < 600,
              callbackURL.scheme == attempt.redirectURI.scheme, callbackURL.host == attempt.redirectURI.host,
              callbackURL.port == attempt.redirectURI.port, callbackURL.path == attempt.redirectURI.path,
              let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems else {
            throw AIProviderError(.notLoggedIn, "로그인 요청이 없거나 만료되었습니다. 다시 로그인하세요.")
        }
        var values: [String: String] = [:]
        for item in items {
            guard values[item.name] == nil, let value = item.value else {
                throw AIProviderError(.notLoggedIn, "로그인 응답이 올바르지 않습니다.")
            }
            values[item.name] = value
        }
        guard values["state"] == attempt.state else { throw AIProviderError(.notLoggedIn, "로그인 요청 검증에 실패했습니다.") }
        pending = nil // one-time consumption, including declined consent
        if values["error"] != nil { throw AIProviderError(.notLoggedIn, "ChatGPT 로그인을 완료하지 않았습니다.") }
        guard let code = values["code"], !code.isEmpty,
              let clientID = values["client_id"] ?? attempt.clientID,
              clientID != "dynamic_agent_client", !clientID.isEmpty,
              attempt.clientID == nil || attempt.clientID == clientID else {
            throw AIProviderError(.notLoggedIn, "앱의 OAuth 등록을 확인할 수 없습니다.")
        }
        let originalGeneration = generation
        let token = try await tokenRequest(["grant_type": "authorization_code", "client_id": clientID,
                                           "code": code, "code_verifier": attempt.verifier,
                                           "redirect_uri": attempt.redirectURI.absoluteString, "resource": Self.resource])
        guard let idToken = token.id_token else { throw AIProviderError(.notLoggedIn, "계정 확인 토큰이 없습니다.") }
        let identity = try await identityValidator.validate(idToken: idToken, clientID: clientID, nonce: attempt.nonce, now: clock.now())
        guard attempt.subject == nil || identity.subject == attempt.subject, generation == originalGeneration else {
            throw AIProviderError(.notLoggedIn, "선택한 ChatGPT 계정과 로그인 결과가 다릅니다.")
        }
        let registration = ChatGPTOAuthRegistration(clientID: clientID, subject: identity.subject, email: identity.email,
            accessToken: token.access_token, refreshToken: token.refresh_token, idToken: idToken,
            scopes: token.scope.split(separator: " ").map(String.init), expiresAt: clock.now().addingTimeInterval(token.expires_in))
        var saved = try load()
        if let existing = saved.registrations.first(where: { $0.clientID == clientID }), existing.subject != identity.subject {
            throw AIProviderError(.notLoggedIn, "기존 앱 등록과 계정이 일치하지 않습니다.")
        }
        saved.registrations.removeAll { $0.clientID == clientID }
        saved.registrations.append(registration); saved.activeClientID = clientID
        try save(saved)
        generation += 1
        refreshTask?.cancel(); refreshTask = nil
    }

    public func accountStatus() throws -> AIAccountState {
        guard let registration = try active(), registration.accessToken != nil else { return .loggedOut }
        return .loggedIn(accountType: "ChatGPT OAuth", email: registration.email, planType: nil)
    }

    public func hasPlanPermission() throws -> Bool {
        try active()?.scopes.contains("chatgpt.tokens.use.direct") == true
    }

    func authorization() async throws -> ChatGPTAuthorization {
        let expected = generation
        let token = try await accessToken()
        guard generation == expected else { throw AIProviderError(.cancelled, "ChatGPT 계정 연결이 변경되어 요청을 취소했습니다.") }
        return ChatGPTAuthorization(accessToken: token, generation: expected)
    }

    func validateAuthorization(_ authorization: ChatGPTAuthorization) throws {
        guard authorization.generation == generation else {
            throw AIProviderError(.cancelled, "ChatGPT 계정 연결이 변경되어 요청을 취소했습니다.")
        }
    }

    public func accessToken() async throws -> String {
        guard let registration = try active(), let token = registration.accessToken else {
            throw AIProviderError(.notLoggedIn, "설정에서 ChatGPT로 로그인하세요.")
        }
        guard registration.scopes.contains("chatgpt.tokens.use.direct") else {
            throw AIProviderError(.policyRestricted, "이 계정은 앱에서 ChatGPT 플랜을 사용할 권한이 없습니다. Enterprise 지원 여부와 조직 정책을 확인하세요.")
        }
        if registration.expiresAt.timeIntervalSince(clock.now()) > 60 { return token }
        if let refreshTask {
            let expectedGeneration = generation
            let updated = try await refreshTask.value
            guard expectedGeneration == generation else { throw AIProviderError(.cancelled, "계정 연결이 변경되었습니다.") }
            guard updated.scopes.contains("chatgpt.tokens.use.direct"), let access = updated.accessToken else {
                throw AIProviderError(.policyRestricted, "ChatGPT 플랜 사용 권한이 해제되었습니다.")
            }
            return access
        }
        guard let refresh = registration.refreshToken else { throw AIProviderError(.authExpired, "ChatGPT에 다시 로그인하세요.") }
        let originalGeneration = generation
        let task = Task { () throws -> ChatGPTOAuthRegistration in
            let response = try await self.tokenRequest(["grant_type": "refresh_token", "client_id": registration.clientID,
                                                       "refresh_token": refresh, "resource": Self.resource])
            var updated = registration
            updated.accessToken = response.access_token; updated.refreshToken = response.refresh_token ?? refresh
            updated.idToken = response.id_token ?? registration.idToken
            updated.scopes = response.scope.split(separator: " ").map(String.init)
            updated.expiresAt = self.clock.now().addingTimeInterval(response.expires_in)
            return updated
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let updated = try await task.value
            guard originalGeneration == generation else { throw AIProviderError(.cancelled, "계정 연결이 변경되었습니다.") }
            var saved = try load()
            saved.registrations.removeAll { $0.clientID == updated.clientID }; saved.registrations.append(updated)
            try save(saved)
            guard updated.scopes.contains("chatgpt.tokens.use.direct") else {
                throw AIProviderError(.policyRestricted, "ChatGPT 플랜 사용 권한이 해제되었습니다.")
            }
            return updated.accessToken!
        } catch let error as AIProviderError {
            if error.errorClass == .authExpired, originalGeneration == generation { try clearActiveTokens() }
            throw error
        }
    }

    /// False means local sign-out succeeded but server-side revocation was not confirmed.
    @discardableResult public func signOut() async throws -> Bool {
        generation += 1; pending = nil; refreshTask?.cancel(); refreshTask = nil
        let registration = try active()
        try clearActiveTokens()
        guard let registration, let refresh = registration.refreshToken else { return true }
        do {
            let discovery = try await transport.send(URLRequest(url: URL(string: Self.issuer + "/.well-known/openid-configuration")!))
            let document = try JSONDecoder().decode(JSONValue.self, from: discovery.body)
            guard discovery.status == 200, let endpoint = document["revocation_endpoint"]?.stringValue,
                  let url = URL(string: endpoint), url.scheme == "https", url.host == "auth.openai.com" else { return false }
            let response = try await transport.send(Self.formRequest(url: url, values: ["token": refresh,
                "token_type_hint": "refresh_token", "client_id": registration.clientID]))
            return response.status == 200
        } catch { return false }
    }

    private func active() throws -> ChatGPTOAuthRegistration? {
        let saved = try load(); return saved.registrations.first { $0.clientID == saved.activeClientID }
    }
    private func load() throws -> ChatGPTOAuthCredentials {
        if let credentials { return credentials }
        let saved = try store.load() ?? ChatGPTOAuthCredentials(hostID: "urn:uuid:" + ids.make())
        try save(saved); return saved
    }
    private func save(_ value: ChatGPTOAuthCredentials) throws { try store.save(value); credentials = value }
    private func clearActiveTokens() throws {
        var saved = try load()
        if let index = saved.registrations.firstIndex(where: { $0.clientID == saved.activeClientID }) {
            saved.registrations[index].accessToken = nil; saved.registrations[index].refreshToken = nil
            saved.registrations[index].idToken = nil; saved.registrations[index].scopes = []
        }
        try save(saved)
    }
    private func tokenRequest(_ values: [String: String]) async throws -> TokenResponse {
        let response = try await transport.send(Self.formRequest(url: URL(string: Self.issuer + "/api/accounts/oauth/token")!, values: values))
        guard response.status == 200 else { throw ChatGPTResponsesProvider.responseError(response) }
        let token: TokenResponse
        do { token = try JSONDecoder().decode(TokenResponse.self, from: response.body) }
        catch { throw AIProviderError(.protocolMismatch, "OAuth 토큰 응답을 확인할 수 없습니다.") }
        guard token.token_type.lowercased() == "bearer", !token.access_token.isEmpty,
              token.expires_in > 0, token.expires_in.isFinite else { throw AIProviderError(.protocolMismatch, "OAuth 토큰 형식이 올바르지 않습니다.") }
        return token
    }
    static func formRequest(url: URL, values: [String: String]) -> URLRequest {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let body = values.keys.sorted().map { key in
            key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + values[key]!.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&")
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8); return request
    }
    private struct PendingLogin {
        var state: String; var nonce: String; var verifier: String; var redirectURI: URL
        var clientID: String?; var subject: String?; var startedAt: Date
    }
    private struct TokenResponse: Decodable {
        var access_token: String; var refresh_token: String?; var id_token: String?
        var token_type: String; var expires_in: TimeInterval; var scope: String
    }
}
