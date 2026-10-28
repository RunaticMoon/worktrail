import Foundation
import Crypto

public enum MeetingArchiveDuplicatePolicy: Sendable { case reject, newCopy }

public struct MeetingArchivePreview: Sendable, Equatable {
    public let title: String
    public let audioFileCount: Int
    public let audioBytes: Int64
    public let missingTrackCount: Int
    public let includesAudio: Bool
}

private enum ArchiveCell: Codable {
    case text(String), integer(Int64), real(Double), null
    init(_ value: SQLValue) throws {
        switch value {
        case .text(let v): self = .text(v)
        case .int(let v): self = .integer(v)
        case .double(let v): self = .real(v)
        case .null: self = .null
        case .blob: throw WorkLogError.validation("회의 아카이브에 지원하지 않는 데이터가 있습니다.")
        }
    }
    var sql: SQLValue {
        switch self {
        case .text(let v): return .text(v)
        case .integer(let v): return .int(v)
        case .real(let v): return .double(v)
        case .null: return .null
        }
    }
    var string: String? { if case .text(let value) = self { return value }; return nil }
}
private typealias ArchiveRow = [String: ArchiveCell]
private struct ArchiveProjectReference: Codable {
    var id: String
    /// nil records an already unavailable reference, rather than inventing a name.
    var name: String?
    var archivedAt: Date?
}
private struct ArchiveTagReference: Codable { var id: String; var name: String? }
private struct ArchivePayload: Codable {
    var tables: [String: [ArchiveRow]]
    /// Only classifications selected by this meeting. Optional for older v1 archives.
    var projects: [ArchiveProjectReference]?
    var tags: [ArchiveTagReference]?
}
private struct ArchiveEntry: Codable {
    var path: String
    var size: Int64
    var sha256: String
    var trackID: String?
}
private struct ArchiveManifest: Codable {
    var version: Int
    var meetingID: String
    var title: String
    var includesAudio: Bool
    var missingTrackIDs: [String]
    var entries: [ArchiveEntry]
}

/// Local, allowlisted relational snapshots plus streamed audio files. No model weights,
/// credentials, general task data or external AI calls are part of this format.
public final class MeetingArchiveService: @unchecked Sendable {
    public let repo: WorkRepository
    public let audioRoot: URL
    private let fm = FileManager.default
    private let availableBytes: (URL) throws -> Int64
    private static let tableOrder = ["meeting", "meeting_memo_snapshot", "meeting_summary", "meeting_summary_edit",
        "meeting_recording", "meeting_audio_track", "meeting_transcript_run", "meeting_speaker",
        "meeting_transcript_segment", "meeting_transcript_edit", "meeting_preview_gap"]
    private static let maxPayloadBytes: Int64 = 64 * 1024 * 1024
    private static let maxArchiveBytes: Int64 = 100 * 1024 * 1024 * 1024

    public init(repo: WorkRepository, audioRoot: URL, availableBytes: ((URL) throws -> Int64)? = nil) {
        self.repo = repo; self.audioRoot = audioRoot
        self.availableBytes = availableBytes ?? { url in
            let values = try FileManager.default.attributesOfFileSystem(forPath: url.path)
            return (values[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        }
    }

    public func preview(meetingID: String, includeAudio: Bool) throws -> MeetingArchivePreview {
        let payload = try snapshot(meetingID)
        let (files, missing) = try audioFiles(payload, includeAudio: includeAudio, hashFiles: false)
        return MeetingArchivePreview(title: payload.tables["meeting"]?.first?["title"]?.string ?? "회의",
            audioFileCount: files.count, audioBytes: files.reduce(0) { $0 + $1.size },
            missingTrackCount: missing.count, includesAudio: includeAudio)
    }

    public func export(meetingID: String, includeAudio: Bool, to destination: URL,
                       expectedPreview: MeetingArchivePreview? = nil,
                       checkCancellation: () throws -> Void = {}) throws {
        guard destination.isFileURL, !fm.fileExists(atPath: destination.path) else { throw failure("이미 있는 아카이브를 덮어쓰지 않습니다.") }
        try validateAncestors(destination.deletingLastPathComponent())
        let payload = try snapshot(meetingID)
        let data = try StableJSON.encode(payload)
        guard data.count <= Self.maxPayloadBytes else { throw failure("회의 텍스트가 아카이브 제한을 넘습니다.") }
        let (audio, missing) = try audioFiles(payload, includeAudio: includeAudio)
        if let expectedPreview {
            let actual = MeetingArchivePreview(title: payload.tables["meeting"]?.first?["title"]?.string ?? "회의",
                audioFileCount: audio.count, audioBytes: audio.reduce(0) { $0 + $1.size },
                missingTrackCount: missing.count, includesAudio: includeAudio)
            guard actual == expectedPreview else { throw failure("회의 또는 원본 파일이 변경되었습니다. 파일 수·용량과 누락 원본을 다시 확인하세요.") }
        }
        let total = audio.reduce(Int64(data.count)) { $0 + $1.size }
        try requireCapacity(total, at: destination.deletingLastPathComponent())
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".meeting-incomplete-" + repo.ids.make())
        guard !fm.fileExists(atPath: temporary.path) else { throw failure("임시 아카이브 경로가 이미 있습니다. 기존 파일은 유지했습니다.") }
        try createDirectory(temporary)
        defer { try? fm.removeItem(at: temporary) }
        try data.write(to: temporary.appendingPathComponent("records.json"), options: .atomic)
        var entries = [ArchiveEntry(path: "records.json", size: Int64(data.count), sha256: hash(data), trackID: nil)]
        for item in audio {
            try checkCancellation()
            let target = try safeFile(root: temporary, path: item.path, mustExist: false)
            try createDirectory(target.deletingLastPathComponent())
            let source = try sourceFile(trackID: item.trackID!, payload: payload)
            try fm.copyItem(at: source, to: target)
            let copied = try fileEntry(target, path: item.path, trackID: item.trackID)
            guard copied.size == item.size, copied.sha256 == item.sha256 else { throw failure("내보내기 중 원본이 변경되었습니다. 다시 시도하세요.") }
            entries.append(copied)
        }
        let manifest = ArchiveManifest(version: 1, meetingID: meetingID,
            title: payload.tables["meeting"]?.first?["title"]?.string ?? "회의", includesAudio: includeAudio,
            missingTrackIDs: missing, entries: entries)
        try StableJSON.encode(manifest).write(to: temporary.appendingPathComponent("manifest.json"), options: .atomic)
        try checkCancellation()
        try fm.moveItem(at: temporary, to: destination)
    }

    public func inspect(_ archive: URL) throws -> MeetingArchivePreview {
        let (manifest, _) = try verified(archive)
        let audio = manifest.entries.filter { $0.trackID != nil }
        return MeetingArchivePreview(title: manifest.title, audioFileCount: audio.count,
            audioBytes: audio.reduce(0) { $0 + $1.size }, missingTrackCount: manifest.missingTrackIDs.count,
            includesAudio: manifest.includesAudio)
    }

    /// Files are staged before the SQLite savepoint. A failure removes only newly created
    /// files and rolls back every inserted row. Existing rows/files are never replaced.
    @discardableResult public func restore(_ archive: URL, duplicatePolicy: MeetingArchiveDuplicatePolicy,
                                            checkCancellation: () throws -> Void = {}) throws -> String {
        let (manifest, original) = try verified(archive)
        if duplicatePolicy == .reject,
           try repo.db.scalarIntV("SELECT COUNT(*) FROM meeting WHERE id = ?", manifest.meetingID) > 0 {
            throw failure("같은 회의가 이미 있습니다. 새 복사본으로 가져오기를 선택하세요.")
        }
        try validateAncestors(audioRoot)
        try createDirectory(audioRoot)
        let audio = manifest.entries.filter { $0.trackID != nil }
        try requireCapacity(audio.reduce(0) { $0 + $1.size }, at: audioRoot)
        var payload = original
        var mapping: [String: String] = [:]
        for table in Self.tableOrder {
            for row in payload.tables[table] ?? [] {
                if let id = row["id"]?.string {
                    guard mapping[id] == nil else { throw failure("아카이브 식별자가 중복되었습니다.") }
                    mapping[id] = duplicatePolicy == .newCopy ? repo.ids.make() : id
                }
            }
        }
        guard let meetingID = mapping[manifest.meetingID] else { throw failure("회의 식별자가 없습니다.") }
        let directoryName = "import-" + repo.ids.make()
        let staging = audioRoot.appendingPathComponent(".incomplete-" + directoryName)
        let final = audioRoot.appendingPathComponent(directoryName)
        guard !fm.fileExists(atPath: final.path), !fm.fileExists(atPath: staging.path) else { throw failure("가져오기 경로가 이미 있습니다.") }
        try createDirectory(staging)
        var moved = false
        var succeeded = false
        defer {
            try? fm.removeItem(at: staging)
            if moved && !succeeded { try? fm.removeItem(at: final) }
        }
        var trackPaths: [String: String] = [:]
        for (index, entry) in audio.enumerated() {
            try checkCancellation()
            let source = try safeFile(root: archive, path: entry.path, mustExist: true)
            let name = "track-\(index)." + source.pathExtension
            let target = staging.appendingPathComponent(name)
            try fm.copyItem(at: source, to: target)
            let copied = try fileEntry(target, path: name, trackID: entry.trackID)
            guard copied.size == entry.size, copied.sha256 == entry.sha256 else { throw failure("가져오는 동안 파일이 변경되었습니다.") }
            trackPaths[entry.trackID!] = directoryName + "/" + name
        }
        let foreignKeys = Set(["meeting_id", "recording_id", "source_run_id", "run_id", "track_id", "segment_id", "speaker_id", "original_speaker_id", "edited_speaker_id", "active_transcript_run_id", "summary_id"])
        for table in Self.tableOrder {
            payload.tables[table] = try (payload.tables[table] ?? []).map { source in
                var row = source
                for (key, cell) in source where key == "id" || foreignKeys.contains(key) {
                    guard let old = cell.string else { continue }
                    guard let new = mapping[old] else { throw failure("아카이브 내부 연결이 누락되었습니다.") }
                    row[key] = .text(new)
                }
                if table == "meeting" { row["local_only"] = .integer(1) }
                if table == "meeting_recording", ["recording", "paused"].contains(row["state"]?.string ?? "") { row["state"] = .text("interrupted") }
                if table == "meeting_transcript_run", row["status"]?.string == "running" { row["status"] = .text("interrupted") }
                if table == "meeting_audio_track", let id = source["id"]?.string {
                    row["relative_path"] = .text(trackPaths[id] ?? directoryName + "/missing-" + (mapping[id] ?? id))
                    row["file_state"] = .text(trackPaths[id] == nil ? "missing" : "available")
                }
                return row
            }
        }
        try repo.db.transaction {
            // Classification creation shares the meeting transaction and rolls back with it.
            try remapMetadata(in: &payload)
            for table in Self.tableOrder {
                guard let rows = payload.tables[table], !rows.isEmpty else { continue }
                let columns = try knownColumns(table)
                for row in rows {
                    try checkCancellation()
                    let names = row.keys.sorted()
                    guard !names.isEmpty, Set(names).isSubset(of: columns) else { throw failure("지원하지 않는 아카이브 필드가 있습니다.") }
                    // Identifiers are selected only from the compiled table allowlist and live schema.
                    let sql = "INSERT INTO \(table)(\(names.joined(separator: ","))) VALUES(\(names.map { _ in "?" }.joined(separator: ",")))"
                    try repo.db.run(sql, names.map { row[$0]!.sql })
                }
            }
            guard try repo.db.query("PRAGMA foreign_key_check").isEmpty else { throw failure("아카이브 연결 검증에 실패했습니다.") }
            try checkCancellation()
            try fm.moveItem(at: staging, to: final)
            moved = true
        }
        succeeded = true
        return meetingID
    }

    private func snapshot(_ meetingID: String) throws -> ArchivePayload {
        try repo.db.transaction {
            guard try repo.db.scalarIntV("SELECT COUNT(*) FROM meeting WHERE id = ?", meetingID) == 1 else { throw WorkLogError.notFound("회의") }
            guard try repo.db.scalarIntV("SELECT COUNT(*) FROM meeting_recording WHERE meeting_id = ? AND state IN ('recording','paused')", meetingID) == 0,
                  try repo.db.scalarIntV("SELECT COUNT(*) FROM meeting_transcript_run WHERE meeting_id = ? AND status = 'running'", meetingID) == 0 else { throw failure("녹음과 전사 처리가 끝난 후 내보내세요.") }
            var tables: [String: [ArchiveRow]] = [:]
            for table in Self.tableOrder {
                guard try repo.db.scalarIntV("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?", table) == 1 else { continue }
                let condition: String
                switch table {
                case "meeting": condition = "id = ?"
                case "meeting_memo_snapshot", "meeting_summary", "meeting_recording", "meeting_transcript_run": condition = "meeting_id = ?"
                case "meeting_summary_edit": condition = "summary_id IN (SELECT id FROM meeting_summary WHERE meeting_id = ?)"
                case "meeting_audio_track": condition = "recording_id IN (SELECT id FROM meeting_recording WHERE meeting_id = ?)"
                default: condition = "run_id IN (SELECT id FROM meeting_transcript_run WHERE meeting_id = ?)"
                }
                let order = table == "meeting_transcript_run" ? " ORDER BY version" : ""
                tables[table] = try repo.db.query("SELECT * FROM \(table) WHERE \(condition)\(order)", [meetingID]).map { row in
                    try row.columns.mapValues(ArchiveCell.init)
                }
            }
            let metadata = try tables["meeting"]?.first?["metadata_json"]?.string.map {
                try StableJSON.decode(MeetingMetadata.self, from: $0)
            }
            let projects = try Set(metadata?.projectIDs ?? []).sorted().map { id in
                let project = try repo.project(id: id)
                return ArchiveProjectReference(id: id, name: project?.name, archivedAt: project?.archivedAt)
            }
            let tags = try Set(metadata?.tagIDs ?? []).sorted().map { id in
                let row = try repo.db.queryOneV("SELECT name FROM tag WHERE id = ?", id)
                return ArchiveTagReference(id: id, name: row?.string("name"))
            }
            return ArchivePayload(tables: tables, projects: projects, tags: tags)
        }
    }

    private func verified(_ archive: URL) throws -> (ArchiveManifest, ArchivePayload) {
        let manifestURL = try safeFile(root: archive, path: "manifest.json", mustExist: true)
        guard try size(manifestURL) < 2 * 1024 * 1024 else { throw failure("아카이브 목록이 너무 큽니다.") }
        let manifest = try StableJSON.decode(ArchiveManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.version == 1, manifest.entries.count <= 10_000,
              Set(manifest.entries.map(\.path)).count == manifest.entries.count,
              manifest.entries.filter({ $0.path == "records.json" && $0.trackID == nil }).count == 1 else { throw failure("지원하지 않거나 손상된 아카이브입니다.") }
        var total: Int64 = 0
        for entry in manifest.entries {
            guard entry.size >= 0, entry.size <= Self.maxArchiveBytes - total else { throw failure("아카이브 용량 제한을 넘습니다.") }
            total += entry.size
            let url = try safeFile(root: archive, path: entry.path, mustExist: true)
            let actual = try fileEntry(url, path: entry.path, trackID: entry.trackID)
            guard actual.size == entry.size, actual.sha256 == entry.sha256 else { throw failure("파일 크기 또는 SHA-256이 일치하지 않습니다.") }
        }
        let recordsURL = archive.appendingPathComponent("records.json")
        guard try size(recordsURL) <= Self.maxPayloadBytes else { throw failure("회의 데이터가 너무 큽니다.") }
        let payload = try StableJSON.decode(ArchivePayload.self, from: Data(contentsOf: recordsURL))
        guard Set(payload.tables.keys).isSubset(of: Set(Self.tableOrder)),
              payload.tables["meeting"]?.count == 1,
              payload.tables["meeting"]?.first?["id"]?.string == manifest.meetingID else { throw failure("회의 데이터 범위를 확인할 수 없습니다.") }
        let trackIDs = Set((payload.tables["meeting_audio_track"] ?? []).compactMap { $0["id"]?.string })
        let audioIDs = manifest.entries.compactMap(\.trackID)
        guard Set(audioIDs).count == audioIDs.count, Set(audioIDs).isSubset(of: trackIDs),
              Set(manifest.missingTrackIDs).count == manifest.missingTrackIDs.count,
              Set(manifest.missingTrackIDs) == trackIDs.subtracting(audioIDs),
              manifest.includesAudio || audioIDs.isEmpty else { throw failure("오디오 연결 또는 누락 목록이 잘못되었습니다.") }
        let metadata = try payload.tables["meeting"]?.first?["metadata_json"]?.string.map {
            try StableJSON.decode(MeetingMetadata.self, from: $0)
        }
        if let projects = payload.projects {
            guard Set(projects.map(\.id)).count == projects.count,
                  Set(projects.map(\.id)) == Set(metadata?.projectIDs ?? []) else {
                throw failure("회의에서 선택한 프로젝트 범위를 확인할 수 없습니다.")
            }
        }
        if let tags = payload.tags {
            guard Set(tags.map(\.id)).count == tags.count,
                  Set(tags.map(\.id)) == Set(metadata?.tagIDs ?? []) else {
                throw failure("회의에서 선택한 태그 범위를 확인할 수 없습니다.")
            }
        }
        return (manifest, payload)
    }

    /// Reuse matching classifications without changing their current name/archive state.
    /// Unknown references stay unavailable even if their old ID belongs to unrelated local data.
    private func remapMetadata(in payload: inout ArchivePayload) throws {
        guard var meeting = payload.tables["meeting"]?.first,
              let json = meeting["metadata_json"]?.string else { return }
        var metadata = try StableJSON.decode(MeetingMetadata.self, from: json)
        let projects = Dictionary(uniqueKeysWithValues: (payload.projects ?? []).map { ($0.id, $0) })
        let tags = Dictionary(uniqueKeysWithValues: (payload.tags ?? []).map { ($0.id, $0) })
        var projectMapping: [String: String] = [:], tagMapping: [String: String] = [:]
        for id in Set(metadata.projectIDs).sorted() {
            guard let reference = projects[id], let name = reference.name else {
                projectMapping[id] = try unusedReference(id, table: "project")
                continue
            }
            if let existing = try repo.project(id: id), existing.name == name {
                projectMapping[id] = existing.id
            } else if let existing = try repo.db.queryOneV("SELECT id FROM project WHERE name = ?", name)?.string("id") {
                projectMapping[id] = existing
            } else {
                let newID = repo.ids.make()
                try repo.db.runV("INSERT INTO project (id, name, archived_at) VALUES (?, ?, ?)", newID, name, reference.archivedAt)
                projectMapping[id] = newID
            }
        }
        for id in Set(metadata.tagIDs).sorted() {
            guard let name = tags[id]?.name else {
                tagMapping[id] = try unusedReference(id, table: "tag")
                continue
            }
            if let row = try repo.db.queryOneV("SELECT name FROM tag WHERE id = ?", id), row.string("name") == name {
                tagMapping[id] = id
            } else if let existing = try repo.db.queryOneV("SELECT id FROM tag WHERE name = ?", name)?.string("id") {
                tagMapping[id] = existing
            } else {
                let newID = repo.ids.make()
                try repo.db.runV("INSERT INTO tag (id, name) VALUES (?, ?)", newID, name)
                tagMapping[id] = newID
            }
        }
        metadata.projectIDs = metadata.projectIDs.map { projectMapping[$0]! }
        metadata.tagIDs = metadata.tagIDs.map { tagMapping[$0]! }
        meeting["metadata_json"] = .text(try StableJSON.string(metadata))
        payload.tables["meeting"] = [meeting]
    }

    private func unusedReference(_ original: String, table: String) throws -> String {
        // The table is selected only by these two compiled callers; values are bound.
        guard table == "project" || table == "tag" else { throw failure("잘못된 분류 종류입니다.") }
        var candidate = original
        while try repo.db.scalarIntV("SELECT COUNT(*) FROM \(table) WHERE id = ?", candidate) > 0 {
            candidate = "archive-missing-" + repo.ids.make()
        }
        return candidate
    }

    private func audioFiles(_ payload: ArchivePayload, includeAudio: Bool, hashFiles: Bool = true) throws -> ([ArchiveEntry], [String]) {
        var entries: [ArchiveEntry] = [], missing: [String] = []
        for (index, track) in (payload.tables["meeting_audio_track"] ?? []).enumerated() {
            guard let id = track["id"]?.string else { throw failure("오디오 식별자가 없습니다.") }
            guard includeAudio else { missing.append(id); continue }
            do {
                let source = try sourceFile(trackID: id, payload: payload)
                let path = "audio/track-\(index)." + source.pathExtension
                entries.append(try hashFiles ? fileEntry(source, path: path, trackID: id) : ArchiveEntry(path: path, size: size(source), sha256: "", trackID: id))
            } catch {
                let cocoa = error as NSError
                let unavailable = cocoa.domain == NSCocoaErrorDomain
                    && [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(cocoa.code)
                guard unavailable else { throw error }
                missing.append(id)
            }
        }
        return (entries, missing)
    }
    private func sourceFile(trackID: String, payload: ArchivePayload) throws -> URL {
        guard let path = payload.tables["meeting_audio_track"]?.first(where: { $0["id"]?.string == trackID })?["relative_path"]?.string else { throw failure("원본 경로가 없습니다.") }
        return try safeFile(root: audioRoot, path: path, mustExist: true)
    }
    private func knownColumns(_ table: String) throws -> Set<String> {
        guard Self.tableOrder.contains(table) else { throw failure("잘못된 데이터 종류입니다.") }
        return Set(try repo.db.query("PRAGMA table_info(\(table))").compactMap { $0.string("name") })
    }
    private func safeFile(root: URL, path: String, mustExist: Bool) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard root.isFileURL, !parts.isEmpty, !path.contains("\\"), !path.contains(":"),
              !path.contains("\0"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw failure("안전하지 않은 상대 경로입니다.") }
        let result = root.appendingPathComponent(path)
        try validateAncestors(result)
        if mustExist {
            let attrs = try fm.attributesOfItem(atPath: result.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular else { throw failure("일반 파일만 가져올 수 있습니다.") }
        }
        return result
    }
    private func validateAncestors(_ url: URL) throws {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if let values = try? fm.attributesOfItem(atPath: current.path), values[.type] as? FileAttributeType == .typeSymbolicLink {
                // macOS presents its root-owned /private/var and /private/tmp via these aliases.
                let target = try fm.destinationOfSymbolicLink(atPath: current.path)
                let systemAlias = (current.path == "/var" && target == "private/var") || (current.path == "/tmp" && target == "private/tmp")
                guard systemAlias else { throw failure("심볼릭 링크 경로는 사용할 수 없습니다.") }
            }
            current.deleteLastPathComponent()
        }
    }
    private func createDirectory(_ url: URL) throws {
        try validateAncestors(url)
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func requireCapacity(_ bytes: Int64, at url: URL) throws {
        guard bytes <= Self.maxArchiveBytes, try availableBytes(url) >= bytes + 1024 * 1024 else { throw failure("저장 공간이 부족합니다. 기존 데이터는 유지됩니다.") }
    }
    private func size(_ url: URL) throws -> Int64 { (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0 }
    private func fileEntry(_ url: URL, path: String, trackID: String?) throws -> ArchiveEntry {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var digest = SHA256(); var length: Int64 = 0
        while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty { digest.update(data: block); length += Int64(block.count) }
        return ArchiveEntry(path: path, size: length, sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(), trackID: trackID)
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func failure(_ text: String) -> WorkLogError { .validation(text) }
}
