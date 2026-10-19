#if os(macOS)
import SwiftUI
import WorkLogCore

/// Embed in the host's ScrollView so long documents share one scrolling surface.
struct MarkdownDocumentView: View {
    let markdown: String
    private let identifier: String
    private let blocks: [MarkdownDocumentBlock]
    @State private var mode: DisplayMode = .preview

    private enum DisplayMode: Hashable { case preview, text }

    init(markdown: String, accessibilityIdentifier: String? = nil) {
        self.markdown = markdown
        self.identifier = accessibilityIdentifier ?? "markdown-document"
        self.blocks = MarkdownDocumentParser.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if markdown.isEmpty {
                Text("본문이 비어 있습니다.").foregroundStyle(WorkLogTheme.muted)
            } else if mode == .preview {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(blocks.indices, id: \.self) { index in
                        MarkdownBlockView(block: blocks[index])
                    }
                }
                .textSelection(.enabled)
                .accessibilityIdentifier("\(identifier)-preview")
            } else {
                Text(markdown)
                    .font(.system(size: 14, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHint("Markdown 원문입니다. 텍스트를 선택하여 복사할 수 있습니다.")
                    .accessibilityIdentifier("\(identifier)-source")
            }
            Divider()
            Picker("본문 표시", selection: $mode) {
                Text("미리보기").tag(DisplayMode.preview)
                Text("텍스트").tag(DisplayMode.text)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            .accessibilityIdentifier("\(identifier)-mode")
            .help("미리보기는 서식을 표시하고, 텍스트는 Markdown 원문을 표시합니다.")
        }
        .font(.system(size: 14))
        .foregroundStyle(WorkLogTheme.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(identifier)
        .environment(\.openURL, OpenURLAction { url in
            ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownDocumentBlock

    @ViewBuilder var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(headingFont(level))
                .padding(.top, level == 1 ? 8 : 12)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(inline(text)).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).monospacedDigit().foregroundStyle(WorkLogTheme.muted)
                Text(inline(text)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(min(depth, 4)) * 16)
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 8) {
                if !language.isEmpty {
                    Text(language).font(.caption).foregroundStyle(WorkLogTheme.muted)
                }
                ScrollView(.horizontal) {
                    Text(text).font(.system(size: 13, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.bottom, 4)
                }
                .accessibilityLabel("코드 블록")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "text.quote").foregroundStyle(WorkLogTheme.muted).accessibilityHidden(true)
                Text(inline(text)).lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider().padding(.vertical, 8)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.bold)
        case 2: return .title3.weight(.semibold)
        default: return .headline
        }
    }

    private func inline(_ source: String) -> AttributedString {
        guard var text = try? AttributedString(markdown: source, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return AttributedString(source) }
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            text[run.range].font = .system(size: 14, design: .monospaced)
        }
        return text
    }
}
#endif
