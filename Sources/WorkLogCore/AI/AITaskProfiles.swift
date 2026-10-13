import Foundation

/// Account-visible model metadata returned by Codex. Contains no account or token data.
public struct DiscoveredAIModel: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var isDefault: Bool
    public var supportedEfforts: [String]
    public var defaultEffort: String?

    public init(id: String, title: String, isDefault: Bool = false,
                supportedEfforts: [String] = [], defaultEffort: String? = nil) {
        self.id = id; self.title = title; self.isDefault = isDefault
        self.supportedEfforts = supportedEfforts; self.defaultEffort = defaultEffort
    }
}

/// Kept separate from AIProvider so existing providers do not need model discovery.
public protocol AIModelCatalogProvider: Sendable {
    func listAvailableModels() async throws -> [DiscoveredAIModel]
}

public struct AIModelOption: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

public typealias AIEffortOption = AIModelOption

public struct AITaskProfile: Codable, Equatable, Sendable {
    /// nil chooses a task-appropriate model from the discovered account catalog.
    public var model: String?
    /// nil selects the task recommendation when the model advertises support for it.
    public var effort: String?
    public init(model: String? = nil, effort: String? = nil) {
        self.model = model; self.effort = effort
    }
}

/// Additive settings document: old settings.json and AIJobInput remain compatible.
public struct AITaskProfiles: Codable, Equatable, Sendable {
    public var profiles: [String: AITaskProfile]
    public var models: [DiscoveredAIModel]

    public init(profiles: [String: AITaskProfile] = [:], models: [DiscoveredAIModel] = []) {
        self.profiles = profiles; self.models = models
    }

    private enum CodingKeys: String, CodingKey { case profiles, models }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try container.decodeIfPresent([String: AITaskProfile].self, forKey: .profiles) ?? [:]
        models = try container.decodeIfPresent([DiscoveredAIModel].self, forKey: .models) ?? []
    }

    public subscript(_ type: AIJobType) -> AITaskProfile {
        get { profiles[type.rawValue] ?? AITaskProfile() }
        set {
            if newValue == AITaskProfile() { profiles.removeValue(forKey: type.rawValue) }
            else { profiles[type.rawValue] = newValue }
        }
    }

    public static func recommendedEffort(for type: AIJobType) -> String {
        switch type {
        case .memoTaskSuggestions, .queryPlan: return "low"
        case .submissionWeekly, .evidenceQuiz, .groundedAnswer: return "medium"
        case .performanceReport: return "high"
        }
    }

    public func selectedModel(for type: AIJobType) -> DiscoveredAIModel? {
        if let id = self[type].model { return models.first { $0.id == id } }
        return automaticModel(for: type)
    }

    /// The automatic option must describe the same catalog-based choice used at execution.
    public func automaticModel(for type: AIJobType) -> DiscoveredAIModel? {
        let preferred: [String]
        switch type {
        case .memoTaskSuggestions, .queryPlan, .evidenceQuiz:
            preferred = ["gpt-6-luna", "gpt-6.1-sol", "gpt-6-sol"]
        case .submissionWeekly, .groundedAnswer, .performanceReport:
            preferred = ["gpt-6.1-sol", "gpt-6-sol"]
        }
        for id in preferred {
            if let model = models.first(where: { $0.id == id }) { return model }
        }
        return models.first { $0.isDefault }
    }

    /// Only send a recommended effort when account-visible metadata confirms support.
    /// Without a catalog, automatic selections defer to the server instead of guessing.
    public func executionProfile(for type: AIJobType) -> AITaskProfile {
        let profile = self[type]
        guard let selected = selectedModel(for: type) else { return profile }
        let desired = profile.effort ?? Self.recommendedEffort(for: type)
        let effort = selected.supportedEfforts.contains(desired) ? desired : selected.defaultEffort
        return AITaskProfile(model: selected.id, effort: effort)
    }

    public static func effortTitle(_ value: String) -> String {
        switch value {
        case "none": return "없음"
        case "minimal": return "최소"
        case "low": return "낮음"
        case "medium": return "보통"
        case "high": return "높음"
        case "xhigh": return "매우 높음"
        default: return value
        }
    }
}

/// Stores only model preferences and public capability metadata. No Secret or credentials.
public final class AITaskProfileStore: @unchecked Sendable {
    public static let fileName = "ai-task-profiles.json"
    private let fileURL: URL
    private let ids: IDGenerator

    public init(dataRoot: URL, ids: IDGenerator = UUIDGenerator()) {
        fileURL = dataRoot.appendingPathComponent(Self.fileName)
        self.ids = ids
    }

    public func load() throws -> AITaskProfiles {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return AITaskProfiles() }
        do { return try StableJSON.decode(AITaskProfiles.self, from: Data(contentsOf: fileURL)) }
        catch { throw WorkLogError.storage("AI 작업 설정을 읽을 수 없습니다. 기존 파일을 확인하세요.") }
    }

    public func save(_ profiles: AITaskProfiles) throws {
        try write(StableJSON.encode(profiles))
    }

    /// Keeps AI preferences unchanged if the app settings/hotkey transaction fails.
    public func save(_ profiles: AITaskProfiles, applying: () throws -> Void) throws {
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        let previous = exists ? try Data(contentsOf: fileURL) : nil
        try save(profiles)
        do { try applying() }
        catch {
            if let previous { try write(previous) }
            else { try FileManager.default.removeItem(at: fileURL) }
            throw error
        }
    }

    private func write(_ data: Data) throws {
        let fm = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".ai-task-profiles-\(ids.make()).tmp")
        guard fm.createFile(atPath: temporary.path, contents: data,
                            attributes: [.posixPermissions: 0o600]) else {
            throw WorkLogError.storage("AI 작업 설정을 저장할 수 없습니다.")
        }
        defer { try? fm.removeItem(at: temporary) }
        guard rename(temporary.path, fileURL.path) == 0 else {
            throw WorkLogError.storage("AI 작업 설정을 교체할 수 없습니다.")
        }
    }
}
