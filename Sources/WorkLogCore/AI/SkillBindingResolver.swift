import Foundation
import Crypto

// MARK: - 작업별 스킬 바인딩 리졸버 (AI-01)
//
// 설정(AppSettings.skillBindings: jobType rawValue → 스킬 이름 또는 SKILL.md 경로)을
// AI 작업 요청에 넣을 SkillRef로 바꾼다.
// - 스킬 파일은 읽기만 하고 절대 수정하지 않는다. print/로그 출력도 하지 않는다.
// - 값이 비어 있으면 nil, "/"가 없으면 이름만, 경로면 파일 해시(변경 감지·출처 기록)까지 계산한다.
// - 보호 경로(차단 prefix, `.codex` 구성요소, auth.json, sqlite 계열)면 파일을 읽지 않고 nil을
//   돌려준다(스킬 미적용; 이름만 남기는 대체도 하지 않는다).
public final class SkillBindingResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var bindings: [String: String]
    /// 파일을 읽지 않을 경로 접두사(정규화됨). 데이터 루트·백업 루트 등.
    private let blockedPathPrefixes: [String]

    public init(bindings: [String: String], blockedPathPrefixes: [String] = []) {
        self.bindings = bindings
        self.blockedPathPrefixes = blockedPathPrefixes.map(Self.normalizedPath)
    }

    /// 설정 변경 시 바인딩을 교체한다.
    public func update(bindings: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        self.bindings = bindings
    }

    /// jobType에 바인딩된 스킬을 해석한다. 없거나 비어 있으면 nil.
    public func skill(for jobType: AIJobType) -> SkillRef? {
        lock.lock()
        let raw = bindings[jobType.rawValue]
        lock.unlock()
        return Self.resolve(raw, blockedPathPrefixes: blockedPathPrefixes)
    }

    /// 파일 해시를 계산하는 최대 크기(1 MiB). 초과하면 해시 없이 경로만 남긴다.
    static let maxHashableFileSize = 1_048_576

    /// 바인딩 문자열 하나를 SkillRef로 바꾼다.
    static func resolve(_ raw: String?) -> SkillRef? {
        resolve(raw, blockedPathPrefixes: [])
    }

    /// 바인딩 문자열 하나를 SkillRef로 바꾼다. 보호 경로면 읽지 않고 nil.
    static func resolve(_ raw: String?, blockedPathPrefixes: [String]) -> SkillRef? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        // "/"가 없으면 스킬 이름만 바인딩된 것으로 본다.
        guard value.contains("/") else {
            return SkillRef(name: value, path: nil, contentHash: nil)
        }

        let expanded = (value as NSString).expandingTildeInPath
        let path = expanded.hasPrefix("/")
            ? expanded
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)

        // 파일을 읽기 전에 정규화된 경로로 보호 대상인지 판정한다(심볼릭 링크 포함).
        let normalized = normalizedPath(path)
        guard !isBlocked(normalized, blockedPathPrefixes: blockedPathPrefixes) else { return nil }

        let lastComponent = (path as NSString).lastPathComponent
        let name: String
        if lastComponent == "SKILL.md" {
            name = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        } else {
            name = (lastComponent as NSString).deletingPathExtension
        }

        let contentHash = readSmallRegularFile(atPath: path).map { data in
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        // 경로가 없어도 크래시 없이 SkillRef를 돌려준다(해시만 nil).
        return SkillRef(name: name, path: path, contentHash: contentHash)
    }

    /// `~` 확장 + 표준화 + 심볼릭 링크 해석. 차단 판정에만 쓴다.
    private static func normalizedPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// 보호 경로인가: (a) 차단 prefix 하위(디렉터리 경계) (b) `.codex` 구성요소
    /// (c) 파일명 auth.json (d) 확장자 sqlite/sqlite-wal/sqlite-shm.
    private static func isBlocked(_ path: String, blockedPathPrefixes: [String]) -> Bool {
        for rawPrefix in blockedPathPrefixes {
            let prefix = normalizedPath(rawPrefix)
            guard !prefix.isEmpty else { continue }
            if path == prefix { return true }
            let boundary = prefix.hasSuffix("/") ? prefix : prefix + "/"
            if path.hasPrefix(boundary) { return true }
        }

        if path.split(separator: "/").contains(".codex") { return true }

        let url = URL(fileURLWithPath: path)
        if url.lastPathComponent == "auth.json" { return true }
        if ["sqlite", "sqlite-wal", "sqlite-shm"].contains(url.pathExtension) { return true }

        return false
    }

    /// 존재하는 일반 파일이고 1 MiB 이하일 때만 내용을 읽는다. 그 밖에는 nil.
    private static func readSmallRegularFile(atPath path: String) -> Data? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              (attrs[.type] as? FileAttributeType) == .typeRegular else { return nil }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxHashableFileSize else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }
}
