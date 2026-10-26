import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Official SIWC direct route. Sends app-supplied text only; no process, shell, file or hosted tools.
public final class ChatGPTResponsesProvider: AIProvider, AIModelCatalogProvider, AIAccountGenerationProvider, @unchecked Sendable {
    public let session: ChatGPTOAuthSession
    private let profileResolver: (@Sendable (AIJobType) throws -> AITaskProfile)?
    private let blockedSkillPathPrefixes: [String]
    private let lock = NSLock()
    private var jobs: [String: Task<AIJobOutput, Error>] = [:]

    public init(session: ChatGPTOAuthSession,
                blockedSkillPathPrefixes: [String] = [],
                profileResolver: (@Sendable (AIJobType) throws -> AITaskProfile)? = nil) {
        self.session = session; self.profileResolver = profileResolver
        self.blockedSkillPathPrefixes = blockedSkillPathPrefixes
    }
    public func checkCapabilities() async -> AICapabilities {
        AICapabilities(installed: true, protocolCompatible: true,
                       notes: ["ChatGPT OAuth · CLI 설치 불필요. Enterprise 플랜 사용은 공식 문서에서 보장되지 않습니다."])
    }
    public func getAccountStatus() async throws -> AIAccountState { try await session.accountStatus() }
    public func beginOfficialLogin() async throws -> URL? { nil } // The macOS coordinator owns the listener.
    public func listAvailableSkills() async throws -> [DiscoveredSkill] { [] }

    public func listAvailableModels() async throws -> [DiscoveredAIModel] {
        let authorization = try await session.authorization()
        return try await listAvailableModels(authorization: authorization)
    }

    private func listAvailableModels(authorization: ChatGPTAuthorization) async throws -> [DiscoveredAIModel] {
        try await session.validateAuthorization(authorization)
        var request = URLRequest(url: URL(string: ChatGPTOAuthSession.resource + "/models")!)
        request.setValue("Bearer " + authorization.accessToken, forHTTPHeaderField: "Authorization")
        let response = try await session.transport.send(request)
        try await session.validateAuthorization(authorization)
        try Task.checkCancellation()
        guard response.status == 200 else { throw Self.responseError(response) }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: response.body),
              let entries = json["models"]?.arrayValue else {
            throw AIProviderError(.protocolMismatch, "ChatGPT 모델 목록 형식이 올바르지 않습니다.")
        }
        var models: [DiscoveredAIModel] = []
        for entry in entries where entry["visibility"]?.stringValue == "list" {
            guard let slug = entry["slug"]?.stringValue, !slug.isEmpty,
                  !models.contains(where: { $0.id == slug }) else { continue }
            models.append(DiscoveredAIModel(id: slug, title: entry["display_name"]?.stringValue ?? slug,
                isDefault: entry["is_default"]?.boolValue ?? false,
                supportedEfforts: entry["supported_reasoning_levels"]?.arrayValue?.compactMap { $0["effort"]?.stringValue } ?? [],
                defaultEffort: entry["default_reasoning_level"]?.stringValue))
        }
        return models
    }

    public func run(_ input: AIJobInput) async throws -> AIJobOutput {
        try await run(input, expectedGeneration: nil)
    }
    public func accountGeneration() async -> Int { await session.accountGeneration() }
    public func run(_ input: AIJobInput, expectedAccountGeneration: Int) async throws -> AIJobOutput {
        try await run(input, expectedGeneration: expectedAccountGeneration)
    }
    private func run(_ input: AIJobInput, expectedGeneration: Int?) async throws -> AIJobOutput {
        let task = withLock { () -> Task<AIJobOutput, Error>? in
            guard jobs[input.jobId] == nil else { return nil }
            let task = Task { try await self.perform(input, expectedGeneration: expectedGeneration) }
            jobs[input.jobId] = task; return task
        }
        guard let task else { throw AIProviderError(.protocolMismatch, "동일한 AI 작업이 이미 진행 중입니다.") }
        defer { _ = withLock { jobs.removeValue(forKey: input.jobId) } }
        do { return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() }) }
        catch is CancellationError { throw AIProviderError(.cancelled, "AI 요청을 취소했습니다.") }
    }
    public func cancel(jobId: String) async { withLock { jobs[jobId] }?.cancel() }
    public func cancelAll() async { withLock { Array(jobs.values) }.forEach { $0.cancel() } }

    private func perform(_ input: AIJobInput, expectedGeneration: Int?) async throws -> AIJobOutput {
        try Task.checkCancellation()
        let instructions = try ChatGPTSkillInstructions.appending(input.skill, to: input.instructions,
                                                                 blockedPathPrefixes: blockedSkillPathPrefixes)
        let preference = try profileResolver?(input.jobType) ?? AITaskProfile()
        if let expectedGeneration, await session.accountGeneration() != expectedGeneration {
            throw AIProviderError(.cancelled, "대기 중 ChatGPT 계정 연결이 변경되어 요청을 취소했습니다.")
        }
        let authorization = try await session.authorization()
        if let expectedGeneration, authorization.generation != expectedGeneration {
            throw AIProviderError(.cancelled, "대기 중 ChatGPT 계정 연결이 변경되어 요청을 취소했습니다.")
        }
        let models = try await listAvailableModels(authorization: authorization)
        if let explicit = preference.model, !models.contains(where: { $0.id == explicit }) {
            throw AIProviderError(.policyRestricted, "저장된 모델은 현재 ChatGPT 계정에서 사용할 수 없습니다. 작업별 모델 설정을 변경하세요.")
        }
        let catalog = AITaskProfiles(profiles: [input.jobType.rawValue: preference], models: models)
        if let effort = preference.effort, let selected = catalog.selectedModel(for: input.jobType),
           !selected.supportedEfforts.contains(effort) {
            throw AIProviderError(.policyRestricted, "현재 모델에서 저장된 추론 강도를 확인할 수 없습니다. 작업별 추론 강도를 자동으로 변경하거나 지원 값을 선택하세요.")
        }
        let profile = catalog.executionProfile(for: input.jobType)
        guard let model = profile.model else { throw AIProviderError(.policyRestricted, "사용 가능한 ChatGPT 모델이 없습니다.") }
        try await session.validateAuthorization(authorization)
        try Task.checkCancellation()
        var body: [String: JSONValue] = [
            "model": .string(model), "instructions": .string(instructions),
            "input": .array([.object(["role": .string("user"), "content": .string(input.payloadJSON)])]),
            "store": .bool(false), "stream": .bool(true)
        ]
        if let effort = profile.effort { body["reasoning"] = .object(["effort": .string(effort)]) }
        if input.jobType == .submissionWeekly {
            body["text"] = .object(["format": .object([
                "type": .string("json_schema"), "name": .string("submission_weekly"),
                "strict": .bool(true), "schema": SubmissionOutputSchema.schema
            ])])
        }
        var request = URLRequest(url: URL(string: ChatGPTOAuthSession.resource + "/responses")!)
        request.httpMethod = "POST"; request.timeoutInterval = 600
        request.setValue("Bearer " + authorization.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        let response = try await session.transport.send(request)
        try await session.validateAuthorization(authorization)
        guard response.status == 200 else { throw Self.responseError(response) }
        try Task.checkCancellation()
        return try Self.parseEvents(response.body, model: model,
                                    maximumOutputBytes: input.jobType == .meetingSummary ? 65_536 : 1_048_576)
    }

    /// An EOF or output-text delta is never success; the terminal completed event is mandatory.
    static func parseEvents(_ data: Data, model: String, maximumOutputBytes: Int = 1_048_576) throws -> AIJobOutput {
        guard let text = String(data: data, encoding: .utf8) else { throw AIProviderError(.protocolMismatch, "AI 스트림 문자 인코딩이 올바르지 않습니다.") }
        var result = ""; var completed: JSONValue?
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for block in normalized.components(separatedBy: "\n\n") {
            let payload = block.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }
                .map { line in String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            if payload.isEmpty || payload == "[DONE]" { continue }
            guard let event = try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)),
                  let type = event["type"]?.stringValue else { throw AIProviderError(.protocolMismatch, "AI 스트림 이벤트를 읽을 수 없습니다.") }
            switch type {
            case "response.output_text.delta": result += event["delta"]?.stringValue ?? ""
            case "response.completed":
                guard event["response"]?["status"]?.stringValue == "completed" else {
                    throw AIProviderError(.outputInvalid, "AI 응답이 완료되지 않았습니다.")
                }
                completed = event["response"]
            case "response.failed", "error":
                let error = event["response"]?["error"] ?? event["error"] ?? event
                throw responseError(ChatGPTHTTPResponse(status: 400, body: try JSONEncoder().encode(JSONValue.object(["error": error]))))
            case "response.incomplete": throw AIProviderError(.outputInvalid, "AI 응답이 중간에 종료되었습니다. 초안은 저장하지 않았습니다.")
            default: break
            }
            guard result.utf8.count <= maximumOutputBytes else { throw AIProviderError(.outputInvalid, "AI 결과가 저장 가능한 크기를 초과했습니다.") }
        }
        guard let completed else { throw AIProviderError(.network, "AI 스트림이 완료 전에 끊겼습니다. 초안은 저장하지 않았습니다.") }
        // Prefer terminal output to deltas, which may include separate text parts.
        let finalText = completed["output"]?.arrayValue?.flatMap { item in
            item["content"]?.arrayValue?.compactMap { $0["type"]?.stringValue == "output_text" ? $0["text"]?.stringValue : nil } ?? []
        }.joined() ?? ""
        if !finalText.isEmpty { result = finalText }
        guard result.utf8.count <= maximumOutputBytes else { throw AIProviderError(.outputInvalid, "AI 결과가 저장 가능한 크기를 초과했습니다.") }
        guard !result.isEmpty else { throw AIProviderError(.outputInvalid, "AI가 텍스트 결과를 반환하지 않았습니다.") }
        return AIJobOutput(rawJSON: result, model: completed["model"]?.stringValue ?? model, providerRef: completed["id"]?.stringValue)
    }

    /// Use stable error codes, never echo server text that may contain user data or credentials.
    static func responseError(_ response: ChatGPTHTTPResponse) -> AIProviderError {
        let json = try? JSONDecoder().decode(JSONValue.self, from: response.body)
        let code = json?["error"]?["code"]?.stringValue ?? json?["error"]?.stringValue ?? ""
        let category: AIErrorClass
        let message: String
        switch code {
        case "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused":
            category = .authExpired; message = "ChatGPT 인증이 만료되었습니다. 다시 로그인하세요."
        case "subscription_sharing_usage_limit_exceeded":
            category = .rateLimited; message = "ChatGPT 플랜 또는 이 앱의 사용 한도에 도달했습니다. ChatGPT 사용량 설정을 확인하세요."
        case "subscription_sharing_user_not_eligible":
            category = .policyRestricted; message = "선택한 계정·워크스페이스는 앱에서 ChatGPT 플랜을 사용할 수 없습니다. Enterprise 지원과 조직 정책을 확인하세요."
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            category = .network; message = "현재 ChatGPT 사용 가능 여부를 확인할 수 없습니다. 나중에 다시 시도하세요."
        case "subscription_sharing_unsupported_capability", "subscription_sharing_route_not_supported", "invalid_client":
            category = .protocolMismatch; message = "현재 ChatGPT 연결에서 지원되지 않는 요청입니다. 앱 설정을 확인하세요."
        default:
            if response.status == 401 { category = .notLoggedIn; message = "ChatGPT 인증 또는 사용 권한을 확인하세요." }
            else if response.status == 403 { category = .policyRestricted; message = "계정·워크스페이스 정책으로 ChatGPT 요청이 제한되었습니다." }
            else if response.status == 429 { category = .rateLimited; message = "ChatGPT 사용 한도 또는 요청 제한에 도달했습니다. 사용량 설정을 확인하세요." }
            else if response.status >= 500 { category = .network; message = "OpenAI 서비스 연결을 완료하지 못했습니다." }
            else { category = .protocolMismatch; message = "ChatGPT 요청을 처리하지 못했습니다." }
        }
        return AIProviderError(category, message)
    }
    private func withLock<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}
