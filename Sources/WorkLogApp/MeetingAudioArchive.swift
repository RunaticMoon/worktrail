#if os(macOS)
import AVFoundation
import Darwin
import Foundation
import WorkLogCore

enum MeetingAudioTrackID: String, Codable, CaseIterable, Sendable { case microphone, system }
enum MeetingAudioArchiveStatus: String, Codable, Sendable { case pending, archived, interrupted }

struct MeetingAudioGap: Codable, Equatable, Sendable {
    let startOffset: TimeInterval
    let duration: TimeInterval
    let reason: String
}

struct MeetingAudioTrackSnapshot: Codable, Sendable {
    let id: MeetingAudioTrackID
    let relativePath: String
    let sampleRate: Double
    let channelCount: UInt32
    let commonFormat: UInt
    let interleaved: Bool
    let startOffset: TimeInterval
    var frameCount: Int64
    var gaps: [MeetingAudioGap]
    var duration: TimeInterval { Double(frameCount) / sampleRate }
}

struct MeetingAudioArchiveSnapshot: Codable, Sendable {
    let version: Int
    let recordingID: String
    let meetingID: String
    let startedAt: Date
    var status: MeetingAudioArchiveStatus
    var tracks: [MeetingAudioTrackSnapshot]
    var error: String?
    var journalNeedsRetry: Bool? = nil
}

/// The buffer is a private copy. After enqueueing it, neither producer nor consumer
/// may mutate it. The original writer always finishes its write before onPCM runs.
struct MeetingCapturedPCM: @unchecked Sendable {
    let track: MeetingAudioTrackID
    let buffer: AVAudioPCMBuffer
    let relativeStartSeconds: TimeInterval
    var byteCount: Int { UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).reduce(0) { $0 + Int($1.mDataByteSize) } }

    static func copy(track: MeetingAudioTrackID, buffer: AVAudioPCMBuffer, relativeStartSeconds: TimeInterval) throws -> Self {
        guard relativeStartSeconds.isFinite, relativeStartSeconds >= 0,
              buffer.frameLength > 0,
              buffer.format.sampleRate > 0, buffer.format.channelCount > 0 else {
            throw MeetingAudioArchiveError.invalidPCM
        }
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let byteCount = source.reduce(0) { $0 + Int($1.mDataByteSize) }
        guard byteCount > 0, byteCount <= 8 * 1024 * 1024,
              let owned = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { throw MeetingAudioArchiveError.invalidPCM }
        owned.frameLength = buffer.frameLength
        let destination = UnsafeMutableAudioBufferListPointer(owned.mutableAudioBufferList)
        guard source.count == destination.count else { throw MeetingAudioArchiveError.invalidPCM }
        for index in source.indices {
            guard let src = source[index].mData, let dst = destination[index].mData,
                  source[index].mDataByteSize <= destination[index].mDataByteSize else { throw MeetingAudioArchiveError.invalidPCM }
            memcpy(dst, src, Int(source[index].mDataByteSize))
        }
        return Self(track: track, buffer: owned, relativeStartSeconds: relativeStartSeconds)
    }
}

enum MeetingAudioArchiveError: LocalizedError {
    case invalidPath, alreadyExists, invalidManifest, invalidPCM, formatChanged, queueOverflow, closed
    var errorDescription: String? {
        switch self {
        case .invalidPath: return "녹음 보관 경로가 안전하지 않거나 다른 파일을 가리킵니다. 원본은 삭제하지 않았습니다."
        case .alreadyExists: return "같은 녹음 ID의 보관 파일이 이미 있습니다. 기존 원본은 덮어쓰지 않았습니다."
        case .invalidManifest: return "녹음 복구 정보를 확인하지 못했습니다. 원본 파일은 그대로 보존했습니다."
        case .invalidPCM: return "입력 오디오의 PCM 형식 또는 시간을 확인하지 못했습니다. 녹음을 중단합니다."
        case .formatChanged: return "녹음 중 입력 장치의 오디오 형식 또는 시계가 변경되었습니다. 기존 원본을 보존하고 중단합니다."
        case .queueOverflow: return "저장 장치가 녹음 속도를 따라가지 못해 녹음을 중단했습니다. 이미 저장한 원본은 보존했습니다."
        case .closed: return "녹음 보관 작업이 이미 종료되었습니다."
        }
    }
}

/// Only this app-owned root is inspected. Imported audio is never moved or modified.
/// Recovery is read-only; the caller decides when to persist the recovered DB state.
struct MeetingAudioArchive: Sendable {
    let root: URL
    private var manager: FileManager { .default }

    func recoverAll() throws -> [MeetingAudioArchiveSnapshot] {
        try validateRoot()
        guard manager.fileExists(atPath: root.path) else { return [] }
        return try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map { try recover(recordingID: $0.lastPathComponent) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// A broken archive must not prevent unrelated recordings from recovering.
    func recoverAvailable() throws -> (snapshots: [MeetingAudioArchiveSnapshot], unavailableCount: Int) {
        try validateRoot()
        guard manager.fileExists(atPath: root.path) else { return ([], 0) }
        var snapshots: [MeetingAudioArchiveSnapshot] = [], failures = 0
        for url in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where !url.lastPathComponent.hasPrefix(".") {
            do { snapshots.append(try recover(recordingID: url.lastPathComponent)) }
            catch { failures += 1 }
        }
        return (snapshots.sorted { $0.startedAt < $1.startedAt }, failures)
    }

    func recover(recordingID: String) throws -> MeetingAudioArchiveSnapshot {
        var snapshot = try read(recordingID: recordingID)
        for index in snapshot.tracks.indices {
            let url = try audioURL(recordingID: recordingID, track: snapshot.tracks[index].id)
            try requireRegularFile(url)
            let file = try AVAudioFile(forReading: url)
            let track = snapshot.tracks[index]
            guard file.processingFormat.sampleRate == track.sampleRate,
                  file.processingFormat.channelCount == track.channelCount else { throw MeetingAudioArchiveError.invalidManifest }
            // CAF's actual frame count is authoritative after an unclean exit.
            snapshot.tracks[index].frameCount = file.length
        }
        if snapshot.status == .pending {
            snapshot.status = .interrupted
            snapshot.error = "앱이 녹음을 정상 종료하지 못했습니다. 저장된 PCM 원본을 복구했습니다."
        }
        return snapshot
    }

    func audioURL(recordingID: String, track: MeetingAudioTrackID) throws -> URL {
        let result = try directory(recordingID: recordingID).appendingPathComponent(track.rawValue + ".caf")
        if entryExists(result) { try requireRegularFile(result) }
        return result
    }

    /// DB-owned relative paths cover native recordings and imported meeting archives.
    /// Validate every component, including the final file, before any audio reader opens it.
    func resolveTrackURL(relativePath: String) throws -> URL {
        try validateRoot()
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.hasPrefix("/"), !relativePath.contains("\\"), !relativePath.contains("\0"),
              !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw MeetingAudioArchiveError.invalidPath
        }
        var result = root
        for (index, component) in components.enumerated() {
            result.appendPathComponent(String(component))
            guard result.standardizedFileURL == result.resolvingSymlinksInPath().standardizedFileURL else {
                throw MeetingAudioArchiveError.invalidPath
            }
            if index == components.count - 1 { try requireRegularFile(result) }
            else { try requireDirectory(result) }
        }
        return result
    }

    /// Explicit user deletion only; unknown entries block deletion before any write.
    func delete(recordingID: String) throws {
        let snapshot = try read(recordingID: recordingID)
        guard snapshot.status != .pending else { throw MeetingAudioArchiveError.closed }
        let folder = try directory(recordingID: recordingID)
        let names = Set(snapshot.tracks.map { $0.id.rawValue + ".caf" } + ["manifest.json"])
        let entries = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        guard Set(entries.map(\.lastPathComponent)) == names else { throw MeetingAudioArchiveError.invalidPath }
        try entries.forEach { try requireRegularFile($0) }
        // Delete only the validated named files. rmdir refuses any unexpected entry
        // added after validation instead of recursively deleting someone else's file.
        for track in snapshot.tracks { try manager.removeItem(at: folder.appendingPathComponent(track.id.rawValue + ".caf")) }
        try manager.removeItem(at: folder.appendingPathComponent("manifest.json"))
        guard rmdir(folder.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    func export(recordingID: String, to destination: URL) throws {
        let snapshot = try read(recordingID: recordingID)
        guard snapshot.status != .pending, destination.isFileURL,
              !manager.fileExists(atPath: destination.path) else { throw MeetingAudioArchiveError.invalidPath }
        let source = try directory(recordingID: recordingID)
        guard !destination.standardizedFileURL.path.hasPrefix(source.path + "/") else { throw MeetingAudioArchiveError.invalidPath }
        let files = [source.appendingPathComponent("manifest.json")] + (try snapshot.tracks.map { try audioURL(recordingID: recordingID, track: $0.id) })
        try files.forEach { try requireRegularFile($0) }
        try manager.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for file in files {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            try manager.copyItem(at: file, to: target)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
    }

    /// Explicitly closes a recovered pending journal, retaining every source file.
    func acknowledgeRecovery(recordingID: String) throws -> MeetingAudioArchiveSnapshot {
        var snapshot = try recover(recordingID: recordingID)
        snapshot.journalNeedsRetry = false
        try save(snapshot)
        return snapshot
    }

    func retryClosedJournal(_ snapshot: MeetingAudioArchiveSnapshot) throws -> MeetingAudioArchiveSnapshot {
        guard snapshot.status != .pending else { throw MeetingAudioArchiveError.closed }
        var repaired = snapshot
        repaired.journalNeedsRetry = false
        try save(repaired)
        return repaired
    }

    fileprivate func create(recordingID: String, meetingID: String, startedAt: Date) throws -> MeetingAudioArchiveSnapshot {
        guard !meetingID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              meetingID.utf8.count <= 512, !meetingID.contains("\0") else { throw MeetingAudioArchiveError.invalidManifest }
        try validateRoot()
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let folder = try directory(recordingID: recordingID)
        guard mkdir(folder.path, 0o700) == 0 else {
            if errno == EEXIST { throw MeetingAudioArchiveError.alreadyExists }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let snapshot = MeetingAudioArchiveSnapshot(version: 1, recordingID: recordingID, meetingID: meetingID,
                                                   startedAt: startedAt, status: .pending, tracks: [], error: nil)
        try save(snapshot)
        return snapshot
    }

    fileprivate func save(_ snapshot: MeetingAudioArchiveSnapshot) throws {
        let target = try directory(recordingID: snapshot.recordingID).appendingPathComponent("manifest.json")
        if entryExists(target) { try requireRegularFile(target) }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: target, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    private func read(recordingID: String) throws -> MeetingAudioArchiveSnapshot {
        let folder = try directory(recordingID: recordingID)
        let manifest = folder.appendingPathComponent("manifest.json")
        try requireRegularFile(manifest)
        let attributes = try manager.attributesOfItem(atPath: manifest.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 4 * 1024 * 1024 else { throw MeetingAudioArchiveError.invalidManifest }
        let snapshot = try JSONDecoder().decode(MeetingAudioArchiveSnapshot.self, from: Data(contentsOf: manifest))
        guard snapshot.version == 1, snapshot.recordingID == recordingID,
              !snapshot.meetingID.isEmpty, snapshot.meetingID.utf8.count <= 512,
              snapshot.startedAt.timeIntervalSinceReferenceDate.isFinite,
              Set(snapshot.tracks.map(\.id)).count == snapshot.tracks.count else { throw MeetingAudioArchiveError.invalidManifest }
        for track in snapshot.tracks {
            guard track.relativePath == recordingID + "/" + track.id.rawValue + ".caf",
                  track.sampleRate.isFinite, track.sampleRate > 0, track.channelCount > 0,
                  track.startOffset.isFinite, track.startOffset >= 0, track.frameCount >= 0,
                  track.gaps.allSatisfy({ $0.startOffset.isFinite && $0.startOffset >= 0 && $0.duration.isFinite && $0.duration >= 0 }) else {
                throw MeetingAudioArchiveError.invalidManifest
            }
        }
        return snapshot
    }

    private func directory(recordingID: String) throws -> URL {
        try validateRoot()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard !recordingID.isEmpty, recordingID.utf8.count <= 128,
              recordingID.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { throw MeetingAudioArchiveError.invalidPath }
        let result = root.appendingPathComponent(recordingID, isDirectory: true)
        if entryExists(result) { try requireDirectory(result) }
        return result
    }

    private func validateRoot() throws {
        guard root.isFileURL, root.standardizedFileURL == root.resolvingSymlinksInPath().standardizedFileURL else { throw MeetingAudioArchiveError.invalidPath }
        if entryExists(root) { try requireDirectory(root) }
    }

    private func entryExists(_ url: URL) -> Bool { (try? manager.attributesOfItem(atPath: url.path)) != nil }
    private func requireDirectory(_ url: URL) throws {
        guard try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else { throw MeetingAudioArchiveError.invalidPath }
    }
    private func requireRegularFile(_ url: URL) throws {
        guard try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else { throw MeetingAudioArchiveError.invalidPath }
    }
}

/// A bounded queue, not an unbounded collection of DispatchQueue.async closures.
/// Capture threads only copy PCM and acquire the short queue lock. All file IO,
/// metering, journal writes and preview delivery happen on the worker queue.
final class MeetingAudioArchiveWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "WorkLog.meeting.original-writer", qos: .userInitiated)
    private let archive: MeetingAudioArchive
    private let maximumQueuedBytes: Int
    private let maximumQueuedPackets: Int
    private var pending: [MeetingCapturedPCM] = []
    private var pendingBytes = 0
    private var draining = false
    private var accepting = true
    private var terminalError: String?
    private var finishWaiters: [CheckedContinuation<MeetingAudioArchiveSnapshot, Never>] = []
    private var finalSnapshot: MeetingAudioArchiveSnapshot?
    // Only accessed by queue below.
    private var snapshot: MeetingAudioArchiveSnapshot
    private var files: [MeetingAudioTrackID: AVAudioFile] = [:]
    private var nextJournalTime: TimeInterval = 0
    private var nextMeterTime: [MeetingAudioTrackID: TimeInterval] = [:]
    private let onPCM: @Sendable (MeetingCapturedPCM) -> Void
    private let onLevel: @Sendable (MeetingAudioTrackID, Float) -> Void
    private let onFailure: @Sendable (String) -> Void
    private let writeHook: (@Sendable () throws -> Void)?

    init(archive: MeetingAudioArchive, recordingID: String, meetingID: String,
         clock: any Clock = SystemClock(), maximumQueuedBytes: Int = 16 * 1024 * 1024,
         maximumQueuedPackets: Int = 128,
         onPCM: @escaping @Sendable (MeetingCapturedPCM) -> Void,
         onLevel: @escaping @Sendable (MeetingAudioTrackID, Float) -> Void,
         onFailure: @escaping @Sendable (String) -> Void,
         writeHook: (@Sendable () throws -> Void)? = nil) throws {
        self.archive = archive
        self.snapshot = try archive.create(recordingID: recordingID, meetingID: meetingID, startedAt: clock.now())
        self.maximumQueuedBytes = max(1, maximumQueuedBytes)
        self.maximumQueuedPackets = max(1, maximumQueuedPackets)
        self.onPCM = onPCM; self.onLevel = onLevel; self.onFailure = onFailure; self.writeHook = writeHook
    }

    @discardableResult func enqueue(_ packet: MeetingCapturedPCM) -> Bool {
        lock.lock()
        guard accepting else { lock.unlock(); return false }
        guard pending.count < maximumQueuedPackets, pendingBytes + packet.byteCount <= maximumQueuedBytes else {
            accepting = false
            terminalError = MeetingAudioArchiveError.queueOverflow.localizedDescription
            let message = terminalError!
            lock.unlock()
            // Failure delivery is outside the capture callback and outside the writer
            // queue, so a stalled disk cannot delay the request to stop capture.
            DispatchQueue.global(qos: .userInitiated).async { self.onFailure(message) }
            return false
        }
        pending.append(packet); pendingBytes += packet.byteCount
        let schedule = !draining
        draining = true
        lock.unlock()
        if schedule { queue.async { self.drain() } }
        return true
    }

    /// Sequential file-import producers await each write instead of outrunning a
    /// real-time bounded queue. Capture producers always use nonblocking enqueue.
    func appendForImport(_ packet: MeetingCapturedPCM) async throws {
        guard enqueue(packet) else { throw MeetingAudioArchiveError.queueOverflow }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.lock.lock()
                let failure = self.terminalError
                self.lock.unlock()
                if let failure { continuation.resume(throwing: NSError(domain: "MeetingAudioImport", code: 1, userInfo: [NSLocalizedDescriptionKey: failure])) }
                else { continuation.resume() }
            }
        }
    }

    func finish(reason: String? = nil) async -> MeetingAudioArchiveSnapshot {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let finalSnapshot { lock.unlock(); continuation.resume(returning: finalSnapshot); return }
            accepting = false
            if terminalError == nil { terminalError = reason }
            finishWaiters.append(continuation)
            let schedule = !draining
            draining = true
            lock.unlock()
            if schedule { queue.async { self.drain() } }
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard !pending.isEmpty else {
                if !finishWaiters.isEmpty {
                    let message = terminalError
                    lock.unlock()
                    complete(reason: message)
                } else { draining = false; lock.unlock() }
                return
            }
            let packet = pending.removeFirst()
            pendingBytes -= packet.byteCount
            lock.unlock()
            do { try write(packet) }
            catch {
                let message = "PCM 원본 저장을 중단했습니다: " + error.localizedDescription
                lock.lock()
                accepting = false
                if terminalError == nil { terminalError = message }
                // A failed writer must not continue and pretend later audio is intact.
                pending.removeAll(); pendingBytes = 0
                lock.unlock()
                onFailure(message)
            }
        }
    }

    private func write(_ packet: MeetingCapturedPCM) throws {
        try writeHook?()
        let format = packet.buffer.format
        var newTrack = false
        if files[packet.track] == nil {
            let url = try archive.audioURL(recordingID: snapshot.recordingID, track: packet.track)
            guard !FileManager.default.fileExists(atPath: url.path) else { throw MeetingAudioArchiveError.alreadyExists }
            var fileSettings = format.settings
            // CAF stores interleaved PCM; the processing buffer keeps its original
            // layout. This changes layout only, never sample values or precision.
            fileSettings[AVLinearPCMIsNonInterleaved] = false
            files[packet.track] = try AVAudioFile(forWriting: url, settings: fileSettings,
                                                commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            snapshot.tracks.append(MeetingAudioTrackSnapshot(id: packet.track,
                relativePath: snapshot.recordingID + "/" + packet.track.rawValue + ".caf",
                sampleRate: format.sampleRate, channelCount: format.channelCount,
                commonFormat: format.commonFormat.rawValue, interleaved: format.isInterleaved,
                startOffset: packet.relativeStartSeconds, frameCount: 0, gaps: []))
            // Track identity reaches the journal before its first PCM write.
            try archive.save(snapshot)
            newTrack = true
        }
        guard let index = snapshot.tracks.firstIndex(where: { $0.id == packet.track }), let file = files[packet.track] else { throw MeetingAudioArchiveError.invalidPCM }
        let track = snapshot.tracks[index]
        guard file.processingFormat == format else { throw MeetingAudioArchiveError.formatChanged }
        let expected = track.startOffset + track.duration + track.gaps.reduce(0) { $0 + $1.duration }
        let delta = packet.relativeStartSeconds - expected
        guard delta >= -0.025 else { throw MeetingAudioArchiveError.formatChanged }
        if delta > 0.025 {
            snapshot.tracks[index].gaps.append(MeetingAudioGap(startOffset: expected, duration: delta, reason: "입력 오디오 시간 간격"))
            // Persist timing before the corresponding audio; crash recovery can still
            // reconstruct the frame-to-meeting-time mapping.
            try archive.save(snapshot)
        }
        try file.write(from: packet.buffer)
        snapshot.tracks[index].frameCount += Int64(packet.buffer.frameLength)
        if newTrack || packet.relativeStartSeconds >= nextJournalTime {
            try archive.save(snapshot)
            nextJournalTime = packet.relativeStartSeconds + 1
        }
        if packet.relativeStartSeconds >= nextMeterTime[packet.track, default: 0], let channel = packet.buffer.floatChannelData?[0] {
            var square: Float = 0
            for frame in 0..<Int(packet.buffer.frameLength) { let value = channel[frame * packet.buffer.stride]; square += value * value }
            onLevel(packet.track, sqrt(square / Float(packet.buffer.frameLength)))
            nextMeterTime[packet.track] = packet.relativeStartSeconds + 0.1
        }
        onPCM(packet)
    }

    private func complete(reason: String?) {
        for file in files.values { file.close() }
        files.removeAll() // closes CAF files before the final journal commit
        let failure = reason ?? (snapshot.tracks.allSatisfy { $0.frameCount == 0 }
            ? "저장된 PCM 오디오가 없습니다. 입력 장치와 녹음 권한을 확인해 주세요." : nil)
        snapshot.status = failure == nil ? .archived : .interrupted
        snapshot.error = failure
        do { try archive.save(snapshot) }
        catch {
            snapshot.status = .interrupted; snapshot.journalNeedsRetry = true
            snapshot.error = "원본은 보존했지만 복구 정보 저장에 실패했습니다. 저장 공간과 폴더 권한을 확인하고 저장을 재시도하세요."
        }
        lock.lock()
        finalSnapshot = snapshot
        let waiters = finishWaiters
        finishWaiters.removeAll()
        draining = false
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: snapshot) }
    }
}
#endif
