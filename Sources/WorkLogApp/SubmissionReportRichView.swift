#if os(macOS)
import SwiftUI
import WorkLogCore

/// WEEK-02/03 reading surface. Unknown lines remain visible verbatim.
@MainActor struct SubmissionReportRichView: View {
    private let text: String
    @StateObject private var document: ParsedDocumentState<[SubmissionDocumentLine]>

    init(text: String) {
        self.text = text
        self._document = StateObject(wrappedValue: ParsedDocumentState(
            source: text, parse: SubmissionDocumentParser.parse))
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(document.value.indices, id: \.self) { index in
                lineView(document.value[index])
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(WorkLogTheme.text)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("submission-report-rich-body")
        .onChange(of: text, initial: true) { _, source in document.update(source) }
    }

    @ViewBuilder private func lineView(_ line: SubmissionDocumentLine) -> some View {
        switch line.kind {
        case .heading:
            Text(displayText(line.source)).font(.title3.weight(.semibold))
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
        case .item(let status, let text):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TaskStatusBadge(status: status)
                    .fixedSize()
                Text(displayText(text)).lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        case .text:
            Text(displayText(line.source)).fixedSize(horizontal: false, vertical: true)
        case .blank:
            Color.clear.frame(height: 12).accessibilityHidden(true)
        }
    }

    // CRLF source stays exact for text mode and copying; only rendered lines omit CR.
    private func displayText(_ source: String) -> String {
        source.hasSuffix("\r") ? String(source.dropLast()) : source
    }
}
#endif
