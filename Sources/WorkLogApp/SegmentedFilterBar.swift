#if os(macOS)
import SwiftUI

/// Values must be unique within a bar. Shortcut hints describe caller-owned shortcuts.
struct SegmentedFilterItem<Value: Hashable> {
    let value: Value
    let label: String
    let systemImage: String?
    let count: Int?
    let accessibilityIdentifier: String?
    let shortcutHint: String?

    init(value: Value, label: String, systemImage: String? = nil, count: Int? = nil,
         accessibilityIdentifier: String? = nil, shortcutHint: String? = nil) {
        self.value = value
        self.label = label
        self.systemImage = systemImage
        self.count = count
        self.accessibilityIdentifier = accessibilityIdentifier
        self.shortcutHint = shortcutHint
    }
}

/// Leading-aligned selection tabs; compact windows keep whole labels in a scrollable row.
struct SegmentedFilterBar<Value: Hashable>: View {
    let title: String?
    @Binding var selection: Value
    let items: [SegmentedFilterItem<Value>]
    let showsShortcutHints: Bool
    @FocusState private var focusedValue: Value?

    init(title: String? = nil, selection: Binding<Value>, items: [SegmentedFilterItem<Value>],
         showsShortcutHints: Bool = false) {
        self.title = title
        self._selection = selection
        self.items = items
        self.showsShortcutHints = showsShortcutHints
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                titleLabel
                tabs
            }
            .fixedSize(horizontal: true, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                titleLabel
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) { tabs }
                        .fixedSize(horizontal: false, vertical: true)
                        .onChange(of: focusedValue) { _, value in
                            if let value { proxy.scrollTo(value) }
                        }
                        .onChange(of: selection) { _, value in proxy.scrollTo(value) }
                        .onAppear { proxy.scrollTo(selection) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var titleLabel: some View {
        if let title, !title.isEmpty {
            Text(title)
                .font(.callout)
                .foregroundStyle(WorkLogTheme.muted)
                .fixedSize()
        }
    }

    private var tabs: some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.value) { item in
                identifiedButton(item).id(item.value)
            }
        }
        // Reserve the overlay's overhang even while hints are hidden, including inside the scroll view.
        .padding(.top, items.contains { $0.shortcutHint != nil } ? 8 : 0)
    }

    @ViewBuilder private func identifiedButton(_ item: SegmentedFilterItem<Value>) -> some View {
        if let identifier = item.accessibilityIdentifier {
            tabButton(item).accessibilityIdentifier(identifier)
        } else {
            tabButton(item)
        }
    }

    private func tabButton(_ item: SegmentedFilterItem<Value>) -> some View {
        Button { selection = item.value } label: {
            HStack(spacing: 6) {
                if let systemImage = item.systemImage {
                    Image(systemName: systemImage).accessibilityHidden(true)
                }
                Text(item.label)
                if let count = item.count {
                    Text(count, format: .number)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(WorkLogTheme.text.opacity(0.08), in: Capsule())
                }
            }
            .font(.callout.weight(selection == item.value ? .semibold : .medium))
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
        }
        .buttonStyle(SegmentedFilterTabStyle(isSelected: selection == item.value,
                                            isFocused: focusedValue == item.value))
        .overlay(alignment: .topTrailing) {
            if showsShortcutHints, let shortcutHint = item.shortcutHint {
                Keycap(shortcutHint)
                    .background(WorkLogTheme.surface, in: RoundedRectangle(cornerRadius: 4))
                    .padding(.trailing, 4)
                    .offset(y: -8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .focused($focusedValue, equals: item.value)
        .focusEffectDisabled()
        .accessibilityLabel(Text(accessibilityLabel(for: item)))
        .accessibilityAddTraits(selection == item.value ? .isSelected : [])
        .worklogHelp(item.label, keys: item.shortcutHint)
        .worklogAnimation(.easeInOut(duration: 0.16), value: selection == item.value)
    }

    private func accessibilityLabel(for item: SegmentedFilterItem<Value>) -> String {
        let label = item.count.map { "\(item.label), \($0)개" } ?? item.label
        return item.shortcutHint.map { "\(label), 단축키 \($0)" } ?? label
    }
}

/// Scoped to these tabs; ordinary app buttons retain their system styles.
private struct SegmentedFilterTabStyle: ButtonStyle {
    let isSelected: Bool
    let isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(WorkLogTheme.text)
            .background(background(isPressed: configuration.isPressed), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(outlineColor, lineWidth: outlineWidth)
                    .allowsHitTesting(false)
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { isHovering = $0 }
    }

    private func background(isPressed: Bool) -> Color {
        if isEnabled && isPressed { return WorkLogTheme.accent.opacity(0.25) }
        if isSelected { return WorkLogTheme.accent.opacity(isEnabled && isHovering ? 0.22 : 0.16) }
        return isEnabled && isHovering ? WorkLogTheme.rowHover : WorkLogTheme.surface
    }

    private var outlineColor: Color {
        if isFocused { return WorkLogTheme.focusColor(for: contrast) }
        if contrast == .increased { return WorkLogTheme.text }
        return isSelected ? WorkLogTheme.accent : WorkLogTheme.border
    }

    private var outlineWidth: CGFloat {
        if isFocused { return 3 }
        if isSelected || contrast == .increased { return 2 }
        return 1
    }
}
#endif
