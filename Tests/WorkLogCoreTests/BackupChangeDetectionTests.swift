import XCTest
@testable import WorkLogCore

/// 회귀 테스트: #73(일반 설정만 바뀐 경우 자동 백업 변경 감지)과
/// #72(손상·누락된 최신 백업을 건너뛰지 않고, retention이 유일한 검증 가능 사본을 지우지 않음).
/// 모든 경로는 임시 디렉터리이며 실제 사용자 백업 경로를 건드리지 않는다.
final class BackupChangeDetectionTests: XCTestCase {

    private var tempRoots: [URL] = []
    private let calendar = WorkCalendar()

    override func tearDown() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupChangeDetectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoots.append(root)
        return root
    }

    private func makePaths(root: URL) -> AppPaths {
        AppPaths(dataRoot: root.appendingPathComponent("data", isDirectory: true),
                 backupRoot: root.appendingPathComponent("backups", isDirectory: true))
    }

    private struct Stores {
        let workDB: SQLiteDatabase
        let repo: WorkRepository
        let vaultDB: SQLiteDatabase
        let vault: SecretVault

        func close() {
            workDB.close()
            vaultDB.close()
        }
    }

    private func openStores(_ paths: AppPaths, keyStore: VaultKeyStore, clock: Clock,
                            ids: IDGenerator) throws -> Stores {
        let workDB = try SQLiteDatabase(path: paths.workDatabase.path)
        let repo = try WorkRepository(db: workDB, clock: clock, ids: ids)
        let vaultDB = try SQLiteDatabase(path: paths.vaultDatabase.path)
        let vault = try SecretVault(db: vaultDB, keyStore: keyStore, clock: clock, ids: ids)
        return Stores(workDB: workDB, repo: repo, vaultDB: vaultDB, vault: vault)
    }

    private func makeService(_ paths: AppPaths, _ stores: Stores, clock: Clock,
                             ids: IDGenerator = UUIDGenerator()) -> BackupService {
        BackupService(paths: paths, workDB: stores.workDB, vaultDB: stores.vaultDB,
                      identity: .default, clock: clock, ids: ids)
    }

    private func fixedClock(_ date: WorkDate = WorkDate(year: 2026, month: 10, day: 1)) -> FixedClock {
        FixedClock(calendar.startOfDay(date))
    }

    private func bytes(_ url: URL) -> Data? {
        FileManager.default.contents(atPath: url.path)
    }

    /// settings.json을 읽고-고쳐-저장한다. SettingsStore의 실제 저장 경로를 그대로 쓴다.
    private func mutateSettings(_ paths: AppPaths, _ mutate: (inout AppSettings) -> Void) throws {
        let store = SettingsStore(fileURL: paths.settingsFile)
        var settings = try store.load()
        mutate(&settings)
        try store.save(settings)
    }

    private func readSettings(in backup: BackupInfo) throws -> AppSettings {
        try SettingsStore(fileURL: backup.directory.appendingPathComponent(BackupService.settingsFileName)).load()
    }

    private func backendFile(_ backup: BackupInfo, _ name: String) -> URL {
        backup.directory.appendingPathComponent(name)
    }

    /// manifest는 그대로 두고 work.sqlite 바이트만 손상시킨다(중간 1바이트 반전 → 해시 불일치).
    private func corruptWorkDatabase(in backup: BackupInfo) throws {
        let url = backendFile(backup, BackupService.workFileName)
        var data = try XCTUnwrap(bytes(url))
        let index = data.count / 2
        data[index] = data[index] ^ 0xFF
        try data.write(to: url)
    }

    private func memoBodies(_ stores: Stores, on date: WorkDate) throws -> [String] {
        try stores.repo.memos(on: date).map(\.body)
    }

    // MARK: - #73: 일반 설정만 변경해도 다음 일일 백업이 만들어진다

    func testDailyBackupDetectsGeneralSettingsOnlyChange() throws {
        let root = try makeRoot(), paths = makePaths(root: root)
        let clock = fixedClock(WorkDate(year: 2026, month: 10, day: 1))
        let ids = SequentialIDGenerator(prefix: "src")
        let stores = try openStores(paths, keyStore: InMemoryVaultKeyStore(), clock: clock, ids: ids)
        defer { stores.close() }
        let workDate = WorkDate(year: 2026, month: 10, day: 1)
        try stores.repo.insertMemo(Memo(id: ids.make(), body: "일반 설정 변경 감지",
                                        workDate: workDate, recordedAt: clock.now()))
        try mutateSettings(paths) { $0.backupRetentionDays = 21 }

        let service = makeService(paths, stores, clock: clock)
        let first = try XCTUnwrap(try service.createDailyBackupIfChanged(calendar: calendar))
        XCTAssertEqual(try readSettings(in: first).backupRetentionDays, 21)

        // DB·AI 연결·활동 연결 설정은 그대로 두고 일반 settings.json만 바꾼다.
        clock.set(calendar.startOfDay(WorkDate(year: 2026, month: 10, day: 2)))
        try mutateSettings(paths) {
            $0.secretIdleLockMinutes = 41
            $0.defaultCaptureKind = .task
        }

        let second = try XCTUnwrap(try service.createDailyBackupIfChanged(calendar: calendar),
                                   "일반 설정만 바뀌었는데도 새 백업이 필요하다")
        XCTAssertNotEqual(second.id, first.id)
        try service.verify(second)

        let saved = try readSettings(in: second)
        XCTAssertEqual(saved.secretIdleLockMinutes, 41)
        XCTAssertEqual(saved.defaultCaptureKind, .task)
        XCTAssertEqual(saved.backupRetentionDays, 21)

        // 새 백업을 다른 임시 대상에 복원해도 변경한 일반 설정이 유지된다.
        let target = makePaths(root: root.appendingPathComponent("restore-target"))
        try BackupService.restore(second, into: target, keyStore: InMemoryVaultKeyStore(),
                                  includeVault: false, clock: clock)
        let restored = try SettingsStore(fileURL: target.settingsFile).load()
        XCTAssertEqual(restored.secretIdleLockMinutes, 41)
        XCTAssertEqual(restored.defaultCaptureKind, .task)
    }

    func testDailyBackupDetectsSettingsFilePresenceChanges() throws {
        let root = try makeRoot(), paths = makePaths(root: root)
        let clock = fixedClock(WorkDate(year: 2026, month: 10, day: 1))
        let stores = try openStores(paths, keyStore: InMemoryVaultKeyStore(), clock: clock,
                                    ids: SequentialIDGenerator())
        defer { stores.close() }
        let service = makeService(paths, stores, clock: clock)

        // 1) settings.json 없음 → 첫 daily 백업에는 settings.json이 없다.
        let without = try XCTUnwrap(try service.createDailyBackupIfChanged(calendar: calendar))
        XCTAssertFalse(without.manifest.files.contains { $0.name == BackupService.settingsFileName })

        // 2) 없음 → 있음 전환은 변경이다.
        clock.set(calendar.startOfDay(WorkDate(year: 2026, month: 10, day: 2)))
        try mutateSettings(paths) { $0.secretIdleLockMinutes = 45 }
        let added = try XCTUnwrap(try service.createDailyBackupIfChanged(calendar: calendar))
        XCTAssertTrue(added.manifest.files.contains { $0.name == BackupService.settingsFileName })
        XCTAssertEqual(try readSettings(in: added).secretIdleLockMinutes, 45)

        // 3) 있음 → 없음 전환도 변경이다.
        clock.set(calendar.startOfDay(WorkDate(year: 2026, month: 10, day: 3)))
        try FileManager.default.removeItem(at: paths.settingsFile)
        let removed = try XCTUnwrap(try service.createDailyBackupIfChanged(calendar: calendar))
        XCTAssertFalse(removed.manifest.files.contains { $0.name == BackupService.settingsFileName })

        // 4) 이후 아무것도 바뀌지 않으면 생략한다.
        clock.set(calendar.startOfDay(WorkDate(year: 2026, month: 10, day: 4)))
        XCTAssertNil(try service.createDailyBackupIfChanged(calendar: calendar))
        XCTAssertEqual(try service.listBackups().count, 3)
    }

    func testDailyBackupSkipsWhenNothingChangedWithSettingsPresent() throws {
        let root = try makeRoot(), paths = makePaths(root: root)
        let clock = fixedClock(WorkDate(year: 2026, month: 10, day: 1))
        let stores = try openStores(paths, keyStore: InMemoryVaultKeyStore(), clock: clock,
                                    ids: SequentialIDGenerator())
        defer { stores.close() }
        try mutateSettings(paths) { $0.clipboardClearSeconds = 200 }
        let service = makeService(paths, stores, clock: clock)

        let first = try XCTUnwrap(try service.createDailyBackupIfChanged(calendar: calendar))
        XCTAssertTrue(first.manifest.files.contains { $0.name == BackupService.settingsFileName })

        // 같은 날 중복 방지도 유지된다(설정이 바뀌어도 오늘 이미 daily 백업이 있으면 만들지 않는다).
        try mutateSettings(paths) { $0.clipboardClearSeconds = 210 }
        XCTAssertNil(try service.createDailyBackupIfChanged(calendar: calendar),
                     "오늘 이미 daily 백업이 있으면 만들지 않는다")
        XCTAssertEqual(try service.listBackups().count, 1)
        try mutateSettings(paths) { $0.clipboardClearSeconds = 200 }

        clock.set(calendar.startOfDay(WorkDate(year: 2026, month: 10, day: 2)))
        XCTAssertNil(try service.createDailyBackupIfChanged(calendar: calendar),
                     "모든 파일이 그대로면 생략해야 한다")
        XCTAssertEqual(try service.listBackups().count, 1)
    }

    // MARK: - #72: 손상·누락된 최신 백업은 건너뛰지 않고 live 데이터로 새 백업을 만든다

    func testDailyBackupReplacesCorruptedLatestBackup() throws {
        let root = try makeRoot(), paths = makePaths(root: root)
        let clock = fixedClock(WorkDate(year: 2026, month: 10, day: 1))
        let ids = SequentialIDGenerator(prefix: "src")
        let stores = try openStores(paths, keyStore: InMemoryVaultKeyStore(), clock: clock, ids: ids)
        defer { stores.close() }
        let workDate = WorkDate(year: 2026, month: 10, day: 1)
        try stores.repo.insertMemo(Memo(id: ids.make(), body: "손상 최신본", workDate: workDate,
                                        recordedAt: clock.now()))
        try mutateSettings(paths) { $0.secretIdleLockMinutes = 33 }
        let service = makeService(paths, stores, clock: clock)

        let latest = try XCTUnwrap(try service.createDailyBackupIfChanged(calendar: calendar))
        try corruptWorkDatabase(in: latest)
        XCTAssertThrowsError(try service.verify(latest), "손상된 사본은 검증에 실패해야 한다")

        // 다음 날, live 데이터는 변경 없음. 그래도 최신본이 손상됐으므로 새 백업을 만든다.
        clock.set(calendar.startOfDay(WorkDate(year: 2026, month: 10, day: 2)))
        let replacement = try XCTUnwrap(try service.createDailyBackupIfChanged(calendar: calendar),
                                        "최신 백업이 손상되면 변경 없음으로 건너뛰면 안 된다")
        XCTAssertNotEqual(replacement.id, latest.id)
        try service.verify(replacement)
        XCTAssertEqual(replacement.manifest.reason, .daily)

        // live 데이터는 그대로다.
        XCTAssertEqual(try memoBodies(stores, on: workDate), ["손상 최신본"])
        XCTAssertEqual(try readSettings(in: replacement).secretIdleLockMinutes, 33)

        // 다음 날 다시 호출하면 새 정상본 덕분에 생략된다.
        clock.set(calendar.startOfDay(WorkDate(year: 2026, month: 10, day: 3)))
        XCTAssertNil(try service.createDailyBackupIfChanged(calendar: calendar))
    }

    func testDailyBackupReplacesLatestBackupWithMissingWorkDatabase() throws {
        let root = try makeRoot(), paths = makePaths(root: root)
        let clock = fixedClock(WorkDate(year: 2026, month: 10, day: 1))
        let ids = SequentialIDGenerator(prefix: "src")
        let stores = try openStores(paths, keyStore: InMemoryVaultKeyStore(), clock: clock, ids: ids)
        defer { stores.close() }
        let workDate = WorkDate(year: 2026, month: 10, day: 1)
        try stores.repo.insertMemo(Memo(id: ids.make(), body: "누락 최신본", workDate: workDate,
                                        recordedAt: clock.now()))
        let service = makeService(paths, stores, clock: clock)

        let latest = try XCTUnwrap(try service.createDailyBackupIfChanged(calendar: calendar))
        try FileManager.default.removeItem(at: backendFile(latest, BackupService.workFileName))
        XCTAssertThrowsError(try service.verify(latest))

        clock.set(calendar.startOfDay(WorkDate(year: 2026, month: 10, day: 2)))
        let replacement = try XCTUnwrap(try service.createDailyBackupIfChanged(calendar: calendar))
        XCTAssertNotEqual(replacement.id, latest.id)
        try service.verify(replacement)
        XCTAssertEqual(try memoBodies(stores, on: workDate), ["누락 최신본"])
    }

    // MARK: - #72: retention은 검증되는 가장 최신 사본을 지우지 않는다

    func testRetentionKeepsHealthyNewestAndDeletesOldBackup() throws {
        let root = try makeRoot(), paths = makePaths(root: root)
        let clock = fixedClock(WorkDate(year: 2026, month: 10, day: 1))
        let stores = try openStores(paths, keyStore: InMemoryVaultKeyStore(), clock: clock,
                                    ids: SequentialIDGenerator(prefix: "src"))
        defer { stores.close() }
        let service = makeService(paths, stores, clock: clock)

        let old = try service.createBackup(reason: .manual) // day1
        clock.set(calendar.startOfDay(WorkDate(year: 2026, month: 10, day: 10)))
        let latest = try service.createBackup(reason: .manual) // day10, 건강한 최신본

        // 보관 기간 밖(day40)에서도 변경이 없고 최신본이 건강하면 daily 백업은 생략된다.
        clock.set(calendar.startOfDay(WorkDate(year: 2026, month: 11, day: 9)))
        XCTAssertNil(try service.createDailyBackupIfChanged(calendar: calendar))

        // 기존 동작대로 오래된 A만 지우고 건강한 최신 B는 남긴다.
        let deleted = try service.applyRetention(keepDays: 5, lastBackupSucceeded: true)
        XCTAssertEqual(deleted, [old.id])
        XCTAssertEqual(try service.listBackups().map(\.id), [latest.id])
    }

    func testRetentionKeepsNewestVerifyingBackupWhenLatestIsCorrupted() throws {
        let root = try makeRoot(), paths = makePaths(root: root)
        let clock = fixedClock(WorkDate(year: 2026, month: 10, day: 1))
        let stores = try openStores(paths, keyStore: InMemoryVaultKeyStore(), clock: clock,
                                    ids: SequentialIDGenerator(prefix: "src"))
        defer { stores.close() }
        let service = makeService(paths, stores, clock: clock)

        let old = try service.createBackup(reason: .manual) // day1, 건강한 A
        clock.set(calendar.startOfDay(WorkDate(year: 2026, month: 10, day: 10)))
        let latest = try service.createBackup(reason: .manual) // day10, 손상시킬 B

        try corruptWorkDatabase(in: latest)
        XCTAssertThrowsError(try service.verify(latest))
        XCTAssertNoThrow(try service.verify(old))

        // A는 보관 기간 밖이지만 유일하게 검증되는 복원 지점이므로 지우면 안 된다.
        clock.set(calendar.startOfDay(WorkDate(year: 2026, month: 11, day: 9)))
        let deleted = try service.applyRetention(keepDays: 5, lastBackupSucceeded: true)
        XCTAssertEqual(deleted, [], "검증되는 유일한 사본을 지우면 안 된다")
        XCTAssertEqual(Set(try service.listBackups().map(\.id)), Set([old.id, latest.id]))
        XCTAssertNoThrow(try service.verify(old))
    }

    // MARK: - #72: 새 백업 생성 실패 시 기존 정상 사본·live 데이터 보존

    func testFailedDailyBackupPreservesExistingBackupsAndRetentionKeepsThem() throws {
        let root = try makeRoot(), paths = makePaths(root: root)
        let clock = fixedClock(WorkDate(year: 2026, month: 10, day: 1))
        let ids = SequentialIDGenerator(prefix: "src")
        let stores = try openStores(paths, keyStore: InMemoryVaultKeyStore(), clock: clock, ids: ids)
        defer { stores.close() }
        let workDate = WorkDate(year: 2026, month: 10, day: 1)
        try stores.repo.insertMemo(Memo(id: ids.make(), body: "실패 보존", workDate: workDate,
                                        recordedAt: clock.now()))
        let service = makeService(paths, stores, clock: clock)

        let old = try service.createBackup(reason: .manual) // day1, 건강한 A
        clock.set(calendar.startOfDay(WorkDate(year: 2026, month: 10, day: 10)))
        let latest = try service.createBackup(reason: .manual) // day10, 손상시킬 B
        try corruptWorkDatabase(in: latest)

        // settings.json을 디렉터리로 바꿔 스테이징 복사 실패(ioFailed)를 유도한다.
        try mutateSettings(paths) { $0.secretIdleLockMinutes = 50 }
        try FileManager.default.removeItem(at: paths.settingsFile)
        try FileManager.default.createDirectory(at: paths.settingsFile, withIntermediateDirectories: false)

        clock.set(calendar.startOfDay(WorkDate(year: 2026, month: 11, day: 9)))
        XCTAssertThrowsError(try service.createDailyBackupIfChanged(calendar: calendar)) { error in
            guard case .ioFailed? = error as? BackupFailure else {
                return XCTFail("ioFailed를 기대했지만 \(error)")
            }
        }

        // 실패한 백업은 기존 사본을 건드리지 않고 임시 디렉터리도 남기지 않는다.
        XCTAssertEqual(try service.listBackups().map(\.id), [latest.id, old.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: latest.directory.path))
        let contents = try FileManager.default.contentsOfDirectory(atPath: paths.backupRoot.path)
        XCTAssertFalse(contents.contains { $0.hasPrefix(".tmp-") }, "임시 디렉터리가 남았다: \(contents)")
        XCTAssertEqual(try memoBodies(stores, on: workDate), ["실패 보존"])

        // 실패 플래그에서는 아무것도 지우지 않는다.
        XCTAssertEqual(try service.applyRetention(keepDays: 1, lastBackupSucceeded: false), [])
        XCTAssertEqual(Set(try service.listBackups().map(\.id)), Set([old.id, latest.id]))

        // 성공 플래그로 잘못 호출해도 검증되는 유일한 사본(A)은 남는다.
        XCTAssertEqual(try service.applyRetention(keepDays: 1, lastBackupSucceeded: true), [])
        XCTAssertNoThrow(try service.verify(old))
    }
}
