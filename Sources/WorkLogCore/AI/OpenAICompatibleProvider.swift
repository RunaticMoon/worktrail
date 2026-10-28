import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Chat Completions adapter. Sends supplied text only; no model-controlled file or tool access.
public actor OpenAICompatibleProvider: AIProvider, AIModelCatalogProvider {
    private let settings: AIConnectionSettings
    private let credentials: any ServiceCredentialStore
    private let transport: any ChatGPTHTTPTransport
    private let blockedSkillPathPrefixes: [String]
    private let profileResolver: (@Sendable (AIJobType) throws -> AITaskProfile)?
    private var jobs: [String: Task<AIJobOutput, Error>] = [:]

    public init(settings: AIConnectionSettings, credentials: any ServiceCredentialStore,
                transport: any ChatGPTHTTPTransport = ChatGPTURLSessionTransport(),
                blockedSkillPathPrefixes: [String] = [],
                profileResolver: (@Sendable (AIJobType) throws -> AITaskProfile)? = nil) {
        self.settings = settings; self.credentials = credentials; self.transport = transport
        self.blockedSkillPathPrefixes = blockedSkillPathPrefixes; self.profileResolver = profileResolver
    }
    public func checkCapabilities() async -> AICapabilities {
        AICapabilities(installed: true, protocolCompatible: true, notes: ["OpenAI 호환 Chat Completions API"])
    }
    public func beginOfficialLogin() async throws -> URL? { nil }
    public func listAvailableSkills() async throws -> [DiscoveredSkill] { [] }
    public func getAccountStatus() async throws -> AIAccountState {
        guard try credentials.read(account: settings.credentialAccount())?.isEmpty == false else { return .loggedOut }
        _ = try await listAvailableModels()
        return .loggedIn(accountType: "OpenAI 호환 API", email: nil, planType: nil)
    }
    public func listAvailableModels() async throws -> [DiscoveredAIModel] {
        let response = try await transport.send(authorizedRequest(path: "models"))
        guard response.status == 200 else { throw Self.responseError(response) }
        guard let object = try? JSONDecoder().decode(JSONValue.self, from: response.body),
              let models = object["data"]?.arrayValue else {
            throw AIProviderError(.protocolMismatch, "API 모델 목록 형식이 올바르지 않습니다. 모델 이름을 직접 지정할 수 있습니다.")
        }
        var seen = Set<String>()
        return models.compactMap { item in
            guard let id = item["id"]?.stringValue, !id.isEmpty, seen.insert(id).inserted else { return nil }
            return DiscoveredAIModel(id: id, title: id, isDefault: id == settings.model)
        }
    }
    public func run(_ input: AIJobInput) async throws -> AIJobOutput {
        guard jobs[input.jobId] == nil else { throw AIProviderError(.protocolMismatch, "동일한 AI 작업이 이미 진행 중입니다.") }
        let task = Task { try await perform(input) }
        jobs[input.jobId] = task
        defer { jobs.removeValue(forKey: input.jobId) }
        do {
            return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        } catch is CancellationError { throw AIProviderError(.cancelled, "AI 요청을 취소했습니다.") }
    }
    public func cancel(jobId: String) async { jobs[jobId]?.cancel() }

    private func perform(_ input: AIJobInput) async throws -> AIJobOutput {
        try settings.validate(); try Task.checkCancellation()
        let profile = try profileResolver?(input.jobType) ?? AITaskProfile()
        let model = profile.model ?? settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        var instructions = try ChatGPTSkillInstructions.appending(input.skill, to: input.instructions,
                                                                  blockedPathPrefixes: blockedSkillPathPrefixes)
        instructions += "\nReturn only a JSON object matching the requested output contract."
        if input.jobType == .submissionWeekly {
            let schema = try JSONEncoder().encode(SubmissionOutputSchema.schema)
            instructions += "\nJSON output schema: " + String(decoding: schema, as: UTF8.self)
        }
        var body: [String: JSONValue] = [
            "model": .string(model), "stream": .bool(false),
            "messages": .array([
                .object(["role": .string("system"), "content": .string(instructions)]),
                .object(["role": .string("user"), "content": .string(input.payloadJSON)])
            ]),
            "response_format": .object(["type": .string("json_object")])
        ]
        if let effort = profile.effort { body["reasoning_effort"] = .string(effort) }
        var request = try authorizedRequest(path: "chat/completions")
        request.httpMethod = "POST"; request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        let response = try await transport.send(request)
        try Task.checkCancellation()
        guard response.status == 200 else { throw Self.responseError(response) }
        guard let object = try? JSONDecoder().decode(JSONValue.self, from: response.body),
              let choice = object["choices"]?.arrayValue?.first,
              choice["finish_reason"]?.stringValue == "stop",
              let content = choice["message"]?["content"]?.stringValue, !content.isEmpty,
              content.utf8.count <= (input.jobType == .meetingSummary ? 65_536 : 1_048_576),
              let json = try? JSONDecoder().decode(JSONValue.self, from: Data(content.utf8)),
              case .object = json else {
            throw AIProviderError(.outputInvalid, "API가 완전한 JSON 결과를 반환하지 않았습니다. 초안은 저장하지 않았습니다.")
        }
        return AIJobOutput(rawJSON: content, model: object["model"]?.stringValue ?? model,
                           providerRef: object["id"]?.stringValue)
    }
    private func authorizedRequest(path: String) throws -> URLRequest {
        let endpoint = try settings.endpoint()
        guard let key = try credentials.read(account: settings.credentialAccount()), !key.isEmpty,
              !key.contains("\r"), !key.contains("\n") else {
            throw AIProviderError(.notLoggedIn, "이 API 주소의 키를 설정에서 저장하세요.")
        }
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    static func responseError(_ response: ChatGPTHTTPResponse) -> AIProviderError {
        switch response.status {
        case 401: return AIProviderError(.notLoggedIn, "API 키를 확인하세요.")
        case 402: return AIProviderError(.rateLimited, "API 잔액 또는 크레딧이 부족합니다. 공급자의 결제·사용량을 확인하세요.")
        case 403: return AIProviderError(.policyRestricted, "API 계정 또는 조직 정책에서 요청을 허용하지 않습니다.")
        case 429: return AIProviderError(.rateLimited, "API 요청 한도에 도달했습니다. 공급자의 사용량과 재시도 시각을 확인하세요.")
        case 500...599: return AIProviderError(.network, "API 서버에 연결을 완료하지 못했습니다.")
        default: return AIProviderError(.protocolMismatch, "API 주소·모델·요청 지원 범위를 확인하세요.")
        }
    }
}
