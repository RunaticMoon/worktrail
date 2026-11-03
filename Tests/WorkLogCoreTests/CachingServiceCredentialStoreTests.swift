import XCTest
@testable import WorkLogCore

final class CachingServiceCredentialStoreTests: XCTestCase {
    func testInteractiveApprovalServesLaterBackgroundReadsFromMemory() throws {
        let base = ApprovalGatedCredentials(values: ["github": "fake-token"])
        let store = CachingServiceCredentialStore(base)
        XCTAssertThrowsError(try store.read(account: "github", allowAuthenticationUI: false))
        XCTAssertEqual(store.authorize(accounts: ["github", "github"]), [])
        XCTAssertEqual(try store.read(account: "github", allowAuthenticationUI: false), "fake-token")
        XCTAssertEqual(try store.read(account: "github"), "fake-token")
        XCTAssertEqual(base.reads, [false, true], "Duplicate and cached accounts must not reopen the Keychain")
    }

    func testFailedApprovalIsNotCachedAndMissingItemsAre() throws {
        let base = ApprovalGatedCredentials(values: [:])
        base.denyInteractive = true
        let store = CachingServiceCredentialStore(base)
        base.values["jira"] = "fake-token"
        XCTAssertEqual(store.authorize(accounts: ["jira", "missing"]), ["jira", "missing"])
        XCTAssertEqual(base.reads, [true], "A refused dialog must not be followed by more dialogs")
        base.denyInteractive = false
        XCTAssertEqual(store.authorize(accounts: ["jira", "missing"]), [])
        XCTAssertNil(try store.read(account: "missing"))
        XCTAssertEqual(try store.read(account: "jira"), "fake-token")
        XCTAssertEqual(base.reads, [true, true, true])
    }

    func testWriteAndDeleteUpdateTheCache() throws {
        let base = ApprovalGatedCredentials(values: [:])
        let store = CachingServiceCredentialStore(base)
        try store.write("fake-new", account: "api")
        XCTAssertEqual(try store.read(account: "api"), "fake-new")
        try store.delete(account: "api")
        XCTAssertNil(try store.read(account: "api"))
        XCTAssertEqual(base.reads, [], "Writes and deletes define the cached state without another Keychain read")
        base.failWrites = true
        XCTAssertThrowsError(try store.write("fake-other", account: "api"))
        base.failWrites = false
        base.approved = true
        XCTAssertNil(try store.read(account: "api"), "A failed write must fall back to the stored value")
        XCTAssertEqual(base.reads, [false])
    }
}

/// Mimics the legacy Keychain: background reads fail until an interactive read is approved.
final class ApprovalGatedCredentials: ServiceCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    var values: [String: String]
    var approved = false
    var denyInteractive = false
    var failWrites = false
    private(set) var reads: [Bool] = []
    init(values: [String: String]) { self.values = values }
    func read(account: String) throws -> String? { try read(account: account, allowAuthenticationUI: false) }
    func read(account: String, allowAuthenticationUI: Bool) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        reads.append(allowAuthenticationUI)
        if allowAuthenticationUI && !denyInteractive { approved = true }
        guard approved else { throw AIProviderError(.notLoggedIn, "approval required") }
        return values[account]
    }
    func write(_ credential: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw AIProviderError(.notLoggedIn, "write failed") }
        values[account] = credential
    }
    func delete(account: String) throws { lock.lock(); defer { lock.unlock() }; values[account] = nil }
}
