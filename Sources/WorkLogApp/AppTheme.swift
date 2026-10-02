#if os(macOS)
import AppKit
import SwiftUI

/// Shared surfaces stay opaque and follow the system appearance, including panels.
enum WorkLogTheme {
    static let cornerRadius: CGFloat = 10
    static let contentInset: CGFloat = 16
    static let cardInset: CGFloat = 12
    static let accent = adaptive(light: 0x5753CF, dark: 0xABA7FF)
    static let accentSoft = adaptive(light: 0xECEBFC, dark: 0x302E4B)
    static let canvas = adaptive(light: 0xF5F5F8, dark: 0x19191F)
    static let surface = adaptive(light: 0xFDFDFE, dark: 0x222229)
    static let elevated = adaptive(light: 0xEEEEF4, dark: 0x2C2C35)
    static let border = adaptive(light: 0xDDDDE7, dark: 0x41414E)
    static let text = Color(nsColor: .labelColor)
    static let muted = Color(nsColor: .secondaryLabelColor)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                           green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        })
    }
}

extension View {
    func worklogCard(padding: CGFloat = WorkLogTheme.cardInset) -> some View {
        self.padding(padding)
            .background(WorkLogTheme.surface, in: RoundedRectangle(cornerRadius: WorkLogTheme.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: WorkLogTheme.cornerRadius)
                    .strokeBorder(WorkLogTheme.border.opacity(0.65), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }
}

struct WorkLogButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(foreground(role: configuration.role))
            .background(background(pressed: configuration.isPressed, role: configuration.role), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(prominent ? Color.clear : WorkLogTheme.border.opacity(0.7), lineWidth: 0.5)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { isHovering = $0 }
    }

    private func foreground(role: ButtonRole?) -> Color {
        if prominent { return role == .destructive ? .white : Color(nsColor: .windowBackgroundColor) }
        return role == .destructive ? .red : WorkLogTheme.text
    }

    private func background(pressed: Bool, role: ButtonRole?) -> Color {
        if prominent {
            let color = role == .destructive ? Color.red : WorkLogTheme.accent
            return color.opacity(pressed ? 0.75 : (isHovering ? 0.88 : 1))
        }
        return pressed || isHovering ? WorkLogTheme.elevated : WorkLogTheme.surface
    }
}

struct Keycap: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(WorkLogTheme.muted)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(WorkLogTheme.elevated, in: RoundedRectangle(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(WorkLogTheme.border, lineWidth: 0.5) }
            .fixedSize()
    }
}

struct WorkLogGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            configuration.label.font(.system(size: 13, weight: .semibold))
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
