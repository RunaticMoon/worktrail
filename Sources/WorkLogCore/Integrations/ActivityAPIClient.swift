import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ActivityAPIClient: Sendable {
    private let transport: any ChatGPTHTTPTransport
    public init(transport: any ChatGPTHTTPTransport = ChatGPTURLSessionTransport()) { self.transport = transport }

    public func fetch(connection: ActivityConnection, token: String, range: DateRange,
                      calendar: WorkCalendar) async throws -> ActivityFetchResult {
        try connection.validate()
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !token.contains(where: { $0.isNewline }) else {
            throw WorkLogError.validation("\(connection.source.title) API 토큰을 설정하세요.")
        }
        if connection.source == .github {
            return try await github(connection, token: token, range: range, calendar: calendar)
        }
        return try await jira(connection, token: token, range: range, calendar: calendar)
    }

    private func request<T: Decodable>(_ type: T.Type, _ connection: ActivityConnection, token: String,
                                        path: [String], query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> T {
        try Task.checkCancellation()
        var base = try normalizedEndpoint(connection)
        if connection.source == .github {
            if base.host == "github.com" { base = URL(string: "https://api.github.com")! }
            else if base.host != "api.github.com", !base.path.hasSuffix("/api/v3") {
                base.appendPathComponent("api/v3")
            }
        } else if !base.path.hasSuffix("/rest/api/3") { base.appendPathComponent("rest/api/3") }
        for component in path { base.appendPathComponent(component) }
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 45
        request.setValue("WorkLog-Activity-Import", forHTTPHeaderField: "User-Agent")
        request.setValue(connection.source == .github ? "application/vnd.github+json" : "application/json", forHTTPHeaderField: "Accept")
        let authorization = connection.source == .github ? "Bearer \(token)"
            : "Basic " + Data("\(connection.account.trimmingCharacters(in: .whitespacesAndNewlines)):\(token)".utf8).base64EncodedString()
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let response: ChatGPTHTTPResponse
        do { response = try await transport.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            throw WorkLogError.validation("\(connection.source.title)에 연결하지 못했습니다. 사내망/VPN과 서버 주소를 확인하세요.")
        }
        switch response.status {
        case 200..<300: break
        case 403 where Self.isRateLimit(response), 429:
            throw WorkLogError.validation(Self.rateLimitMessage(source: connection.source, response: response))
        case 401, 403: throw WorkLogError.validation("\(connection.source.title) 인증 또는 읽기 권한을 확인하세요. (HTTP \(response.status))")
        case 300..<400: throw WorkLogError.validation("\(connection.source.title) 주소가 다른 위치로 이동합니다. 최종 API 주소를 설정하세요.")
        default: throw WorkLogError.validation("\(connection.source.title) 수집에 실패했습니다. (HTTP \(response.status))")
        }
        do { return try JSONDecoder().decode(type, from: response.body) }
        catch { throw WorkLogError.validation("\(connection.source.title) 응답 형식이 예상과 다릅니다. 기록은 변경하지 않았습니다.") }
    }

    private func github(_ c: ActivityConnection, token: String, range: DateRange,
                        calendar: WorkCalendar) async throws -> ActivityFetchResult {
        let identity = try await request(GitHubIdentity.self, c, token: token, path: ["user"])
        guard identity.login.lowercased() == c.account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            throw WorkLogError.validation("GitHub 토큰 소유자와 설정한 사용자 이름이 다릅니다.")
        }
        var result = ActivityFetchResult(activities: [])
        for page in 1...3 {
            try Task.checkCancellation()
            let events = try await request([GitHubEvent].self, c, token: token, path: ["users", identity.login, "events"],
                query: [.init(name: "per_page", value: "100"), .init(name: "page", value: String(page))])
            for event in events {
                guard event.actor.login.lowercased() == identity.login.lowercased(),
                      let instant = SQLDate.parse(event.created_at), range.contains(calendar.workDate(of: instant)) else { continue }
                let web = githubWebURL(c).appendingPathComponent(event.repo.name)
                let activity: ImportedActivity?
                switch event.type {
                case "PushEvent":
                    let ref = event.payload.ref ?? "브랜치"
                    let commits = event.payload.commits ?? []
                    let detail = (["\(ref) · push"] + commits.map { String($0.message.prefix(500)) }).joined(separator: "\n")
                    let url = event.payload.head.map { web.appendingPathComponent("commit").appendingPathComponent($0) } ?? web
                    let count = event.payload.size.flatMap { $0 >= 0 ? $0 : nil }
                    activity = .init(id: event.id, occurredAt: instant, title: "\(event.repo.name) push", detail: detail,
                        url: url.absoluteString, display: .init(kind: .githubPush, repository: event.repo.name,
                            action: "push", branch: ActivityDisplayMetadata.branchName(event.payload.ref), commitCount: count))
                case "PullRequestEvent", "PullRequestReviewEvent", "PullRequestReviewCommentEvent":
                    guard let number = event.payload.pull_request?.number ?? event.payload.number else { continue }
                    let pr = event.payload.pull_request
                    let action = pr?.merged == true && event.payload.action == "closed" ? "merged" : (event.payload.action ?? "review")
                    // GitHub's trimmed Events payload omits title/merged on current
                    // servers. Retain the event even when richer PR details are absent.
                    let title = "\(event.repo.name) PR #\(number)" + (pr?.title.map { ": " + $0 } ?? "")
                    let displayAction = pr?.merged == true && event.payload.action == "closed" ? "merged" : event.payload.action
                    activity = .init(id: event.id, occurredAt: instant, title: title,
                        detail: "PR \(action)", url: web.appendingPathComponent("pull/\(number)").absoluteString,
                        display: .init(kind: event.type == "PullRequestEvent" ? .githubPullRequest : .githubReview,
                            repository: event.repo.name, title: pr?.title, number: number, action: displayAction))
                default: activity = nil
                }
                if let activity { result.activities.append(activity) }
            }
            if events.count < 100 { break }
            if page == 3 {
                result.warnings.append("GitHub는 최근 최대 300개 이벤트만 제공합니다. 요청 기간의 일부 기록이 누락될 수 있습니다.")
            }
        }
        return result
    }

    private func githubWebURL(_ connection: ActivityConnection) -> URL {
        var url = try! normalizedEndpoint(connection)
        if url.host == "api.github.com" { return URL(string: "https://github.com")! }
        if url.path.hasSuffix("/api/v3") { url.deleteLastPathComponent(); url.deleteLastPathComponent() }
        return url
    }

    private func normalizedEndpoint(_ connection: ActivityConnection) throws -> URL {
        var parts = URLComponents(url: try connection.endpoint(), resolvingAgainstBaseURL: false)!
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.url!
    }

    private static func isRateLimit(_ response: ChatGPTHTTPResponse) -> Bool {
        if response.headers["x-ratelimit-remaining"] == "0" || response.headers["retry-after"] != nil { return true }
        guard let body = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let message = body["message"] as? String else { return false }
        return message.localizedCaseInsensitiveContains("rate limit")
    }

    private static func rateLimitMessage(source: ActivitySource, response: ChatGPTHTTPResponse) -> String {
        let reset: String
        if let value = response.headers["x-ratelimit-reset"], let epoch = Double(value), epoch.isFinite, epoch > 0 {
            reset = "재설정: " + koreanTime(Date(timeIntervalSince1970: epoch))
        } else if let value = response.headers["retry-after"], let seconds = Double(value), seconds.isFinite, seconds >= 0, seconds <= 31_536_000 {
            reset = "재시도 가능: \(Int(seconds.rounded(.up)))초 뒤"
        } else if let value = response.headers["retry-after"] {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            reset = formatter.date(from: value).map { "재시도 가능: " + koreanTime($0) } ?? "재설정 시각은 확인되지 않았습니다."
        } else { reset = "재설정 시각은 확인되지 않았습니다." }
        return "\(source.title) 요청 한도에 도달했습니다. 자동 재시도 없이 중단했습니다. \(reset)"
    }

    private static func koreanTime(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'KST'"
        return formatter.string(from: date)
    }

    private static func hasOrderBy(_ jql: String) -> Bool {
        var quote: Character?, escaped = false, unquoted = ""
        for character in jql {
            if escaped { escaped = false; unquoted.append(" "); continue }
            if character == "\\" { escaped = true; unquoted.append(" "); continue }
            if let current = quote {
                if character == current { quote = nil }
                unquoted.append(" ")
            } else if character == "\"" || character == "'" { quote = character; unquoted.append(" ") }
            else { unquoted.append(character) }
        }
        return unquoted.range(of: #"\border\s+by\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func jiraWebURL(_ connection: ActivityConnection, token: String) async throws -> URL {
        var url = try normalizedEndpoint(connection)
        if url.host?.lowercased() == "api.atlassian.com" {
            // Scoped tokens use an API gateway, not the site's browser origin.
            // This read still sends credentials exclusively to the configured API.
            let info = try await request(JiraServerInfo.self, connection, token: token, path: ["serverInfo"])
            var site = connection; site.baseURL = info.baseUrl
            do { url = try normalizedEndpoint(site) }
            catch { throw WorkLogError.validation("Jira 사이트의 HTTPS 주소를 확인하지 못했습니다. 기록은 변경하지 않았습니다.") }
        }
        if url.path.hasSuffix("/rest/api/3") { for _ in 0..<3 { url.deleteLastPathComponent() } }
        return url
    }

    private func jira(_ c: ActivityConnection, token: String, range: DateRange,
                      calendar: WorkCalendar) async throws -> ActivityFetchResult {
        guard !Self.hasOrderBy(c.jiraJQL) else {
            throw WorkLogError.validation("Jira JQL에는 ORDER BY를 제외한 검색 조건만 입력하세요. 활동 날짜순 정렬은 자동 적용됩니다.")
        }
        let me = try await request(JiraUser.self, c, token: token, path: ["myself"])
        let web = try await jiraWebURL(c, token: token)
        // JQL date literals use the server user's timezone. Widen the search and filter exact instants locally.
        let lower = calendar.adding(days: -2, to: range.start).iso
        let jql = "(\(c.jiraJQL)) AND updated >= \"\(lower)\" ORDER BY updated ASC"
        var activities: [ImportedActivity] = []
        var cursor: String?
        var seenCursors = Set<String>()
        for page in 0..<100 {
            try Task.checkCancellation()
            var body: [String: Any] = ["jql": jql, "maxResults": 100, "fields": ["summary", "created", "creator"]]
            if let cursor { body["nextPageToken"] = cursor }
            let response = try await request(JiraSearch.self, c, token: token, path: ["search", "jql"], body: body)
            for issue in response.issues {
                let url = web.appendingPathComponent("browse").appendingPathComponent(issue.key).absoluteString
                let title = "\(issue.key): \(issue.fields.summary)"
                if issue.fields.creator?.accountId == me.accountId, let created = issue.fields.created.flatMap(SQLDate.parse),
                   range.contains(calendar.workDate(of: created)) {
                    activities.append(.init(id: "\(issue.id):created", occurredAt: created, title: title, detail: "이슈 생성", url: url,
                        display: .init(kind: .jiraCreated, title: issue.fields.summary, issueKey: issue.key)))
                }
                var start = 0
                for changelogPage in 0..<100 {
                    let changes = try await request(JiraChangelogs.self, c, token: token, path: ["issue", issue.key, "changelog"],
                        query: [.init(name: "startAt", value: String(start)), .init(name: "maxResults", value: "100")])
                    for change in changes.values where change.author?.accountId == me.accountId {
                        guard let instant = SQLDate.parse(change.created), range.contains(calendar.workDate(of: instant)) else { continue }
                        let details = change.items.map { "\($0.field): \($0.fromString ?? "—") → \($0.toString ?? "—")" }.joined(separator: "\n")
                        let statuses = change.items.filter { item in
                            if let fieldID = ActivityDisplayMetadata.nonempty(item.fieldId) { return fieldID == "status" }
                            return item.field.lowercased() == "status"
                        }
                        let status = statuses.count == 1 ? statuses[0] : nil
                        activities.append(.init(id: "\(issue.id):change:\(change.id)", occurredAt: instant,
                            title: title, detail: details, url: url,
                            display: .init(kind: status == nil ? .jiraUpdated : .jiraTransition,
                                title: issue.fields.summary, issueKey: issue.key,
                                statusFrom: ActivityDisplayMetadata.nonempty(status?.fromString),
                                statusTo: ActivityDisplayMetadata.nonempty(status?.toString), changedFields: change.items.map(\.field))))
                    }
                    start += changes.values.count
                    if changes.isLast == true || start >= changes.total { break }
                    if changes.values.isEmpty || changelogPage == 99 { throw incompleteJira() }
                }
                start = 0
                for worklogPage in 0..<100 {
                    let logs = try await request(JiraWorklogs.self, c, token: token, path: ["issue", issue.key, "worklog"],
                        query: [.init(name: "startAt", value: String(start)), .init(name: "maxResults", value: "100")])
                    for log in logs.worklogs where log.author.accountId == me.accountId {
                        guard let instant = SQLDate.parse(log.started), range.contains(calendar.workDate(of: instant)) else { continue }
                        activities.append(.init(id: "\(issue.id):worklog:\(log.id)", occurredAt: instant, title: title,
                            detail: "작업 시간 기록: \(log.timeSpentSeconds / 60)분", url: url,
                            display: .init(kind: .jiraWorklog, title: issue.fields.summary, issueKey: issue.key,
                                durationSeconds: log.timeSpentSeconds >= 0 ? log.timeSpentSeconds : nil)))
                    }
                    start += logs.worklogs.count
                    if start >= logs.total { break }
                    if logs.worklogs.isEmpty || worklogPage == 99 { throw incompleteJira() }
                }
            }
            if response.isLast == true || (response.isLast == nil && response.nextPageToken == nil) { return .init(activities: activities) }
            guard let next = response.nextPageToken, !next.isEmpty, seenCursors.insert(next).inserted, page < 99 else { throw incompleteJira() }
            cursor = next
        }
        throw incompleteJira()
    }

    private func incompleteJira() -> WorkLogError {
        .validation("Jira 결과가 너무 많거나 페이지를 완료하지 못했습니다. JQL 범위를 줄이세요. 부분 기록은 저장하지 않았습니다.")
    }
}

private struct GitHubIdentity: Decodable { let login: String }
private struct GitHubEvent: Decodable {
    let id: String; let type: String; let actor: GitHubIdentity; let created_at: String; let repo: Repo; let payload: Payload
    struct Repo: Decodable { let name: String }
    struct Payload: Decodable {
        let action: String?; let number: Int?; let ref: String?; let head: String?; let size: Int?; let commits: [Commit]?; let pull_request: PR?
    }
    struct Commit: Decodable { let message: String }
    struct PR: Decodable { let number: Int?; let title: String?; let merged: Bool? }
}
private struct JiraServerInfo: Decodable { let baseUrl: String }
private struct JiraUser: Decodable { let accountId: String }
private struct JiraSearch: Decodable {
    let issues: [Issue]; let nextPageToken: String?; let isLast: Bool?
    struct Issue: Decodable { let id: String; let key: String; let fields: Fields }
    struct Fields: Decodable { let summary: String; let created: String?; let creator: JiraUser? }
}
private struct JiraChangelogs: Decodable {
    let values: [Change]; let total: Int; let isLast: Bool?
    struct Change: Decodable { let id: String; let author: JiraUser?; let created: String; let items: [Item] }
    struct Item: Decodable { let field: String; let fieldId: String?; let fromString: String?; let toString: String? }
}
private struct JiraWorklogs: Decodable {
    let worklogs: [Log]; let total: Int
    struct Log: Decodable { let id: String; let author: JiraUser; let started: String; let timeSpentSeconds: Int }
}
