import Foundation

extension MeetingAudioStore {
    func decodePreviewGap(_ row: SQLRow) throws -> MeetingStoredPreviewGap {
        guard let id = row.string("id"), let runID = row.string("run_id"), let trackID = row.string("track_id"),
              let start = number(row, "start"), let end = number(row, "end"),
              let reason = row.string("reason"), let createdAt = row.date("created_at") else { throw invalidStorage() }
        return MeetingStoredPreviewGap(id: id, runID: runID, trackID: trackID, start: start, end: end, reason: reason, createdAt: createdAt)
    }

    func decodeRecording(_ row: SQLRow) throws -> MeetingRecording {
        guard let id = row.string("id"), let meetingID = row.string("meeting_id"),
              let state = row.string("state").flatMap(MeetingRecordingState.init(rawValue:)),
              let revision = row.int("revision"), let started = row.date("started_at"),
              let updated = row.date("updated_at") else { throw invalidStorage() }
        return MeetingRecording(id: id, meetingID: meetingID, state: state, revision: revision,
            startedAt: started, endedAt: row.date("ended_at"), updatedAt: updated)
    }

    func decodeTrack(_ row: SQLRow) throws -> MeetingAudioTrack {
        guard let id = row.string("id"), let recordingID = row.string("recording_id"),
              let kind = row.string("kind").flatMap(MeetingTrackKind.init(rawValue:)),
              let path = row.string("relative_path"),
              let state = row.string("file_state").flatMap(MeetingTrackFileState.init(rawValue:)),
              let sampleRate = number(row, "sample_rate"), let channels = row.int("channels"),
              let offset = number(row, "start_offset"), let interruptions = row.string("interruptions_json"),
              let revision = row.int("revision"), let created = row.date("created_at"),
              let updated = row.date("updated_at") else { throw invalidStorage() }
        return MeetingAudioTrack(id: id, recordingID: recordingID, kind: kind, relativePath: path,
            fileState: state, sampleRate: sampleRate, channels: channels, startOffset: offset,
            duration: number(row, "duration"),
            interruptions: try StableJSON.decode([MeetingTrackInterruption].self, from: interruptions),
            revision: revision, createdAt: created, updatedAt: updated)
    }

    func decodeRun(_ row: SQLRow) throws -> MeetingTranscriptRun {
        guard let id = row.string("id"), let meetingID = row.string("meeting_id"),
              let stage = row.string("stage").flatMap(MeetingTranscriptStage.init(rawValue:)),
              let engine = row.string("engine"), let model = row.string("model_identifier"),
              let settings = row.string("settings_json"),
              let status = row.string("status").flatMap(MeetingTranscriptRunStatus.init(rawValue:)),
              let version = row.int("version"), let revision = row.int("revision"),
              let created = row.date("created_at"), let updated = row.date("updated_at") else { throw invalidStorage() }
        return MeetingTranscriptRun(id: id, meetingID: meetingID, recordingID: row.string("recording_id"),
            sourceRunID: row.string("source_run_id"), stage: stage, engine: engine, modelIdentifier: model,
            modelRevision: row.string("model_revision"), settingsJSON: settings, status: status,
            version: version, revision: revision, manualText: row.string("manual_text"),
            createdAt: created, updatedAt: updated, completedAt: row.date("completed_at"))
    }

    func decodeSegment(_ row: SQLRow) throws -> MeetingTranscriptSegment {
        guard let id = row.string("id"), let runID = row.string("run_id"), let trackID = row.string("track_id"),
              let key = row.string("source_key"), let start = number(row, "start"), let end = number(row, "end"),
              let original = row.string("original_text"), let revision = row.int("revision") else { throw invalidStorage() }
        return MeetingTranscriptSegment(id: id, runID: runID, trackID: trackID, sourceKey: key,
            start: start, end: end, originalText: original, editedText: row.string("edited_text"),
            originalSpeakerID: row.string("original_speaker_id"), editedSpeakerID: row.string("edited_speaker_id"),
            isSpeakerEdited: row.bool("is_speaker_edited"), isFinal: row.bool("is_final"), revision: revision)
    }

    func decodeSpeaker(_ row: SQLRow) throws -> MeetingSpeaker {
        guard let id = row.string("id"), let recordingID = row.string("recording_id"),
              let runID = row.string("run_id"), let sourceKey = row.string("source_key"),
              let original = row.string("original_name"), let display = row.string("display_name"),
              let revision = row.int("revision") else { throw invalidStorage() }
        return MeetingSpeaker(id: id, recordingID: recordingID, runID: runID, sourceKey: sourceKey,
            originalName: original, displayName: display, isUserEdited: row.bool("is_user_edited"), revision: revision)
    }

    private func number(_ row: SQLRow, _ column: String) -> Double? {
        guard let raw = row.string(column), let number = Double(raw), number.isFinite else { return nil }
        return number
    }
}
