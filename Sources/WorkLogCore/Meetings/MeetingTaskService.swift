import Foundation

/// Provenance is stored separately from general search and report facts.
public struct MeetingTaskLink: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var meetingID: String
    public var meetingRevision: Int
    public var actionKey: String
    public var taskID: String
    public var transcriptRunID: String?
    public var segmentID: String?
    public var quote: String
    public var owner: String?
    public var localOnly: Bool
    public var createdAt: Date
}

public final class MeetingTaskService: Sendable {
    public let repo: WorkRepository
    public init(repo: WorkRepository) { self.repo = repo }

    /// Invoke only after the review card is explicitly confirmed. The same action is idempotent.
    public func confirm(meetingID: String, expectedRevision: Int, actionKey: String,
                        title: String, owner: String? = nil, dueOn: WorkDate? = nil,
                        projectIDs: [String] = [], quote: String, transcriptRunID: String? = nil,
                        segmentID: String? = nil, existingTaskID: String? = nil) throws -> MeetingTaskLink {
        try repo.db.transaction {
            if let existing = try links(meetingID: meetingID).first(where: { $0.actionKey == actionKey }) { return existing }
            guard let meeting = try MeetingService(repo: repo).meeting(id: meetingID) else { throw WorkLogError.notFound("회의") }
            guard meeting.revision == expectedRevision else { throw WorkLogError.conflict("회의 원문이 변경되었습니다. 근거를 다시 검토해 주세요.") }
            guard !actionKey.isEmpty, !quote.isEmpty else { throw WorkLogError.validation("업무 근거가 필요합니다.") }
            if let transcriptRunID {
                guard try MeetingAudioStore(repo: repo).run(id: transcriptRunID)?.meetingID == meetingID, segmentID != nil else {
                    throw WorkLogError.validation("회의에 속한 전사 구간을 선택해 주세요.")
                }
            }
            if let segmentID {
                guard let transcriptRunID, let run = try MeetingAudioStore(repo: repo).run(id: transcriptRunID), run.meetingID == meetingID,
                      let segment = try MeetingAudioStore(repo: repo).segments(runID: transcriptRunID).first(where: { $0.id == segmentID }),
                      segment.text.contains(quote) else { throw WorkLogError.validation("선택한 전사 근거가 변경되었습니다.") }
            } else {
                let texts = [meeting.notes, meeting.transcript, meeting.summary?.content ?? ""] + meeting.memoSnapshots.map(\.body)
                guard texts.contains(where: { $0.contains(quote) }) else { throw WorkLogError.validation("회의에 없는 근거입니다.") }
            }
            let taskID: String
            if let existingTaskID {
                guard try repo.task(id: existingTaskID) != nil else { throw WorkLogError.notFound("업무") }
                taskID = existingTaskID // Linking never changes task status or attributes.
            } else {
                let names = try projectIDs.map { id -> String in
                    guard let project = try repo.project(id: id), project.archivedAt == nil else { throw WorkLogError.notFound("사용 가능한 프로젝트") }
                    return project.name
                }
                taskID = try TaskService(repo: repo).createTask(title: title, workDate: meeting.workDate,
                    dueOn: dueOn, projectNames: names).id
            }
            let id = repo.ids.make(), now = repo.clock.now()
            // Protection follows the source and is never relaxed by later meeting policy changes.
            try repo.db.runV("""
                INSERT INTO meeting_task_link (id, meeting_id, meeting_revision, action_key, task_id,
                    transcript_run_id, segment_id, quote, owner, local_only, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, id, meetingID, expectedRevision, actionKey, taskID, transcriptRunID, segmentID, quote,
                owner?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty, meeting.localOnly, now)
            return try links(meetingID: meetingID).first { $0.id == id }!
        }
    }
    public func links(meetingID: String) throws -> [MeetingTaskLink] {
        try repo.db.queryV("SELECT * FROM meeting_task_link WHERE meeting_id = ? ORDER BY created_at, id", meetingID).map(decode)
    }
    public func links(taskID: String) throws -> [MeetingTaskLink] {
        try repo.db.queryV("SELECT * FROM meeting_task_link WHERE task_id = ? ORDER BY created_at, id", taskID).map(decode)
    }
    private func decode(_ row: SQLRow) throws -> MeetingTaskLink {
        guard let id = row.string("id"), let meetingID = row.string("meeting_id"), let revision = row.int("meeting_revision"),
              let key = row.string("action_key"), let taskID = row.string("task_id"), let quote = row.string("quote"),
              let date = row.date("created_at") else { throw WorkLogError.storage("회의 업무 연결 형식 오류") }
        return .init(id: id, meetingID: meetingID, meetingRevision: revision, actionKey: key, taskID: taskID,
            transcriptRunID: row.string("transcript_run_id"), segmentID: row.string("segment_id"), quote: quote,
            owner: row.string("owner"), localOnly: row.bool("local_only"), createdAt: date)
    }
}
private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
