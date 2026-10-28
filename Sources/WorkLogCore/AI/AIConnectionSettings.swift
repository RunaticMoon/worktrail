import Foundation

public enum AIConnectionKind: String, Codable, CaseIterable, Sendable {
    case codexCLI, openAICompatible
    public var title: String {
        switch self {
        case .codexCLI: return "Codex CLI · Enterprise 포함"
        case .openAICompatible: return "OpenAI 호환 API · DeepSeek"
        }
    }
}

/// Public endpoint/model preferences only. API keys live in the app's credential store.
public struct AIConnectionSettings: Codable, Equatable, Sendable {
    public var kind: AIConnectionKind
    public var baseURL: String
    public var model: String
    public init(kind: AIConnectionKind = .codexCLI, baseURL: String = "https://api.deepseek.com", model: String = "deepseek-flash") {
        self.kind = kind; self.baseURL = baseURL; self.model = model
    }
    public func endpoint() throws -> URL {
        guard let components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url else {
            throw AIProviderError(.protocolMismatch, "API 기본 URL은 인증정보·쿼리 없는 HTTPS 주소여야 합니다.")
        }
        return url
    }
    public func credentialAccount() throws -> String {
        let url = try endpoint()
        return "openai-compatible:" + url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    public func validate() throws {
        guard kind == .openAICompatible else { return }
        _ = try endpoint()
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError(.protocolMismatch, "API에서 사용할 모델 이름을 입력하세요.")
        }
    }
}

public final class AIConnectionSettingsStore: @unchecked Sendable {
    public static let fileName = "ai-connection.json"
    private let fileURL: URL
    private let ids: IDGenerator
    public init(dataRoot: URL, ids: IDGenerator = UUIDGenerator()) {
        fileURL = dataRoot.appendingPathComponent(Self.fileName); self.ids = ids
    }
    public func load() throws -> AIConnectionSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return AIConnectionSettings() }
        do { return try StableJSON.decode(AIConnectionSettings.self, from: Data(contentsOf: fileURL)) }
        catch { throw WorkLogError.storage("AI 연결 설정을 읽을 수 없습니다. 기존 파일을 확인하세요.") }
    }
    public func save(_ settings: AIConnectionSettings, applying: () throws -> Void = {}) throws {
        try settings.validate()
        let previous = FileManager.default.fileExists(atPath: fileURL.path) ? try Data(contentsOf: fileURL) : nil
        try write(StableJSON.encode(settings))
        do { try applying() }
        catch {
            if let previous { try write(previous) } else { try FileManager.default.removeItem(at: fileURL) }
            throw error
        }
    }
    private func write(_ data: Data) throws {
        let fm = FileManager.default, directory = fileURL.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".ai-connection-\(ids.make()).tmp")
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw WorkLogError.storage("AI 연결 설정을 저장할 수 없습니다.")
        }
        defer { try? fm.removeItem(at: temporary) }
        guard rename(temporary.path, fileURL.path) == 0 else {
            throw WorkLogError.storage("AI 연결 설정을 교체할 수 없습니다.")
        }
    }
}
