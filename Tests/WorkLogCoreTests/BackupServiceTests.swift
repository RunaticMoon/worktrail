import XCTest
@testable import WorkLogCore

/// BACKUP-01~03 / 기술설계 §11 / 흐름 E: 로컬 백업·검증·복원.
/// 모든 AppPaths는 임시 디렉터리로 만들고 실제 홈 경로를 쓰지 않는다.
final class BackupServiceTests: XCTestCase {

    private var tempRoots: [URL] = []

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
            .appendingPathComponent("BackupServiceTests-\(UUID().uuidString)", isDirectory: true)
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

    /// 임시 경로에 실제 파일 DB로 저장소를 구성한다. backupRoot는 만들지 않는다.
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
        FixedClock(WorkCalendar().startOfDay(date))
    }

    private func fileBytes(_ url: URL) -> Data? {
        FileManager.default.contents(atPath: url.path)
    }

    /// 접미사(-wal/-shm 포함) 별 바이트. DB가 닫힌 뒤 상태 비교에 쓴다.
    private func databaseBytes(_ url: URL) -> [String: Data] {
        var result: [String: Data] = [:]
        for suffix in ["", "-wal", "-shm"] {
            if let data = FileManager.default.contents(atPath: url.path + suffix) {
                result[suffix] = data
            }
        }
        return result
    }

    private func allFiles(in dir: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                files.append(url)
            }
        }
        return files
    }

    private func permissions(of url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func insertConfirmedReport(_ stores: Stores, now: Date) throws {
        try stores.workDB.run("""
            INSERT INTO source_snapshot
                (id, start, end_exclusive, state_cutoff, known_at, frozen_facts_json, digest, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, ["snap-1", "2026-09-28", "2026-10-05", "2026-10-05", now, "{}", "digest-1", now])
        try stores.workDB.run("""
            INSERT INTO report
                (id, family, period_type, period_key, start, end_exclusive, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, ["rep-1", "submission", "week", "2026-W40", "2026-09-28", "2026-10-05", now])
        try stores.workDB.run("""
            INSERT INTO report_version
                (id, report_id, version, state, content, structured_json, source_snapshot_id,
                 template_version_id, skill_ref, ai_model, generator, warnings_json,
                 based_on_version_id, created_at, confirmed_at)
            VALUES (?, ?, ?, ?, ?, NULL, ?, NULL, NULL, NULL, ?, '[]', NULL, ?, ?)
            """, ["rv-1", "rep-1", 1, "confirmed", "확정 본문", "snap-1", "deterministic", now, now])
    }

    // MARK: - BACK-T01: 백업 폴더 자동 생성

    func testBackupRootIsCreatedAutomatically() throws {
        let root = try makeRoot()
        let paths = makePaths(root: root)
        let stores = try openStores(paths, keyStore: InMemoryVaultKeyStore(),
                                    clock: fixedClock(), ids: SequentialIDGenerator())
        defer { stores.close() }

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.backupRoot.path),
                       "백업 폴더가 미리 있으면 안 된다")

        let service = makeService(paths, stores, clock: fixedClock())
        let url = try service.ensureBackupRoot()

        XCTAssertEqual(url, paths.backupRoot)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.backupRoot.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertEqual(permissions(of: paths.backupRoot), 0o700)
    }

    // MARK: - BACK-T02: 백업 생성·manifest 해시 검증 + daily 변경 감지

    func testCreateBackupProducesVerifiedManifest() throws {
        let root = try makeRoot()
        let paths = makePaths(root: root)
        let clock = fixedClock()
        let ids = SequentialIDGenerator(prefix: "src")
        let stores = try openStores(paths, keyStore: InMemoryVaultKeyStore(), clock: clock, ids: ids)
        defer { stores.close() }

        let service = WorkLogCore.TaskService(repo: stores.repo)
        _ = try service.createTask(title: "백업 업무", projectNames: ["Alpha"], note: "진행 기록")
        try stores.repo.insertMemo(Memo(id: ids.make(), body: "메모 본문",
                                        workDate: WorkDate(year: 2026, month: 10, day: 1),
                                        recordedAt: clock.now()))
        _ = try stores.vault.create(title: "서버", groupName: "infra",
                                    rows: [SecretRowInput(key: "API_KEY", value: "s3cret")])
        try Data("{\"defaultInputMode\":\"memo\"}".utf8).write(to: paths.settingsFile)

        let backupService = makeService(paths, stores, clock: clock)
        let info = try backupService.createBackup(reason: .manual)

        XCTAssertEqual(info.manifest.reason, .manual)
        XCTAssertEqual(info.manifest.formatVersion, 1)
        XCTAssertEqual(info.manifest.appDirectoryName, AppIdentity.default.directoryName)
        XCTAssertEqual(Set(info.manifest.files.map(\.name)),
                       Set(["work.sqlite", "vault.sqlite", "settings.json"]))
        XCTAssertEqual(info.manifest.workSchemaVersion, WorkSchema.migrations.map(\.version).max())

        // manifest의 해시·크기가 실제 파일과 일치한다.
        for entry in info.manifest.files {
            let data = try XCTUnwrap(fileBytes(info.directory.appendingPathComponent(entry.name)))
            XCTAssertEqual(data.count, entry.size, "\(entry.name) 크기 불일치")
            XCTAssertEqual(BackupService.sha256Hex(data), entry.sha256, "\(entry.name) 해시 불일치")
        }
        XCTAssertNoThrow(try backupService.verify(info))

        // 완성된 백업만 목록에 오른다.
        XCTAssertEqual(try backupService.listBackups().map(\.id), [info.id])
        XCTAssertEqual(backupService.status.lastSuccessAt, backupService.status.lastSuccessAt)
        XCTAssertNotNil(backupService.status.lastSuccessAt)
    }

    func testDailyBackupOnlyWhenChanged() throws {
        let root = try makeRoot()
        let paths = makePaths(root: root)
        let calendar = WorkCalendar()
        let clock = fixedClock(WorkDate(year: 2026, month: 10, day: 1))
        let ids = SequentialIDGenerator(prefix: "src")
        let stores = try openStores(paths, keyStore: InMemoryVaultKeyStore(), clock: clock, ids: ids)
        defer { stores.close() }

        let backupService = makeService(paths, stores, clock: clock)
        try stores.repo.insertMemo(Memo(id: ids.make(), body: "본문 1",
                                        workDate: WorkDate(year: 2026, month: 10, day: 1),
                                        recordedAt: clock.now()))

        let first = try backupService.createDailyBackupIfChanged(calendar: calendar)
        XCTAssertNotNil(first)

        // 같은 날 두 번째 호출은 nil.
        XCTAssertNil(try backupService.createDailyBackupIfChanged(calendar: calendar))

        // 다음 날, 변경 없음 → nil.
        clock.set(calendar.startOfDay(WorkDate(year: 2026, month: 10, day: 2)))
        XCTAssertNil(try backupService.createDailyBackupIfChanged(calendar: calendar))

        // 다음 날, 변경 있음 → 생성.
        try stores.repo.insertMemo(Memo(id: ids.make(), body: "본문 2",
                                        workDate: WorkDate(year: 2026, month: 10, day: 2),
                                        recordedAt: clock.now()))
        let changed = try backupService.createDailyBackupIfChanged(calendar: calendar)
        XCTAssertNotNil(changed)
        XCTAssertEqual(changed?.manifest.reason, .daily)

        // 같은 날 다시 호출 → nil.
        XCTAssertNil(try backupService.createDailyBackupIfChanged(calendar: calendar))
    }

    // MARK: - BACK-T03: 백업 중 실패 → 기존 성공본 보존

    func testFailedBackupKeepsExistingBackupAndCleansTemp() throws {
        let root = try makeRoot()
        let paths = makePaths(root: root)
        let clock = fixedClock()
        let stores = try openStores(paths, keyStore: InMemoryVaultKeyStore(),
                                    clock: clock, ids: SequentialIDGenerator())
        defer { stores.close() }
        try Data("{\"a\":1}".utf8).write(to: paths.settingsFile)

        let backupService = makeService(paths, stores, clock: clock)
        let success = try backupService.createBackup(reason: .manual)

        // settings.json을 디렉터리로 바꿔 복사 실패를 유도한다.
        try FileManager.default.removeItem(at: paths.settingsFile)
        try FileManager.default.createDirectory(at: paths.settingsFile, withIntermediateDirectories: false)

        XCTAssertThrowsError(try backupService.createBackup(reason: .manual)) { error in
            guard case .ioFailed? = error as? BackupFailure else {
                return XCTFail("ioFailed를 기대했지만 \(error)")
            }
        }

        // 기존 성공본은 그대로, 불완전본·임시 디렉터리 없음.
        let listed = try backupService.listBackups()
        XCTAssertEqual(listed.map(\.id), [success.id])
        let contents = try FileManager.default.contentsOfDirectory(atPath: paths.backupRoot.path)
        XCTAssertFalse(contents.contains { $0.hasPrefix(".tmp-") }, "임시 디렉터리가 남았다: \(contents)")
        XCTAssertNotNil(backupService.status.lastFailureAt)
        XCTAssertNotNil(backupService.status.lastFailureMessage)
    }

    // MARK: - BACK-T04: 백업에 키·Secret 평문이 없다

    func testBackupContainsCiphertextButNoKeyOrPlaintext() throws {
        let root = try makeRoot()
        let paths = makePaths(root: root)
        let clock = fixedClock()
        let keyStore = InMemoryVaultKeyStore()
        let stores = try openStores(paths, keyStore: keyStore, clock: clock,
                                    ids: SequentialIDGenerator(prefix: "src"))
        defer { stores.close() }

        let canary = "CANARY-BACKUP-55e1"
        _ = try stores.vault.create(title: "카나리아", groupName: nil,
                                    rows: [SecretRowInput(key: "CANARY_KEY", value: canary)])
        let keyVersion = try XCTUnwrap(stores.vault.keyVersion)
        let keyBytes = try XCTUnwrap(keyStore.loadKey(id: keyVersion))
        XCTAssertEqual(keyBytes.count, 32)

        let backupService = makeService(paths, stores, clock: clock)
        let info = try backupService.createBackup(reason: .manual)

        let names = Set(info.manifest.files.map(\.name))
        XCTAssertTrue(names.contains("vault.sqlite"), "vault.sqlite(암호문)는 포함되어야 한다")

        let canaryData = Data(canary.utf8)
        let files = allFiles(in: info.directory)
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let data = try XCTUnwrap(fileBytes(file))
            XCTAssertNil(data.range(of: canaryData), "\(file.lastPathComponent)에 Secret 평문이 남음")
            XCTAssertNil(data.range(of: keyBytes), "\(file.lastPathComponent)에 vault 키가 남음")
        }
    }

    // MARK: - BACK-T05: 손상된 manifest/DB는 검증 실패, 복원 시 원본 불변

    func testCorruptedBackupFailsVerificationAndLeavesTargetUntouched() throws {
        let root = try makeRoot()
        let sourcePaths = makePaths(root: root.appendingPathComponent("source"))
        let clock = fixedClock()
        let sourceStores = try openStores(sourcePaths, keyStore: InMemoryVaultKeyStore(),
                                          clock: clock, ids: SequentialIDGenerator(prefix: "src"))
        let sourceIds = SequentialIDGenerator(prefix: "sm")
        try sourceStores.repo.insertMemo(Memo(id: sourceIds.make(), body: "원본",
                                              workDate: WorkDate(year: 2026, month: 10, day: 1),
                                              recordedAt: clock.now()))
        _ = try sourceStores.vault.create(title: "원본", groupName: nil,
                                          rows: [SecretRowInput(key: "A", value: "1")])
        let backupService = makeService(sourcePaths, sourceStores, clock: clock)
        let info = try backupService.createBackup(reason: .manual)
        let originalManifest = try XCTUnwrap(fileBytes(info.directory.appendingPathComponent("manifest.json")))
        sourceStores.close()

        // 기존 데이터가 있는 복원 대상.
        let targetPaths = makePaths(root: root.appendingPathComponent("target"))
        let targetKeyStore = InMemoryVaultKeyStore()
        let targetStores = try openStores(targetPaths, keyStore: targetKeyStore, clock: clock,
                                          ids: SequentialIDGenerator(prefix: "tgt"))
        let targetIds = SequentialIDGenerator(prefix: "tm")
        try targetStores.repo.insertMemo(Memo(id: targetIds.make(), body: "기존",
                                              workDate: WorkDate(year: 2026, month: 10, day: 1),
                                              recordedAt: clock.now()))
        _ = try targetStores.vault.create(title: "기존", groupName: nil,
                                          rows: [SecretRowInput(key: "B", value: "2")])
        targetStores.close()
        let beforeWork = databaseBytes(targetPaths.workDatabase)
        let beforeVault = databaseBytes(targetPaths.vaultDatabase)

        // (1) manifest 손상.
        try Data("not a manifest".utf8).write(to: info.directory.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try backupService.verify(info)) { error in
            guard case .manifestInvalid? = error as? BackupFailure else {
                return XCTFail("manifestInvalid를 기대했지만 \(error)")
            }
        }

        // (2) manifest 복구 후 DB 1바이트 변조 → hashMismatch.
        try originalManifest.write(to: info.directory.appendingPathComponent("manifest.json"))
        let workURL = info.directory.appendingPathComponent("work.sqlite")
        var corrupted = try XCTUnwrap(fileBytes(workURL))
        corrupted[corrupted.count / 2] ^= 0xFF
        try corrupted.write(to: workURL)
        XCTAssertThrowsError(try backupService.verify(info)) { error in
            XCTAssertEqual(error as? BackupFailure, .hashMismatch(file: "work.sqlite"))
        }

        // 변조본 복원 시도 → 검증 실패, 대상 파일 바이트 불변.
        XCTAssertThrowsError(
            try BackupService.restore(info, into: targetPaths,
                                      keyStore: targetKeyStore, includeVault: true, clock: clock))
        XCTAssertEqual(databaseBytes(targetPaths.workDatabase), beforeWork)
        XCTAssertEqual(databaseBytes(targetPaths.vaultDatabase), beforeVault)
    }

    // MARK: - BACK-T06: 같은 키로 별도 대상에 복원

    func testRestoreRoundTripWithSharedKeyStore() throws {
        let root = try makeRoot()
        let clock = fixedClock()
        let keyStore = InMemoryVaultKeyStore()
        let sourcePaths = makePaths(root: root.appendingPathComponent("source"))
        let sourceIds = SequentialIDGenerator(prefix: "src")
        let sourceStores = try openStores(sourcePaths, keyStore: keyStore, clock: clock, ids: sourceIds)

        let taskService = WorkLogCore.TaskService(repo: sourceStores.repo)
        let task = try taskService.createTask(title: "복원 대상 업무", projectNames: ["P1"], note: "기록")
        let memoId = sourceIds.make()
        try sourceStores.repo.insertMemo(Memo(id: memoId, body: "복원 메모",
                                              workDate: WorkDate(year: 2026, month: 10, day: 1),
                                              recordedAt: clock.now()))
        _ = try taskService.addActivity(taskId: task.id, body: "추가 기록",
                                        workDate: WorkDate(year: 2026, month: 10, day: 2))
        let secret = try sourceStores.vault.create(title: "복원 Secret", groupName: "g",
                                                   rows: [SecretRowInput(key: "K", value: "V")])
        let sourceSecretRows = try sourceStores.vault.currentRows(secretId: secret.id)
        let sourceRevisionCount = try sourceStores.vault.revisions(secretId: secret.id).count
        try insertConfirmedReport(sourceStores, now: clock.now())

        let backupService = makeService(sourcePaths, sourceStores, clock: clock)
        let info = try backupService.createBackup(reason: .manual)
        sourceStores.close()

        // 복원 대상에 기존 데이터가 있어 preRestore 백업이 남아야 한다.
        let targetPaths = makePaths(root: root.appendingPathComponent("target"))
        let targetStores = try openStores(targetPaths, keyStore: keyStore, clock: clock,
                                          ids: SequentialIDGenerator(prefix: "tgt"))
        let oldMemo = SequentialIDGenerator(prefix: "old").make()
        try targetStores.repo.insertMemo(Memo(id: oldMemo, body: "복원 전 데이터",
                                              workDate: WorkDate(year: 2026, month: 10, day: 1),
                                              recordedAt: clock.now()))
        targetStores.close()

        try BackupService.restore(info, into: targetPaths, keyStore: keyStore,
                                  includeVault: true, clock: clock)

        let restored = try openStores(targetPaths, keyStore: keyStore, clock: clock,
                                      ids: SequentialIDGenerator(prefix: "re"))
        defer { restored.close() }

        // 일반 기록.
        XCTAssertNil(try restored.repo.memo(id: oldMemo), "복원 전 메모가 남아 있으면 안 된다")
        let memo = try XCTUnwrap(try restored.repo.memo(id: memoId))
        XCTAssertEqual(memo.body, "복원 메모")
        XCTAssertEqual(try restored.repo.tasks().count, 1)
        XCTAssertEqual(try restored.repo.task(id: task.id)?.title, "복원 대상 업무")
        XCTAssertEqual(try restored.repo.activities(taskId: task.id).count, 2)

        // 확정 리포트.
        XCTAssertEqual(try restored.workDB.scalarInt(
            "SELECT COUNT(*) AS c FROM report_version WHERE state = 'confirmed'"), 1)

        // Secret revision·현재 값.
        let restoredRows = try restored.vault.currentRows(secretId: secret.id)
        XCTAssertEqual(restoredRows.count, sourceSecretRows.count)
        XCTAssertEqual(restoredRows.first { $0.key == "K" }?.value, "V")
        XCTAssertEqual(try restored.vault.revisions(secretId: secret.id).count, sourceRevisionCount)

        // 복원 전 보존본이 preRestore 사유로 남아 있다.
        let backups = try BackupService(paths: targetPaths, workDB: restored.workDB,
                                        vaultDB: restored.vaultDB, clock: clock).listBackups()
        XCTAssertTrue(backups.contains { $0.manifest.reason == .preRestore },
                      "복원 전 데이터가 preRestore 백업으로 보존되어야 한다")
    }

    // MARK: - BACK-T07: 키 없는 복원

    func testRestoreWithoutVaultKeyPreservesTargetVault() throws {
        let root = try makeRoot()
        let clock = fixedClock()
        let sourceKeyStore = InMemoryVaultKeyStore()
        let sourcePaths = makePaths(root: root.appendingPathComponent("source"))
        let sourceIds = SequentialIDGenerator(prefix: "src")
        let sourceStores = try openStores(sourcePaths, keyStore: sourceKeyStore, clock: clock, ids: sourceIds)
        let memoId = sourceIds.make()
        try sourceStores.repo.insertMemo(Memo(id: memoId, body: "일반 기록",
                                              workDate: WorkDate(year: 2026, month: 10, day: 1),
                                              recordedAt: clock.now()))
        _ = try sourceStores.vault.create(title: "복원 Secret", groupName: nil,
                                          rows: [SecretRowInput(key: "K", value: "V")])
        let sourceKeyVersion = try XCTUnwrap(sourceStores.vault.keyVersion)
        let backupService = makeService(sourcePaths, sourceStores, clock: clock)
        let info = try backupService.createBackup(reason: .manual)
        sourceStores.close()

        // 대상은 자기 키로 자기 vault를 가진다.
        let targetKeyStore = InMemoryVaultKeyStore()
        let targetPaths = makePaths(root: root.appendingPathComponent("target"))
        let targetIds = SequentialIDGenerator(prefix: "tgt")
        let targetStores = try openStores(targetPaths, keyStore: targetKeyStore, clock: clock, ids: targetIds)
        let targetSecret = try targetStores.vault.create(title: "대상 Secret", groupName: nil,
                                                         rows: [SecretRowInput(key: "T", value: "T")])
        targetStores.close()
        let beforeVault = databaseBytes(targetPaths.vaultDatabase)

        // 키 없는 복원 → vaultKeyMissing, 대상 vault 불변.
        let emptyKeyStore = InMemoryVaultKeyStore()
        XCTAssertThrowsError(
            try BackupService.restore(info, into: targetPaths, keyStore: emptyKeyStore,
                                      includeVault: true, clock: clock)) { error in
            XCTAssertEqual(error as? BackupFailure, .vaultKeyMissing(keyVersion: sourceKeyVersion))
        }
        XCTAssertEqual(databaseBytes(targetPaths.vaultDatabase), beforeVault)

        // includeVault: false → 일반 기록만 복원, 대상 vault는 그대로.
        try BackupService.restore(info, into: targetPaths, keyStore: emptyKeyStore,
                                  includeVault: false, clock: clock)
        XCTAssertEqual(databaseBytes(targetPaths.vaultDatabase), beforeVault)

        let restored = try openStores(targetPaths, keyStore: targetKeyStore, clock: clock,
                                      ids: SequentialIDGenerator(prefix: "re"))
        defer { restored.close() }
        XCTAssertEqual(try restored.repo.memo(id: memoId)?.body, "일반 기록")
        // 대상 vault의 원래 Secret은 살아 있다.
        XCTAssertEqual(try restored.vault.currentRows(secretId: targetSecret.id).first?.value, "T")
    }

    // MARK: - BACK-T08: 보존 정리

    func testRetentionKeepsNewestAndRespectsFailureFlag() throws {
        let root = try makeRoot()
        let paths = makePaths(root: root)
        let calendar = WorkCalendar()
        let clock = fixedClock(WorkDate(year: 2026, month: 10, day: 1))
        let stores = try openStores(paths, keyStore: InMemoryVaultKeyStore(),
                                    clock: clock, ids: SequentialIDGenerator(prefix: "src"))
        defer { stores.close() }
        let backupService = makeService(paths, stores, clock: clock)

        // day1, day2, day3, day10 백업.
        let days = [1, 2, 3, 10]
        var infos: [BackupInfo] = []
        for day in days {
            clock.set(calendar.startOfDay(WorkDate(year: 2026, month: 10, day: day)))
            infos.append(try backupService.createBackup(reason: .manual))
        }
        XCTAssertEqual(try backupService.listBackups().count, 4)

        // 새 백업 실패 시에는 아무것도 지우지 않는다.
        XCTAssertEqual(try backupService.applyRetention(keepDays: 5, lastBackupSucceeded: false), [])
        XCTAssertEqual(try backupService.listBackups().count, 4)

        // 성공 시 오래된 것만 지우고 최신 1개는 보존한다.
        let deleted = try backupService.applyRetention(keepDays: 5, lastBackupSucceeded: true)
        XCTAssertEqual(Set(deleted), Set(infos.prefix(3).map(\.id)))
        let remaining = try backupService.listBackups()
        XCTAssertEqual(remaining.map(\.id), [infos[3].id])

        // 백업이 1개뿐이면 아무리 오래돼도 지우지 않는다.
        clock.set(calendar.startOfDay(WorkDate(year: 2027, month: 1, day: 1)))
        XCTAssertEqual(try backupService.applyRetention(keepDays: 1, lastBackupSucceeded: true), [])
        XCTAssertEqual(try backupService.listBackups().count, 1)
    }

    // MARK: - BACK-T09: manifest의 vault key_version 대조

    func testVerifyRejectsManifestKeyVersionMismatch() throws {
        let root = try makeRoot()
        let paths = makePaths(root: root)
        let clock = fixedClock()
        let stores = try openStores(paths, keyStore: InMemoryVaultKeyStore(), clock: clock,
                                    ids: SequentialIDGenerator(prefix: "src"))
        defer { stores.close() }
        _ = try stores.vault.create(title: "서버", groupName: nil,
                                    rows: [SecretRowInput(key: "K", value: "V")])

        let backupService = makeService(paths, stores, clock: clock)
        let info = try backupService.createBackup(reason: .manual)
        XCTAssertEqual(info.manifest.vaultKeyVersion, try stores.vault.keyVersion)

        // manifest의 vaultKeyVersion만 다른 값으로 바꿔 다시 기록한다(파일 해시 대상이 아니다).
        let manifestURL = info.directory.appendingPathComponent("manifest.json")
        var manifest = try StableJSON.decode(BackupManifest.self,
                                             from: try XCTUnwrap(fileBytes(manifestURL)))
        manifest.vaultKeyVersion = "tampered-key-version"
        try StableJSON.encode(manifest).write(to: manifestURL)

        let reread = try XCTUnwrap(try backupService.listBackups().first)
        XCTAssertThrowsError(try backupService.verify(reread)) { error in
            guard case .manifestInvalid? = error as? BackupFailure else {
                return XCTFail("manifestInvalid를 기대했지만 \(error)")
            }
        }
    }

    // MARK: - BACK-T10: 같은 키 id지만 다른 키 바이트 → 시험 복호화 실패, 대상 불변

    func testRestoreRejectsWrongKeyBytesAndLeavesTargetUntouched() throws {
        let root = try makeRoot()
        let clock = fixedClock()
        let sourceKeyStore = InMemoryVaultKeyStore()
        let sourcePaths = makePaths(root: root.appendingPathComponent("source"))
        let sourceStores = try openStores(sourcePaths, keyStore: sourceKeyStore, clock: clock,
                                          ids: SequentialIDGenerator(prefix: "src"))
        _ = try sourceStores.vault.create(title: "Secret", groupName: nil,
                                          rows: [SecretRowInput(key: "K", value: "V")])
        let sourceKeyVersion = try XCTUnwrap(sourceStores.vault.keyVersion)
        let sourceKeyBytes = try XCTUnwrap(sourceKeyStore.loadKey(id: sourceKeyVersion))
        let backupService = makeService(sourcePaths, sourceStores, clock: clock)
        let info = try backupService.createBackup(reason: .manual)
        sourceStores.close()

        // 같은 키 id에 다른 바이트를 넣은 KeyStore.
        let wrongKeyStore = InMemoryVaultKeyStore()
        var wrongBytes = sourceKeyBytes
        wrongBytes[0] ^= 0xFF
        try wrongKeyStore.storeKey(wrongBytes, id: sourceKeyVersion)

        // 복원 대상에 기존 데이터가 있다(불변이어야 함).
        let targetPaths = makePaths(root: root.appendingPathComponent("target"))
        let targetStores = try openStores(targetPaths, keyStore: InMemoryVaultKeyStore(), clock: clock,
                                          ids: SequentialIDGenerator(prefix: "tgt"))
        try targetStores.repo.insertMemo(Memo(id: "old", body: "기존",
                                              workDate: WorkDate(year: 2026, month: 10, day: 1),
                                              recordedAt: clock.now()))
        targetStores.close()
        let beforeWork = databaseBytes(targetPaths.workDatabase)
        let beforeVault = databaseBytes(targetPaths.vaultDatabase)

        XCTAssertThrowsError(
            try BackupService.restore(info, into: targetPaths, keyStore: wrongKeyStore,
                                      includeVault: true, clock: clock)) { error in
            guard case .vaultKeyMismatch(let version)? = error as? BackupFailure else {
                return XCTFail("vaultKeyMismatch를 기대했지만 \(error)")
            }
            XCTAssertEqual(version, sourceKeyVersion)
        }

        // 대상 파일은 그대로이고, preRestore 백업이 만들어지지 않았다.
        XCTAssertEqual(databaseBytes(targetPaths.workDatabase), beforeWork)
        XCTAssertEqual(databaseBytes(targetPaths.vaultDatabase), beforeVault)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetPaths.backupRoot.path),
                       "검증 실패인데 preRestore 백업이 생겼다")
    }

    // MARK: - BACK-T11: 롤백이 새로 놓은 파일까지 제거

    func testRestoreRollbackRemovesNewlyPlacedFiles() throws {
        let root = try makeRoot()
        let clock = fixedClock()
        let keyStore = InMemoryVaultKeyStore()
        let sourcePaths = makePaths(root: root.appendingPathComponent("source"))
        let sourceStores = try openStores(sourcePaths, keyStore: keyStore, clock: clock,
                                          ids: SequentialIDGenerator(prefix: "src"))
        _ = try sourceStores.vault.create(title: "Secret", groupName: nil,
                                          rows: [SecretRowInput(key: "K", value: "V")])
        let backupService = makeService(sourcePaths, sourceStores, clock: clock)
        let info = try backupService.createBackup(reason: .manual)
        sourceStores.close()

        // 대상에는 아직 아무 파일도 없다.
        let targetPaths = makePaths(root: root.appendingPathComponent("target"))
        try FileManager.default.createDirectory(at: targetPaths.dataRoot,
                                                withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try BackupService.restore(info, into: targetPaths, keyStore: keyStore,
                                      includeVault: true, clock: clock) { name in
                // 첫 파일(work.sqlite)은 이미 놓였고, 두 번째 배치 직전에 실패를 주입한다.
                if name == "vault.sqlite" { throw BackupFailure.ioFailed("주입 오류") }
            }) { error in
            guard case .ioFailed? = error as? BackupFailure else {
                return XCTFail("ioFailed를 기대했지만 \(error)")
            }
        }

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: targetPaths.workDatabase.path),
                       "새로 놓은 work.sqlite가 남았다")
        XCTAssertFalse(fm.fileExists(atPath: targetPaths.vaultDatabase.path),
                       "새로 놓은 vault.sqlite가 남았다")
        let leftovers = allFiles(in: targetPaths.dataRoot).map(\.lastPathComponent)
        XCTAssertFalse(leftovers.contains { $0.contains(".restore-") }, "temp 파일이 남았다: \(leftovers)")
        XCTAssertFalse(leftovers.contains { $0.contains(".stash-") }, "stash 파일이 남았다: \(leftovers)")
        XCTAssertFalse(fm.fileExists(atPath: targetPaths.backupRoot.path),
                       "대상에 원본이 없었는데 preRestore 백업이 생겼다")
    }
}
