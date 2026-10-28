import Foundation
import Crypto

public enum ActivitySource: String, Codable, CaseIterable, Sendable {
    case github, jira
    public var title: String { self == .github ? "GitHub Enterprise" : "Jira Cloud" }
}

/// Connection metadata only. Tokens are kept in the separate service credential store.
public struct ActivityConnection: Codable, Equatable, Sendable {
    public var source: ActivitySource
    public var enabled = false
    public var baseURL = ""
    public var account = ""
    /// Jira candidate scope. Changelog authorship is checked separately.
    public var jiraJQL = "assignee = currentUser() OR reporter = currentUser() OR worklogAuthor = currentUser()"

    public init(source: ActivitySource) { self.source = source }

    public func endpoint() throws -> URL {
        guard let parts = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let url = parts.url else {
            throw WorkLogError.validation("\(source.title) 주소는 계정·쿼리 없는 HTTPS 주소여야 합니다.")
        }
        return url
    }

    public var credentialAccount: String {
        let canonical = (try? endpoint().absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) ?? baseURL
        let value = "\(source.rawValue)\n\(canonical)\n\(account.trimmingCharacters(in: .whitespacesAndNewlines))"
        return "activity-" + SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func validate() throws {
        _ = try endpoint()
        guard !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !account.contains(where: { $0.isNewline }) else {
            throw WorkLogError.validation("\(source.title)의 계정을 입력하세요.")
        }
        if source == .github, account.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]*$"#, options: .regularExpression) == nil {
            throw WorkLogError.validation("GitHub 사용자 이름을 확인하세요.")
        }
        if source == .jira, jiraJQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw WorkLogError.validation("Jira 수집 범위 JQL을 입력하세요.")
        }
    }
}

public struct ActivityIntegrationSettings: Codable, Equatable, Sendable {
    public var github = ActivityConnection(source: .github)
    public var jira = ActivityConnection(source: .jira)
    public init() {}
    public var connections: [ActivityConnection] { [github, jira] }
}

public struct ActivityIntegrationSettingsStore {
    public static let fileName = "activity-integrations.json"
    private let url: URL
    private let ids: IDGenerator
    public init(dataRoot: URL, ids: IDGenerator = UUIDGenerator()) {
        url = dataRoot.appendingPathComponent(Self.fileName); self.ids = ids
    }
    public func load() throws -> ActivityIntegrationSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        do { return try StableJSON.decode(ActivityIntegrationSettings.self, from: Data(contentsOf: url)) }
        catch { throw WorkLogError.storage("활동 수집 설정을 읽지 못했습니다. 기존 파일은 보존됩니다.") }
    }
    public func save(_ settings: ActivityIntegrationSettings) throws {
        for connection in settings.connections where connection.enabled { try connection.validate() }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let temp = directory.appendingPathComponent(".activity-integrations-\(ids.make())")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard FileManager.default.createFile(atPath: temp.path, contents: try StableJSON.encode(settings),
                                              attributes: [.posixPermissions: 0o600]) else {
            throw WorkLogError.storage("활동 수집 설정을 저장하지 못했습니다.")
        }
        guard rename(temp.path, url.path) == 0 else { throw WorkLogError.storage("활동 수집 설정을 교체하지 못했습니다.") }
    }
}
