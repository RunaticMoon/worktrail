import XCTest
@testable import WorkLogCore

final class SecretGroupingTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    @MainActor private func environment() throws -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SecretGroups-\(UUID().uuidString)")
        roots.append(root)
        return try AppEnvironment.open(.init(
            paths: AppPaths(dataRoot: root.appendingPathComponent("data"), backupRoot: root.appendingPathComponent("backup")),
            keyStore: InMemoryVaultKeyStore(), authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(),
            clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_000)), ids: SequentialIDGenerator()))
    }

    @MainActor func testGroupsRemainLocalMetadataAndSuggestionsIgnoreTitleSearch() async throws {
        let env = try environment()
        let model = SecretsModel(environment: env)
        await model.unlock()
        _ = try env.vaultSession.create(title: "A token", groupName: "  Engineering  ", rows: [.init(key: "token", value: "fake-only-a")])
        _ = try env.vaultSession.create(title: "B token", groupName: "Operations", rows: [.init(key: "token", value: "fake-only-b")])
        _ = try env.vaultSession.create(title: "C token", groupName: "Engineering", rows: [])
        _ = try env.vaultSession.create(title: "Unsorted", groupName: nil, rows: [])
        model.searchTitles()
        XCTAssertEqual(model.titleGroups.map(\.label), ["Engineering", "Operations", "그룹 없음"])
        XCTAssertEqual(model.titleGroups.map { $0.items.count }, [2, 1, 1])

        model.query = "A token"
        XCTAssertEqual(model.titles.count, 1)
        model.beginNew()
        model.groupName = "oper"
        XCTAssertEqual(model.groupSuggestions, ["Operations"])
        model.title = "Quick fixture"
        model.groupName = "Operations"
        XCTAssertTrue(model.save())
        XCTAssertEqual(try env.vaultSession.searchTitles("Quick fixture").first?.groupName, "Operations")

        model.lock()
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(try env.vaultSession.groupNames(), ["Engineering", "Operations"])
        XCTAssertThrowsError(try env.vaultSession.currentRows(secretId: try XCTUnwrap(model.titles.first?.id)))
        XCTAssertTrue(try env.repo.db.query("SELECT * FROM memo WHERE body LIKE ?", ["%fake-only-%"]).isEmpty)
    }

    @MainActor func testSuggestionsIncludeGroupsBeyondSearchLimitAndHideTrashOnlyGroups() async throws {
        let env = try environment()
        try await env.vaultSession.unlock(reason: "fixture only")
        for index in 0..<55 {
            _ = try env.vaultSession.create(title: "Fixture \(index)", groupName: "Group \(index)", rows: [])
        }
        let trash = try env.vaultSession.create(title: "Trash fixture", groupName: "Trash only", rows: [])
        let model = SecretsModel(environment: env)
        XCTAssertEqual(model.titles.count, 50)
        XCTAssertEqual(model.groupNames.count, 56)
        try env.vaultSession.moveToTrash(secretId: trash.id)
        model.searchTitles()
        XCTAssertEqual(model.groupNames.count, 55)
        XCTAssertFalse(model.groupNames.contains("Trash only"))
        try env.vaultSession.restoreFromTrash(secretId: trash.id)
        model.searchTitles()
        XCTAssertTrue(model.groupNames.contains("Trash only"))
    }
}
