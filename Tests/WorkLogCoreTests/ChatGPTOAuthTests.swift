import XCTest
@testable import WorkLogCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ChatGPTOAuthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testInitializationDoesNotReadCredentialsAndAuthorizationUsesDynamicRegistration() async throws {
        let store = FakeOAuthStore()
        let session = makeSession(store: store)
        XCTAssertEqual(store.reads, 0)
        let url = try await session.beginLogin(redirectURI: redirect)
        let query = values(url)
        XCTAssertEqual(url.host, "auth.openai.com")
        XCTAssertEqual(query["client_id"], "dynamic_agent_client")
        XCTAssertEqual(query["agent_name_hint"], "WorkLog")
        XCTAssertEqual(query["resource"], "https://api.openai.com/v1")
        XCTAssertEqual(query["redirect_uri"], redirect.absoluteString)
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertNotEqual(query["code_challenge"], "fake-random-verifier")
        XCTAssertEqual(store.value?.hostID, "urn:uuid:host-1")
        let repeated = try await session.beginLogin(redirectURI: redirect)
        XCTAssertEqual(values(repeated)["ext_agent_host_id"], query["ext_agent_host_id"])
    }

    func testWrongStateOrClientIDNeverExchangesCode() async throws {
        let transport = FakeOAuthHTTP([])
        let session = makeSession(store: FakeOAuthStore(value: credentials()), transport: transport)
        _ = try await session.beginLogin(redirectURI: redirect)
        do { try await session.completeLogin(callbackURL: callback(state: "wrong")); XCTFail() }
        catch { XCTAssertEqual((error as? AIProviderError)?.errorClass, .notLoggedIn) }
        do { try await session.completeLogin(callbackURL: callback(client: "oaiapp-other")); XCTFail() }
        catch { XCTAssertEqual((error as? AIProviderError)?.errorClass, .notLoggedIn) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    func testNewRegistrationValidatesIdentityBeforeSavingAndUsesIssuedClientID() async throws {
        let store = FakeOAuthStore()
        let transport = FakeOAuthHTTP([tokenResponse()])
        let validator = FakeOAuthValidator()
        let session = makeSession(store: store, transport: transport, validator: validator)
        _ = try await session.beginLogin(redirectURI: redirect)
        try await session.completeLogin(callbackURL: callback())
        XCTAssertEqual(store.value?.activeClientID, "oaiapp-test")
        XCTAssertEqual(store.value?.registrations.first?.subject, "fake-subject")
        XCTAssertEqual(validator.calls, 1)
        let requests = await transport.requests
        let form = formValues(requests[0])
        XCTAssertEqual(form["client_id"], "oaiapp-test")
        XCTAssertEqual(form["redirect_uri"], redirect.absoluteString)
        XCTAssertNil(form["client_secret"])
        let next = try await session.beginLogin(redirectURI: redirect)
        XCTAssertEqual(values(next)["client_id"], "oaiapp-test")
        XCTAssertNil(values(next)["agent_name_hint"])
    }

    func testInvalidIdentityCannotReplaceCredentials() async throws {
        let store = FakeOAuthStore(value: credentials())
        let session = makeSession(store: store, transport: FakeOAuthHTTP([tokenResponse()]),
                                  validator: FakeOAuthValidator(subject: "another-subject"))
        _ = try await session.beginLogin(redirectURI: redirect)
        do { try await session.completeLogin(callbackURL: callback()); XCTFail() } catch {}
        XCTAssertEqual(store.value?.registrations.first?.accessToken, "fake-access")
    }

    func testMissingPlanScopeKeepsSignInButBlocksInference() async throws {
        let store = FakeOAuthStore()
        let session = makeSession(store: store, transport: FakeOAuthHTTP([tokenResponse(scopes: "openid profile email")]))
        _ = try await session.beginLogin(redirectURI: redirect)
        try await session.completeLogin(callbackURL: callback())
        let status = try await session.accountStatus()
        XCTAssertEqual(status, .loggedIn(accountType: "ChatGPT OAuth", email: "fake@example.invalid", planType: nil))
        do { _ = try await session.accessToken(); XCTFail() }
        catch { XCTAssertEqual((error as? AIProviderError)?.errorClass, .policyRestricted) }
    }

    func testRefreshRotatesTokensAndReusesClientWithoutScope() async throws {
        let store = FakeOAuthStore(value: credentials(expired: true))
        let transport = FakeOAuthHTTP([tokenResponse(access: "fake-renewed", refresh: "fake-rotated")])
        let session = makeSession(store: store, transport: transport)
        let access = try await session.accessToken()
        XCTAssertEqual(access, "fake-renewed")
        XCTAssertEqual(store.value?.registrations.first?.refreshToken, "fake-rotated")
        let requests = await transport.requests
        XCTAssertEqual(formValues(requests[0])["grant_type"], "refresh_token")
        XCTAssertNil(formValues(requests[0])["scope"])
    }

    func testTerminalRefreshFailureClearsTokensButNetworkFailurePreservesThem() async throws {
        for status in [400, 503] {
            let store = FakeOAuthStore(value: credentials(expired: true))
            let body = status == 400 ? "{\"error\":\"invalid_grant\"}" : "{\"detail\":\"unavailable\"}"
            let session = makeSession(store: store, transport: FakeOAuthHTTP([ChatGPTHTTPResponse(status: status, body: Data(body.utf8))]))
            do { _ = try await session.accessToken(); XCTFail() } catch {}
            XCTAssertEqual(store.value?.registrations.first?.accessToken == nil, status == 400)
            XCTAssertEqual(store.value?.activeClientID, "oaiapp-test")
        }
    }

    func testSignOutClearsOnlyTokensAndReportsUnconfirmedRevocation() async throws {
        let store = FakeOAuthStore(value: credentials())
        let session = makeSession(store: store, transport: FakeOAuthHTTP([ChatGPTHTTPResponse(status: 503, body: Data())]))
        let revoked = try await session.signOut()
        XCTAssertFalse(revoked)
        XCTAssertNil(store.value?.registrations.first?.accessToken)
        XCTAssertEqual(store.value?.registrations.first?.clientID, "oaiapp-test")
        XCTAssertEqual(store.value?.hostID, "urn:uuid:fake-host")
    }

    func testProviderUsesPublicResponsesWithNoToolsAndRequiresCompletedEvent() async throws {
        let transport = FakeOAuthHTTP([modelResponse(), ChatGPTHTTPResponse(status: 200, body: Data(Self.completed.utf8))])
        let session = makeSession(store: FakeOAuthStore(value: credentials()), transport: transport)
        let provider = ChatGPTResponsesProvider(session: session, profileResolver: { _ in AITaskProfile(model: "fake-model") })
        let output = try await provider.run(AIJobInput(jobId: "job", jobType: .submissionWeekly,
            instructions: "fake instructions", payloadJSON: "{\"fake\":true}"))
        XCTAssertEqual(output.rawJSON, "{\"ok\":true}")
        let requests = await transport.requests
        let request = requests[1]
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(body["store"], .bool(false)); XCTAssertEqual(body["stream"], .bool(true))
        XCTAssertNil(body["tools"]); XCTAssertNil(body["max_output_tokens"])
        XCTAssertEqual(body["instructions"], .string("fake instructions"))
        XCTAssertEqual(body["text"]?["format"]?["schema"], SubmissionOutputSchema.schema)
    }

    func testTruncatedStreamAndLateQuotaFailureDoNotReturnDraft() throws {
        let delta = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n"
        XCTAssertThrowsError(try ChatGPTResponsesProvider.parseEvents(Data(delta.utf8), model: "fake"))
        let failed = delta + "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}\n\n"
        XCTAssertThrowsError(try ChatGPTResponsesProvider.parseEvents(Data(failed.utf8), model: "fake")) {
            XCTAssertEqual(($0 as? AIProviderError)?.errorClass, .rateLimited)
        }
    }

    func testEligibilityIsPolicyNotQuotaAndDoesNotEchoResponse() {
        let response = ChatGPTHTTPResponse(status: 403, body: Data("{\"error\":{\"code\":\"subscription_sharing_user_not_eligible\",\"message\":\"private fake detail\"}}".utf8))
        let error = ChatGPTResponsesProvider.responseError(response)
        XCTAssertEqual(error.errorClass, .policyRestricted)
        XCTAssertFalse(error.message.contains("private fake detail"))
    }

    func testModelCatalogUsesVisibleEntriesInServerOrder() async throws {
        let body = "{\"models\":[{\"slug\":\"hidden\",\"visibility\":\"hide\"},{\"slug\":\"visible\",\"display_name\":\"Visible\",\"visibility\":\"list\"}]}"
        let session = makeSession(store: FakeOAuthStore(value: credentials()), transport: FakeOAuthHTTP([ChatGPTHTTPResponse(status: 200, body: Data(body.utf8))]))
        let models = try await ChatGPTResponsesProvider(session: session).listAvailableModels()
        XCTAssertEqual(models.map(\.id), ["visible"])
        XCTAssertEqual(models.first?.isDefault, false)
    }

    func testCancelledLoginDuringTokenExchangeDoesNotSaveCredentials() async throws {
        let store = FakeOAuthStore()
        let transport = ControlledOAuthHTTP()
        let session = makeSession(store: store, transport: transport)
        _ = try await session.beginLogin(redirectURI: redirect)
        let callbackURL = callback()
        let login = Task { try await session.completeLogin(callbackURL: callbackURL) }
        await transport.firstRequestStarted()
        await session.cancelLogin()
        await transport.release(tokenResponse())
        do { try await login.value; XCTFail("Cancelled login saved credentials") } catch {}
        XCTAssertTrue(store.value?.registrations.isEmpty == true)
    }

    func testOldRefreshCannotOverwriteNewLogin() async throws {
        let store = FakeOAuthStore(value: credentials(expired: true))
        let transport = ControlledOAuthHTTP(next: [tokenResponse(access: "fake-new-login")])
        let session = makeSession(store: store, transport: transport)
        let refresh = Task { try await session.accessToken() }
        await transport.firstRequestStarted()
        _ = try await session.beginLogin(redirectURI: redirect)
        try await session.completeLogin(callbackURL: callback())
        await transport.release(tokenResponse(access: "fake-stale-refresh"))
        do { _ = try await refresh.value; XCTFail("Old refresh accepted after new login") } catch {}
        XCTAssertEqual(store.value?.registrations.first?.accessToken, "fake-new-login")
    }

    func testConcurrentAccessRefreshesOnce() async throws {
        let store = FakeOAuthStore(value: credentials(expired: true))
        let transport = ControlledOAuthHTTP()
        let session = makeSession(store: store, transport: transport)
        let first = Task { try await session.accessToken() }
        await transport.firstRequestStarted()
        let second = Task { try await session.accessToken() }
        await transport.release(tokenResponse(access: "fake-shared-refresh"))
        let a = try await first.value; let b = try await second.value
        XCTAssertEqual(a, "fake-shared-refresh"); XCTAssertEqual(b, a)
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testOutputCapIsEnforcedBeforeReturningDataForStorage() throws {
        let output = String(repeating: "x", count: 65_537)
        let response = JSONValue.object(["type": .string("response.completed"), "response": .object([
            "status": .string("completed"), "output": .array([.object(["content": .array([
                .object(["type": .string("output_text"), "text": .string(output)])])])])])])
        let json = try JSONEncoder().encode(response)
        let data = Data(("data: " + String(decoding: json, as: UTF8.self) + "\n\n").utf8)
        XCTAssertThrowsError(try ChatGPTResponsesProvider.parseEvents(data, model: "fake", maximumOutputBytes: 65_536)) {
            XCTAssertEqual(($0 as? AIProviderError)?.errorClass, .outputInvalid)
        }
    }

    func testAccountChangeDuringModelLookupNeverSendsInferenceToNewAccount() async throws {
        let store = FakeOAuthStore(value: credentials())
        let transport = ControlledOAuthHTTP(next: [tokenResponse(access: "fake-other-account")])
        let session = makeSession(store: store, transport: transport)
        let provider = ChatGPTResponsesProvider(session: session)
        let job = Task { try await provider.run(AIJobInput(jobId: "fake", jobType: .meetingSummary, instructions: "fake", payloadJSON: "{}")) }
        await transport.firstRequestStarted()
        _ = try await session.beginLogin(redirectURI: redirect, addAccount: true)
        try await session.completeLogin(callbackURL: callback(client: "oaiapp-another"))
        await transport.release(modelResponse())
        do { _ = try await job.value; XCTFail("Account-switched job returned output") }
        catch { XCTAssertEqual((error as? AIProviderError)?.errorClass, .cancelled) }
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.url?.path == "/v1/responses" })
        XCTAssertEqual(store.value?.activeClientID, "oaiapp-another")
    }

    func testSignOutDuringInferenceDiscardsResult() async throws {
        let transport = ControlledOAuthHTTP(next: [modelResponse()], delayedRequest: 2)
        let session = makeSession(store: FakeOAuthStore(value: credentials()), transport: transport)
        let provider = ChatGPTResponsesProvider(session: session)
        let job = Task { try await provider.run(AIJobInput(jobId: "fake", jobType: .meetingSummary, instructions: "fake", payloadJSON: "{}")) }
        await transport.firstRequestStarted()
        _ = try await session.signOut()
        await transport.release(ChatGPTHTTPResponse(status: 200, body: Data(Self.completed.utf8)))
        do { _ = try await job.value; XCTFail("Signed-out job returned a draft") }
        catch { XCTAssertEqual((error as? AIProviderError)?.errorClass, .cancelled) }
    }

    func testBoundRunRejectsAccountChangeBetweenQueueCheckAndProviderEntry() async throws {
        let store = FakeOAuthStore(value: credentials())
        let transport = FakeOAuthHTTP([])
        let session = makeSession(store: store, transport: transport)
        let provider = ChatGPTResponsesProvider(session: session)
        let submitted = await provider.accountGeneration()
        XCTAssertEqual(store.reads, 0, "Reading a queue generation must not access credentials")
        _ = try await session.beginLogin(redirectURI: redirect, addAccount: true)
        do {
            _ = try await provider.run(AIJobInput(jobId: "fake", jobType: .meetingSummary, instructions: "fake", payloadJSON: "{}"),
                                       expectedAccountGeneration: submitted)
            XCTFail("A queued request borrowed the newer login generation")
        } catch { XCTAssertEqual((error as? AIProviderError)?.errorClass, .cancelled) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    func testEveryJobChecksFreshCatalogAndRejectsStalePreferences() async throws {
        for preference in [AITaskProfile(model: "unavailable"), AITaskProfile(model: "fake-model", effort: "ultra")] {
            let transport = FakeOAuthHTTP([modelResponse()])
            let provider = ChatGPTResponsesProvider(session: makeSession(store: FakeOAuthStore(value: credentials()), transport: transport),
                                                    profileResolver: { _ in preference })
            do { _ = try await provider.run(AIJobInput(jobId: "fake", jobType: .meetingSummary, instructions: "fake", payloadJSON: "{}")); XCTFail() }
            catch { XCTAssertEqual((error as? AIProviderError)?.errorClass, .policyRestricted) }
            let requests = await transport.requests
            XCTAssertEqual(requests.map { $0.url?.path }, ["/v1/models"])
        }
        let completed = ChatGPTHTTPResponse(status: 200, body: Data(Self.completed.utf8))
        let transport = FakeOAuthHTTP([modelResponse(), completed, modelResponse(), completed])
        let provider = ChatGPTResponsesProvider(session: makeSession(store: FakeOAuthStore(value: credentials()), transport: transport))
        for id in ["first", "second"] {
            _ = try await provider.run(AIJobInput(jobId: id, jobType: .meetingSummary, instructions: "fake", payloadJSON: "{}"))
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/v1/models", "/v1/responses", "/v1/models", "/v1/responses"])
    }

    private var redirect: URL { URL(string: "http://127.0.0.1:1455/auth/callback")! }
    private func callback(state: String = "fake-random-verifier", client: String = "oaiapp-test") -> URL {
        URL(string: redirect.absoluteString + "?code=fake-code&state=" + state + "&client_id=" + client)!
    }
    private func values(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
    }
    private func formValues(_ request: URLRequest) -> [String: String] {
        values(URL(string: "https://example.invalid/?" + String(decoding: request.httpBody!, as: UTF8.self))!)
    }
    private func credentials(expired: Bool = false) -> ChatGPTOAuthCredentials {
        ChatGPTOAuthCredentials(hostID: "urn:uuid:fake-host", registrations: [ChatGPTOAuthRegistration(
            clientID: "oaiapp-test", subject: "fake-subject", accessToken: "fake-access", refreshToken: "fake-refresh",
            idToken: "fake-id", scopes: ChatGPTOAuthSession.requiredScopes.split(separator: " ").map(String.init),
            expiresAt: now.addingTimeInterval(expired ? -1 : 3600))], activeClientID: "oaiapp-test")
    }
    private func tokenResponse(access: String = "fake-new-access", refresh: String = "fake-new-refresh",
                               scopes: String = ChatGPTOAuthSession.requiredScopes) -> ChatGPTHTTPResponse {
        ChatGPTHTTPResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: ["access_token": access,
            "refresh_token": refresh, "id_token": "fake-id", "token_type": "Bearer", "expires_in": 3600, "scope": scopes]))
    }
    private func modelResponse() -> ChatGPTHTTPResponse {
        ChatGPTHTTPResponse(status: 200, body: Data("{\"models\":[{\"slug\":\"fake-model\",\"display_name\":\"Fake\",\"visibility\":\"list\"}]}".utf8))
    }
    private func makeSession(store: FakeOAuthStore, transport: ChatGPTHTTPTransport = FakeOAuthHTTP([]),
                             validator: FakeOAuthValidator = FakeOAuthValidator()) -> ChatGPTOAuthSession {
        ChatGPTOAuthSession(store: store, transport: transport, identityValidator: validator,
            clock: FixedClock(now), ids: SequentialIDGenerator(prefix: "host"), random: { "fake-random-verifier" })
    }
    private static let completed = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"id\":\"fake-response\",\"model\":\"fake-model\",\"output\":[{\"content\":[{\"type\":\"output_text\",\"text\":\"{\\\"ok\\\":true}\"}]}]}}\n\n"
}

private final class FakeOAuthStore: ChatGPTOAuthCredentialStore, @unchecked Sendable {
    var value: ChatGPTOAuthCredentials?
    var reads = 0
    init(value: ChatGPTOAuthCredentials? = nil) { self.value = value }
    func load() throws -> ChatGPTOAuthCredentials? { reads += 1; return value }
    func save(_ credentials: ChatGPTOAuthCredentials) throws { value = credentials }
}
private actor FakeOAuthHTTP: ChatGPTHTTPTransport {
    var requests: [URLRequest] = []
    var responses: [ChatGPTHTTPResponse]
    init(_ responses: [ChatGPTHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> ChatGPTHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw AIProviderError(.network, "fake offline") }
        return responses.removeFirst()
    }
}
private final class FakeOAuthValidator: ChatGPTIdentityValidator, @unchecked Sendable {
    var calls = 0
    let subject: String
    init(subject: String = "fake-subject") { self.subject = subject }
    func validate(idToken: String, clientID: String, nonce: String, now: Date) async throws -> ChatGPTVerifiedIdentity {
        calls += 1
        return ChatGPTVerifiedIdentity(subject: subject, email: "fake@example.invalid")
    }
}

private actor ControlledOAuthHTTP: ChatGPTHTTPTransport {
    var requests: [URLRequest] = []
    private var continuation: CheckedContinuation<ChatGPTHTTPResponse, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var next: [ChatGPTHTTPResponse]
    private let delayedRequest: Int
    init(next: [ChatGPTHTTPResponse] = [], delayedRequest: Int = 1) { self.next = next; self.delayedRequest = delayedRequest }
    func send(_ request: URLRequest) async throws -> ChatGPTHTTPResponse {
        requests.append(request)
        if requests.count == delayedRequest {
            return await withCheckedContinuation { continuation in
                self.continuation = continuation; started?.resume(); started = nil
            }
        }
        guard !next.isEmpty else { throw AIProviderError(.network, "fake offline") }
        return next.removeFirst()
    }
    func firstRequestStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release(_ response: ChatGPTHTTPResponse) { continuation?.resume(returning: response); continuation = nil }
}
