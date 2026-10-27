import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import WorkLogCore

final class OpenAICompatibleProviderTests: XCTestCase {
    private let input = AIJobInput(jobId: "fake-job", jobType: .queryPlan,
                                   instructions: "Return the requested plan.", payloadJSON: #"{"question":"fake question"}"#)
    private func response(content: String = #"{"query":"fixture"}"#, finish: String = "stop") throws -> ChatGPTHTTPResponse {
        ChatGPTHTTPResponse(status: 200, body: try JSONEncoder().encode(JSONValue.object([
            "id": .string("fixture-response"), "model": .string("fixture-model"),
            "choices": .array([.object(["finish_reason": .string(finish),
                                        "message": .object(["content": .string(content)])])])
        ])))
    }
    func testDeepSeekRequestUsesSavedEndpointKeyAndJSONContractWithoutTools() async throws {
        let settings = AIConnectionSettings(kind: .openAICompatible, baseURL: "https://api.deepseek.com/v1", model: "fixture-model")
        let credentials = FakeServiceCredentials()
        try credentials.write("fake-key", account: settings.credentialAccount())
        let transport = FakeCompatibleTransport(responses: [try response()])
        let provider = OpenAICompatibleProvider(settings: settings, credentials: credentials, transport: transport)
        let result = try await provider.run(input)
        XCTAssertEqual(result.rawJSON, #"{"query":"fixture"}"#)
        XCTAssertEqual(result.providerRef, "fixture-response")
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-key")
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(body["model"]?.stringValue, "fixture-model")
        XCTAssertEqual(body["response_format"]?["type"]?.stringValue, "json_object")
        XCTAssertEqual(body["messages"]?.arrayValue?.last?["content"]?.stringValue, input.payloadJSON)
        XCTAssertTrue(body["messages"]?.arrayValue?.first?["content"]?.stringValue?.contains("JSON") == true)
        XCTAssertNil(body["tools"])
        XCTAssertNil(body["reasoning_effort"])
    }
    func testIncompleteOrNonJSONOutputIsRejected() async throws {
        for response in [try response(finish: "length"), try response(content: "not JSON"), try response(content: "[]")] {
            let settings = AIConnectionSettings(kind: .openAICompatible)
            let credentials = FakeServiceCredentials()
            try credentials.write("fake-key", account: settings.credentialAccount())
            let provider = OpenAICompatibleProvider(settings: settings, credentials: credentials,
                transport: FakeCompatibleTransport(responses: [response]))
            do { _ = try await provider.run(input); XCTFail("Incomplete output must fail") }
            catch let error as AIProviderError { XCTAssertEqual(error.errorClass, .outputInvalid) }
        }
    }
    func testSubmissionIncludesSchemaAndExplicitModelWithoutDiscovery() async throws {
        let settings = AIConnectionSettings(kind: .openAICompatible)
        let credentials = FakeServiceCredentials()
        try credentials.write("fake-key", account: settings.credentialAccount())
        let transport = FakeCompatibleTransport(responses: [try response()])
        let provider = OpenAICompatibleProvider(settings: settings, credentials: credentials, transport: transport,
            profileResolver: { _ in AITaskProfile(model: "private-model") })
        var weekly = input; weekly.jobType = .submissionWeekly
        _ = try await provider.run(weekly)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1, "Compatible APIs may not implement /models")
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requests.first?.httpBody))
        XCTAssertEqual(body["model"]?.stringValue, "private-model")
        XCTAssertTrue(body["messages"]?.arrayValue?.first?["content"]?.stringValue?.contains("JSON output schema:") == true)
    }
    func testEndpointChangeNeverUsesAnotherHostsCredential() async throws {
        let original = AIConnectionSettings(kind: .openAICompatible)
        var changed = original; changed.baseURL = "https://other.example.invalid/v1"
        let credentials = FakeServiceCredentials()
        try credentials.write("fake-key", account: original.credentialAccount())
        let transport = FakeCompatibleTransport(responses: [try response()])
        let provider = OpenAICompatibleProvider(settings: changed, credentials: credentials, transport: transport)
        do { _ = try await provider.run(input); XCTFail("Key is scoped to endpoint") }
        catch let error as AIProviderError { XCTAssertEqual(error.errorClass, .notLoggedIn) }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }
    func testQuotaAndAuthErrorsAreDistinctAndNeverEchoResponseBody() async throws {
        for (status, expected) in [(401, AIErrorClass.notLoggedIn), (402, .rateLimited), (429, .rateLimited), (403, .policyRestricted)] {
            let error = OpenAICompatibleProvider.responseError(ChatGPTHTTPResponse(status: status,
                body: Data(#"{"error":{"message":"fake-private-value"}}"#.utf8)))
            XCTAssertEqual(error.errorClass, expected)
            XCTAssertFalse(error.message.contains("fake-private-value"))
        }
    }
    func testModelDiscoveryUsesStandardDataAndDeduplicates() async throws {
        let settings = AIConnectionSettings(kind: .openAICompatible, model: "fixture")
        let credentials = FakeServiceCredentials()
        try credentials.write("fake-key", account: settings.credentialAccount())
        let transport = FakeCompatibleTransport(responses: [ChatGPTHTTPResponse(status: 200,
            body: Data(#"{"data":[{"id":"fixture"},{"id":"fixture"},{"id":"second"}]}"#.utf8))])
        let provider = OpenAICompatibleProvider(settings: settings, credentials: credentials, transport: transport)
        let models = try await provider.listAvailableModels()
        XCTAssertEqual(models.map(\.id), ["fixture", "second"])
        XCTAssertEqual(models.first?.isDefault, true)
        XCTAssertEqual(models.first?.supportedEfforts, [])
    }
}

final class FakeServiceCredentials: ServiceCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private(set) var reads = 0
    func read(account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }; reads += 1; return values[account]
    }
    func write(_ credential: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }; values[account] = credential
    }
    func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: account)
    }
}
private actor FakeCompatibleTransport: ChatGPTHTTPTransport {
    var responses: [ChatGPTHTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(responses: [ChatGPTHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> ChatGPTHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw AIProviderError(.network, "fixture exhausted") }
        return responses.removeFirst()
    }
}
