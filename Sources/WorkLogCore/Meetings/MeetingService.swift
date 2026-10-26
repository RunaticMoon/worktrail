import Foundation

/// 회의 원문과 요약 초안을 관리한다. 모든 수정은 revision으로 경쟁 저장을 확인한다.
public final class MeetingService: @unchecked Sendable {
    public let repo: WorkRepository
    public let runner: AIJobRunner?

    public init(repo: WorkRepository, runner: AIJobRunner? = nil) {
        self.repo = repo; self.runner = runner
    }

    public func create(title: String, workDate: WorkDate? = nil, transcript: String = "",
                       notes: String = "", memoIDs: [String] = [], localOnly: Bool = true) throws -> Meeting {
        let title = try validateInput(title: title, transcript: transcript, notes: notes)
        let now = repo.clock.now()
        let date = workDate ?? repo.calendar.workDate(of: now)
        try validateDate(date)
        return try repo.db.transaction {
            let snapshots = try snapshots(for: memoIDs, capturedAt: now)
            let id = repo.ids.make()
            try repo.db.runV("""
                INSERT INTO meeting (id, title, work_date, transcript, notes, revision, created_at, updated_at, local_only)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, id, title, date, transcript, notes, 1, now, now, localOnly)
            try writeSnapshots(snapshots, meetingID: id)
            return try requireMeeting(id)
        }
    }

    /// 날짜 내림차순. includeDeleted이면 휴지통 회의도 포함한다.
    public func meetings(includeDeleted: Bool = false) throws -> [Meeting] {
        try repo.db.transaction {
            let sql = includeDeleted
                ? "SELECT * FROM meeting ORDER BY work_date DESC, updated_at DESC, id ASC"
                : "SELECT * FROM meeting WHERE deleted_at IS NULL ORDER BY work_date DESC, updated_at DESC, id ASC"
            return try repo.db.query(sql).map(decodeMeeting)
        }
    }

    public func meeting(id: String, includeDeleted: Bool = false) throws -> Meeting? {
        try repo.db.transaction {
            let sql = includeDeleted ? "SELECT * FROM meeting WHERE id = ?"
                : "SELECT * FROM meeting WHERE id = ? AND deleted_at IS NULL"
            return try repo.db.queryOneV(sql, id).map(decodeMeeting)
        }
    }

    @discardableResult
    public func update(id: String, expectedRevision: Int, title: String, workDate: WorkDate,
                       transcript: String, notes: String) throws -> Meeting {
        let title = try validateInput(title: title, transcript: transcript, notes: notes)
        try validateDate(workDate)
        return try repo.db.transaction {
            let current = try requireMeeting(id, expectedRevision: expectedRevision)
            guard current.title != title || current.workDate != workDate || current.transcript != transcript
                    || current.notes != notes else { return current }
            let activeRunID = current.transcript == transcript ? current.activeTranscriptRunID
                : try MeetingAudioStore(repo: repo).preserveManualTranscript(meeting: current, text: transcript)
            let changed = try repo.db.runV("""
                UPDATE meeting SET title = ?, work_date = ?, transcript = ?, notes = ?,
                    revision = revision + 1, updated_at = ?, active_transcript_run_id = ?
                WHERE id = ? AND revision = ? AND deleted_at IS NULL
                """, title, workDate, transcript, notes, repo.clock.now(), activeRunID, id, expectedRevision)
            try requireChanged(changed)
            return try requireMeeting(id)
        }
    }

    /// 외부 AI 사용을 명시적으로 허용한 호출자만 false로 바꿀 수 있다.
    @discardableResult
    public func setLocalOnly(id: String, expectedRevision: Int, localOnly: Bool) throws -> Meeting {
        try repo.db.transaction {
            let current = try requireMeeting(id, expectedRevision: expectedRevision)
            if current.localOnly == localOnly { return current }
            try repo.db.runV("UPDATE meeting SET local_only = ?, revision = revision + 1, updated_at = ? WHERE id = ? AND revision = ?",
                localOnly, repo.clock.now(), id, expectedRevision)
            return try requireMeeting(id)
        }
    }

    /// 선택한 일반 메모를 현재 revision으로 다시 스냅샷한다. Secret을 조회하는 경로는 없다.
    @discardableResult
    public func setLinkedMemos(id: String, expectedRevision: Int, memoIDs: [String]) throws -> Meeting {
        try repo.db.transaction {
            let current = try requireMeeting(id, expectedRevision: expectedRevision)
            let now = repo.clock.now()
            let next = try snapshots(for: memoIDs, capturedAt: now)
            // 동일 선택·동일 원문은 캡처 시각만 바꾸거나 기존 요약을 무효화하지 않는다.
            let unchanged = current.memoSnapshots.count == next.count && zip(current.memoSnapshots, next).allSatisfy {
                $0.memoID == $1.memoID && $0.revision == $1.revision && $0.body == $1.body && $0.workDate == $1.workDate
            }
            if unchanged { return current }
            try repo.db.runV("DELETE FROM meeting_memo_snapshot WHERE meeting_id = ?", id)
            try writeSnapshots(next, meetingID: id)
            let changed = try repo.db.runV("""
                UPDATE meeting SET revision = revision + 1, updated_at = ?
                WHERE id = ? AND revision = ? AND deleted_at IS NULL
                """, now, id, expectedRevision)
            try requireChanged(changed)
            return try requireMeeting(id)
        }
    }

    public func delete(id: String, expectedRevision: Int) throws {
        try repo.db.transaction {
            _ = try requireMeeting(id, expectedRevision: expectedRevision)
            guard try repo.db.scalarIntV("SELECT COUNT(*) FROM meeting_recording WHERE meeting_id = ? AND state IN ('recording','paused')", id) == 0 else {
                throw WorkLogError.invalidTransition("녹음 중인 회의는 삭제할 수 없습니다. 녹음을 먼저 종료해 주세요.")
            }
            let now = repo.clock.now()
            let changed = try repo.db.runV("""
                UPDATE meeting SET deleted_at = ?, updated_at = ?, revision = revision + 1
                WHERE id = ? AND revision = ? AND deleted_at IS NULL
                """, now, now, id, expectedRevision)
            try requireChanged(changed)
        }
    }

    @discardableResult
    public func restore(id: String, expectedRevision: Int) throws -> Meeting {
        try repo.db.transaction {
            guard let current = try meeting(id: id, includeDeleted: true) else {
                throw WorkLogError.notFound("회의")
            }
            guard current.revision == expectedRevision else { throw staleEdit() }
            guard current.deletedAt != nil else { return current }
            let changed = try repo.db.runV("""
                UPDATE meeting SET deleted_at = NULL, updated_at = ?, revision = revision + 1
                WHERE id = ? AND revision = ? AND deleted_at IS NOT NULL
                """, repo.clock.now(), id, expectedRevision)
            try requireChanged(changed)
            return try requireMeeting(id)
        }
    }

    public func summaryHistory(meetingID: String) throws -> [MeetingSummary] {
        try repo.db.queryV("SELECT * FROM meeting_summary WHERE meeting_id = ? ORDER BY version DESC", meetingID)
            .map(decodeSummary)
    }

    /// 실패·취소·원문 경쟁 수정은 기존 요약을 유지한다. regenerate가 true일 때만 명시적으로 재생성한다.
    public func generateSummary(id: String, regenerate: Bool = false) async throws -> MeetingSummary {
        try Task.checkCancellation()
        let source = try requireMeeting(id)
        try requireCloudSummaryAllowed(source)
        if !regenerate, let existing = source.summary, !source.isSummaryStale { return existing }
        guard let runner else { throw WorkLogError.validation("AI 연결을 설정한 뒤 요약을 생성해 주세요.") }
        let sources = MeetingSummaryContract.sources(for: source)
        guard !sources.isEmpty else { throw WorkLogError.validation("전사 또는 메모를 입력해 주세요.") }
        let payload = try StableJSON.string(SummaryPayload(meetingID: source.id, title: source.title,
            workDate: source.workDate, sourceRevision: source.revision, sources: sources))
        guard payload.utf8.count <= MeetingLimits.summaryInputBytes else {
            throw WorkLogError.validation("요약 입력이 너무 큽니다. 전사·메모를 나누거나 연결 메모를 줄여 주세요.")
        }
        // 기존 출력 민감 마커와 사용자 차단 규칙을 입력에도 적용한다. 원문은 오류에 포함하지 않는다.
        guard !runner.outputGuard.containsSensitiveContent(payload) else {
            throw WorkLogError.policyBlocked("회의 입력에 AI로 보낼 수 없는 민감 정보 표시가 있습니다.")
        }
        let request = AIJobRequest(jobType: .meetingSummary, instructions: MeetingSummaryContract.instructions,
            payloadJSON: payload, regenerationNonce: regenerate ? repo.ids.make() : nil)
        let result = try await runner.submit(request, preflight: { [self] in
            let current = try requireMeeting(id)
            try requireCloudSummaryAllowed(current)
            guard current.revision == source.revision else {
                throw WorkLogError.conflict("대기 중 회의가 변경되어 AI 전송을 취소했습니다.")
            }
        })
        try Task.checkCancellation()
        guard let raw = result.output?.rawJSON, result.job.status == .succeeded else {
            throw WorkLogError.validation(Self.failureMessage(for: result.job))
        }
        let output: MeetingSummaryOutput
        do {
            guard raw.utf8.count <= MeetingLimits.summaryOutputBytes else {
                throw WorkLogError.validation("회의 요약 응답이 허용 크기를 초과했습니다.")
            }
            output = try StableJSON.decode(MeetingSummaryOutput.self, from: raw)
            try MeetingSummaryContract.validate(output, sources: sources)
        } catch {
            // 계약 위반 원문은 AI 작업 결과에도 보존하지 않는다. 이전 회의 요약은 그대로 둔다.
            var invalid = result.job
            invalid.status = .failed; invalid.lastErrorClass = .outputInvalid; invalid.resultJSON = nil
            invalid.updatedAt = repo.clock.now()
            try repo.updateAIJob(invalid)
            throw WorkLogError.validation("AI 요약의 형식이나 근거를 검증하지 못했습니다. 기존 요약은 유지했습니다.")
        }
        return try repo.db.transaction {
            let current = try requireMeeting(id)
            try requireCloudSummaryAllowed(current)
            guard current.revision == source.revision,
                  current.summary?.id == source.summary?.id,
                  current.summary?.revision == source.summary?.revision else {
                throw WorkLogError.conflict("요약 생성 중 회의 원문 또는 요약이 변경되었습니다. 최신 내용을 확인하고 다시 생성해 주세요.")
            }
            let summaryID = repo.ids.make()
            let now = repo.clock.now()
            let version = (current.summary?.version ?? 0) + 1
            // 버전이 교체되어도 revision이 증가해 이전 편집 화면의 저장을 거절한다.
            let revision = (current.summary?.revision ?? 0) + 1
            try repo.db.runV("""
                INSERT INTO meeting_summary (id, meeting_id, version, revision, source_revision,
                    content, structured_json, sources_json, is_user_edited, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, summaryID, id, version, revision, source.revision,
                MeetingSummaryContract.render(output, sources: sources), try StableJSON.string(output),
                try StableJSON.string(sources), false, now, now)
            guard let saved = try latestSummary(meetingID: id) else {
                throw WorkLogError.storage("회의 요약 저장 후 조회 실패")
            }
            return saved
        }
    }

    private func requireCloudSummaryAllowed(_ meeting: Meeting) throws {
        guard !meeting.localOnly else {
            throw WorkLogError.policyBlocked("이 회의는 로컬 전용입니다. 전사·메모를 외부 AI로 전송할 수 없습니다.")
        }
    }

    /// 생성된 근거는 그대로 보존하고 사용자가 편집한 본문임을 구분한다.
    @discardableResult
    public func editSummary(meetingID: String, expectedRevision: Int, content: String) throws -> MeetingSummary {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              content.utf8.count <= MeetingLimits.summaryOutputBytes else {
            throw WorkLogError.validation("요약 본문을 입력하고 허용 크기를 확인해 주세요.")
        }
        return try repo.db.transaction {
            let meeting = try requireMeeting(meetingID)
            guard let current = meeting.summary else { throw WorkLogError.notFound("회의 요약") }
            guard current.revision == expectedRevision else { throw staleEdit() }
            if current.content == content { return current }
            let changed = try repo.db.runV("""
                UPDATE meeting_summary SET content = ?, is_user_edited = ?, revision = revision + 1, updated_at = ?
                WHERE id = ? AND revision = ?
                """, content, true, repo.clock.now(), current.id, expectedRevision)
            try requireChanged(changed)
            guard let updated = try latestSummary(meetingID: meetingID) else {
                throw WorkLogError.storage("회의 요약 편집 후 조회 실패")
            }
            return updated
        }
    }

    private struct SummaryPayload: Encodable {
        let meetingID: String
        let title: String
        let workDate: WorkDate
        let sourceRevision: Int
        let sources: [MeetingSummarySource]
    }

    private func validateInput(title: String, transcript: String, notes: String) throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= MeetingLimits.titleBytes else {
            throw WorkLogError.validation("회의 제목을 입력하고 길이를 확인해 주세요.")
        }
        guard transcript.utf8.count <= MeetingLimits.transcriptBytes, notes.utf8.count <= MeetingLimits.notesBytes else {
            throw WorkLogError.validation("회의 전사 또는 메모가 허용 크기를 초과했습니다.")
        }
        return trimmed
    }

    private func validateDate(_ date: WorkDate) throws {
        guard WorkDate(date.iso) != nil else { throw WorkLogError.validation("유효한 회의 날짜가 필요합니다.") }
    }

    private func snapshots(for memoIDs: [String], capturedAt: Date) throws -> [MeetingMemoSnapshot] {
        let unique = Set(memoIDs).sorted()
        guard unique.count <= MeetingLimits.linkedMemoCount else {
            throw WorkLogError.validation("연결 메모는 최대 \(MeetingLimits.linkedMemoCount)개입니다.")
        }
        var totalBytes = 0
        return try unique.map { id in
            guard let memo = try repo.memo(id: id) else { throw WorkLogError.notFound("선택한 일반 메모") }
            totalBytes += memo.body.utf8.count
            guard totalBytes <= MeetingLimits.linkedMemoBytes else {
                throw WorkLogError.validation("연결 메모의 전체 크기가 허용 범위를 초과했습니다.")
            }
            return MeetingMemoSnapshot(memoID: memo.id, revision: memo.revision, body: memo.body,
                workDate: memo.workDate, capturedAt: capturedAt)
        }
    }

    private func writeSnapshots(_ snapshots: [MeetingMemoSnapshot], meetingID: String) throws {
        for snapshot in snapshots {
            try repo.db.runV("""
                INSERT INTO meeting_memo_snapshot (meeting_id, memo_id, source_revision, body, work_date, captured_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, meetingID, snapshot.memoID, snapshot.revision, snapshot.body, snapshot.workDate, snapshot.capturedAt)
        }
    }

    private func requireMeeting(_ id: String, expectedRevision: Int? = nil) throws -> Meeting {
        guard let meeting = try meeting(id: id) else { throw WorkLogError.notFound("회의") }
        if let expectedRevision, meeting.revision != expectedRevision { throw staleEdit() }
        return meeting
    }

    private func staleEdit() -> WorkLogError {
        .conflict("다른 작업에서 회의가 변경되었습니다. 최신 내용을 다시 불러와 주세요.")
    }

    private func requireChanged(_ count: Int) throws {
        guard count == 1 else { throw staleEdit() }
    }

    private func latestSummary(meetingID: String) throws -> MeetingSummary? {
        try repo.db.queryOneV("SELECT * FROM meeting_summary WHERE meeting_id = ? ORDER BY version DESC LIMIT 1", meetingID)
            .map(decodeSummary)
    }

    private func decodeMeeting(_ row: SQLRow) throws -> Meeting {
        guard let id = row.string("id"), let title = row.string("title"),
              let date = row.workDate("work_date"), let transcript = row.string("transcript"),
              let notes = row.string("notes"), let revision = row.int("revision"),
              let createdAt = row.date("created_at"), let updatedAt = row.date("updated_at") else {
            throw WorkLogError.storage("회의 저장 형식이 올바르지 않습니다.")
        }
        let snapshots = try repo.db.queryV("""
            SELECT * FROM meeting_memo_snapshot WHERE meeting_id = ? ORDER BY memo_id ASC
            """, id).map { item -> MeetingMemoSnapshot in
                guard let memoID = item.string("memo_id"), let revision = item.int("source_revision"),
                      let body = item.string("body"), let date = item.workDate("work_date"),
                      let capturedAt = item.date("captured_at") else {
                    throw WorkLogError.storage("회의 연결 메모 저장 형식이 올바르지 않습니다.")
                }
                return MeetingMemoSnapshot(memoID: memoID, revision: revision, body: body,
                    workDate: date, capturedAt: capturedAt)
            }
        var meeting = Meeting(id: id, title: title, workDate: date, transcript: transcript, notes: notes,
            memoSnapshots: snapshots, revision: revision, createdAt: createdAt, updatedAt: updatedAt,
            deletedAt: row.date("deleted_at"), summary: try latestSummary(meetingID: id))
        meeting.localOnly = row.bool("local_only")
        meeting.activeTranscriptRunID = row.string("active_transcript_run_id")
        return meeting
    }

    private func decodeSummary(_ row: SQLRow) throws -> MeetingSummary {
        guard let id = row.string("id"), let meetingID = row.string("meeting_id"),
              let version = row.int("version"), let revision = row.int("revision"),
              let sourceRevision = row.int("source_revision"), let content = row.string("content"),
              let structured = row.string("structured_json"), let sources = row.string("sources_json"),
              let createdAt = row.date("created_at"), let updatedAt = row.date("updated_at") else {
            throw WorkLogError.storage("회의 요약 저장 형식이 올바르지 않습니다.")
        }
        return MeetingSummary(id: id, meetingID: meetingID, version: version, revision: revision,
            sourceRevision: sourceRevision, content: content,
            structuredOutput: try StableJSON.decode(MeetingSummaryOutput.self, from: structured),
            sources: try StableJSON.decode([MeetingSummarySource].self, from: sources),
            isUserEdited: row.bool("is_user_edited"), createdAt: createdAt, updatedAt: updatedAt)
    }

    private static func failureMessage(for job: AIJob) -> String {
        switch job.status {
        case .blockedAuth: return "AI 로그인을 확인해 주세요. 기존 요약은 유지했습니다."
        case .blockedPolicy: return "계정 또는 조직 정책으로 AI 요청이 차단되었습니다. 기존 요약은 유지했습니다."
        case .cancelled: return "요약 생성을 취소했습니다. 기존 요약은 유지했습니다."
        default:
            if job.lastErrorClass == .rateLimited {
                return "AI 사용 한도에 도달했습니다. 잠시 후 다시 시도해 주세요. 기존 요약은 유지했습니다."
            }
            return "회의 요약을 생성하지 못했습니다. 기존 요약은 유지했습니다."
        }
    }
}
