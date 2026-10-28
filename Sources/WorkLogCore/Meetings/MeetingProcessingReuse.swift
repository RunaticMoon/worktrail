import Foundation

/// Only immutable completed refined output with exactly matching inputs/settings can be reused.
public enum MeetingProcessingReuse {
    public static func isReusable(_ run: MeetingTranscriptRun, recordingID: String,
                                  modelIdentifier: String, modelRevision: String,
                                  settingsJSON: String, hasUserEdits: Bool) -> Bool {
        run.recordingID == recordingID && run.stage == .refined && run.status == .completed &&
        run.modelIdentifier == modelIdentifier && run.modelRevision == modelRevision &&
        run.settingsJSON == settingsJSON && !hasUserEdits
    }
}
