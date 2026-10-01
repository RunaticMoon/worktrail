#if os(macOS)
import SwiftUI
import WorkLogCore

struct MemoDetailScreen: View {
    @Bindable var model: MemoDetailModel
    let onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("메모와 업무 연결").font(.title2)
                Spacer()
                Button("닫기", action: onClose).keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let memo = model.memo {
                        Text(memo.workDate.iso).font(.caption).foregroundStyle(.secondary)
                        Text(memo.body).textSelection(.enabled)
                    }
                    Text("제안은 승인 후 연결됩니다. 메모 원문과 업무 상태는 유지됩니다.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("AI 업무 연결 제안") { Task { await model.suggest() } }
                        .disabled(!model.isAIAvailable || model.isSuggesting)
                    if !model.isAIAvailable { Text("AI 연결 제안 비활성화").foregroundStyle(.secondary) }
                    if model.isSuggesting { ProgressView("연결 후보 찾는 중…") }
                    if let message = model.message { InlineNotice(message: message) }
                    if model.links.isEmpty { Text("연결 제안 없음").foregroundStyle(.secondary) }
                    ForEach(model.links) { link in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.tasks.first { $0.id == link.taskId }?.title ?? "찾을 수 없는 업무").font(.headline)
                            Text(link.reason)
                            Text(label(link.status)).font(.callout)
                            if link.status != .accepted && link.status != .rejected {
                                HStack {
                                    Button("승인") { model.decide(linkId: link.id, status: .accepted) }
                                    Button("거절") { model.decide(linkId: link.id, status: .rejected) }
                                    Button("나중에") { model.decide(linkId: link.id, status: .deferred) }
                                }
                            }
                        }
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(20).frame(minWidth: 540, minHeight: 440)
    }
    private func label(_ status: MemoTaskLinkStatus) -> String {
        switch status { case .proposed: return "검토 대기"; case .accepted: return "연결 승인"; case .rejected: return "연결 거절"; case .deferred: return "나중에 검토" }
    }
}
#endif
