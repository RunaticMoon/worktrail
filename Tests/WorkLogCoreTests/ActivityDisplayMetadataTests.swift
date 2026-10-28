import XCTest
@testable import WorkLogCore

final class ActivityDisplayMetadataTests: XCTestCase {
    func testMetadataRoundTripPreservesExplicitFacts() throws {
        let metadata = ActivityDisplayMetadata(kind: .jiraTransition, title: "사용자 지정 워크플로",
            issueKey: "PROJECT-77", statusFrom: "검토 대기", statusTo: "QA / 보류", changedFields: ["상태", "담당자"])
        XCTAssertEqual(try StableJSON.decode(ActivityDisplayMetadata.self, from: StableJSON.encode(metadata)), metadata)
        let unknown = ActivityDisplayMetadata(kind: .unknown)
        XCTAssertNil(unknown.action); XCTAssertNil(unknown.statusFrom); XCTAssertNil(unknown.statusTo)
        XCTAssertEqual(unknown.changedFields, [])
    }

    func testLegacyPullRequestPreservesOnlyExplicitAction() {
        let url = "https://git.example.test/org/repo/pull/77"
        for action in ["merged", "closed", "opened"] {
            let value = ActivityDisplayMetadata.legacy(source: .github,
                body: "[GitHub Enterprise] org/repo PR #77: 가짜 개선\nPR \(action)\n\(url)", url: url)
            XCTAssertEqual(value.kind, .githubPullRequest)
            XCTAssertEqual(value.repository, "org/repo"); XCTAssertEqual(value.number, 77)
            XCTAssertEqual(value.title, "가짜 개선"); XCTAssertEqual(value.action, action)
        }
        let sparse = ActivityDisplayMetadata.legacy(source: .github,
            body: "[GitHub Enterprise] org/repo PR #77\nPR closed\n\(url)", url: url)
        XCTAssertNil(sparse.title); XCTAssertEqual(sparse.action, "closed")
    }

    func testLegacyPushDoesNotCountCommitMessageLines() {
        let url = "https://git.example.test/org/repo/commit/fake-sha"
        let value = ActivityDisplayMetadata.legacy(source: .github,
            body: "[GitHub Enterprise] org/repo push\nrefs/heads/feature/test · push\n첫 커밋\n여러 줄 메시지\n\(url)", url: url)
        XCTAssertEqual(value.kind, .githubPush); XCTAssertEqual(value.repository, "org/repo")
        XCTAssertEqual(value.branch, "feature/test"); XCTAssertNil(value.commitCount)
        let unknownBranch = ActivityDisplayMetadata.legacy(source: .github,
            body: "[GitHub Enterprise] org/repo push\n브랜치 · push\n\(url)", url: url)
        XCTAssertEqual(unknownBranch.kind, .githubPush); XCTAssertNil(unknownBranch.branch)
    }

    func testLegacyJiraTransitionKeepsCustomAndMissingStates() {
        let url = "https://jira.example.test/browse/PROJECT-77"
        let value = ActivityDisplayMetadata.legacy(source: .jira,
            body: "[Jira Cloud] PROJECT-77: 가짜 이슈\nstatus: 검토 대기 → QA / 보류\nassignee: 이전 담당자 → 새 담당자\n\(url)", url: url)
        XCTAssertEqual(value.kind, .jiraTransition); XCTAssertEqual(value.issueKey, "PROJECT-77")
        XCTAssertEqual(value.title, "가짜 이슈"); XCTAssertEqual(value.statusFrom, "검토 대기")
        XCTAssertEqual(value.statusTo, "QA / 보류"); XCTAssertEqual(value.changedFields, ["status", "assignee"])
        let missing = ActivityDisplayMetadata.legacy(source: .jira,
            body: "[Jira Cloud] PROJECT-77: 가짜 이슈\nstatus: — → \n\(url)", url: url)
        XCTAssertEqual(missing.kind, .jiraTransition)
        XCTAssertNil(missing.statusFrom); XCTAssertNil(missing.statusTo)
    }

    func testLegacyJiraCreationUpdatesAndRoundedWorklog() {
        let url = "https://jira.example.test/browse/PROJECT-77"
        func parse(_ detail: String) -> ActivityDisplayMetadata {
            .legacy(source: .jira, body: "[Jira Cloud] PROJECT-77: 가짜 이슈\n\(detail)\n\(url)", url: url)
        }
        XCTAssertEqual(parse("이슈 생성").kind, .jiraCreated)
        let update = parse("summary: 이전 제목 → 새 제목")
        XCTAssertEqual(update.kind, .jiraUpdated); XCTAssertEqual(update.changedFields, ["summary"])
        let worklog = parse("작업 시간 기록: 60분")
        XCTAssertEqual(worklog.kind, .jiraWorklog); XCTAssertNil(worklog.durationSeconds)
        // Localized labels alone do not prove that this was the built-in status field.
        XCTAssertEqual(parse("상태: A → B").kind, .jiraUpdated)
    }

    func testLegacyUserEditsAndMismatchedURLsFallBackWithoutInventingFacts() {
        let url = "https://git.example.test/org/repo/pull/77"
        let bodies = [
            "사용자가 고친 기록",
            "[GitHub Enterprise] org/repo PR #77\nPR closed\n\(url)\n사용자가 덧붙인 메모",
            "[GitHub Enterprise] org/repo PR #78\nPR closed\n\(url)",
            "[GitHub Enterprise] other/repo PR #77\nPR closed\n\(url)",
            "[GitHub Enterprise] org/repo PR #77\nPR maybe_merged\n\(url)",
            "[Jira Cloud] PROJECT-77: 가짜 이슈\n이슈 생성\n\(url)"
        ]
        for body in bodies {
            XCTAssertEqual(ActivityDisplayMetadata.legacy(source: .github, body: body, url: url), .init(kind: .unknown))
        }
        let jiraURL = "https://jira.example.test/browse/PROJECT-77"
        for detail in ["사용자가 바꾼 상태 메모", "status: A → B → C", "status: A → B\n추가 설명"] {
            let value = ActivityDisplayMetadata.legacy(source: .jira,
                body: "[Jira Cloud] PROJECT-77: 가짜 이슈\n\(detail)\n\(jiraURL)", url: jiraURL)
            XCTAssertEqual(value.kind, .unknown)
        }
    }

    func testLegacyRefusesUnsafeURLsAndConflictingStatusLines() {
        for url in ["http://git.example.test/org/repo/pull/77", "https://user:pass@git.example.test/org/repo/pull/77",
                    "https://git.example.test/org/repo/pull/77?token=fake", "https://git.example.test/org/repo/pull/77#fragment"] {
            XCTAssertEqual(ActivityDisplayMetadata.legacy(source: .github,
                body: "[GitHub Enterprise] org/repo PR #77\nPR merged\n\(url)", url: url).kind, .unknown)
        }
        let url = "https://jira.example.test/browse/PROJECT-77"
        let value = ActivityDisplayMetadata.legacy(source: .jira,
            body: "[Jira Cloud] PROJECT-77: 가짜 이슈\nstatus: A → B\nstatus: B → C\n\(url)", url: url)
        XCTAssertEqual(value.kind, .jiraUpdated); XCTAssertNil(value.statusFrom); XCTAssertNil(value.statusTo)
    }
}
