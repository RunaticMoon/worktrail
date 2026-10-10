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
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(Array(pendingDiff.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 8) {
                        Text(marker(line.kind))
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .foregroundStyle(color(line.kind))
                            .frame(width: 18, alignment: .center)
                            .accessibilityHidden(true)
                        Text(line.text.isEmpty ? "(빈 줄)" : line.text).font(.body).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(label(line.kind)): \(line.text.isEmpty ? "빈 줄" : line.text)")
                }
            }
        }
    }
    private func label(_ kind: DiffLine.Kind) -> String {
        switch kind { case .same: return "= 유지"; case .added: return "+ 추가"; case .removed: return "− 삭제" }
    }
    private func marker(_ kind: DiffLine.Kind) -> String {
        switch kind { case .same: return "="; case .added: return "+"; case .removed: return "−" }
    }
    private func color(_ kind: DiffLine.Kind) -> Color {
        switch kind { case .same: return WorkLogTheme.muted; case .added: return .green; case .removed: return .red }
    }
}
#endif
