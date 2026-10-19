#if os(macOS)
import SwiftUI

enum DocumentDisplayMode: Hashable { case preview, text }

/// Shared controls; each host retains its existing automation identifier and help text.
struct DocumentModeToggle: View {
    @Binding var mode: DocumentDisplayMode
    let accessibilityIdentifier: String
    let help: String

    var body: some View {
        Divider()
        Picker("본문 표시", selection: $mode) {
            Text("미리보기").tag(DocumentDisplayMode.preview)
            Text("텍스트").tag(DocumentDisplayMode.text)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 260)
        .accessibilityIdentifier(accessibilityIdentifier)
        .help(help)
    }
}
#endif
