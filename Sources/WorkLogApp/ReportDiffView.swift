#if os(macOS)
import SwiftUI
import WorkLogCore

struct ReportDiffView: View {
    let pendingDiff: [DiffLine]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("변경 비교").font(.headline).accessibilityAddTraits(.isHeader)
            Text("+ 추가 · − 삭제 · = 유지").font(.callout).foregroundStyle(WorkLogTheme.muted)
            if pendingDiff.isEmpty { Text("비교할 본문이 없습니다.").foregroundStyle(WorkLogTheme.muted) }
            else if !pendingDiff.contains(where: { $0.kind != .same }) {
                Label("본문 변경 없음", systemImage: "equal.circle")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(pendingDiff.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 8) {
                            StatusBadge(label: label(line.kind), systemImage: symbol(line.kind), tone: tone(line.kind))
                            Text(line.text.isEmpty ? "(빈 줄)" : line.text).font(.body).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(label(line.kind)): \(line.text.isEmpty ? "빈 줄" : line.text)")
                    }
                }.padding(4)
            }.frame(maxHeight: 360)
        }
    }
    private func label(_ kind: DiffLine.Kind) -> String {
        switch kind { case .same: return "= 유지"; case .added: return "+ 추가"; case .removed: return "− 삭제" }
    }
    private func symbol(_ kind: DiffLine.Kind) -> String {
        switch kind { case .same: return "equal.circle"; case .added: return "plus.circle"; case .removed: return "minus.circle" }
    }
    private func tone(_ kind: DiffLine.Kind) -> StatusTone {
        switch kind { case .same: return .neutral; case .added: return .success; case .removed: return .danger }
    }
}
#endif
