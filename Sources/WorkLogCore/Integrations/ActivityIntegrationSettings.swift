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

    /// Imported-activity identity: the API the events were read from, not the spelling of the
    /// configured address. Equivalent addresses and account casing deduplicate to one record.
    /// Keychain accounts keep using `credentialAccount`, so tokens never move to another host.
    public var importIdentity: String {
        guard let canonical = Self.canonicalAPIBase(try? apiBaseURL()) else { return credentialAccount }
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        // GitHub logins are case-insensitive; Jira accounts may be e-mail addresses.
        let canonicalAccount = source == .github ? trimmed.lowercased() : trimmed
        let value = "\(source.rawValue)\n\(canonical)\n\(canonicalAccount)"
        return "activity-import-" + SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The API root every request for this connection is built on. One definition for the
    /// API client and for `importIdentity`, so equivalent spellings cannot diverge.
    public func apiBaseURL() throws -> URL {
        var base = try normalizedEndpoint()
        switch source {
        case .github:
            // Hosts are case-insensitive; URLComponents keeps the spelling the user typed.
            if base.host?.lowercased() == "github.com" { base = URL(string: "https://api.github.com")! }
            else if base.host?.lowercased() != "api.github.com", !base.path.hasSuffix("/api/v3") {
                base.appendPathComponent("api/v3")
            }
        case .jira:
            if !base.path.hasSuffix("/rest/api/3") { base.appendPathComponent("rest/api/3") }
        }
        return base
    }

    /// Configured address without a trailing slash, as the API paths are appended to it.
    func normalizedEndpoint() throws -> URL {
        var parts = URLComponents(url: try endpoint(), resolvingAgainstBaseURL: false)!
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.url!
    }

    /// Case, default port and trailing slash do not change the API a URL addresses.
    static func canonicalAPIBase(_ url: URL?) -> String? {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = parts.scheme?.lowercased()
        if let host = parts.host { parts.host = host.lowercased() }
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) {
            parts.port = nil
        }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        parts.fragment = nil
        parts.query = nil
        return parts.string
    }

    /// Keychain-account spellings an older build could have hashed for this same API and account:
    /// the entered address, the API base, the service's web root, and the lowercased-host form of
    /// each. Account casing is lowercased for GitHub, whose logins are case-insensitive.
    /// Adoption moves rows written under these keys; every candidate is re-checked against
    /// `importIdentity`, so a different server or account can never be merged in.
    var equivalentCredentialAccounts: [String] {
        guard let apiBase = try? apiBaseURL() else { return [] }
        var urls: [URL] = []
        if let entered = try? endpoint() { urls.append(entered) }
        urls.append(apiBase)
        switch source {
        case .github:
            if Self.canonicalAPIBase(apiBase) == "https://api.github.com" {
                urls.append(URL(string: "https://github.com")!)
            } else if let webRoot = Self.removingSuffix("api/v3", from: apiBase) {
                urls.append(webRoot)
            }
        case .jira:
            if let site = Self.removingSuffix("rest/api/3", from: apiBase) { urls.append(site) }
        }
        let lowered = urls.compactMap(Self.lowercasingHost)
        urls.append(contentsOf: lowered)
        var accounts = [account.trimmingCharacters(in: .whitespacesAndNewlines)]
        if source == .github { accounts.append(accounts[0].lowercased()) }
        var seen = Set<String>()
        var result: [String] = []
        for url in urls {
            for account in accounts {
                var candidate = self
                candidate.baseURL = url.absoluteString
                candidate.account = account
                guard candidate.importIdentity == importIdentity else { continue }
                let key = candidate.credentialAccount
                if seen.insert(key).inserted { result.append(key) }
            }
        }
        return result
    }

    private static func removingSuffix(_ suffix: String, from url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.path.hasSuffix("/" + suffix) else { return nil }
        parts.path = String(parts.path.dropLast(suffix.count + 1))
        return parts.url
    }

    private static func lowercasingHost(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = parts.host else { return nil }
        parts.host = host.lowercased()
        return parts.url
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
