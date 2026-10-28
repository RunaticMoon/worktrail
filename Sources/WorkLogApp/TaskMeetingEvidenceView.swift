#if os(macOS)
import SwiftUI
import WorkLogCore

struct TaskMeetingEvidenceView: View {
    let repo: WorkRepository
    let taskID: String
    let onOpen: (MeetingLocalSearchHit) -> Void
    @State private var links: [MeetingTaskLink] = []
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            if !links.isEmpty {
                DisclosureGroup("회의 근거 (\(links.count))") {
                    ForEach(links) { link in
                        let meeting = try? MeetingService(repo: repo).meeting(id: link.meetingID, includeDeleted: true)
                        let segment = try? link.segmentID.flatMap { try MeetingAudioStore(repo: repo).segment(id: $0) }
                        VStack(alignment: .leading, spacing: 5) {
                            Button(meeting?.title ?? "원 회의") {
                                onOpen(.init(meetingID: link.meetingID, title: meeting?.title ?? "회의",
                                    runID: link.transcriptRunID, segmentID: link.segmentID,
                                    start: segment?.start, snippet: link.quote))
                            }
                            if link.localOnly { Label("로컬 전용 근거 · 이 업무와 진행 기록은 외부 AI·보고서에서 제외됩니다.", systemImage: "lock.shield").font(.caption) }
                            if meeting?.deletedAt != nil { Text("원 회의는 휴지통에 있으며 이 업무는 유지됩니다.").font(.caption) }
                            if meeting?.revision != link.meetingRevision || (segment.map { !$0.text.contains(link.quote) } ?? false) {
                                Text("연결 후 원문 변경 · 아래는 연결 당시 근거입니다.").font(.caption).foregroundStyle(.orange)
                            }
                            if let owner = link.owner { Text("담당자: \(owner)").font(.caption) }
                            Text(link.quote).font(.callout).textSelection(.enabled)
                        }.padding(.vertical, 4)
                    }
                }
            }
        }.task(id: taskID) {
            do { links = try MeetingTaskService(repo: repo).links(taskID: taskID); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
}
#endif
