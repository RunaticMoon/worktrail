import Foundation

/// 녹음 파일의 참조와 전사 버전만 관리한다. 파일·네트워크·마이크에 접근하지 않는다.
public final class MeetingAudioStore: @unchecked Sendable {
    public let repo: WorkRepository
    public init(repo: WorkRepository) { self.repo = repo }

    public func recordings(meetingID: String) throws -> [MeetingRecording] {
        try repo.db.queryV("SELECT * FROM meeting_recording WHERE meeting_id = ? ORDER BY started_at, id", meetingID)
            .map(decodeRecording)
    }
    public func recording(id: String) throws -> MeetingRecording? {
        try repo.db.queryOneV("SELECT * FROM meeting_recording WHERE id = ?", id).map(decodeRecording)
    }
    public func tracks(recordingID: String) throws -> [MeetingAudioTrack] {
        try repo.db.queryV("SELECT * FROM meeting_audio_track WHERE recording_id = ? ORDER BY start_offset, id", recordingID)
            .map(decodeTrack)
    }
    public func track(id: String) throws -> MeetingAudioTrack? {
        try repo.db.queryOneV("SELECT * FROM meeting_audio_track WHERE id = ?", id).map(decodeTrack)
    }
    public func runs(meetingID: String) throws -> [MeetingTranscriptRun] {
        try repo.db.queryV("SELECT * FROM meeting_transcript_run WHERE meeting_id = ? ORDER BY version DESC", meetingID)
            .map(decodeRun)
    }
    public func run(id: String) throws -> MeetingTranscriptRun? {
        try repo.db.queryOneV("SELECT * FROM meeting_transcript_run WHERE id = ?", id).map(decodeRun)
    }
    public func segments(runID: String) throws -> [MeetingTranscriptSegment] {
        try repo.db.queryV("SELECT * FROM meeting_transcript_segment WHERE run_id = ? ORDER BY start, end, source_key", runID)
            .map(decodeSegment)
    }
    public func segment(id: String) throws -> MeetingTranscriptSegment? {
        try repo.db.queryOneV("SELECT * FROM meeting_transcript_segment WHERE id = ?", id).map(decodeSegment)
    }
    public func speakers(runID: String) throws -> [MeetingSpeaker] {
        try repo.db.queryV("SELECT * FROM meeting_speaker WHERE run_id = ? ORDER BY source_key, id", runID)
            .map(decodeSpeaker)
    }
    public func speaker(id: String) throws -> MeetingSpeaker? {
        try repo.db.queryOneV("SELECT * FROM meeting_speaker WHERE id = ?", id).map(decodeSpeaker)
    }
    public func edits(runID: String) throws -> [MeetingTranscriptEdit] {
        try repo.db.queryV("SELECT * FROM meeting_transcript_edit WHERE run_id = ? ORDER BY created_at, id", runID).map {
            guard let id = $0.string("id"), let previous = $0.string("previous_text"),
                  let replacement = $0.string("replacement_text"), let date = $0.date("created_at") else { throw invalidStorage() }
            return MeetingTranscriptEdit(id: id, runID: runID, segmentID: $0.string("segment_id"),
                speakerID: $0.string("speaker_id"), previousText: previous, replacementText: replacement, createdAt: date)
        }
    }

    public func previewGaps(runID: String) throws -> [MeetingStoredPreviewGap] {
        try repo.db.queryV("SELECT * FROM meeting_preview_gap WHERE run_id = ? ORDER BY start, end, id", runID).map(decodePreviewGap)
    }

    public func previewGaps(recordingID: String) throws -> [MeetingStoredPreviewGap] {
        try repo.db.queryV("""
            SELECT g.* FROM meeting_preview_gap g JOIN meeting_transcript_run r ON r.id = g.run_id
            WHERE r.recording_id = ? ORDER BY g.start, g.end, g.id
            """, recordingID).map(decodePreviewGap)
    }

    @discardableResult
    public func recordPreviewGap(runID: String, trackID: String, start: Double, end: Double,
                                  reason: String) throws -> MeetingStoredPreviewGap {
        try validateLabel(reason)
        guard start.isFinite, end.isFinite, start >= 0, end > start else {
            throw WorkLogError.validation("미리보기 누락 구간을 확인해 주세요.")
        }
        return try repo.db.transaction {
            let run = try requireRun(runID), track = try requireTrack(trackID)
            _ = try requireMeeting(run.meetingID)
            guard [.live, .refined].contains(run.stage), track.recordingID == run.recordingID else {
                throw WorkLogError.validation("미리보기와 음성 트랙의 녹음이 다릅니다.")
            }
            if let existing = try repo.db.queryOneV("""
                SELECT * FROM meeting_preview_gap WHERE run_id = ? AND track_id = ? AND start = ? AND end = ? AND reason = ?
                """, runID, trackID, start, end, reason) { return try decodePreviewGap(existing) }
            guard try repo.db.scalarIntV("SELECT COUNT(*) FROM meeting_preview_gap WHERE run_id = ?", runID) < 100_000 else {
                throw WorkLogError.validation("미리보기 누락 기록이 너무 많습니다.")
            }
            let id = repo.ids.make()
            try repo.db.runV("""
                INSERT INTO meeting_preview_gap (id, run_id, track_id, start, end, reason, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, id, runID, trackID, start, end, reason, repo.clock.now())
            try bumpRun(runID)
            guard let saved = try repo.db.queryOneV("SELECT * FROM meeting_preview_gap WHERE id = ?", id) else { throw invalidStorage() }
            return try decodePreviewGap(saved)
        }
    }

    public func createRecording(meetingID: String, id suppliedID: String? = nil,
                                 startedAt: Date? = nil) throws -> MeetingRecording {
        if let suppliedID { try validateLabel(suppliedID) }
        if let startedAt, !startedAt.timeIntervalSince1970.isFinite { throw WorkLogError.validation("녹음 시작 시각을 확인해 주세요.") }
        return try repo.db.transaction {
            _ = try requireMeeting(meetingID)
            if let suppliedID, let existing = try recording(id: suppliedID) {
                guard existing.meetingID == meetingID else { throw WorkLogError.conflict("녹음 식별자가 다른 회의에서 사용 중입니다.") }
                return existing
            }
            let id = suppliedID ?? repo.ids.make(), now = repo.clock.now()
            try repo.db.runV("""
                INSERT INTO meeting_recording (id, meeting_id, state, revision, started_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, id, meetingID, MeetingRecordingState.recording.rawValue, 1, startedAt ?? now, now)
            return try requireRecording(id)
        }
    }

    @discardableResult
    public func updateRecordingState(id: String, expectedRevision: Int,
                                     state: MeetingRecordingState) throws -> MeetingRecording {
        try repo.db.transaction {
            let old = try requireRecording(id)
            _ = try requireMeeting(old.meetingID)
            try checkRevision(old.revision, expectedRevision)
            if old.state == state { return old }
            let permitted: Bool
            switch old.state {
            case .recording: permitted = state != .recording
            case .paused: permitted = state != .paused
            case .interrupted: permitted = [.recording, .completed, .discarded].contains(state)
            case .failed: permitted = [.recording, .completed, .interrupted, .discarded].contains(state)
            case .completed: permitted = state == .discarded
            case .discarded: permitted = false
            }
            guard permitted else { throw WorkLogError.invalidTransition("녹음 상태를 변경할 수 없습니다.") }
            let now = repo.clock.now()
            let ended: Date? = state == .completed || state == .discarded ? now : old.endedAt
            try repo.db.runV("""
                UPDATE meeting_recording SET state = ?, revision = revision + 1, ended_at = ?, updated_at = ?
                WHERE id = ? AND revision = ?
                """, state.rawValue, ended, now, id, expectedRevision)
            return try requireRecording(id)
        }
    }

    public func addTrack(recordingID: String, kind: MeetingTrackKind, relativePath: String,
                         sampleRate: Double, channels: Int, startOffset: Double = 0,
                         fileState: MeetingTrackFileState = .pending) throws -> MeetingAudioTrack {
        try validateRelativePath(relativePath)
        guard sampleRate.isFinite, (1...384_000).contains(sampleRate), (1...32).contains(channels),
              startOffset.isFinite, startOffset >= 0 else { throw WorkLogError.validation("음성 트랙 형식을 확인해 주세요.") }
        return try repo.db.transaction {
            let recording = try requireRecording(recordingID)
            _ = try requireMeeting(recording.meetingID)
            guard recording.state != .discarded else { throw WorkLogError.invalidTransition("폐기한 녹음에는 트랙을 추가할 수 없습니다.") }
            let id = repo.ids.make(), now = repo.clock.now()
            try repo.db.runV("""
                INSERT INTO meeting_audio_track (id, recording_id, kind, relative_path, file_state,
                    sample_rate, channels, start_offset, revision, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, id, recordingID, kind.rawValue, relativePath, fileState.rawValue,
                sampleRate, channels, startOffset, 1, now, now)
            return try requireTrack(id)
        }
    }

    @discardableResult
    public func updateTrack(id: String, expectedRevision: Int, fileState: MeetingTrackFileState,
                            duration: Double? = nil, interruptions: [MeetingTrackInterruption]? = nil,
                            startOffset: Double? = nil) throws -> MeetingAudioTrack {
        if let duration, !duration.isFinite || duration < 0 { throw WorkLogError.validation("음성 길이를 확인해 주세요.") }
        if let startOffset, !startOffset.isFinite || startOffset < 0 { throw WorkLogError.validation("음성 시작 시점을 확인해 주세요.") }
        if let interruptions { try validateInterruptions(interruptions) }
        return try repo.db.transaction {
            let old = try requireTrack(id)
            try checkRevision(old.revision, expectedRevision)
            guard old.fileState != .deleted || fileState == .deleted else {
                throw WorkLogError.invalidTransition("삭제한 음성 파일 참조를 다시 사용할 수 없습니다.")
            }
            let recording = try requireRecording(old.recordingID)
            // 복원한 백업의 음성 누락 표시는 휴지통 회의에도 유지한다.
            _ = try requireMeeting(recording.meetingID, includeDeleted: true)
            try repo.db.runV("""
                UPDATE meeting_audio_track SET file_state = ?, duration = ?, interruptions_json = ?,
                    start_offset = ?, revision = revision + 1, updated_at = ? WHERE id = ? AND revision = ?
                """, fileState.rawValue, duration ?? old.duration,
                try StableJSON.string(interruptions ?? old.interruptions), startOffset ?? old.startOffset,
                repo.clock.now(), id, expectedRevision)
            return try requireTrack(id)
        }
    }

    public func createRun(meetingID: String, recordingID: String? = nil, stage: MeetingTranscriptStage,
                          engine: String, modelIdentifier: String, modelRevision: String? = nil,
                          settingsJSON: String = "{}", sourceRunID: String? = nil) throws -> MeetingTranscriptRun {
        try validateLabel(engine); try validateLabel(modelIdentifier)
        if let modelRevision { try validateLabel(modelRevision) }
        guard settingsJSON.utf8.count <= 64_000,
              let settings = try? JSONSerialization.jsonObject(with: Data(settingsJSON.utf8)),
              settings is [String: Any] else { throw WorkLogError.validation("전사 설정은 JSON 객체여야 합니다.") }
        return try repo.db.transaction {
            _ = try requireMeeting(meetingID)
            if let recordingID {
                let recording = try requireRecording(recordingID)
                guard recording.meetingID == meetingID, recording.state != .discarded || stage == .manual else {
                    throw WorkLogError.validation("회의와 녹음이 일치하지 않습니다.")
                }
            } else if stage != .manual {
                throw WorkLogError.validation("음성 전사 버전에는 녹음이 필요합니다.")
            }
            if let sourceRunID {
                let source = try requireRun(sourceRunID)
                guard source.meetingID == meetingID else { throw WorkLogError.validation("이전 전사 버전의 회의가 다릅니다.") }
            }
            let version = try repo.db.scalarIntV("SELECT COALESCE(MAX(version), 0) + 1 FROM meeting_transcript_run WHERE meeting_id = ?", meetingID)
            let id = repo.ids.make(), now = repo.clock.now()
            try repo.db.runV("""
                INSERT INTO meeting_transcript_run (id, meeting_id, recording_id, source_run_id, stage,
                    engine, model_identifier, model_revision, settings_json, status, version, revision, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, id, meetingID, recordingID, sourceRunID, stage.rawValue, engine, modelIdentifier,
                modelRevision, settingsJSON, MeetingTranscriptRunStatus.running.rawValue, version, 1, now, now)
            return try requireRun(id)
        }
    }

    /// 모델 결과 재전송은 sourceKey로 갱신한다. 사용자가 수정한 본문·화자는 별도 컬럼에 유지한다.
    @discardableResult
    public func upsertSegments(runID: String, segments inputs: [MeetingSegmentInput]) throws -> MeetingTranscriptRun {
        guard inputs.count <= 10_000, Set(inputs.map(\.sourceKey)).count == inputs.count else {
            throw WorkLogError.validation("전사 조각 수 또는 식별자를 확인해 주세요.")
        }
        return try repo.db.transaction {
            let run = try requireRun(runID)
            _ = try requireMeeting(run.meetingID)
            guard run.status == .running, run.stage != .manual else {
                throw WorkLogError.invalidTransition("진행 중인 음성 전사 버전에만 결과를 저장할 수 있습니다.")
            }
            for input in inputs {
                try validateLabel(input.sourceKey)
                guard input.start.isFinite, input.end.isFinite, input.start >= 0, input.end >= input.start,
                      input.text.utf8.count <= MeetingLimits.notesBytes else {
                    throw WorkLogError.validation("전사 조각의 시간 또는 길이를 확인해 주세요.")
                }
                let track = try requireTrack(input.trackID)
                guard track.recordingID == run.recordingID else { throw WorkLogError.validation("전사와 음성 트랙의 녹음이 다릅니다.") }
                try validateSpeaker(input.speakerID, for: run)
                if let row = try repo.db.queryOneV("SELECT * FROM meeting_transcript_segment WHERE run_id = ? AND source_key = ?", runID, input.sourceKey) {
                    let previous = try decodeSegment(row)
                    guard previous.trackID == input.trackID else { throw WorkLogError.conflict("같은 전사 조각의 트랙이 변경되었습니다.") }
                    try repo.db.runV("""
                        UPDATE meeting_transcript_segment SET start = ?, end = ?, original_text = ?,
                            original_speaker_id = ?, is_final = ?, revision = revision + 1 WHERE id = ?
                        """, input.start, input.end, input.text, input.speakerID, input.isFinal, previous.id)
                } else {
                    try repo.db.runV("""
                        INSERT INTO meeting_transcript_segment (id, run_id, track_id, source_key, start, end,
                            original_text, original_speaker_id, is_final, revision)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, repo.ids.make(), runID, input.trackID, input.sourceKey, input.start, input.end,
                        input.text, input.speakerID, input.isFinal, 1)
                }
            }
            try validateStoredSegmentBounds(runID: runID)
            try bumpRun(runID)
            try refreshActiveTranscript(runID: runID)
            return try requireRun(runID)
        }
    }

    /// 현재 트랙의 partial 키 전체를 전달한다. 사라진 임시 가설만 지우며 확정·직접 수정한 구간은 보존한다.
    /// 실시간·정밀 전사의 rolling decoder 모두 사용한다. segments가 비어도 삭제 체크포인트를 저장한다.
    @discardableResult
    public func checkpointLiveSegments(runID: String, trackID: String, segments inputs: [MeetingSegmentInput],
                                        activePartialKeys: [String]) throws -> MeetingTranscriptRun {
        guard activePartialKeys.count <= 100_000, inputs.count <= 10_000,
              Set(inputs.map(\.sourceKey)).count == inputs.count, inputs.allSatisfy({ $0.trackID == trackID }) else {
            throw WorkLogError.validation("전사 체크포인트의 트랙과 임시 구간을 확인해 주세요.")
        }
        for key in activePartialKeys { try validateLabel(key) }
        return try repo.db.transaction {
            let run = try requireRun(runID), track = try requireTrack(trackID)
            _ = try requireMeeting(run.meetingID)
            guard run.status == .running, [.live, .refined].contains(run.stage),
                  track.recordingID == run.recordingID else {
                throw WorkLogError.invalidTransition("진행 중인 해당 음성 전사에만 체크포인트를 저장할 수 있습니다.")
            }
            let previous = try repo.db.queryV("SELECT * FROM meeting_transcript_segment WHERE run_id = ? AND track_id = ?", runID, trackID).map(decodeSegment)
            let activeKeys = Set(activePartialKeys), incomingFinalKeys = Set(inputs.filter(\.isFinal).map(\.sourceKey))
            for old in previous where !old.isFinal && !old.isUserEdited
                && !activeKeys.contains(old.sourceKey) && !incomingFinalKeys.contains(old.sourceKey) {
                try repo.db.runV("DELETE FROM meeting_transcript_segment WHERE id = ?", old.id)
            }
            // A late rolling hypothesis cannot downgrade or replace an already stable segment.
            let stableKeys = Set(previous.filter(\.isFinal).map(\.sourceKey))
            let retained = inputs.filter { !stableKeys.contains($0.sourceKey) && ($0.isFinal || activeKeys.contains($0.sourceKey)) }
            return try upsertSegments(runID: runID, segments: retained)
        }
    }

    @discardableResult
    public func finishRun(id: String, status: MeetingTranscriptRunStatus = .completed) throws -> MeetingTranscriptRun {
        guard status != .running else { throw WorkLogError.validation("완료할 전사 상태를 선택해 주세요.") }
        return try repo.db.transaction {
            let run = try requireRun(id)
            _ = try requireMeeting(run.meetingID)
            if run.status == status { return run }
            guard run.status == .running || run.status == .interrupted else {
                throw WorkLogError.invalidTransition("종료된 전사 버전의 상태를 변경할 수 없습니다.")
            }
            let now = repo.clock.now()
            try repo.db.runV("UPDATE meeting_transcript_run SET status = ?, completed_at = ?, updated_at = ?, revision = revision + 1 WHERE id = ?",
                status.rawValue, now, now, id)
            try refreshActiveTranscript(runID: id)
            return try requireRun(id)
        }
    }

    public func upsertSpeaker(runID: String, sourceKey: String, displayName: String) throws -> MeetingSpeaker {
        try validateLabel(sourceKey); try validateLabel(displayName)
        return try repo.db.transaction {
            let run = try requireRun(runID)
            _ = try requireMeeting(run.meetingID)
            guard let recordingID = run.recordingID, run.status == .running else {
                throw WorkLogError.invalidTransition("진행 중인 녹음 전사에만 화자를 추가할 수 있습니다.")
            }
            let id: String
            if let row = try repo.db.queryOneV("SELECT * FROM meeting_speaker WHERE run_id = ? AND source_key = ?", runID, sourceKey) {
                let existing = try decodeSpeaker(row); id = existing.id
                try repo.db.runV("""
                    UPDATE meeting_speaker SET original_name = ?, display_name = ?, revision = revision + 1 WHERE id = ?
                    """, displayName, existing.isUserEdited ? existing.displayName : displayName, id)
            } else {
                id = repo.ids.make()
                try repo.db.runV("""
                    INSERT INTO meeting_speaker (id, recording_id, run_id, source_key, original_name, display_name)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, id, recordingID, runID, sourceKey, displayName, displayName)
            }
            try bumpRun(runID)
            try refreshActiveTranscript(runID: runID)
            return try requireSpeaker(id)
        }
    }

    @discardableResult
    public func renameSpeaker(id: String, expectedRevision: Int, displayName: String) throws -> MeetingSpeaker {
        try validateLabel(displayName)
        return try repo.db.transaction {
            let old = try requireSpeaker(id)
            let run = try requireRun(old.runID)
            _ = try requireMeeting(run.meetingID)
            try checkRevision(old.revision, expectedRevision)
            if old.displayName == displayName { return old }
            try recordEdit(runID: old.runID, speakerID: old.id, previous: old.displayName, replacement: displayName)
            try repo.db.runV("UPDATE meeting_speaker SET display_name = ?, is_user_edited = ?, revision = revision + 1 WHERE id = ?",
                displayName, true, id)
            try bumpRun(old.runID)
            try refreshActiveTranscript(runID: old.runID)
            return try requireSpeaker(id)
        }
    }

    @discardableResult
    public func editSegment(id: String, expectedRevision: Int, text: String? = nil,
                            speakerID: String? = nil, editSpeaker: Bool = false) throws -> MeetingTranscriptSegment {
        if let text, text.utf8.count > MeetingLimits.notesBytes { throw WorkLogError.validation("수정한 전사 조각이 너무 깁니다.") }
        return try repo.db.transaction {
            guard let old = try segment(id: id) else { throw WorkLogError.notFound("전사 조각") }
            let run = try requireRun(old.runID)
            _ = try requireMeeting(run.meetingID)
            try checkRevision(old.revision, expectedRevision)
            if editSpeaker { try validateSpeaker(speakerID, for: run) }
            if let text, text != old.text {
                try recordEdit(runID: run.id, segmentID: id, previous: old.text, replacement: text)
            }
            if editSpeaker, speakerID != old.speakerID {
                try recordEdit(runID: run.id, segmentID: id, previous: old.speakerID ?? "", replacement: speakerID ?? "")
            }
            try repo.db.runV("""
                UPDATE meeting_transcript_segment SET edited_text = ?, edited_speaker_id = ?,
                    is_speaker_edited = ?, revision = revision + 1 WHERE id = ?
                """, text ?? old.editedText, editSpeaker ? speakerID : old.editedSpeakerID,
                editSpeaker || old.isSpeakerEdited, id)
            try validateStoredSegmentBounds(runID: run.id)
            try bumpRun(run.id)
            try refreshActiveTranscript(runID: run.id)
            guard let result = try segment(id: id) else { throw invalidStorage() }
            return result
        }
    }

    /// 직접 수정된 활성 버전은 명시적 선택 없이는 다른 결과로 교체하지 않는다.
    @discardableResult
    public func activateRun(meetingID: String, runID: String, expectedMeetingRevision: Int,
                            allowReplacingUserEdits: Bool = false) throws -> Meeting {
        try repo.db.transaction {
            let meeting = try requireMeeting(meetingID)
            try checkRevision(meeting.revision, expectedMeetingRevision)
            let run = try requireRun(runID)
            guard run.meetingID == meetingID,
                  run.status == .completed || (run.stage == .live && run.status == .running) else {
                throw WorkLogError.validation("완료된 전사 또는 진행 중인 실시간 전사만 선택할 수 있습니다.")
            }
            if meeting.activeTranscriptRunID == runID { return meeting }
            if !allowReplacingUserEdits {
                if let activeID = meeting.activeTranscriptRunID {
                    guard try !hasUserEdits(runID: activeID) else {
                        throw WorkLogError.conflict("현재 전사에 직접 수정한 내용이 있습니다. 버전을 비교한 뒤 명시적으로 선택해 주세요.")
                    }
                } else if !meeting.transcript.isEmpty {
                    throw WorkLogError.conflict("직접 작성한 전사가 있습니다. 새 버전을 선택할지 확인해 주세요.")
                }
            }
            // v5의 원문도 첫 교체 전에 manual 버전으로 남긴다.
            if meeting.activeTranscriptRunID == nil, !meeting.transcript.isEmpty {
                _ = try makeManualRun(meeting: meeting, text: meeting.transcript)
            }
            let text = try renderedTranscript(runID: runID)
            try repo.db.runV("""
                UPDATE meeting SET active_transcript_run_id = ?, transcript = ?, revision = revision + 1, updated_at = ? WHERE id = ?
                """, runID, text, repo.clock.now(), meetingID)
            return try requireMeeting(meetingID)
        }
    }

    public func renderedTranscript(runID: String) throws -> String {
        let run = try requireRun(runID)
        if let manual = run.manualText { return manual }
        let names = Dictionary(uniqueKeysWithValues: try speakers(runID: runID).map { ($0.id, $0.displayName) })
        let result = try segments(runID: runID).filter { $0.isFinal || $0.isUserEdited }.map { segment in
            if let id = segment.speakerID, let name = names[id] { return "\(name): \(segment.text)" }
            return segment.text
        }.joined(separator: "\n")
        guard result.utf8.count <= MeetingLimits.transcriptBytes else { throw WorkLogError.validation("전체 전사가 허용 크기를 초과했습니다.") }
        return result
    }

    public func hasUserEdits(runID: String) throws -> Bool {
        let run = try requireRun(runID)
        if run.manualText != nil { return true }
        return try repo.db.scalarIntV("""
            SELECT (SELECT COUNT(*) FROM meeting_transcript_segment WHERE run_id = ? AND (edited_text IS NOT NULL OR is_speaker_edited = 1))
                 + (SELECT COUNT(*) FROM meeting_speaker WHERE run_id = ? AND is_user_edited = 1)
            """, runID, runID) > 0
    }

    /// 앱 재시작 시 호출한다. 실제 파일 유무는 앱이 확인하여 updateTrack으로 반영한다.
    @discardableResult
    public func recoverInterrupted() throws -> [MeetingRecording] {
        try repo.db.transaction {
            let pending = try repo.db.query("SELECT * FROM meeting_recording WHERE state IN ('recording','paused')").map(decodeRecording)
            let now = repo.clock.now()
            for recording in pending {
                try repo.db.runV("UPDATE meeting_recording SET state = ?, revision = revision + 1, updated_at = ? WHERE id = ?",
                    MeetingRecordingState.interrupted.rawValue, now, recording.id)
                try repo.db.runV("""
                    UPDATE meeting_audio_track SET file_state = ?, revision = revision + 1, updated_at = ?
                    WHERE recording_id = ? AND file_state IN ('pending','writing')
                    """, MeetingTrackFileState.needsRecovery.rawValue, now, recording.id)
            }
            try repo.db.runV("""
                UPDATE meeting_transcript_run SET status = ?, revision = revision + 1, updated_at = ? WHERE status = ?
                """, MeetingTranscriptRunStatus.interrupted.rawValue, now, MeetingTranscriptRunStatus.running.rawValue)
            return try pending.map { try requireRecording($0.id) }
        }
    }

    public func recoverableRecordings() throws -> [MeetingRecording] {
        try repo.db.query("""
            SELECT DISTINCT r.* FROM meeting_recording r JOIN meeting_audio_track t ON t.recording_id = r.id
            WHERE r.state != 'discarded' AND (r.state IN ('interrupted','failed') OR t.file_state = 'needsRecovery')
            ORDER BY r.started_at, r.id
            """).map(decodeRecording)
    }

    /// MeetingService의 전체 본문 편집 호환 경로. 새 버전을 만든 뒤 활성 ID만 반환한다.
    func preserveManualTranscript(meeting: Meeting, text: String) throws -> String {
        if meeting.activeTranscriptRunID == nil, !meeting.transcript.isEmpty {
            _ = try makeManualRun(meeting: meeting, text: meeting.transcript)
        }
        return try makeManualRun(meeting: meeting, text: text).id
    }

    private func makeManualRun(meeting: Meeting, text: String) throws -> MeetingTranscriptRun {
        let source = try meeting.activeTranscriptRunID.flatMap { try self.run(id: $0) }
        let run = try createRun(meetingID: meeting.id, recordingID: source?.recordingID, stage: .manual,
            engine: "manual", modelIdentifier: "user", sourceRunID: source?.id)
        try repo.db.runV("UPDATE meeting_transcript_run SET manual_text = ? WHERE id = ?", text, run.id)
        return try finishRun(id: run.id)
    }

    private func refreshActiveTranscript(runID: String) throws {
        let run = try requireRun(runID)
        let text = try renderedTranscript(runID: runID)
        try repo.db.runV("""
            UPDATE meeting SET transcript = ?, revision = revision + 1, updated_at = ?
            WHERE id = ? AND active_transcript_run_id = ? AND transcript != ? AND deleted_at IS NULL
            """, text, repo.clock.now(), run.meetingID, runID, text)
    }
    private func bumpRun(_ id: String) throws {
        try repo.db.runV("UPDATE meeting_transcript_run SET revision = revision + 1, updated_at = ? WHERE id = ?", repo.clock.now(), id)
    }
    private func recordEdit(runID: String, segmentID: String? = nil, speakerID: String? = nil,
                            previous: String, replacement: String) throws {
        try repo.db.runV("""
            INSERT INTO meeting_transcript_edit (id, run_id, segment_id, speaker_id, previous_text, replacement_text, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, repo.ids.make(), runID, segmentID, speakerID, previous, replacement, repo.clock.now())
    }
    private func validateSpeaker(_ id: String?, for run: MeetingTranscriptRun) throws {
        guard let id else { return }
        let speaker = try requireSpeaker(id)
        guard speaker.runID == run.id, speaker.recordingID == run.recordingID else {
            throw WorkLogError.validation("다른 전사 버전의 화자를 같은 인물로 연결할 수 없습니다.")
        }
    }
    private func validateStoredSegmentBounds(runID: String) throws {
        let row = try repo.db.queryOneV("""
            SELECT COUNT(*) AS count,
                COALESCE(SUM(length(CAST(original_text AS BLOB)) + length(CAST(COALESCE(edited_text, '') AS BLOB))), 0) AS bytes
            FROM meeting_transcript_segment WHERE run_id = ?
            """, runID)
        guard let count = row?.int("count"), count <= 100_000,
              let bytes = row?.int("bytes"), bytes <= MeetingLimits.transcriptBytes * 2 else {
            throw WorkLogError.validation("전사 버전의 저장 크기를 초과했습니다.")
        }
    }
    private func validateRelativePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 2_048, !path.hasPrefix("/"), !path.contains("\\"),
              !path.contains(":"), !path.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw WorkLogError.validation("녹음 파일은 앱 녹음 폴더의 상대 경로여야 합니다.")
        }
    }
    private func validateLabel(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 1_000,
              !value.contains("\0") else { throw WorkLogError.validation("전사 식별자 또는 이름을 확인해 주세요.") }
    }
    private func validateInterruptions(_ values: [MeetingTrackInterruption]) throws {
        guard values.count <= 10_000 else { throw WorkLogError.validation("녹음 중단 기록이 너무 많습니다.") }
        for value in values {
            guard value.start.isFinite, value.start >= 0,
                  value.end.map({ $0.isFinite && $0 >= value.start }) ?? true,
                  value.reason.utf8.count <= 1_000 else { throw WorkLogError.validation("녹음 중단 시간을 확인해 주세요.") }
        }
    }
    private func checkRevision(_ actual: Int, _ expected: Int) throws {
        guard actual == expected else { throw WorkLogError.conflict("녹음 또는 전사가 변경되었습니다. 최신 내용을 다시 불러와 주세요.") }
    }
    private func requireMeeting(_ id: String, includeDeleted: Bool = false) throws -> Meeting {
        guard let value = try MeetingService(repo: repo).meeting(id: id, includeDeleted: includeDeleted) else { throw WorkLogError.notFound("회의") }
        return value
    }
    private func requireRecording(_ id: String) throws -> MeetingRecording {
        guard let value = try recording(id: id) else { throw WorkLogError.notFound("녹음") }; return value
    }
    private func requireTrack(_ id: String) throws -> MeetingAudioTrack {
        guard let value = try track(id: id) else { throw WorkLogError.notFound("음성 트랙") }; return value
    }
    private func requireRun(_ id: String) throws -> MeetingTranscriptRun {
        guard let value = try run(id: id) else { throw WorkLogError.notFound("전사 버전") }; return value
    }
    private func requireSpeaker(_ id: String) throws -> MeetingSpeaker {
        guard let value = try speaker(id: id) else { throw WorkLogError.notFound("화자") }; return value
    }
    func invalidStorage() -> WorkLogError { .storage("녹음 또는 전사 저장 형식이 올바르지 않습니다.") }
}
