import XCTest
@testable import WorkLogCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private actor ActivityAPIFixtureTransport: ChatGPTHTTPTransport {
    enum FixtureError: Error { case unexpectedRequest }
    var replies: [ChatGPTHTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [ChatGPTHTTPResponse]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> ChatGPTHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw FixtureError.unexpectedRequest }
        return replies.removeFirst()
    }
}

final class ActivityAPIClientTests: XCTestCase {
    private let range = DateRange(start: WorkDate("2026-10-28")!, endExclusive: WorkDate("2026-10-29")!)
    private let calendar = WorkCalendar()
    private func response(_ json: Any, status: Int = 200, headers: [String: String] = [:]) throws -> ChatGPTHTTPResponse {
        .init(status: status, body: try JSONSerialization.data(withJSONObject: json), headers: headers)
    }
    private func connection(_ source: ActivitySource, url: String) -> ActivityConnection {
        var c = ActivityConnection(source: source)
        c.baseURL = url; c.account = source == .github ? "fixture" : "fixture@example.test"; c.enabled = true
        return c
    }
    private func event(_ id: String, type: String, at: String = "2026-10-28T01:00:00Z", actor: String = "fixture", payload: [String: Any] = [:]) -> [String: Any] {
        ["id": id, "type": type, "actor": ["login": actor], "created_at": at, "repo": ["name": "org/repo"], "payload": payload]
    }

    func testGitHubSparsePRPaginationAndKSTDateBoundaries() async throws {
        var first = (0..<98).map { event("watch-\($0)", type: "WatchEvent") }
        first.append(event("pr", type: "PullRequestEvent", at: "2026-10-27T15:00:00Z",
                           payload: ["action": "merged", "number": 42, "pull_request": ["number": 42, "id": 100, "url": "https://ignored.example/pull/42"]]))
        first.append(event("too-early", type: "PushEvent", at: "2026-10-27T14:59:59Z"))
        let second = [event("push", type: "PushEvent", at: "2026-10-28T14:59:59Z", payload: ["ref": "refs/heads/main", "head": "fake-sha"]),
                      event("next-day", type: "PushEvent", at: "2026-10-28T15:00:00Z"),
                      event("other-user", type: "PushEvent", actor: "other")]
        let transport = ActivityAPIFixtureTransport(try [response(["login": "FiXtUrE"]), response(first), response(second)])
        let result = try await ActivityAPIClient(transport: transport).fetch(
            connection: connection(.github, url: "https://git.example.test/api/v3/"), token: "fake-token", range: range, calendar: calendar)
        XCTAssertEqual(result.activities.map(\.id), ["pr", "push"])
        XCTAssertEqual(result.activities[0].title, "org/repo PR #42")
        XCTAssertEqual(result.activities[0].detail, "PR merged")
        XCTAssertEqual(result.activities[0].url, "https://git.example.test/org/repo/pull/42")
        XCTAssertEqual(result.activities[0].display, .init(kind: .githubPullRequest, repository: "org/repo", number: 42, action: "merged"))
        XCTAssertEqual(result.activities[1].url, "https://git.example.test/org/repo/commit/fake-sha")
        XCTAssertEqual(result.activities[1].display, .init(kind: .githubPush, repository: "org/repo", action: "push", branch: "main"))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].url?.path, "/api/v3/user")
        XCTAssertEqual(URLComponents(url: requests[2].url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value, "2")
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token" })
    }

    func testGitHubStopsAtDocumentedEventLimitWithWarning() async throws {
        let page = (0..<100).map { event("\($0)", type: "WatchEvent") }
        let transport = ActivityAPIFixtureTransport(try [response(["login": "fixture"]), response(page), response(page), response(page)])
        let result = try await ActivityAPIClient(transport: transport).fetch(
            connection: connection(.github, url: "https://github.com/"), token: "fake-token", range: range, calendar: calendar)
        XCTAssertTrue(result.activities.isEmpty)
        XCTAssertEqual(result.warnings.count, 1)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "api.github.com" })
    }

    func testGitHubIdentityMustMatchConfiguredAccount() async throws {
        let transport = ActivityAPIFixtureTransport(try [response(["login": "other-user"])])
        do {
            _ = try await ActivityAPIClient(transport: transport).fetch(connection: connection(.github, url: "https://git.example.test"),
                token: "fake-token", range: range, calendar: calendar)
            XCTFail("Expected identity mismatch")
        } catch { XCTAssertTrue(error.localizedDescription.contains("소유자")) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testGitHubDisplayMetadataUsesExplicitMergeReviewAndPushFactsOnly() async throws {
        let events = [
            event("merged", type: "PullRequestEvent", payload: ["action": "closed", "pull_request": ["number": 77, "title": "가짜 개선", "merged": true]]),
            event("closed", type: "PullRequestEvent", payload: ["action": "closed", "number": 78]),
            event("unknown-action", type: "PullRequestEvent", payload: ["number": 79]),
            event("review", type: "PullRequestReviewEvent", payload: ["action": "submitted", "pull_request": ["number": 77, "merged": true]]),
            event("push", type: "PushEvent", payload: ["ref": "refs/heads/feature/test", "size": 25, "commits": [["message": "첫 커밋"], ["message": "다음 커밋"]]]),
            event("sparse-push", type: "PushEvent", payload: ["commits": [["message": "일부 메시지만 제공"]]])
        ]
        let transport = ActivityAPIFixtureTransport(try [response(["login": "fixture"]), response(events)])
        let result = try await ActivityAPIClient(transport: transport).fetch(connection: connection(.github, url: "https://git.example.test"),
            token: "fake-token", range: range, calendar: calendar)
        XCTAssertEqual(result.activities.count, 6)
        XCTAssertEqual(result.activities[0].display, .init(kind: .githubPullRequest, repository: "org/repo", title: "가짜 개선", number: 77, action: "merged"))
        XCTAssertEqual(result.activities[0].detail, "PR merged")
        XCTAssertEqual(result.activities[1].display?.action, "closed")
        XCTAssertNil(result.activities[1].display?.title)
        XCTAssertNil(result.activities[2].display?.action, "Missing action is not an observed review")
        XCTAssertEqual(result.activities[2].detail, "PR review", "Keep the existing original body")
        XCTAssertEqual(result.activities[3].display?.kind, .githubReview)
        XCTAssertEqual(result.activities[3].display?.action, "submitted", "Review on a merged PR is still a review")
        XCTAssertEqual(result.activities[4].display?.branch, "feature/test")
        XCTAssertEqual(result.activities[4].display?.commitCount, 25, "Payload commits can be truncated")
        XCTAssertNil(result.activities[5].display?.branch)
        XCTAssertNil(result.activities[5].display?.commitCount, "Available messages do not establish total count")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2, "Display metadata requires no extra network calls")
    }

    func testJiraScopedGatewayAuthorshipWorklogsAndAllPagination() async throws {
        let issue: [String: Any] = ["id": "100", "key": "TEST-1", "fields": ["summary": "가짜 업무", "created": "2026-10-27T15:00:00.000+0000", "creator": ["accountId": "me"]]]
        func change(_ id: String, author: String, at: String) -> [String: Any] {
            ["id": id, "author": ["accountId": author], "created": at, "items": [["field": "status", "fromString": "Open", "toString": "Done"]]]
        }
        func worklog(_ id: String, author: String) -> [String: Any] {
            ["id": id, "author": ["accountId": author], "started": "2026-10-28T10:00:00.000+0900", "timeSpentSeconds": 3600]
        }
        let transport = ActivityAPIFixtureTransport(try [
            response(["accountId": "me"]), response(["baseUrl": "https://jira.example.test/"]),
            response(["issues": [issue], "isLast": false, "nextPageToken": "page-2"]),
            response(["total": 3, "isLast": false, "values": [change("mine", author: "me", at: "2026-10-28T14:59:59Z"), change("theirs", author: "other", at: "2026-10-28T01:00:00Z")]]),
            response(["total": 3, "isLast": true, "values": [change("tomorrow", author: "me", at: "2026-10-28T15:00:00Z")]]),
            response(["total": 2, "worklogs": [worklog("mine", author: "me")]]),
            response(["total": 2, "worklogs": [worklog("theirs", author: "other")]]),
            response(["issues": [], "isLast": true])
        ])
        let c = connection(.jira, url: "https://api.atlassian.com/ex/jira/fake-cloud/rest/api/3/")
        let result = try await ActivityAPIClient(transport: transport).fetch(connection: c, token: "fake-token", range: range, calendar: calendar)
        XCTAssertEqual(result.activities.map(\.id), ["100:created", "100:change:mine", "100:worklog:mine"])
        XCTAssertEqual(result.activities[0].display, .init(kind: .jiraCreated, title: "가짜 업무", issueKey: "TEST-1"))
        XCTAssertEqual(result.activities[1].display, .init(kind: .jiraTransition, title: "가짜 업무", issueKey: "TEST-1",
            statusFrom: "Open", statusTo: "Done", changedFields: ["status"]))
        XCTAssertEqual(result.activities[2].display, .init(kind: .jiraWorklog, title: "가짜 업무", issueKey: "TEST-1", durationSeconds: 3600))
        XCTAssertTrue(result.activities.allSatisfy { $0.url == "https://jira.example.test/browse/TEST-1" })
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 8)
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "api.atlassian.com" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("fixture@example.test:fake-token".utf8).base64EncodedString() })
        XCTAssertEqual(requests[0].url?.path, "/ex/jira/fake-cloud/rest/api/3/myself")
        let query = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[2].httpBody!) as? [String: Any])
        XCTAssertTrue((query["jql"] as? String)?.contains("updated >= \"2026-10-26\"") == true)
        let lastBody = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[7].httpBody!) as? [String: Any])
        XCTAssertEqual(lastBody["nextPageToken"] as? String, "page-2")
        XCTAssertEqual(URLComponents(url: requests[4].url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "startAt" }?.value, "2")
        XCTAssertEqual(URLComponents(url: requests[6].url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "startAt" }?.value, "1")
    }

    func testJiraDisplayUsesStatusFieldIDAndPreservesUnknownStateNames() async throws {
        let issue: [String: Any] = ["id": "100", "key": "PROJECT-77", "fields": ["summary": "가짜 이슈"]]
        func change(_ id: String, _ items: [[String: Any]]) -> [String: Any] {
            ["id": id, "author": ["accountId": "me"], "created": "2026-10-28T01:00:00Z", "items": items]
        }
        let changes = [
            change("localized", [["field": "상태", "fieldId": "status", "fromString": "검토 대기", "toString": "QA / 보류"],
                                 ["field": "담당자", "fieldId": "assignee", "fromString": "A", "toString": "B"]]),
            change("missing", [["field": "status", "fieldId": "status", "from": "1", "to": "2"]]),
            change("custom", [["field": "status", "fieldId": "customfield_123", "fromString": "A", "toString": "B"]]),
            change("updated", [["field": "summary", "fromString": "이전 제목", "toString": "새 제목"]])
        ]
        let transport = ActivityAPIFixtureTransport(try [response(["accountId": "me"]), response(["issues": [issue], "isLast": true]),
            response(["total": changes.count, "isLast": true, "values": changes]), response(["total": 0, "worklogs": []])])
        let result = try await ActivityAPIClient(transport: transport).fetch(connection: connection(.jira, url: "https://jira.example.test"),
            token: "fake-token", range: range, calendar: calendar)
        XCTAssertEqual(result.activities.count, 4)
        XCTAssertEqual(result.activities[0].display, .init(kind: .jiraTransition, title: "가짜 이슈", issueKey: "PROJECT-77",
            statusFrom: "검토 대기", statusTo: "QA / 보류", changedFields: ["상태", "담당자"]))
        XCTAssertEqual(result.activities[0].detail, "상태: 검토 대기 → QA / 보류\n담당자: A → B")
        XCTAssertEqual(result.activities[1].display?.kind, .jiraTransition)
        XCTAssertNil(result.activities[1].display?.statusFrom); XCTAssertNil(result.activities[1].display?.statusTo)
        XCTAssertEqual(result.activities[1].detail, "status: — → —", "Do not present opaque IDs as state names")
        XCTAssertEqual(result.activities[2].display?.kind, .jiraUpdated, "An explicit custom field ID takes precedence over its label")
        XCTAssertNil(result.activities[2].display?.statusFrom); XCTAssertNil(result.activities[2].display?.statusTo)
        XCTAssertEqual(result.activities[3].display?.changedFields, ["summary"])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4, "Display metadata requires no extra network calls")
    }

    func testJiraRejectsIncompleteAndRepeatedSearchCursors() async throws {
        for replies in [
            try [response(["accountId": "me"]), response(["issues": [], "isLast": false])],
            try [response(["accountId": "me"]), response(["issues": [], "isLast": false, "nextPageToken": "same"]), response(["issues": [], "isLast": false, "nextPageToken": "same"])]
        ] {
            let transport = ActivityAPIFixtureTransport(replies)
            do {
                _ = try await ActivityAPIClient(transport: transport).fetch(connection: connection(.jira, url: "https://jira.example.test/rest/api/3/"),
                    token: "fake-token", range: range, calendar: calendar)
                XCTFail("Expected incomplete pagination to fail without returning partial records")
            } catch { XCTAssertTrue(error.localizedDescription.contains("페이지")) }
        }
    }

    func testJiraRejectsUnsafeServerInfoAndNeverSendsTokenToReturnedHost() async throws {
        for site in ["http://jira.example.test", "https://user:password@jira.example.test", "https://jira.example.test?token=unsafe"] {
            let transport = ActivityAPIFixtureTransport(try [response(["accountId": "me"]), response(["baseUrl": site])])
            do {
                _ = try await ActivityAPIClient(transport: transport).fetch(connection: connection(.jira, url: "https://api.atlassian.com/ex/jira/fake-cloud"),
                    token: "fake-token", range: range, calendar: calendar)
                XCTFail("Expected unsafe browser URL to fail")
            } catch { XCTAssertTrue(error.localizedDescription.contains("HTTPS")) }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 2)
            XCTAssertTrue(requests.allSatisfy { $0.url?.host == "api.atlassian.com" })
        }
    }

    func testJiraOrderByValidationPreservesQuotedSearchText() async throws {
        var c = connection(.jira, url: "https://jira.example.test")
        c.jiraJQL = "project = TEST ORDER BY created DESC"
        let transport = ActivityAPIFixtureTransport([])
        do {
            _ = try await ActivityAPIClient(transport: transport).fetch(connection: c, token: "fake-token", range: range, calendar: calendar)
            XCTFail("Expected ORDER BY instruction")
        } catch { XCTAssertTrue(error.localizedDescription.contains("ORDER BY")) }
        let rejectedRequests = await transport.requests
        XCTAssertTrue(rejectedRequests.isEmpty)
        c.jiraJQL = #"summary ~ "order by""#
        let quoted = ActivityAPIFixtureTransport(try [response(["accountId": "me"]), response(["issues": [], "isLast": true])])
        let result = try await ActivityAPIClient(transport: quoted).fetch(connection: c, token: "fake-token", range: range, calendar: calendar)
        XCTAssertTrue(result.activities.isEmpty)
    }

    func testAuthenticationRateLimitsAndRedirectsExposeNoRawResponseOrToken() async throws {
        let epoch = SQLDate.parse("2026-10-28T15:00:00Z")!.timeIntervalSince1970
        let cases: [(Int, [String: String], String)] = [
            (401, [:], "인증"), (403, [:], "권한"), (429, ["retry-after": "120"], "120초 뒤"),
            (403, ["x-ratelimit-remaining": "0", "x-ratelimit-reset": String(epoch)], "2026-10-29 00:00:00 KST"),
            (302, [:], "최종 API 주소"), (500, [:], "HTTP 500")
        ]
        for (status, headers, expected) in cases {
            let transport = ActivityAPIFixtureTransport(try [response(["message": "unsafe-raw-error fake-token"], status: status, headers: headers)])
            do {
                _ = try await ActivityAPIClient(transport: transport).fetch(connection: connection(.github, url: "https://git.example.test"),
                    token: "fake-token", range: range, calendar: calendar)
                XCTFail("Expected HTTP \(status) failure")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
                XCTAssertFalse(error.localizedDescription.contains("unsafe-raw-error"))
                XCTAssertFalse(error.localizedDescription.contains("fake-token"))
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1, "No automatic retries")
        }
    }
}
