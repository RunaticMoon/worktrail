import XCTest
@testable import WorkLogCore

/// WLOG-45A3 Z: 앱 구성 루트(AppEnvironment).
///
/// macOS 앱·CLI가 공유하는 조립 지점을 검증한다. 실제 Keychain·LocalAuthentication·
/// NSPasteboard 어댑터는 Linux에서 검증하지 않는다(메모리 Mock 사용).
final class AppEnvironmentTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppEnvironmentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    /// 임시 루트 아래 dataRoot/backupRoot를 가진 AppPaths.
    private func makePaths() throws -> AppPaths {
        let root = try makeTempDir()
        return AppPaths(dataRoot: root.appendingPathComponent("data", isDirectory: true),
                        backupRoot: root.appendingPathComponent("backups", isDirectory: true))
    }

    private func fixedClock() -> FixedClock {
        FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func makeOptions(paths: AppPaths,
                             keyStore: VaultKeyStore = InMemoryVaultKeyStore(),
                             authenticator: DeviceAuthenticator = MockDeviceAuthenticator(),
                             pasteboard: Pasteboard = InMemoryPasteboard(),
                             aiProvider: AIProvider? = nil,
                             clock: Clock? = nil,
                             ids: IDGenerator = SequentialIDGenerator()) -> AppEnvironmentOptions {
        AppEnvironmentOptions(paths: paths, keyStore: keyStore, authenticator: authenticator,
                              pasteboard: pasteboard, aiProvider: aiProvider,
                              clock: clock ?? fixedClock(), ids: ids)
    }

    private func permissions(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// 저장된 키 id를 기록하는 키 저장소(키 삭제 시나리오용).
    private final class RecordingVaultKeyStore: VaultKeyStore, @unchecked Sendable {
        private let inner = InMemoryVaultKeyStore()
        private let lock = NSLock()
        private var ids: [String] = []

        func loadKey(id: String) throws -> Data? { try inner.loadKey(id: id) }
        func storeKey(_ key: Data, id: String) throws {
            try inner.storeKey(key, id: id)
            lock.lock(); ids.append(id); lock.unlock()
        }
        func deleteKey(id: String) throws { try inner.deleteKey(id: id) }

        var storedIds: [String] {
            lock.lock(); defer { lock.unlock() }
            return ids
        }
    }

    // MARK: - 1. 두 DB 분리 + 디렉터리 권한

    func testOpenCreatesSeparateDatabasesWithOwnerOnlyDirectories() throws {
        let paths = try makePaths()
        let env = try AppEnvironment.open(makeOptions(paths: paths))

        XCTAssertEqual(env.repo.db.path, paths.workDatabase.path)
        XCTAssertNotEqual(paths.workDatabase.path, paths.vaultDatabase.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.workDatabase.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.vaultDatabase.path))

        for dir in [paths.dataRoot,
                    paths.workDatabase.deletingLastPathComponent(),
                    paths.vaultDatabase.deletingLastPathComponent(),
                    paths.backupRoot] {
            XCTAssertEqual(permissions(dir), 0o700, "디렉터리 권한이 0700이어야 함: \(dir.path)")
        }
    }

    // MARK: - 2. AI 비활성 + Memo 기록·검색 정상

    func testNilProviderDisablesAIButMemoWorks() throws {
        let env = try AppEnvironment.open(makeOptions(paths: try makePaths()))

        XCTAssertNil(env.aiRunner)
        XCTAssertNil(env.memoLinks)
        XCTAssertNil(env.quiz)
        XCTAssertNil(env.groundedAnswers)

        let memo = try env.tasks.captureMemo(body: "아키텍처 정리 회의 공유")
        let hits = try env.search.search(SearchQuery(text: "아키텍처"))
        XCTAssertTrue(hits.contains { $0.sourceType == .memo && $0.sourceId == memo.id })
    }

    // MARK: - 3. MockAIProvider 제공 + aiEnabled=false면 비활성

    func testProviderEnablesAIUnlessDisabledInSettings() throws {
        let paths = try makePaths()
        let provider = MockAIProvider()
        let env = try AppEnvironment.open(makeOptions(paths: paths, aiProvider: provider))
        XCTAssertNotNil(env.aiRunner)
        XCTAssertNotNil(env.groundedAnswers)

        var disabled = env.settings
        disabled.aiEnabled = false
        try env.updateSettings(disabled)

        let reopened = try AppEnvironment.open(makeOptions(paths: paths, aiProvider: provider))
        XCTAssertNil(reopened.aiRunner)
        XCTAssertNil(reopened.memoLinks)
        XCTAssertNil(reopened.quiz)
        XCTAssertNil(reopened.groundedAnswers)
        XCTAssertFalse(reopened.settings.aiEnabled)
    }

    // MARK: - 4. onLaunch 시드·백업

    func testOnLaunchSeedsTemplatesAndCreatesBackupOnce() throws {
        let paths = try makePaths()
        let env = try AppEnvironment.open(makeOptions(paths: paths))

        let first = env.onLaunch()
        XCTAssertEqual(first.seededTemplates, 7)
        XCTAssertTrue(first.backupCreated)
        XCTAssertNil(first.backupError)

        let backupEntries = try FileManager.default.contentsOfDirectory(atPath: paths.backupRoot.path)
            .filter { !$0.hasPrefix(".") }
        XCTAssertFalse(backupEntries.isEmpty, "backupRoot에 백업 디렉터리가 있어야 함")

        let second = env.onLaunch()
        XCTAssertEqual(second.seededTemplates, 0)
    }

    // MARK: - 5. updateSettings 반영·지속·검증

    func testUpdateSettingsAppliesAndPersists() throws {
        let paths = try makePaths()
        let env = try AppEnvironment.open(makeOptions(paths: paths))

        var changed = env.settings
        changed.secretIdleLockMinutes = 10
        changed.clipboardClearSeconds = 30
        try env.updateSettings(changed)

        XCTAssertEqual(env.vaultSession.idleTimeout, 600)
        XCTAssertEqual(env.clipboard.clearAfter, 30)

        let reopened = try AppEnvironment.open(makeOptions(paths: paths))
        XCTAssertEqual(reopened.settings.secretIdleLockMinutes, 10)
        XCTAssertEqual(reopened.settings.clipboardClearSeconds, 30)
        XCTAssertEqual(reopened.vaultSession.idleTimeout, 600)
        XCTAssertEqual(reopened.clipboard.clearAfter, 30)

        var invalid = env.settings
        invalid.secretIdleLockMinutes = 0
        XCTAssertThrowsError(try env.updateSettings(invalid))
        XCTAssertEqual(env.settings.secretIdleLockMinutes, 10)
        XCTAssertEqual(env.vaultSession.idleTimeout, 600)
    }

    // MARK: - 6. lockSecrets

    func testLockSecretsLocksVaultSession() async throws {
        let env = try AppEnvironment.open(makeOptions(paths: try makePaths()))

        try await env.vaultSession.unlock(reason: "테스트")
        XCTAssertEqual(env.vaultSession.state, .unlocked)

        env.lockSecrets(.screenLocked)
        XCTAssertEqual(env.vaultSession.state, .locked)
    }

    // MARK: - 7. AI guard: vault DB 경로 차단

    func testAIPayloadGuardBlocksVaultPath() async throws {
        let paths = try makePaths()
        let env = try AppEnvironment.open(makeOptions(paths: paths,
                                                      aiProvider: MockAIProvider()))
        let runner = try XCTUnwrap(env.aiRunner)

        let request = AIJobRequest(jobType: .evidenceQuiz,
                                   instructions: "요약해줘",
                                   payloadJSON: "{\"path\":\"\(paths.vaultDatabase.path)\"}")

        do {
            _ = try await runner.submit(request)
            XCTFail("vault 경로가 든 AI 입력은 차단되어야 함")
        } catch let error as WorkLogError {
            guard case .policyBlocked = error else {
                return XCTFail("policyBlocked여야 함: \(error)")
            }
        }
    }

    // MARK: - 8. 키 삭제 후 재open + unlock vaultKeyMissing

    func testOpenSucceedsWithoutKeyAndUnlockReportsMissing() async throws {
        let paths = try makePaths()
        let keyStore = RecordingVaultKeyStore()

        _ = try AppEnvironment.open(makeOptions(paths: paths, keyStore: keyStore))
        let keyId = try XCTUnwrap(keyStore.storedIds.first)
        try keyStore.deleteKey(id: keyId)

        // open은 실패하지 않는다(기존 데이터 보존).
        let reopened = try AppEnvironment.open(makeOptions(paths: paths, keyStore: keyStore))

        do {
            try await reopened.vaultSession.unlock(reason: "테스트")
            XCTFail("키가 없으면 unlock은 vaultKeyMissing이어야 함")
        } catch let error as WorkLogError {
            XCTAssertEqual(error, .vaultKeyMissing)
        }
    }
}
