#if os(macOS)
import SwiftUI
import WorkLogCore

/// WEEK-02/03 reading surface. Unknown lines remain visible verbatim.
struct SubmissionReportRichView: View {
    private let lines: [SubmissionDocumentLine]

    init(text: String) {
        self.lines = SubmissionDocumentParser.parse(text)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(lines.indices, id: \.self) { index in
                lineView(lines[index])
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(WorkLogTheme.text)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("submission-report-rich-body")
    }

    @ViewBuilder private func lineView(_ line: SubmissionDocumentLine) -> some View {
        switch line.kind {
        case .heading:
            Text(line.source).font(.title3.weight(.semibold))
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
        case .item(let status, let text):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TaskStatusBadge(status: status)
                    .fixedSize()
                Text(text).lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        case .text:
            Text(line.source).fixedSize(horizontal: false, vertical: true)
        case .blank:
            Color.clear.frame(height: 12).accessibilityHidden(true)
        }
    }
}
#endif
