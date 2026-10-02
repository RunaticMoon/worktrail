import Foundation

// 앱 소유 AI 추상 인터페이스. 실제 Codex RPC 이름이 아니다.
// Secret 타입(SecretRow/SecretPayload/SecretMetadata)은 이 경로의 어떤 입력에도 들어갈 수 없다.

/// AI 작업 종류 (05_RUNTIME_PROMPTS의 jobType)
public enum AIJobType: String, Codable, Sendable, CaseIterable {
    case submissionWeekly = "submission_weekly"
    case performanceReport = "performance_report"
    case evidenceQuiz = "evidence_quiz"
    case memoTaskSuggestions = "memo_task_suggestions"
    case queryPlan = "query_plan"
    case groundedAnswer = "grounded_answer"
}

/// AI에 보내는 일반 기록 입력. jobContext/facts/sources는 앱이 만든 JSON 문자열이다.
public struct AIJobInput: Codable, Hashable, Sendable {
    public var jobId: String
    public var jobType: AIJobType
    /// 공통 지침(P-00) + 목적별 지침 + 템플릿 스타일이 합쳐진 프롬프트 본문
    public var instructions: String
    /// 05_RUNTIME_PROMPTS 입력 자료 계약(jobContext/facts/sources/previousReports/template)을 직렬화한 JSON
    public var payloadJSON: String
    /// 선택한 기존 Codex 스킬 (없으면 앱 기본 지침만으로 실행)
    public var skill: SkillRef?
    public init(jobId: String, jobType: AIJobType, instructions: String, payloadJSON: String, skill: SkillRef? = nil) {
        self.jobId = jobId; self.jobType = jobType; self.instructions = instructions
        self.payloadJSON = payloadJSON; self.skill = skill
    }
}

public struct SkillRef: Codable, Hashable, Sendable {
    public var name: String
    public var path: String?
    /// 실행 시점의 스킬 파일 해시 (변경 감지·출처 기록)
    public var contentHash: String?
    public init(name: String, path: String? = nil, contentHash: String? = nil) {
        self.name = name; self.path = path; self.contentHash = contentHash
    }
}

public struct AIJobOutput: Codable, Hashable, Sendable {
    /// 모델이 반환한 JSON 텍스트 (검증 전)
    public var rawJSON: String
    public var model: String?
    public var providerRef: String?
    public init(rawJSON: String, model: String? = nil, providerRef: String? = nil) {
        self.rawJSON = rawJSON; self.model = model; self.providerRef = providerRef
    }
}

public struct AIProviderError: Error, Equatable, Sendable {
    public var errorClass: AIErrorClass
    public var message: String
    public init(_ errorClass: AIErrorClass, _ message: String) {
        self.errorClass = errorClass; self.message = message
    }
}

public enum AIAccountState: Equatable, Sendable {
    case unknown
    case notInstalled
    case loggedOut
    /// 계정 종류·이메일 등 app-server가 제공한 범위만 표시. 확인 못한 권한은 nil.
    case loggedIn(accountType: String?, email: String?, planType: String?)
}

public struct AICapabilities: Equatable, Sendable {
    public var installed: Bool
    public var version: String?
    public var protocolCompatible: Bool
    public var notes: [String]
    public init(installed: Bool, version: String? = nil, protocolCompatible: Bool, notes: [String] = []) {
        self.installed = installed; self.version = version
        self.protocolCompatible = protocolCompatible; self.notes = notes
    }
}

public struct DiscoveredSkill: Codable, Hashable, Sendable {
    public var name: String
    public var description: String?
    public var path: String?
    public var enabled: Bool
    public init(name: String, description: String? = nil, path: String? = nil, enabled: Bool = true) {
        self.name = name; self.description = description; self.path = path; self.enabled = enabled
    }
}

public protocol AIProvider: AnyObject, Sendable {
    func checkCapabilities() async -> AICapabilities
    func getAccountStatus() async throws -> AIAccountState
    /// 공식 ChatGPT 로그인 흐름을 시작하고 브라우저에서 열 URL을 반환한다.
    func beginOfficialLogin() async throws -> URL?
    func listAvailableSkills() async throws -> [DiscoveredSkill]
    func run(_ input: AIJobInput) async throws -> AIJobOutput
    func cancel(jobId: String) async
}
