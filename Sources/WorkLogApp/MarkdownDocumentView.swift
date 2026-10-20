#if os(macOS)
import SwiftUI
import WorkLogCore

/// Embed in the host's ScrollView so long documents share one scrolling surface.
@MainActor struct MarkdownDocumentView: View {
    let markdown: String
    private let identifier: String
    private let bodyLabel: String
    @StateObject private var document: ParsedDocumentState<[MarkdownDocumentBlock]>
    @State private var mode: DocumentDisplayMode = .preview

    init(markdown: String, accessibilityIdentifier: String? = nil,
         accessibilityLabel: String = "Markdown 본문, 읽기 전용") {
        self.markdown = markdown
        self.identifier = accessibilityIdentifier ?? "markdown-document"
        self.bodyLabel = accessibilityLabel
        // StateObject's autoclosure parses only when this view identity is first installed.
        self._document = StateObject(wrappedValue: ParsedDocumentState(
            source: markdown, parse: MarkdownDocumentParser.parse))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if markdown.isEmpty {
                Text("본문이 비어 있습니다.").foregroundStyle(WorkLogTheme.muted)
            } else if mode == .preview {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(document.value.indices, id: \.self) { index in
                        MarkdownBlockView(block: document.value[index])
                    }
                }
                .textSelection(.enabled)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(bodyLabel)
                .accessibilityValue(markdown)
                .accessibilityIdentifier("\(identifier)-preview")
            } else {
                Text(markdown)
                    .font(.system(size: 14, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(bodyLabel)
                    .accessibilityValue(markdown)
                    .accessibilityHint("Markdown 원문입니다. 텍스트를 선택하여 복사할 수 있습니다.")
                    .accessibilityIdentifier("\(identifier)-source")
            }
            DocumentModeToggle(mode: $mode, accessibilityIdentifier: "\(identifier)-mode",
                help: "미리보기는 서식을 표시하고, 텍스트는 Markdown 원문을 표시합니다.")
        }
        .font(.system(size: 14))
        .foregroundStyle(WorkLogTheme.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(identifier)
        .onChange(of: markdown, initial: true) { _, source in document.update(source) }
        .environment(\.openURL, OpenURLAction { url in
            ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }
}

/// Keeps one parsed input per view identity, without retaining other reports globally.
@MainActor final class ParsedDocumentState<Value>: ObservableObject {
    @Published private(set) var value: Value
    private var source: String
    private let parse: (String) -> Value

    init(source: String, parse: @escaping (String) -> Value) {
        self.source = source
        self.parse = parse
        self.value = parse(source)
    }

    func update(_ source: String) {
        guard self.source != source else { return }
        self.source = source
        value = parse(source)
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
