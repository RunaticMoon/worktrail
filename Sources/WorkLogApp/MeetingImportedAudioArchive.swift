#if os(macOS)
import Darwin
import Foundation
import WorkLogCore

/// Restored archives are DB-owned and can contain several recordings in one import directory.
/// Only the selected recording's track files are exported/deleted; the directory is never removed.
struct MeetingImportedAudioArchive {
    let archive: MeetingAudioArchive
    let ids: any IDGenerator

    static func owns(_ track: MeetingAudioTrack) -> Bool {
        track.relativePath.split(separator: "/", omittingEmptySubsequences: false).first?.hasPrefix("import-") == true
    }

    func delete(recordingID: String, tracks: [MeetingAudioTrack]) throws {
        let files = try existingFiles(recordingID: recordingID, tracks: tracks)
        // Preflight every file before touching any. unlink cannot recursively remove an unexpected directory.
        for (track, url) in files {
            _ = try archive.resolveTrackURL(relativePath: track.relativePath)
            guard unlink(url.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
    }

    func export(recording: MeetingRecording, tracks: [MeetingAudioTrack], localOnly: Bool, to destination: URL) throws {
        let files = try existingFiles(recordingID: recording.id, tracks: tracks)
        guard !files.isEmpty, destination.isFileURL,
              !FileManager.default.fileExists(atPath: destination.path),
              destination.deletingLastPathComponent().standardizedFileURL == destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL,
              !destination.standardizedFileURL.path.hasPrefix(archive.root.standardizedFileURL.path + "/") else {
            throw MeetingAudioArchiveError.invalidPath
        }
        let token = ids.make()
        guard !token.isEmpty, !token.contains("/"), !token.contains("\\"), !token.contains("\0") else { throw MeetingAudioArchiveError.invalidPath }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".worklog-originals-partial-" + token)
        guard !FileManager.default.fileExists(atPath: temporary.path) else { throw MeetingAudioArchiveError.alreadyExists }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: temporary) } }
        var exported: [ExportedFile] = []
        for (index, item) in files.enumerated() {
            let filename = "track-\(index + 1)." + item.1.pathExtension
            try FileManager.default.copyItem(at: item.1, to: temporary.appendingPathComponent(filename))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.appendingPathComponent(filename).path)
            exported.append(.init(trackID: item.0.id, relativePath: filename))
        }
        let included = Set(exported.map(\.trackID))
        let manifest = OriginalsManifest(version: 1, recording: recording, tracks: tracks, localOnly: localOnly,
            files: exported, missingTrackIDs: tracks.filter { !included.contains($0.id) }.map(\.id))
        try Data(StableJSON.string(manifest).utf8).write(to: temporary.appendingPathComponent("originals.json"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.appendingPathComponent("originals.json").path)
        try FileManager.default.moveItem(at: temporary, to: destination)
        published = true
    }

    private func existingFiles(recordingID: String, tracks: [MeetingAudioTrack]) throws -> [(MeetingAudioTrack, URL)] {
        guard !tracks.isEmpty, tracks.allSatisfy({ $0.recordingID == recordingID && Self.owns($0) }) else {
            throw MeetingAudioArchiveError.invalidPath
        }
        var result: [(MeetingAudioTrack, URL)] = []
        for track in tracks where track.fileState != .deleted {
            let components = track.relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count >= 2, !track.relativePath.contains("\\"), !track.relativePath.contains("\0"),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw MeetingAudioArchiveError.invalidPath }
            do { result.append((track, try archive.resolveTrackURL(relativePath: track.relativePath))) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                // DB-only archives and already missing sources remain editable; nothing outside the DB list is touched.
                continue
            }
        }
        return result
    }

    private struct ExportedFile: Codable { let trackID: String; let relativePath: String }
    private struct OriginalsManifest: Codable {
        let version: Int
        let recording: MeetingRecording
        let tracks: [MeetingAudioTrack]
        let localOnly: Bool
        let files: [ExportedFile]
        let missingTrackIDs: [String]
    }
}
#endif
