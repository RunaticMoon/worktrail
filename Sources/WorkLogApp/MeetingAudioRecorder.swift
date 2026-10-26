#if os(macOS)
import AVFoundation
import Foundation
import Observation
import WorkLogCore

enum MeetingRecordingError: LocalizedError {
    case busy, pendingRecording, permissionDenied, missingUsageDescription, cannotStart, noRecording, recoveryFailed

    var errorDescription: String? {
        switch self {
        case .busy: return "이미 녹음 중이거나 마이크 권한을 확인하고 있습니다."
        case .pendingRecording: return "이전 녹음을 먼저 전사하거나 삭제해 주세요. 실패한 녹음 파일은 재시도를 위해 보관하고 있습니다."
        case .permissionDenied: return "마이크 접근이 허용되지 않았습니다. 시스템 설정 → 개인정보 보호 및 보안 → 마이크에서 WorkLog를 허용해 주세요."
        case .missingUsageDescription: return "마이크 권한 설명이 포함된 WorkLog 앱 번들에서 녹음을 실행해 주세요."
        case .cannotStart: return "마이크 녹음을 시작하지 못했습니다. 입력 장치와 권한을 확인해 주세요."
        case .noRecording: return "사용할 수 있는 녹음 파일이 없습니다."
        case .recoveryFailed: return "보관된 녹음의 복구 정보를 확인하지 못했습니다. 파일은 삭제하지 않았습니다. 회의 녹음 폴더의 복구 정보와 원본 파일을 확인해 주세요."
        }
    }
}

/// Recording starts exclusively from an explicit user action. Pending audio and a
/// small manifest survive relaunch until the transcript is saved or explicitly discarded.
@Observable @MainActor final class MeetingAudioRecorder: NSObject, AVAudioRecorderDelegate {
    private(set) var isRecording = false
    private(set) var isStarting = false
    private(set) var recordingURL: URL?
    private(set) var pendingMeetingID: String?
    private(set) var lastError: String?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private let storage: MeetingRecordingStorage
    @ObservationIgnored private let ids: any IDGenerator
    @ObservationIgnored private var startCancelled = false
    @ObservationIgnored private var recoveryFailed = false

    init(directory: URL, ids: any IDGenerator = UUIDGenerator()) {
        self.storage = MeetingRecordingStorage(directory: directory)
        self.ids = ids
        super.init()
        // This is a read-only recovery check. No recording, permission prompts,
        // model installation, or scanning of unrelated audio happens at launch.
        do {
            if let pending = try storage.readPending() {
                recordingURL = try storage.audioURL(for: pending)
                pendingMeetingID = pending.meetingID
            }
        } catch {
            recoveryFailed = true
            lastError = MeetingRecordingError.recoveryFailed.localizedDescription
        }
    }

    func start(meetingID: String) async throws {
        guard !isRecording, !isStarting else { throw MeetingRecordingError.busy }
        guard !recoveryFailed else { throw MeetingRecordingError.recoveryFailed }
        guard recordingURL == nil else { throw MeetingRecordingError.pendingRecording }
        let pending = MeetingRecordingManifest(version: 1, fileName: ids.make() + ".m4a", meetingID: meetingID)
        let url = try storage.audioURL(for: pending)
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") is String else {
            throw MeetingRecordingError.missingUsageDescription
        }
        isStarting = true
        startCancelled = false
        lastError = nil
        defer { isStarting = false }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw MeetingRecordingError.permissionDenied
            }
        default: throw MeetingRecordingError.permissionDenied
        }
        try Task.checkCancellation()
        guard !startCancelled else { throw CancellationError() }
        try storage.prepareDirectory()
        // A second app instance or a repeated ID must never overwrite pending audio.
        guard try storage.readPending() == nil, !storage.entryExists(url) else {
            throw MeetingRecordingError.pendingRecording
        }
        do {
            let session = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            session.delegate = self
            guard session.prepareToRecord() else { throw MeetingRecordingError.cannotStart }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            // Persist recovery information before capture can begin.
            try storage.writePending(pending)
            guard session.record() else { throw MeetingRecordingError.cannotStart }
            recorder = session
            recordingURL = url
            pendingMeetingID = meetingID
            isRecording = true
        } catch {
            if (try? storage.readPending()) == pending {
                do { try storage.removePending(expected: pending) }
                catch {
                    recoveryFailed = true
                    lastError = MeetingRecordingError.recoveryFailed.localizedDescription
                    throw MeetingRecordingError.recoveryFailed
                }
            } else {
                // Only this attempt's new file is eligible for cleanup.
                try? FileManager.default.removeItem(at: url)
            }
            lastError = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    func stop() throws -> URL {
        startCancelled = true
        guard let url = recordingURL else { throw MeetingRecordingError.noRecording }
        recorder?.stop()
        recorder = nil
        isRecording = false
        guard let pending = try storage.readPending(), pending.meetingID == pendingMeetingID,
              try storage.audioURL(for: pending) == url else { throw MeetingRecordingError.noRecording }
        return url
    }

    /// Also cancels a pending permission prompt's eventual start; it cannot dismiss
    /// the system prompt itself. It never deletes imported files or other sessions.
    func discardRecording() throws {
        startCancelled = true
        recorder?.stop()
        recorder = nil
        isRecording = false
        guard !recoveryFailed else { throw MeetingRecordingError.recoveryFailed }
        if let url = recordingURL, let meetingID = pendingMeetingID {
            do {
                try storage.removePending(expected: MeetingRecordingManifest(version: 1, fileName: url.lastPathComponent, meetingID: meetingID))
            } catch {
                lastError = MeetingRecordingError.recoveryFailed.localizedDescription
                throw MeetingRecordingError.recoveryFailed
            }
        }
        recordingURL = nil
        pendingMeetingID = nil
        lastError = nil
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.recordingURL == url else { return }
            self.isRecording = false
            if !flag { self.lastError = "녹음이 중단되었습니다. 저장된 음성으로 전사를 재시도할 수 있습니다." }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.recordingURL == url else { return }
            self.recorder?.stop()
            self.isRecording = false
            self.lastError = "녹음 파일을 저장하는 중 오류가 발생했습니다. 입력 장치와 저장 공간을 확인해 주세요."
        }
    }
}

struct MeetingRecordingManifest: Codable, Equatable {
    let version: Int
    let fileName: String
    let meetingID: String
}

/// Confines recovery and cleanup to one explicit file in the injected app-owned folder.
/// No directory enumeration or audio interpretation is needed to recover a pending item.
struct MeetingRecordingStorage {
    let directory: URL
    var manifestURL: URL { directory.appendingPathComponent("pending-recording.json") }

    func prepareDirectory() throws {
        try validateDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    func audioURL(for pending: MeetingRecordingManifest) throws -> URL {
        let fileName = pending.fileName
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let stem = String(fileName.dropLast(4))
        guard directory.isFileURL, pending.version == 1, fileName.hasSuffix(".m4a"),
              !stem.isEmpty, fileName.utf8.count <= 160,
              stem.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !pending.meetingID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              pending.meetingID.utf8.count <= 512, !pending.meetingID.contains("\0") else {
            throw MeetingRecordingError.recoveryFailed
        }
        let url = directory.appendingPathComponent(fileName).standardizedFileURL
        guard url.deletingLastPathComponent().path == directory.standardizedFileURL.path else {
            throw MeetingRecordingError.recoveryFailed
        }
        return url
    }

    func readPending() throws -> MeetingRecordingManifest? {
        try validateDirectory()
        let attributes: [FileAttributeKey: Any]
        do { attributes = try regularFileAttributes(manifestURL) }
        catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) { return nil }
            throw error
        }
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 16_384 else {
            throw MeetingRecordingError.recoveryFailed
        }
        let pending = try JSONDecoder().decode(MeetingRecordingManifest.self, from: Data(contentsOf: manifestURL))
        let url = try audioURL(for: pending)
        _ = try regularFileAttributes(url)
        return pending
    }

    func writePending(_ pending: MeetingRecordingManifest) throws {
        try validateDirectory()
        guard !entryExists(manifestURL) else { throw MeetingRecordingError.pendingRecording }
        let url = try audioURL(for: pending)
        _ = try regularFileAttributes(url)
        try JSONEncoder().encode(pending).write(to: manifestURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    }

    func removePending(expected: MeetingRecordingManifest) throws {
        guard try readPending() == expected else { throw MeetingRecordingError.recoveryFailed }
        // Only the validated manifest's exact regular file is removed. If either
        // deletion fails, expose the error instead of discarding recovery state.
        try FileManager.default.removeItem(at: audioURL(for: expected))
        try FileManager.default.removeItem(at: manifestURL)
    }

    func entryExists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private func validateDirectory() throws {
        guard directory.isFileURL else { throw MeetingRecordingError.recoveryFailed }
        if entryExists(directory) {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw MeetingRecordingError.recoveryFailed
            }
        }
    }

    private func regularFileAttributes(_ url: URL) throws -> [FileAttributeKey: Any] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw MeetingRecordingError.recoveryFailed
        }
        return attributes
    }
}
#endif
