import Foundation

/// Local-only results intentionally do not conform to general SearchHit/AI source contracts.
public struct MeetingLocalSearchHit: Hashable, Sendable, Identifiable {
    public var meetingID: String
    public var title: String
    public var runID: String?
    public var segmentID: String?
    public var start: Double?
    public var snippet: String
    public init(meetingID: String, title: String, runID: String? = nil, segmentID: String? = nil, start: Double? = nil, snippet: String = "") {
        self.meetingID = meetingID; self.title = title; self.runID = runID; self.segmentID = segmentID
        self.start = start; self.snippet = snippet
    }
    public var id: String { meetingID + ":" + (runID ?? "") + ":" + (segmentID ?? "") }
}
public struct MeetingSegmentFilter: Hashable, Sendable {
    public var query = ""
    public var speakerID: String? = nil
    public var unknownSpeakerOnly = false
    public var unconfirmedOnly = false
    public var editedOnly = false
    public var start: Double? = nil
    public var end: Double? = nil
    public init() {}
    public func matches(_ segment: MeetingTranscriptSegment) -> Bool {
        (query.isEmpty || segment.text.localizedCaseInsensitiveContains(query)) &&
        (speakerID == nil || segment.speakerID == speakerID) &&
        (!unknownSpeakerOnly || segment.speakerID == nil) && (!unconfirmedOnly || !segment.isFinal) &&
        (!editedOnly || segment.isUserEdited) && (start == nil || segment.end >= start!) &&
        (end == nil || segment.start <= end!)
    }
}
public final class MeetingLocalSearchService: Sendable {
    public let repo: WorkRepository
    public init(repo: WorkRepository) { self.repo = repo }
    public func search(_ query: String, limit: Int = 100, offset: Int = 0) throws -> [MeetingLocalSearchHit] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, limit > 0, offset >= 0 else { return [] }
        // Bound rows before loading large transcript bodies into memory; no persistent external-search index.
        let escaped = term.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%" + escaped + "%"
        let rows = try repo.db.queryV("""
            SELECT m.id AS meeting_id, m.title, r.id AS run_id, s.id AS segment_id, s.start,
                   COALESCE(s.edited_text, s.original_text) AS snippet
            FROM meeting m JOIN meeting_transcript_run r ON r.meeting_id = m.id
            JOIN meeting_transcript_segment s ON s.run_id = r.id
            WHERE m.deleted_at IS NULL AND COALESCE(s.edited_text,s.original_text) LIKE ? ESCAPE char(92)
            UNION ALL
            SELECT m.id, m.title, NULL, NULL, NULL, m.title || char(10) || m.notes || char(10) || m.transcript
            FROM meeting m WHERE m.deleted_at IS NULL AND
                (m.title LIKE ? ESCAPE char(92) OR m.notes LIKE ? ESCAPE char(92) OR m.transcript LIKE ? ESCAPE char(92))
            ORDER BY meeting_id, run_id, start LIMIT ? OFFSET ?
            """, pattern, pattern, pattern, pattern, min(limit, 500), offset)
        return rows.compactMap { row -> MeetingLocalSearchHit? in
            guard let id = row.string("meeting_id"), let title = row.string("title"), let snippet = row.string("snippet") else { return nil }
            let range = snippet.range(of: term, options: .caseInsensitive)
            let start = range.map { snippet.index($0.lowerBound, offsetBy: -40, limitedBy: snippet.startIndex) ?? snippet.startIndex } ?? snippet.startIndex
            return .init(meetingID: id, title: title, runID: row.string("run_id"), segmentID: row.string("segment_id"),
                start: row.string("start").flatMap(Double.init), snippet: String(snippet[start...].prefix(220)))
        }
    }
}
