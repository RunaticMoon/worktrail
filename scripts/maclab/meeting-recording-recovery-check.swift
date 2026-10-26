// Tests pending-recording recovery with fake files only. No microphone is opened.
import Foundation
import WorkLogCore

@main struct MeetingRecordingRecoveryCheck {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fail("Expected a disposable test directory") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let storage = MeetingRecordingStorage(directory: root.appendingPathComponent("recordings", isDirectory: true))
        try storage.prepareDirectory()
        let pending = MeetingRecordingManifest(version: 1, fileName: "synthetic-recording.m4a", meetingID: "synthetic-meeting")
        let audio = try storage.audioURL(for: pending)
        let unrelated = storage.directory.appendingPathComponent("unrelated.m4a")
        let outside = root.appendingPathComponent("outside.m4a")
        try Data("fake recording, not actual audio".utf8).write(to: audio)
        try Data("unrelated".utf8).write(to: unrelated)
        try Data("outside".utf8).write(to: outside)
        try storage.writePending(pending)
        let manifestBytes = try Data(contentsOf: storage.manifestURL)
        let permissions = try FileManager.default.attributesOfItem(atPath: storage.manifestURL.path)[.posixPermissions] as? NSNumber
        requireThat(permissions?.intValue == 0o600, "Manifest must be private (0600)")
        let restored = MeetingAudioRecorder(directory: storage.directory, ids: SequentialIDGenerator())
        requireThat(restored.recordingURL == audio && restored.pendingMeetingID == pending.meetingID,
                    "Pending file and meeting were not recovered")
        requireThat(!restored.isRecording && !restored.isStarting && restored.lastError == nil,
                    "Recovery must not start recording or report failure")
        try requireThat(try Data(contentsOf: storage.manifestURL) == manifestBytes, "Recovery mutated the manifest")
        print("PASS: relaunch restores the pending meeting/file without recording or modifying the manifest")

        do {
            try storage.writePending(pending)
            fail("Existing manifest overwritten")
        } catch MeetingRecordingError.pendingRecording {
            print("PASS: existing pending manifest is not overwritten")
        }
        try restored.discardRecording()
        requireThat(restored.recordingURL == nil && restored.pendingMeetingID == nil,
                    "Discard did not clear in-memory recovery state")
        requireThat(!storage.entryExists(audio) && !storage.entryExists(storage.manifestURL)
                    && storage.entryExists(unrelated) && storage.entryExists(outside), "Discard touched unrelated files")
        print("PASS: discard removes only the exact pending file and manifest")

        let migrated = MeetingRecordingManifest(version: 1, fileName: "migrated-original.m4a", meetingID: "legacy-meeting")
        let migratedURL = try storage.audioURL(for: migrated)
        let originalBytes = Data("fake migrated original".utf8)
        try originalBytes.write(to: migratedURL)
        try storage.writePending(migrated)
        let released = MeetingAudioRecorder(directory: storage.directory)
        // Simulate another writer changing the pending meeting before release.
        let wrongMeeting = MeetingRecordingManifest(version: 1, fileName: migrated.fileName, meetingID: "different-meeting")
        try JSONEncoder().encode(wrongMeeting).write(to: storage.manifestURL)
        do {
            try released.releasePendingKeepingAudio()
            fail("Stale pending ownership was released")
        } catch MeetingRecordingError.recoveryFailed { }
        try requireThat(try storage.readPending() == wrongMeeting, "Failed release removed another meeting's manifest")
        try JSONEncoder().encode(migrated).write(to: storage.manifestURL)
        try released.releasePendingKeepingAudio()
        requireThat(released.recordingURL == nil && released.pendingMeetingID == nil && released.lastError == nil,
                    "Release did not clear pending ownership")
        try requireThat(try Data(contentsOf: migratedURL) == originalBytes, "Release changed or deleted legacy audio")
        requireThat(!storage.entryExists(storage.manifestURL) && storage.entryExists(unrelated), "Release changed unrelated files")
        print("PASS: migrated legacy release checks meeting ownership, removes only manifest and preserves original bytes")

        try Data("corrupt manifest".utf8).write(to: storage.manifestURL)
        let corrupt = MeetingAudioRecorder(directory: storage.directory)
        requireThat(corrupt.lastError != nil && corrupt.recordingURL == nil, "Corrupt manifest not reported")
        do {
            try await corrupt.start(meetingID: "other-meeting")
            fail("Corrupt recovery permitted a new recording")
        } catch MeetingRecordingError.recoveryFailed {
            // This error must precede bundle or microphone authorization checks.
        }
        try requireThat(try Data(contentsOf: storage.manifestURL) == Data("corrupt manifest".utf8), "Corrupt manifest deleted")
        print("PASS: corrupt manifest is preserved and blocks capture before microphone access")

        let invalid = MeetingRecordingManifest(version: 1, fileName: "../outside.m4a", meetingID: "synthetic-meeting")
        try JSONEncoder().encode(invalid).write(to: storage.manifestURL)
        let traversal = MeetingAudioRecorder(directory: storage.directory)
        requireThat(traversal.lastError != nil && traversal.recordingURL == nil && storage.entryExists(outside),
                    "Path traversal was accepted or removed outside audio")
        print("PASS: path traversal is rejected without touching outside files")

        try JSONEncoder().encode(pending).write(to: storage.manifestURL)
        try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: outside)
        let symlink = MeetingAudioRecorder(directory: storage.directory)
        requireThat(symlink.lastError != nil && symlink.recordingURL == nil && storage.entryExists(outside),
                    "Symlink audio was accepted or removed its target")
        try FileManager.default.removeItem(at: audio)
        print("PASS: symlink audio is rejected and its target is preserved")

        let missing = MeetingAudioRecorder(directory: storage.directory)
        requireThat(missing.lastError != nil && storage.entryExists(storage.manifestURL), "Missing audio lost recovery metadata")
        try FileManager.default.removeItem(at: storage.manifestURL)
        let empty = MeetingAudioRecorder(directory: storage.directory)
        requireThat(empty.recordingURL == nil && empty.lastError == nil && storage.entryExists(unrelated),
                    "An unreferenced file was scanned or removed")
        print("PASS: missing audio is reported, and unreferenced files remain untouched")
    }

    static func requireThat(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        if try !condition() { fail(message) }
    }
    static func fail(_ message: String) -> Never { print("FAIL: \(message)"); exit(1) }
}
