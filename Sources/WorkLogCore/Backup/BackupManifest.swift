import Foundation

// MARK: - 백업 사유

/// 백업을 만든 계기. daily/manual은 일일 보존 대상, pre*는 복원·마이그레이션 직전 보존본이다.
public enum BackupReason: String, Codable, Sendable {
    case daily
    case manual
    case preMigration = "pre_migration"
    case preRestore = "pre_restore"
}

// MARK: - manifest

/// 백업에 포함된 파일 하나의 무결성 정보. 해시·크기는 백업 시점의 스냅샷 값이다.
public struct BackupFileEntry: Codable, Hashable, Sendable {
    public var name: String
    public var sha256: String
    public var size: Int

    public init(name: String, sha256: String, size: Int) {
        self.name = name
        self.sha256 = sha256
        self.size = size
    }
}

/// 완성된 백업 하나의 manifest. 키 값은 절대 담지 않는다(키 식별자만).
public struct BackupManifest: Codable, Hashable, Sendable {
    /// manifest 형식 버전. 현재는 1.
    public var formatVersion: Int
    public var backupId: String
    /// 데이터 디렉터리 이름(예: WorkLog).
    public var appDirectoryName: String
    public var createdAt: Date
    public var reason: BackupReason
    public var workSchemaVersion: Int
    public var vaultSchemaVersion: Int
    /// vault 암호화 키 식별자(vault_meta.key_version)만. 키 값은 포함 금지.
    public var vaultKeyVersion: String?
    /// work.sqlite, vault.sqlite, settings.json(있을 때).
    public var files: [BackupFileEntry]
    /// 사용자에게 그대로 보여줄 한계 안내.
    public var note: String

    public init(formatVersion: Int = 1,
                backupId: String,
                appDirectoryName: String,
                createdAt: Date,
                reason: BackupReason,
                workSchemaVersion: Int,
                vaultSchemaVersion: Int,
                vaultKeyVersion: String?,
                files: [BackupFileEntry],
                note: String = BackupManifest.standardNote) {
        self.formatVersion = formatVersion
        self.backupId = backupId
        self.appDirectoryName = appDirectoryName
        self.createdAt = createdAt
        self.reason = reason
        self.workSchemaVersion = workSchemaVersion
        self.vaultSchemaVersion = vaultSchemaVersion
        self.vaultKeyVersion = vaultKeyVersion
        self.files = files
        self.note = note
    }

    /// 같은 디스크 백업의 한계를 숨기지 않는다.
    public static let standardNote =
        "같은 디스크 백업은 기기 분실·디스크 고장 대책이 아닙니다. Secret 복원에는 같은 Mac의 기존 Keychain 키가 필요합니다."
}

/// 완성된 백업 하나를 가리키는 정보.
public struct BackupInfo: Hashable, Sendable {
    public var id: String
    public var directory: URL
    public var manifest: BackupManifest

    public init(id: String, directory: URL, manifest: BackupManifest) {
        self.id = id
        self.directory = directory
        self.manifest = manifest
    }
}

/// 마지막 성공·실패 상태. UI가 그대로 표시한다.
public struct BackupStatus: Equatable, Sendable {
    public var lastSuccessAt: Date?
    public var lastFailureAt: Date?
    public var lastFailureMessage: String?

    public init(lastSuccessAt: Date? = nil, lastFailureAt: Date? = nil, lastFailureMessage: String? = nil) {
        self.lastSuccessAt = lastSuccessAt
        self.lastFailureAt = lastFailureAt
        self.lastFailureMessage = lastFailureMessage
    }
}

/// 백업·검증·복원 실패. 복원 실패 시 원본은 파괴하지 않는다.
public enum BackupFailure: Error, Equatable, Sendable {
    case manifestMissing
    case manifestInvalid(String)
    case hashMismatch(file: String)
    case integrityFailed(file: String)
    case unsupportedSchema(String)
    case vaultKeyMissing(keyVersion: String?)
    case ioFailed(String)

    /// 임의 오류를 BackupFailure로 정규화한다(이미 BackupFailure면 그대로).
    static func from(_ error: Error) -> BackupFailure {
        if let failure = error as? BackupFailure { return failure }
        return .ioFailed(String(describing: error))
    }
}
