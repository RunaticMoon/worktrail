import Foundation
import Crypto

/// 로컬 백업 생성·검증·복원 서비스.
///
/// - `backupRoot`에 work.sqlite·vault.sqlite·settings.json의 일관된 스냅샷을 원자적으로 만든다.
/// - manifest의 SHA256·크기와 DB integrity_check, 스키마 버전으로 검증한다.
/// - 복원 전 현재 데이터를 preRestore 백업으로 보존하고, 검증된 뒤에만 교체한다.
/// - 키 값·토큰은 절대 백업하지 않는다. vault.sqlite는 암호문 그대로 포함한다.
///
/// 두 DB의 스냅샷 시점은 `writeBarrier`로 맞춘다. barrier가 없으면 순서대로 스냅샷한다
/// (두 DB가 완전히 같은 순간을 보장하지는 않는다는 한계는 설계 §11의 짧은 저장 barrier 제안을 따른다).
public final class BackupService: @unchecked Sendable {
    public static let workFileName = "work.sqlite"
    public static let vaultFileName = "vault.sqlite"
    public static let settingsFileName = "settings.json"
    public static let manifestFileName = "manifest.json"
    private static let tmpPrefix = ".tmp-"

    private let paths: AppPaths
    private let workDB: SQLiteDatabase
    private let vaultDB: SQLiteDatabase
    private let identity: AppIdentity
    private let clock: Clock
    private let ids: IDGenerator
    private let writeBarrier: ((() throws -> Void) throws -> Void)?

    private let statusLock = NSLock()
    private var _status = BackupStatus()

    public init(paths: AppPaths, workDB: SQLiteDatabase, vaultDB: SQLiteDatabase,
                identity: AppIdentity = .default, clock: Clock = SystemClock(),
                ids: IDGenerator = UUIDGenerator(),
                writeBarrier: ((() throws -> Void) throws -> Void)? = nil) {
        self.paths = paths
        self.workDB = workDB
        self.vaultDB = vaultDB
        self.identity = identity
        self.clock = clock
        self.ids = ids
        self.writeBarrier = writeBarrier
    }

    // MARK: - 상태

    public var status: BackupStatus {
        statusLock.lock(); defer { statusLock.unlock() }
        return _status
    }

    private func markSuccess() {
        statusLock.lock(); defer { statusLock.unlock() }
        _status.lastSuccessAt = clock.now()
    }

    private func markFailure(_ error: Error) {
        let failure = BackupFailure.from(error)
        statusLock.lock(); defer { statusLock.unlock() }
        _status.lastFailureAt = clock.now()
        _status.lastFailureMessage = String(describing: failure)
    }

    // MARK: - 백업 루트

    /// `~/<앱이름>/backups/`를 0700 권한으로 자동 생성한다. 사용자에게 위치를 묻지 않는다.
    @discardableResult
    public func ensureBackupRoot() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.backupRoot, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.backupRoot.path)
        return paths.backupRoot
    }

    // MARK: - 백업 생성

    /// 두 DB와 settings.json(있으면)의 일관된 스냅샷을 원자적으로 만든다.
    /// 어느 단계든 실패하면 임시 디렉터리를 지우고 기존 백업은 건드리지 않는다.
    public func createBackup(reason: BackupReason) throws -> BackupInfo {
        do {
            let root = try ensureBackupRoot()
            let staged = try Self.stageBackup(root: root, reason: reason, clock: clock, ids: ids,
                                              writeBarrier: writeBarrier,
                                              sources: stagedSources(),
                                              appDirectoryName: identity.directoryName)
            let info = try Self.finalize(staged, root: root)
            markSuccess()
            return info
        } catch {
            markFailure(error)
            throw BackupFailure.from(error)
        }
    }

    /// 오늘(지역 날짜) 성공한 daily/manual 백업이 없고, 최신 백업 대비 work/vault 스냅샷 해시가
    /// 달라졌을 때만 백업한다. 변경이 없으면 임시본을 삭제하고 nil을 돌려준다.
    public func createDailyBackupIfChanged(calendar: WorkCalendar) throws -> BackupInfo? {
        do {
            let backups = try listBackups()
            let today = calendar.workDate(of: clock.now())
            let alreadyToday = backups.contains { info in
                (info.manifest.reason == .daily || info.manifest.reason == .manual)
                    && calendar.workDate(of: info.manifest.createdAt) == today
            }
            guard !alreadyToday else { return nil }

            let latest = backups.first
            let root = try ensureBackupRoot()
            let staged = try Self.stageBackup(root: root, reason: .daily, clock: clock, ids: ids,
                                              writeBarrier: writeBarrier,
                                              sources: stagedSources(),
                                              appDirectoryName: identity.directoryName)
            guard Self.snapshotChanged(staged: staged, latest: latest) else {
                try? FileManager.default.removeItem(at: staged.tmpDir)
                return nil
            }
            let info = try Self.finalize(staged, root: root)
            markSuccess()
            return info
        } catch {
            markFailure(error)
            throw BackupFailure.from(error)
        }
    }

    // MARK: - 목록 · 보존

    /// 완성된(manifest가 있는) 백업만 최신순으로 돌려준다. `.tmp-*`·manifest 손상본은 제외한다.
    public func listBackups() throws -> [BackupInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: paths.backupRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }
        var infos: [BackupInfo] = []
        for dir in entries {
            if dir.lastPathComponent.hasPrefix(Self.tmpPrefix) { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let manifestURL = dir.appendingPathComponent(Self.manifestFileName)
            guard let data = fm.contents(atPath: manifestURL.path),
                  let manifest = try? StableJSON.decode(BackupManifest.self, from: data) else { continue }
            infos.append(BackupInfo(id: manifest.backupId, directory: dir, manifest: manifest))
        }
        infos.sort { a, b in
            if a.manifest.createdAt != b.manifest.createdAt { return a.manifest.createdAt > b.manifest.createdAt }
            return a.id > b.id
        }
        return infos
    }

    /// keepDays보다 오래된 완성 백업을 삭제한다. 가장 최신 1개는 항상 보존한다.
    /// `lastBackupSucceeded == false`면 아무것도 지우지 않는다(실패한 백업 때문에 기존 성공본을 삭제하지 않음).
    @discardableResult
    public func applyRetention(keepDays: Int, lastBackupSucceeded: Bool) throws -> [String] {
        guard lastBackupSucceeded else { return [] }
        let backups = try listBackups()
        guard backups.count > 1 else { return [] }
        let now = clock.now()
        let cutoff = TimeInterval(max(0, keepDays)) * 86_400
        var deleted: [String] = []
        for (index, info) in backups.enumerated() where index > 0 {
            guard now.timeIntervalSince(info.manifest.createdAt) > cutoff else { continue }
            try FileManager.default.removeItem(at: info.directory)
            deleted.append(info.id)
        }
        return deleted
    }

    // MARK: - 검증

    /// manifest 존재·형식, 파일별 SHA256·크기, DB integrity_check, 스키마 버전 상한을 확인한다.
    public func verify(_ backup: BackupInfo) throws {
        try Self.verifyBackup(backup)
    }

    // MARK: - 내부: 스테이징

    /// 스냅샷 대상. live DB는 Online Backup API로, 닫힌 파일은 바이트 복사로 처리한다.
    enum StagedSource {
        case database(SQLiteDatabase, name: String)
        case file(URL, name: String)

        var name: String {
            switch self {
            case .database(_, let name): return name
            case .file(_, let name): return name
            }
        }
    }

    struct Staged {
        let id: String
        let tmpDir: URL
        let manifest: BackupManifest
        let timestampName: String
    }

    private func stagedSources() -> [StagedSource] {
        var sources: [StagedSource] = [
            .database(workDB, name: Self.workFileName),
            .database(vaultDB, name: Self.vaultFileName),
        ]
        // settings.json은 파일이든 디렉터리든 존재하면 복사 대상에 넣는다(디렉터리면 복사 실패로 처리).
        if FileManager.default.fileExists(atPath: paths.settingsFile.path) {
            sources.append(.file(paths.settingsFile, name: Self.settingsFileName))
        }
        return sources
    }

    private static func stageBackup(root: URL, reason: BackupReason, clock: Clock, ids: IDGenerator,
                                    writeBarrier: ((() throws -> Void) throws -> Void)?,
                                    sources: [StagedSource],
                                    appDirectoryName: String) throws -> Staged {
        let fm = FileManager.default
        let id = ids.make()
        let createdAt = clock.now()
        let tmpDir = root.appendingPathComponent("\(tmpPrefix)\(id)", isDirectory: true)
        try? fm.removeItem(at: tmpDir)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        do {
            let snapshot: () throws -> Void = {
                for source in sources {
                    switch source {
                    case .database(let db, let name):
                        try db.backup(to: tmpDir.appendingPathComponent(name).path)
                    case .file(let url, let name):
                        var isDir: ObjCBool = false
                        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                            throw BackupFailure.ioFailed("복사할 수 없는 경로입니다: \(name)")
                        }
                        let dest = tmpDir.appendingPathComponent(name)
                        try? fm.removeItem(at: dest)
                        try fm.copyItem(at: url, to: dest)
                    }
                }
            }
            if let writeBarrier {
                try writeBarrier(snapshot)
            } else {
                try snapshot()
            }

            var entries: [BackupFileEntry] = []
            for source in sources {
                let url = tmpDir.appendingPathComponent(source.name)
                guard let data = fm.contents(atPath: url.path) else {
                    throw BackupFailure.ioFailed("백업 파일을 읽을 수 없습니다: \(source.name)")
                }
                try setPermissions(0o600, at: url)
                entries.append(BackupFileEntry(name: source.name, sha256: sha256Hex(data), size: data.count))
            }

            var workSchemaVersion = 0
            var vaultSchemaVersion = 0
            var vaultKeyVersion: String?
            for entry in entries where entry.name.hasSuffix(".sqlite") {
                let url = tmpDir.appendingPathComponent(entry.name)
                let check = try SQLiteDatabase(path: url.path, readOnly: true)
                defer { check.close() }
                guard try check.integrityCheck() else {
                    throw BackupFailure.integrityFailed(file: entry.name)
                }
                if entry.name == workFileName {
                    workSchemaVersion = check.userVersion
                } else if entry.name == vaultFileName {
                    vaultSchemaVersion = check.userVersion
                    vaultKeyVersion = try? check.queryOne(
                        "SELECT value FROM vault_meta WHERE key = ?", ["key_version"])?.string("value")
                }
            }

            let manifest = BackupManifest(
                formatVersion: 1,
                backupId: id,
                appDirectoryName: appDirectoryName,
                createdAt: createdAt,
                reason: reason,
                workSchemaVersion: workSchemaVersion,
                vaultSchemaVersion: vaultSchemaVersion,
                vaultKeyVersion: vaultKeyVersion,
                files: entries)
            let manifestURL = tmpDir.appendingPathComponent(manifestFileName)
            try StableJSON.encode(manifest).write(to: manifestURL, options: .atomic)
            try setPermissions(0o600, at: manifestURL)

            return Staged(id: id, tmpDir: tmpDir, manifest: manifest,
                          timestampName: timestampName(createdAt))
        } catch {
            try? fm.removeItem(at: tmpDir)
            throw BackupFailure.from(error)
        }
    }

    private static func finalize(_ staged: Staged, root: URL) throws -> BackupInfo {
        let fm = FileManager.default
        let base = "\(staged.timestampName)-\(String(staged.id.prefix(8)))"
        var finalDir = root.appendingPathComponent(base, isDirectory: true)
        var counter = 2
        while fm.fileExists(atPath: finalDir.path) {
            finalDir = root.appendingPathComponent("\(base)-\(counter)", isDirectory: true)
            counter += 1
        }
        do {
            try fm.moveItem(at: staged.tmpDir, to: finalDir)
            try setPermissions(0o700, at: finalDir)
        } catch {
            try? fm.removeItem(at: staged.tmpDir)
            throw BackupFailure.from(error)
        }
        return BackupInfo(id: staged.id, directory: finalDir, manifest: staged.manifest)
    }

    /// 최신 백업 대비 work/vault 스냅샷 해시가 달라졌는지.
    private static func snapshotChanged(staged: Staged, latest: BackupInfo?) -> Bool {
        guard let latest else { return true }
        for name in [workFileName, vaultFileName] {
            let newHash = staged.manifest.files.first { $0.name == name }?.sha256
            let oldHash = latest.manifest.files.first { $0.name == name }?.sha256
            if newHash != oldHash { return true }
        }
        return false
    }

    // MARK: - 내부: 검증

    static func verifyBackup(_ backup: BackupInfo) throws {
        let fm = FileManager.default
        let manifestURL = backup.directory.appendingPathComponent(manifestFileName)
        guard fm.fileExists(atPath: manifestURL.path),
              let data = fm.contents(atPath: manifestURL.path) else {
            throw BackupFailure.manifestMissing
        }
        let manifest: BackupManifest
        do {
            manifest = try StableJSON.decode(BackupManifest.self, from: data)
        } catch {
            throw BackupFailure.manifestInvalid("manifest.json을 해석할 수 없습니다: \(error)")
        }
        guard manifest.formatVersion == 1 else {
            throw BackupFailure.manifestInvalid("지원하지 않는 백업 형식 버전: \(manifest.formatVersion)")
        }
        let maxWork = WorkSchema.migrations.map(\.version).max() ?? 0
        let maxVault = VaultSchema.migrations.map(\.version).max() ?? 0
        guard manifest.workSchemaVersion <= maxWork else {
            throw BackupFailure.unsupportedSchema(
                "work 스키마 \(manifest.workSchemaVersion)는 앱이 아는 최대 \(maxWork)보다 큽니다")
        }
        guard manifest.vaultSchemaVersion <= maxVault else {
            throw BackupFailure.unsupportedSchema(
                "vault 스키마 \(manifest.vaultSchemaVersion)는 앱이 아는 최대 \(maxVault)보다 큽니다")
        }

        for entry in manifest.files {
            let url = backup.directory.appendingPathComponent(entry.name)
            guard let bytes = fm.contents(atPath: url.path),
                  bytes.count == entry.size,
                  sha256Hex(bytes) == entry.sha256 else {
                throw BackupFailure.hashMismatch(file: entry.name)
            }
        }
        for entry in manifest.files where entry.name.hasSuffix(".sqlite") {
            let url = backup.directory.appendingPathComponent(entry.name)
            do {
                let db = try SQLiteDatabase(path: url.path, readOnly: true)
                defer { db.close() }
                guard try db.integrityCheck() else {
                    throw BackupFailure.integrityFailed(file: entry.name)
                }
            } catch let failure as BackupFailure {
                throw failure
            } catch {
                throw BackupFailure.integrityFailed(file: entry.name)
            }
        }
    }

    // MARK: - 복원

    /// `target`에 백업을 복원한다.
    ///
    /// 순서: verify → (includeVault면) 키 존재 확인(없으면 `.vaultKeyMissing`, 아무 파일도 바꾸지 않음)
    /// → target의 기존 데이터를 preRestore 백업으로 보존 → 검증된 사본을 임시 이름으로 복사·해시 재확인
    /// → 대상 DB의 -wal/-shm 제거 후 rename으로 교체.
    ///
    /// 호출자는 복원 전에 target의 DB 연결을 닫아야 한다(파일을 교체하므로).
    /// `includeVault == false`면 work.sqlite·settings.json만 복원한다(키 없는 환경의 일반 기록 복구).
    public static func restore(_ backup: BackupInfo, into target: AppPaths,
                               keyStore: VaultKeyStore, includeVault: Bool = true,
                               clock: Clock = SystemClock()) throws {
        try verifyBackup(backup)
        let manifest = backup.manifest
        let fm = FileManager.default

        let hasVault = manifest.files.contains { $0.name == vaultFileName }
        if includeVault, hasVault {
            guard let keyVersion = manifest.vaultKeyVersion else {
                throw BackupFailure.vaultKeyMissing(keyVersion: nil)
            }
            let key = try? keyStore.loadKey(id: keyVersion)
            guard let key, !key.isEmpty else {
                throw BackupFailure.vaultKeyMissing(keyVersion: keyVersion)
            }
        }

        var restoreNames: [String] = []
        if manifest.files.contains(where: { $0.name == workFileName }) { restoreNames.append(workFileName) }
        if includeVault, hasVault { restoreNames.append(vaultFileName) }
        if manifest.files.contains(where: { $0.name == settingsFileName }) {
            restoreNames.append(settingsFileName)
        }

        // 기존 데이터 보존(복원 지점).
        _ = try makePreRestoreBackup(target: target, clock: clock)

        try fm.createDirectory(at: target.dataRoot, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: target.workDatabase.deletingLastPathComponent(),
                               withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: target.vaultDatabase.deletingLastPathComponent(),
                               withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let token = String(UUID().uuidString.lowercased().prefix(8))
        var prepared: [(temp: URL, final: URL, name: String)] = []
        do {
            for name in restoreNames {
                let src = backup.directory.appendingPathComponent(name)
                let dst = destinationURL(for: name, in: target)
                let temp = dst.deletingLastPathComponent()
                    .appendingPathComponent("\(name).restore-\(token)")
                try? fm.removeItem(at: temp)
                try fm.copyItem(at: src, to: temp)
                try setPermissions(0o600, at: temp)
                guard let bytes = fm.contents(atPath: temp.path),
                      let entry = manifest.files.first(where: { $0.name == name }),
                      bytes.count == entry.size,
                      sha256Hex(bytes) == entry.sha256 else {
                    throw BackupFailure.hashMismatch(file: name)
                }
                prepared.append((temp, dst, name))
            }

            // 교체 전 원본을 잠시 옮겨 두고, 실패하면 되돌린다.
            var stashed: [(stash: URL, final: URL)] = []
            do {
                for item in prepared where fm.fileExists(atPath: item.final.path) {
                    let stash = item.final.deletingLastPathComponent()
                        .appendingPathComponent("\(item.name).stash-\(token)")
                    try? fm.removeItem(at: stash)
                    try fm.moveItem(at: item.final, to: stash)
                    stashed.append((stash, item.final))
                }
                for item in prepared where item.name.hasSuffix(".sqlite") {
                    try? fm.removeItem(atPath: item.final.path + "-wal")
                    try? fm.removeItem(atPath: item.final.path + "-shm")
                }
                for item in prepared {
                    try fm.moveItem(at: item.temp, to: item.final)
                    try setPermissions(0o600, at: item.final)
                }
                for entry in stashed { try? fm.removeItem(at: entry.stash) }
            } catch {
                // 되돌리기: 새로 놓은 것을 지우고 stash를 복구한다.
                for item in prepared {
                    if fm.fileExists(atPath: item.temp.path) { try? fm.removeItem(at: item.temp) }
                }
                for entry in stashed {
                    try? fm.removeItem(at: entry.final)
                    try? fm.moveItem(at: entry.stash, to: entry.final)
                }
                throw BackupFailure.from(error)
            }
        } catch {
            for item in prepared { try? fm.removeItem(at: item.temp) }
            throw BackupFailure.from(error)
        }
    }

    /// 복원 대상 파일 경로. includeVault와 무관하게 이름으로만 결정한다.
    private static func destinationURL(for name: String, in target: AppPaths) -> URL {
        switch name {
        case workFileName: return target.workDatabase
        case vaultFileName: return target.vaultDatabase
        case settingsFileName: return target.settingsFile
        default: return target.dataRoot.appendingPathComponent(name)
        }
    }

    /// 복원 직전 target의 기존 데이터를 파일 복사 방식으로 preRestore 백업한다.
    /// 기존 파일이 하나도 없으면 nil.
    @discardableResult
    static func makePreRestoreBackup(target: AppPaths, clock: Clock,
                                     ids: IDGenerator = UUIDGenerator()) throws -> BackupInfo? {
        let fm = FileManager.default
        var sources: [StagedSource] = []
        let candidates: [(String, URL)] = [
            (workFileName, target.workDatabase),
            (vaultFileName, target.vaultDatabase),
            (settingsFileName, target.settingsFile),
        ]
        for (name, url) in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                sources.append(.file(url, name: name))
            }
        }
        guard !sources.isEmpty else { return nil }
        let root = target.backupRoot
        try fm.createDirectory(at: root, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let staged = try stageBackup(root: root, reason: .preRestore, clock: clock, ids: ids,
                                     writeBarrier: nil, sources: sources,
                                     appDirectoryName: AppIdentity.default.directoryName)
        return try finalize(staged, root: root)
    }

    // MARK: - 유틸

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func timestampName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func setPermissions(_ permissions: Int, at url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}
