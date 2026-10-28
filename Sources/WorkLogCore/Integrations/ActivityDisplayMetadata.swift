import Foundation

public enum ActivityDisplayKind: String, Codable, Sendable {
    case githubPush, githubPullRequest, githubReview
    case jiraCreated, jiraTransition, jiraUpdated, jiraWorklog
    case unknown
}

/// Presentation facts supplied by the source API. Missing facts stay unknown.
/// The original activity title/detail remain separate and are never rewritten from these fields.
public struct ActivityDisplayMetadata: Codable, Hashable, Sendable {
    public var kind: ActivityDisplayKind
    public var repository: String?
    public var title: String?
    public var number: Int?
    public var action: String?
    public var branch: String?
    public var commitCount: Int?
    public var issueKey: String?
    public var statusFrom: String?
    public var statusTo: String?
    public var durationSeconds: Int?
    public var changedFields: [String]

    public init(kind: ActivityDisplayKind, repository: String? = nil, title: String? = nil,
                number: Int? = nil, action: String? = nil, branch: String? = nil,
                commitCount: Int? = nil, issueKey: String? = nil, statusFrom: String? = nil,
                statusTo: String? = nil, durationSeconds: Int? = nil, changedFields: [String] = []) {
        self.kind = kind; self.repository = repository; self.title = title; self.number = number
        self.action = action; self.branch = branch; self.commitCount = commitCount
        self.issueKey = issueKey; self.statusFrom = statusFrom; self.statusTo = statusTo
        self.durationSeconds = durationSeconds; self.changedFields = changedFields
    }

    /// Recognizes only the old importer's exact envelope and source-specific detail format.
    /// `source` must come from imported_activity, never from a user-written body prefix.
    /// A caller with revision history should use the original imported body for edited records.
    public static func legacy(source: ActivitySource, body: String, url: String) -> Self {
        let lines = body.components(separatedBy: "\n")
        guard lines.count >= 3, lines.last == url,
              let endpoint = URLComponents(string: url), endpoint.scheme == "https",
              endpoint.host?.isEmpty == false, endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil else { return .init(kind: .unknown) }
        let details = Array(lines.dropFirst().dropLast())
        switch source {
        case .github: return legacyGitHub(header: lines[0], details: details, path: endpoint.path)
        case .jira: return legacyJira(header: lines[0], details: details, path: endpoint.path)
        }
    }

    private static func legacyGitHub(header: String, details: [String], path: String) -> Self {
        let repoPattern = #"([A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+)"#
        if let values = captures(#"\A\[GitHub Enterprise\] "# + repoPattern + #" PR #([1-9][0-9]*)(?:: (.+))?\z"#, in: header),
           let number = Int(values[1]), path.hasSuffix("/\(values[0])/pull/\(number)"),
           details.count == 1, let action = captures(#"\APR ([a-z_]+)\z"#, in: details[0])?.first {
            let knownActions: Set<String> = ["opened", "closed", "merged", "reopened", "assigned", "unassigned",
                "labeled", "unlabeled", "review", "created", "updated", "submitted", "edited", "dismissed",
                "synchronize", "ready_for_review", "converted_to_draft", "review_requested", "review_request_removed"]
            guard knownActions.contains(action) else { return .init(kind: .unknown) }
            // The old body does not retain the event type; do not invent review-vs-PR provenance.
            return .init(kind: .githubPullRequest, repository: values[0], title: nonempty(values[2]),
                         number: number, action: action)
        }
        if let values = captures(#"\A\[GitHub Enterprise\] "# + repoPattern + #" push\z"#, in: header),
           let ref = details.first.flatMap({ captures(#"\A(refs/(?:heads|tags)/\S+|브랜치) · push\z"#, in: $0)?.first }) {
            let repository = values[0]
            let parts = path.split(separator: "/").map(String.init)
            let repositoryParts = repository.split(separator: "/").map(String.init)
            let isRepository = Array(parts.suffix(2)) == repositoryParts
            let isCommit = parts.count >= 4 && Array(parts.suffix(4).prefix(2)) == repositoryParts
                && parts[parts.count - 2] == "commit" && !parts[parts.count - 1].isEmpty
            guard isRepository || isCommit else { return .init(kind: .unknown) }
            // Commit messages may contain newlines and the old importer truncated them.
            // Neither their line count nor their presence establishes the push's commit count.
            return .init(kind: .githubPush, repository: repository, action: "push",
                         branch: ref == "브랜치" ? nil : branchName(ref))
        }
        return .init(kind: .unknown)
    }

    private static func legacyJira(header: String, details: [String], path: String) -> Self {
        guard let values = captures(#"\A\[Jira Cloud\] ([A-Z][A-Z0-9_]*-[1-9][0-9]*): (.+)\z"#, in: header),
              path.hasSuffix("/browse/\(values[0])") else { return .init(kind: .unknown) }
        let key = values[0], title = values[1]
        if details == ["이슈 생성"] { return .init(kind: .jiraCreated, title: title, issueKey: key) }
        if details.count == 1, captures(#"\A작업 시간 기록: [0-9]+분\z"#, in: details[0]) != nil {
            // The old body rounded down to minutes. Exact seconds cannot be recovered.
            return .init(kind: .jiraWorklog, title: title, issueKey: key)
        }
        var changes: [(field: String, from: String?, to: String?)] = []
        for line in details {
            guard let parts = captures(#"\A([^:\n]+): (.*) → (.*)\z"#, in: line),
                  !parts[1].contains(" → "), !parts[2].contains(" → ") else { return .init(kind: .unknown) }
            changes.append((parts[0], legacyStatus(parts[1]), legacyStatus(parts[2])))
        }
        guard !changes.isEmpty else { return .init(kind: .unknown) }
        let statuses = changes.filter { $0.field.lowercased() == "status" }
        let status = statuses.count == 1 ? statuses[0] : nil
        return .init(kind: status == nil ? .jiraUpdated : .jiraTransition, title: title, issueKey: key,
                     statusFrom: status?.from, statusTo: status?.to, changedFields: changes.map(\.field))
    }

    static func branchName(_ ref: String?) -> String? {
        guard let ref = nonempty(ref) else { return nil }
        return ref.hasPrefix("refs/heads/") ? nonempty(String(ref.dropFirst("refs/heads/".count))) : ref
    }

    static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func legacyStatus(_ value: String) -> String? { value == "—" ? nil : nonempty(value) }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
