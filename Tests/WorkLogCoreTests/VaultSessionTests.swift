import XCTest
@testable import WorkLogCore

/// SEC-05 / 기술설계 §10.4: 잠금 세션 + 조건부 클립보드 삭제.
/// 실제 Mac 기기 인증(LAContext)·NSPasteboard 어댑터는 Linux에서 검증하지 않는다.
final class VaultSessionTests: XCTestCase {

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
            .appendingPathComponent("VaultSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func databaseURL(_ dir: URL) -> URL {
        dir.appendingPathComponent("vault.sqlite")
    }

    private func fixedClock() -> FixedClock {
        FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// 메모리 DB + 메모리 키 저장소로 만든 vault(단일 프로세스 테스트용).
    private func makeVault(keyStore: VaultKeyStore = InMemoryVaultKeyStore(),
                           clock: Clock) throws -> (SQLiteDatabase, SecretVault) {
        let db = try SQLiteDatabase(path: ":memory:")
        let vault = try SecretVault(db: db, keyStore: keyStore, clock: clock)
        return (db, vault)
    }

    private func makeSession(_ vault: SecretVault, authenticator: DeviceAuthenticator,
                             clock: Clock, idleTimeout: TimeInterval = 30 * 60) -> VaultSession {
        VaultSession(vault: vault, authenticator: authenticator, clock: clock,
                     idleTimeout: idleTimeout)
    }

    /// 잠금 사유를 스레드 안전하게 모으는 테스트 도우미.
    private final class ReasonRecorder: @unchecked Sendable {
        private let mutex = NSLock()
        private var items: [VaultLockReason] = []
        func record(_ reason: VaultLockReason) {
            mutex.lock(); items.append(reason); mutex.unlock()
        }
        var all: [VaultLockReason] {
            mutex.lock(); defer { mutex.unlock() }; return items
        }
    }

    // MARK: - 1. 초기 locked / 잠금 중 제목 검색(SEC-T16)

    func testInitiallyLockedAndTitleSearchWorksWhileLocked() throws {
        let clock = fixedClock()
        let (db, vault) = try makeVault(clock: clock)
        defer { db.close() }

        let meta = try vault.create(title: "서버", groupName: "infra",
                                    rows: [SecretRowInput(key: "API_KEY", value: "fake-secret-value")])
        let auth = MockDeviceAuthenticator()
        let session = makeSession(vault, authenticator: auth, clock: clock)

        XCTAssertEqual(session.state, .locked)
        XCTAssertThrowsError(try session.withUnlocked { _ in 0 }) { error in
            XCTAssertEqual(error as? WorkLogError, .vaultLocked)
        }
        // 제목 검색은 잠금 중에도 가능하고 인증을 요구하지 않는다.
        XCTAssertEqual(try session.searchTitles("서버").map { $0.id }, [meta.id])
        XCTAssertEqual(auth.callCount, 0)
    }

    // MARK: - 2. unlock 성공 / 연속 unlock 재인증 없음(SEC-T18)

    func testUnlockSucceedsThenNoReauthWithinWindow() async throws {
        let clock = fixedClock()
        let (db, vault) = try makeVault(clock: clock)
        defer { db.close() }

        let meta = try vault.create(title: "서버", groupName: nil,
                                    rows: [SecretRowInput(key: "A", value: "v1")])
        let rowId = try XCTUnwrap(try vault.currentRows(secretId: meta.id).first?.id)

        let pb = InMemoryPasteboard()
        let clipboardGuard = ClipboardGuard(pasteboard: pb, clock: clock)
        let auth = MockDeviceAuthenticator()
        let session = makeSession(vault, authenticator: auth, clock: clock)

        try await session.unlock(reason: "조회")
        XCTAssertEqual(session.state, .unlocked)
        XCTAssertEqual(auth.callCount, 1)

        // 허용 시간 안 연속 복사는 재인증하지 않는다.
        clock.advance(by: 10 * 60)
        try session.copyValue(secretId: meta.id, rowId: rowId, to: clipboardGuard)
        try session.copyValue(secretId: meta.id, rowId: rowId, to: clipboardGuard)
        XCTAssertEqual(pb.string, "v1")
        XCTAssertEqual(auth.callCount, 1)

        clock.advance(by: 5 * 60)
        try await session.unlock(reason: "조회")
        XCTAssertEqual(auth.callCount, 1)
        XCTAssertEqual(session.state, .unlocked)
    }

    // MARK: - 3. unlock 취소·실패 → locked 유지

    func testUnlockCancelledAndFailedStayLocked() async throws {
        let clock = fixedClock()
        let (db, vault) = try makeVault(clock: clock)
        defer { db.close() }

        let auth = MockDeviceAuthenticator(result: .cancelled)
        let session = makeSession(vault, authenticator: auth, clock: clock)

        do {
            try await session.unlock(reason: "취소")
            XCTFail("vaultLocked를 기대")
        } catch {
            XCTAssertEqual(error as? WorkLogError, .vaultLocked)
        }
        XCTAssertEqual(session.state, .locked)

        auth.nextResult = .failed("device authentication failed")
        do {
            try await session.unlock(reason: "실패")
            XCTFail("vaultLocked를 기대")
        } catch {
            XCTAssertEqual(error as? WorkLogError, .vaultLocked)
        }
        XCTAssertEqual(session.state, .locked)
        XCTAssertEqual(auth.callCount, 2)
    }

    // MARK: - 4. 키 없음 → 인증 호출 없이 vaultKeyMissing

    func testMissingKeyUnlockDoesNotAuthenticate() async throws {
        let dir = try makeTempDir()
        let keyStore = InMemoryVaultKeyStore()
        let clock = fixedClock()

        let db1 = try SQLiteDatabase(path: databaseURL(dir).path)
        let vault1 = try SecretVault(db: db1, keyStore: keyStore, clock: clock)
        XCTAssertEqual(vault1.keyStatus, .ready)
        _ = try vault1.create(title: "키없음", groupName: nil,
                              rows: [SecretRowInput(key: "A", value: "1")])
        db1.close()

        let db2 = try SQLiteDatabase(path: databaseURL(dir).path)
        defer { db2.close() }
        let vault2 = try SecretVault(db: db2, keyStore: InMemoryVaultKeyStore(), clock: clock)
        XCTAssertEqual(vault2.keyStatus, .missing)

        let auth = MockDeviceAuthenticator()
        let session = makeSession(vault2, authenticator: auth, clock: clock)
        do {
            try await session.unlock(reason: "조회")
            XCTFail("vaultKeyMissing을 기대")
        } catch {
            XCTAssertEqual(error as? WorkLogError, .vaultKeyMissing)
        }
        XCTAssertEqual(auth.callCount, 0)
        XCTAssertEqual(session.state, .locked)
    }

    // MARK: - 5. idle 만료(활동 갱신) + onLock(.idle) 1회

    func testIdleExpiresAfterActivityRefreshAndNotifiesOnce() async throws {
        let clock = fixedClock()
        let (db, vault) = try makeVault(clock: clock)
        defer { db.close() }

        _ = try vault.create(title: "유휴", groupName: nil,
                             rows: [SecretRowInput(key: "A", value: "1")])
        let auth = MockDeviceAuthenticator()
        let session = makeSession(vault, authenticator: auth, clock: clock)
        let recorder = ReasonRecorder()
        session.onLock = { recorder.record($0) }

        try await session.unlock(reason: "조회")

        // 29분 59초: 아직 유효, 접근하면 활동 시각 갱신.
        clock.advance(by: 29 * 60 + 59)
        XCTAssertEqual(session.state, .unlocked)
        _ = try session.withUnlocked { $0.keyStatus }
        XCTAssertEqual(session.state, .unlocked)

        // 갱신 시점부터 30분 경과 → 잠금 + .idle 1회.
        clock.advance(by: 30 * 60)
        XCTAssertEqual(session.state, .locked)
        XCTAssertEqual(recorder.all, [.idle])

        // 이후 조회·checkIdle은 콜백을 다시 부르지 않는다.
        XCTAssertEqual(session.state, .locked)
        XCTAssertFalse(session.checkIdle())
        XCTAssertEqual(recorder.all, [.idle])

        // idle 잠금 후에는 다시 인증해야 한다.
        try await session.unlock(reason: "재조회")
        XCTAssertEqual(auth.callCount, 2)
        XCTAssertEqual(session.state, .unlocked)
    }

    func testExpiredIdleBlocksWithUnlockedAndNotifies() async throws {
        let clock = fixedClock()
        let (db, vault) = try makeVault(clock: clock)
        defer { db.close() }

        let auth = MockDeviceAuthenticator()
        let session = makeSession(vault, authenticator: auth, clock: clock, idleTimeout: 60)
        let recorder = ReasonRecorder()
        session.onLock = { recorder.record($0) }

        try await session.unlock(reason: "조회")
        clock.advance(by: 60)

        XCTAssertThrowsError(try session.withUnlocked { _ in 0 }) { error in
            XCTAssertEqual(error as? WorkLogError, .vaultLocked)
        }
        XCTAssertEqual(recorder.all, [.idle])
        XCTAssertEqual(session.state, .locked)
    }

    // MARK: - 6. 화면 잠금·앱 종료(SEC-T19) + 중복 lock 콜백 1회

    func testExplicitLockReasonsAndDuplicateLockCallbackOnce() async throws {
        let clock = fixedClock()
        let (db, vault) = try makeVault(clock: clock)
        defer { db.close() }

        let auth = MockDeviceAuthenticator()
        let session = makeSession(vault, authenticator: auth, clock: clock)
        let recorder = ReasonRecorder()
        session.onLock = { recorder.record($0) }

        // locked 상태에서 lock은 콜백을 부르지 않는다.
        session.lock(.manual)
        XCTAssertEqual(recorder.all, [])

        try await session.unlock(reason: "조회")
        session.lock(.screenLocked)
        XCTAssertEqual(session.state, .locked)
        XCTAssertEqual(recorder.all, [.screenLocked])

        // 중복 lock은 콜백 1회만.
        session.lock(.screenLocked)
        XCTAssertEqual(recorder.all, [.screenLocked])

        try await session.unlock(reason: "재조회")
        session.lock(.appQuit)
        XCTAssertEqual(recorder.all, [.screenLocked, .appQuit])
        XCTAssertEqual(session.state, .locked)
    }

    // MARK: - 7. idleTimeout 설정 변경 반영

    func testIdleTimeoutChangeApplies() async throws {
        let clock = fixedClock()
        let (db, vault) = try makeVault(clock: clock)
        defer { db.close() }

        let auth = MockDeviceAuthenticator()
        let session = makeSession(vault, authenticator: auth, clock: clock, idleTimeout: 30 * 60)
        try await session.unlock(reason: "조회")

        session.idleTimeout = 60
        clock.advance(by: 59)
        XCTAssertEqual(session.state, .unlocked)
        clock.advance(by: 1)
        XCTAssertEqual(session.state, .locked)
        XCTAssertEqual(session.idleTimeout, 60)
    }

    // MARK: - 8. copyValue: 값 기록·활동 갱신 / 잠금 중 거부

    func testCopyValueWritesClipboardAndRefreshesActivity() async throws {
        let clock = fixedClock()
        let (db, vault) = try makeVault(clock: clock)
        defer { db.close() }

        let meta = try vault.create(title: "복사", groupName: nil,
                                    rows: [SecretRowInput(key: "A", value: "fake-copy-value")])
        let rowId = try XCTUnwrap(try vault.currentRows(secretId: meta.id).first?.id)

        let pb = InMemoryPasteboard()
        let clipboardGuard = ClipboardGuard(pasteboard: pb, clock: clock)
        let auth = MockDeviceAuthenticator()
        let session = makeSession(vault, authenticator: auth, clock: clock, idleTimeout: 60)

        try await session.unlock(reason: "조회")
        clock.advance(by: 50)
        try session.copyValue(secretId: meta.id, rowId: rowId, to: clipboardGuard)
        XCTAssertEqual(pb.string, "fake-copy-value")
        XCTAssertTrue(clipboardGuard.hasPendingClear)

        // 복사 활동이 idle을 갱신했으므로 50초 뒤에도 아직 유효하다.
        clock.advance(by: 50)
        XCTAssertEqual(session.state, .unlocked)

        // 잠금 중 copyValue는 거부하고 클립보드를 바꾸지 않는다.
        session.lock(.manual)
        pb.writeString("sentinel", concealed: false)
        let before = pb.changeCount
        XCTAssertThrowsError(try session.copyValue(secretId: meta.id, rowId: rowId,
                                                   to: clipboardGuard)) { error in
            XCTAssertEqual(error as? WorkLogError, .vaultLocked)
        }
        XCTAssertEqual(pb.changeCount, before)
        XCTAssertEqual(pb.string, "sentinel")
    }

    func testCopyValueUnknownRowThrowsNotFound() async throws {
        let clock = fixedClock()
        let (db, vault) = try makeVault(clock: clock)
        defer { db.close() }

        let meta = try vault.create(title: "복사", groupName: nil,
                                    rows: [SecretRowInput(key: "A", value: "1")])
        let pb = InMemoryPasteboard()
        let clipboardGuard = ClipboardGuard(pasteboard: pb, clock: clock)
        let session = makeSession(vault, authenticator: MockDeviceAuthenticator(), clock: clock)
        try await session.unlock(reason: "조회")

        XCTAssertThrowsError(try session.copyValue(secretId: meta.id, rowId: "missing-row",
                                                   to: clipboardGuard)) { error in
            guard let wl = error as? WorkLogError, case .notFound = wl else {
                XCTFail("notFound를 기대했지만 \(error)")
                return
            }
        }
        XCTAssertNil(pb.string)
        XCTAssertFalse(clipboardGuard.hasPendingClear)
    }

    // MARK: - 9. SEC-T20: 기한 후 변화 없으면 삭제

    func testClipboardClearedAfterDelayWhenUnchanged() {
        let clock = fixedClock()
        let pb = InMemoryPasteboard()
        let clipboardGuard = ClipboardGuard(pasteboard: pb, clock: clock, clearAfter: 120)

        clipboardGuard.copySecret("fake-clipboard-value")
        XCTAssertEqual(pb.string, "fake-clipboard-value")
        XCTAssertTrue(clipboardGuard.hasPendingClear)

        clock.advance(by: 119)
        XCTAssertFalse(clipboardGuard.tick())
        XCTAssertEqual(pb.string, "fake-clipboard-value")
        XCTAssertTrue(clipboardGuard.hasPendingClear)

        clock.advance(by: 1)
        XCTAssertTrue(clipboardGuard.tick())
        XCTAssertNil(pb.string)
        XCTAssertFalse(clipboardGuard.hasPendingClear)
    }

    // MARK: - 10. SEC-T21: 외부 복사로 marker가 바뀌면 지우지 않음

    func testClipboardNotClearedWhenExternalCopyChangedMarker() {
        let clock = fixedClock()

        // 다른 문자열 복사.
        let pb1 = InMemoryPasteboard()
        let guard1 = ClipboardGuard(pasteboard: pb1, clock: clock, clearAfter: 120)
        guard1.copySecret("mine")
        clock.advance(by: 60)
        pb1.simulateExternalCopy("external-other")
        clock.advance(by: 60)
        XCTAssertFalse(guard1.tick())
        XCTAssertEqual(pb1.string, "external-other")
        XCTAssertFalse(guard1.hasPendingClear)

        // 같은 문자열을 다시 복사해도 marker가 다르면 지우지 않는다.
        let pb2 = InMemoryPasteboard()
        let clock2 = fixedClock()
        let guard2 = ClipboardGuard(pasteboard: pb2, clock: clock2, clearAfter: 120)
        guard2.copySecret("same-value")
        clock2.advance(by: 120)
        pb2.simulateExternalCopy("same-value")
        XCTAssertFalse(guard2.tick())
        XCTAssertEqual(pb2.string, "same-value")
    }

    // MARK: - 11. 기한 전 tick / clearAfter 변경 / 마지막 복사 marker 기준

    func testTickBeforeDeadlineAndClearAfterChangeAndLastCopyWins() {
        let clock = fixedClock()
        let pb = InMemoryPasteboard()
        let clipboardGuard = ClipboardGuard(pasteboard: pb, clock: clock, clearAfter: 120)

        clipboardGuard.copySecret("first")
        clock.advance(by: 60)
        clipboardGuard.copySecret("second")   // 이전 대기 항목을 교체, marker 갱신
        XCTAssertEqual(pb.string, "second")

        clock.advance(by: 100)                // 마지막 복사 후 100초
        XCTAssertFalse(clipboardGuard.tick())
        XCTAssertEqual(pb.string, "second")
        XCTAssertTrue(clipboardGuard.hasPendingClear)

        clipboardGuard.clearAfter = 90        // 설정 변경: 이제 기한 경과
        XCTAssertTrue(clipboardGuard.tick())
        XCTAssertNil(pb.string)
        XCTAssertFalse(clipboardGuard.hasPendingClear)
    }

    // MARK: - 12. clearNowIfUnchanged

    func testClearNowIfUnchanged() {
        let clock = fixedClock()
        let pb = InMemoryPasteboard()
        let clipboardGuard = ClipboardGuard(pasteboard: pb, clock: clock, clearAfter: 120)

        // 대기 항목 없음.
        XCTAssertFalse(clipboardGuard.clearNowIfUnchanged())

        // 변화 없음 → 즉시 삭제(기한과 무관).
        clock.advance(by: 1)
        clipboardGuard.copySecret("v")
        XCTAssertTrue(clipboardGuard.clearNowIfUnchanged())
        XCTAssertNil(pb.string)
        XCTAssertFalse(clipboardGuard.hasPendingClear)

        // 외부 변경 → 지우지 않음.
        clipboardGuard.copySecret("v2")
        pb.simulateExternalCopy("external")
        XCTAssertFalse(clipboardGuard.clearNowIfUnchanged())
        XCTAssertEqual(pb.string, "external")
        XCTAssertFalse(clipboardGuard.hasPendingClear)
    }

    // MARK: - 13. 잠금 상태에서는 파사드 값 접근이 vaultLocked (WLOG-45A3 AB2)

    func testFacadeMethodsThrowVaultLockedWhenLocked() throws {
        let clock = fixedClock()
        let (db, vault) = try makeVault(clock: clock)
        defer { db.close() }

        let session = makeSession(vault, authenticator: MockDeviceAuthenticator(), clock: clock)
        XCTAssertEqual(session.state, .locked)

        XCTAssertThrowsError(try session.create(title: "차단", groupName: nil,
                                                rows: [SecretRowInput(key: "A", value: "1")])) { error in
            XCTAssertEqual(error as? WorkLogError, .vaultLocked)
        }
        XCTAssertThrowsError(try session.currentRows(secretId: "missing")) { error in
            XCTAssertEqual(error as? WorkLogError, .vaultLocked)
        }
        XCTAssertThrowsError(try session.save(secretId: "missing",
                                              changes: SecretChangeSet())) { error in
            XCTAssertEqual(error as? WorkLogError, .vaultLocked)
        }
        XCTAssertThrowsError(try session.loadDraft()) { error in
            XCTAssertEqual(error as? WorkLogError, .vaultLocked)
        }
        // 잠금 중에는 아무것도 저장되지 않는다.
        XCTAssertEqual(try db.query("SELECT 1 AS x FROM secret_item").count, 0)
    }

    // MARK: - 14. unlock 후 파사드 전체 왕복 (WLOG-45A3 AB2)

    func testFacadeRoundTripAfterUnlock() async throws {
        let clock = fixedClock()
        let (db, vault) = try makeVault(clock: clock)
        defer { db.close() }

        let session = makeSession(vault, authenticator: MockDeviceAuthenticator(), clock: clock)
        try await session.unlock(reason: "생성")

        let meta = try session.create(title: "왕복", groupName: "grp", rows: [
            SecretRowInput(key: "A", value: "1"),
            SecretRowInput(key: "B", value: "2"),
        ])
        let rowsV1 = try session.currentRows(secretId: meta.id)
        XCTAssertEqual(rowsV1.count, 2)
        let revision1 = try XCTUnwrap(try session.revisions(secretId: meta.id).first)
        let aId = try XCTUnwrap(rowsV1.first { $0.key == "A" }?.id)

        XCTAssertEqual(try session.save(secretId: meta.id, changes: SecretChangeSet(upserts: [
            SecretRowInput(id: aId, key: "A", value: "1-updated")
        ])), .saved(version: 2))
        XCTAssertEqual(try session.currentRows(secretId: meta.id).first { $0.key == "A" }?.value,
                       "1-updated")
        XCTAssertEqual(try session.revisions(secretId: meta.id).count, 2)
        XCTAssertEqual(try session.rows(secretId: meta.id, revisionId: revision1.id)
            .first { $0.key == "A" }?.value, "1")

        XCTAssertEqual(try session.restoreRevision(secretId: meta.id, revisionId: revision1.id),
                       .saved(version: 3))
        XCTAssertEqual(try session.currentRows(secretId: meta.id).first { $0.key == "A" }?.value, "1")
    }

    // MARK: - 15. 중복 key 오류 메시지에 key 문자열이 남지 않는다 (WLOG-45A3 AB2)

    func testDuplicateKeyErrorHidesKeyString() async throws {
        let clock = fixedClock()
        let (db, vault) = try makeVault(clock: clock)
        defer { db.close() }

        let canary = "DUP_KEY_CANARY_77"
        let session = makeSession(vault, authenticator: MockDeviceAuthenticator(), clock: clock)
        try await session.unlock(reason: "저장")

        var caught: Error?
        do {
            _ = try session.create(title: "중복", groupName: nil, rows: [
                SecretRowInput(key: canary, value: "1"),
                SecretRowInput(key: "  \(canary)  ", value: "2"),
            ])
            XCTFail("validation 오류를 기대")
        } catch {
            caught = error
        }

        let error = try XCTUnwrap(caught)
        XCTAssertEqual(error as? WorkLogError,
                       .validation("Secret 저장 전 확인이 필요합니다: 중복된 항목 이름(행 1, 2)"))
        XCTAssertFalse(String(describing: error).contains(canary),
                       "String(describing:)에 key 문자열이 남음")
        XCTAssertFalse(error.localizedDescription.contains(canary),
                       "localizedDescription에 key 문자열이 남음")
        // 중복 오류면 아무것도 저장하지 않는다.
        XCTAssertEqual(try db.query("SELECT 1 AS x FROM secret_item").count, 0)
    }
}
