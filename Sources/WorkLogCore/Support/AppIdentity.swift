import Foundation

/// 제품명이 미정이므로 이름·bundle id·경로를 한곳에서 교체할 수 있게 둔다.
public struct AppIdentity: Sendable, Equatable {
    public var displayName: String
    public var bundleIdentifier: String
    /// 데이터 디렉터리·백업 디렉터리 이름에 쓰는 이름.
    public var directoryName: String

    public init(displayName: String, bundleIdentifier: String, directoryName: String) {
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.directoryName = directoryName
    }

    public static let `default` = AppIdentity(
        displayName: "WorkLog",
        bundleIdentifier: "dev.worklog.WorkLog",
        directoryName: "WorkLog"
    )
}

/// 앱이 사용하는 모든 경로. 테스트에서는 임시 루트를 주입한다.
public struct AppPaths: Sendable, Equatable {
    /// 실제 데이터 저장소 (예: ~/Library/Application Support/WorkLog)
    public var dataRoot: URL
    /// 자동 생성 로컬 백업 폴더 (예: ~/WorkLog/backups)
    public var backupRoot: URL

    public init(dataRoot: URL, backupRoot: URL) {
        self.dataRoot = dataRoot
        self.backupRoot = backupRoot
    }

    public var workDatabase: URL { dataRoot.appendingPathComponent("work/work.sqlite") }
    public var vaultDatabase: URL { dataRoot.appendingPathComponent("vault/vault.sqlite") }
    public var aiJobsDirectory: URL { dataRoot.appendingPathComponent("ai-jobs", isDirectory: true) }
    public var cacheDirectory: URL { dataRoot.appendingPathComponent("cache", isDirectory: true) }
    public var settingsFile: URL { dataRoot.appendingPathComponent("settings.json") }

    /// 운영 기본 경로. macOS는 Application Support, 그 외(Linux 개발 환경)는 XDG 데이터 경로.
    public static func standard(identity: AppIdentity = .default,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AppPaths {
        #if os(macOS)
        let data = home.appendingPathComponent("Library/Application Support/\(identity.directoryName)", isDirectory: true)
        #else
        let data = home.appendingPathComponent(".local/share/\(identity.directoryName)", isDirectory: true)
        #endif
        let backups = home.appendingPathComponent("\(identity.directoryName)/backups", isDirectory: true)
        return AppPaths(dataRoot: data, backupRoot: backups)
    }

    /// 사용자 전용 권한(0700)으로 필요한 디렉터리를 만든다.
    public func createDirectories(fileManager: FileManager = .default) throws {
        for dir in [dataRoot,
                    workDatabase.deletingLastPathComponent(),
                    vaultDatabase.deletingLastPathComponent(),
                    aiJobsDirectory, cacheDirectory, backupRoot] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        }
    }
}
