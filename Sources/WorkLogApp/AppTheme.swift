#if os(macOS)
import AppKit
import SwiftUI

/// Semantic colors for readable content. Navigation and controls use system styles
/// so macOS owns their Liquid Glass appearance and accessibility adaptations.
enum WorkLogTheme {
    static let cornerRadius: CGFloat = 10
    static let contentInset: CGFloat = 16
    static let cardInset: CGFloat = 12
    static var accent: Color { Color(nsColor: .controlAccentColor) }
    static var accentSoft: Color { accent.opacity(0.12) }
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let elevated = Color(nsColor: .underPageBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let text = Color(nsColor: .labelColor)
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let rowCornerRadius: CGFloat = 6
    static let rowHeight: CGFloat = 32
    static var rowHover: Color { text.opacity(0.05) }

    static func outlineColor(for contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? text : border
    }

    static func outlineWidth(for contrast: ColorSchemeContrast) -> CGFloat {
        contrast == .increased ? 2 : 1
    }

    /// Custom input rings retain the system focus color at every contrast level.
    static func focusColor(for contrast: ColorSchemeContrast) -> Color {
        Color(nsColor: .keyboardFocusIndicatorColor)
    }
}

/// Source-list and task rows share a quiet selection, independent of button chrome.
struct WorkLogSourceRowStyle: ButtonStyle {
    var isSelected: Bool
    var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(WorkLogTheme.text)
            .background(background(pressed: configuration.isPressed),
                        in: RoundedRectangle(cornerRadius: WorkLogTheme.rowCornerRadius))
            .overlay {
                if isSelected && contrast == .increased {
                    RoundedRectangle(cornerRadius: WorkLogTheme.rowCornerRadius)
                        .strokeBorder(WorkLogTheme.text, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .leading) {
                if isFocused {
                    Capsule()
                        .fill(contrast == .increased ? WorkLogTheme.text : WorkLogTheme.accent)
                        .frame(width: 3)
                        .padding(.vertical, 7)
                        .padding(.leading, 2)
                        .allowsHitTesting(false)
                }
            }
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: WorkLogTheme.rowCornerRadius))
            .onHover { isHovering = $0 }
    }

    private func background(pressed: Bool) -> Color {
        if pressed { return WorkLogTheme.accent.opacity(0.18) }
        if isSelected { return WorkLogTheme.accentSoft }
        return isHovering ? WorkLogTheme.rowHover : .clear
    }
}

extension View {
    func worklogCard(padding: CGFloat = WorkLogTheme.cardInset) -> some View {
        modifier(WorkLogCardModifier(padding: padding))
    }
}

private struct WorkLogCardModifier: ViewModifier {
    let padding: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.padding(padding)
            .background(WorkLogTheme.surface, in: RoundedRectangle(cornerRadius: WorkLogTheme.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: WorkLogTheme.cornerRadius)
                    .strokeBorder(WorkLogTheme.outlineColor(for: contrast),
                                  lineWidth: WorkLogTheme.outlineWidth(for: contrast))
                    .allowsHitTesting(false)
            }
    }
}

struct Keycap: View {
    let label: String
    @Environment(\.colorSchemeContrast) private var contrast
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(WorkLogTheme.muted)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(WorkLogTheme.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(WorkLogTheme.text, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .fixedSize()
    }
}

struct WorkLogAppIcon: View {
    private static let artwork: NSImage? = Bundle.main.url(forResource: "WorkLog", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        Group {
            if let artwork = Self.artwork {
                Image(nsImage: artwork).resizable().scaledToFit()
            } else {
                Image(systemName: "book.closed.fill").resizable().scaledToFit()
                    .foregroundStyle(WorkLogTheme.accent)
            }
        }
        .accessibilityHidden(true)
    }
}
#endif
