#if os(macOS)
import AppKit
import SwiftUI

/// Shared surfaces stay opaque and follow the system appearance, including panels.
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
                if isFocused || (isSelected && contrast == .increased) {
                    RoundedRectangle(cornerRadius: WorkLogTheme.rowCornerRadius)
                        .strokeBorder(contrast == .increased ? WorkLogTheme.text : WorkLogTheme.accent,
                                      lineWidth: 2)
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

struct WorkLogButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(foreground(role: configuration.role))
            .background(background(pressed: configuration.isPressed, role: configuration.role), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(outline,
                                  lineWidth: isFocused ? 2 : WorkLogTheme.outlineWidth(for: contrast))
                    .allowsHitTesting(false)
            }
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(contrast == .increased ? WorkLogTheme.text : WorkLogTheme.accent,
                                      lineWidth: 2)
                        .padding(-3)
                        .allowsHitTesting(false)
                }
            }
            .opacity(isEnabled ? 1 : (contrast == .increased ? 0.7 : 0.45))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { isHovering = $0 }
    }

    private func foreground(role: ButtonRole?) -> Color {
        // Text stays on a light accent wash, rather than depending on the user's
        // accent color having sufficient contrast against white text.
        if contrast == .increased || prominent { return WorkLogTheme.text }
        return role == .destructive ? Color(nsColor: .systemRed) : WorkLogTheme.text
    }

    private var outline: Color {
        if contrast == .increased { return WorkLogTheme.text }
        return isFocused || prominent ? WorkLogTheme.accent : WorkLogTheme.border
    }

    private func background(pressed: Bool, role: ButtonRole?) -> Color {
        if prominent {
            let color = role == .destructive ? Color(nsColor: .systemRed) : WorkLogTheme.accent
            return color.opacity(pressed ? 0.24 : (isHovering ? 0.18 : 0.12))
        }
        return pressed || isHovering ? WorkLogTheme.elevated : WorkLogTheme.surface
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
            .background(WorkLogTheme.elevated, in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(WorkLogTheme.outlineColor(for: contrast),
                                  lineWidth: WorkLogTheme.outlineWidth(for: contrast))
                    .allowsHitTesting(false)
            }
            .fixedSize()
    }
}

struct WorkLogGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            configuration.label.font(.headline)
            configuration.content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .worklogCard()
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
