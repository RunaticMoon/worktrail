#if os(macOS)
import AppKit
import SwiftUI
import WorkLogCore

/// Tone decorates the symbol and background; the label always carries meaning.
enum StatusTone: Equatable {
    case neutral, info, success, warning, danger

    var color: Color {
        switch self {
        case .neutral: return WorkLogTheme.muted
        case .info: return WorkLogTheme.accent
        case .success: return Color(nsColor: .systemGreen)
        case .warning: return Color(nsColor: .systemOrange)
        case .danger: return Color(nsColor: .systemRed)
        }
    }
}

struct StatusBadge: View {
    let label: String
    let systemImage: String
    let tone: StatusTone
    @Environment(\.colorSchemeContrast) private var contrast

    init(label: String, systemImage: String, tone: StatusTone) {
        self.label = label
        self.systemImage = systemImage
        self.tone = tone
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: systemImage)
                .foregroundStyle(contrast == .increased ? WorkLogTheme.text : tone.color)
                .accessibilityHidden(true)
            Text(label)
                .foregroundStyle(WorkLogTheme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tone.color.opacity(contrast == .increased ? 0.12 : 0.08),
                    in: RoundedRectangle(cornerRadius: 6))
        .background(WorkLogTheme.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(WorkLogTheme.outlineColor(for: contrast),
                              lineWidth: WorkLogTheme.outlineWidth(for: contrast))
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
    }
}

extension TaskStatus {
    var badgeSymbol: String {
        switch self {
        case .planned: return "clock"
        case .inProgress: return "arrow.triangle.2.circlepath"
        case .onHold: return "pause.circle"
        case .completed: return "checkmark.circle"
        case .cancelled: return "xmark.circle"
        }
    }

    var badgeTone: StatusTone {
        switch self {
        case .planned: return .neutral
        case .inProgress: return .info
        case .onHold: return .warning
        case .completed: return .success
        case .cancelled: return .danger
        }
    }
}

struct TaskStatusBadge: View {
    let status: TaskStatus

    var body: some View {
        StatusBadge(label: status.koreanLabel, systemImage: status.badgeSymbol, tone: status.badgeTone)
    }
}

struct ScreenHeader<Trailing: View>: View {
    let title: String
    let purpose: String
    private let trailing: Trailing

    init(title: String, purpose: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.purpose = purpose
        self.trailing = trailing()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                heading
                Spacer(minLength: 12)
                trailing
            }
            VStack(alignment: .leading, spacing: 8) {
                heading
                trailing
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(WorkLogTheme.text)
                .accessibilityAddTraits(.isHeader)
            if !purpose.isEmpty {
                Text(purpose)
                    .font(.callout)
                    .foregroundStyle(WorkLogTheme.muted)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(title: String, purpose: String) {
        self.init(title: title, purpose: purpose) { EmptyView() }
    }
}

/// Inline state only: it does not cover the screen or disable local actions.
struct StateView: View {
    enum Kind: Equatable {
        case empty, noResults, loading, offline, aiUnavailable, failure

        fileprivate var symbol: String {
            switch self {
            case .empty: return "tray"
            case .noResults: return "magnifyingglass"
            case .loading: return "hourglass"
            case .offline: return "wifi.slash"
            case .aiUnavailable: return "sparkles"
            case .failure: return "exclamationmark.triangle"
            }
        }
    }

    let kind: Kind
    let title: String
    let detail: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    init(kind: Kind, title: String, detail: String,
         actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                if kind == .loading {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                } else {
                    Image(systemName: kind.symbol)
                        .font(.body)
                        .foregroundStyle(WorkLogTheme.muted)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(WorkLogTheme.text)
                    Text(detail).font(.callout).foregroundStyle(WorkLogTheme.muted)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.callout)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .worklogCard()
    }
}

/// The caller removes the notice after recovery or explicit dismissal, never a timer.
struct RecoveryNotice: View {
    let failed: String
    let preserved: String
    let retryTitle: String
    private let retry: () -> Void
    private let dismiss: (() -> Void)?
    @Environment(\.colorSchemeContrast) private var contrast

    init(failed: String, preserved: String, retryTitle: String = "다시 시도",
         retry: @escaping () -> Void, dismiss: (() -> Void)? = nil) {
        self.failed = failed
        self.preserved = preserved
        self.retryTitle = retryTitle
        self.retry = retry
        self.dismiss = dismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(contrast == .increased ? WorkLogTheme.text : StatusTone.warning.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(failed).font(.headline).foregroundStyle(WorkLogTheme.text)
                    Text(preserved).font(.callout).foregroundStyle(WorkLogTheme.muted)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(failed). \(preserved). \(retryTitle) 버튼으로 다시 시도할 수 있습니다."))

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { recoveryActions }
                VStack(alignment: .leading, spacing: 8) { recoveryActions }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .worklogCard()
    }

    @ViewBuilder private var recoveryActions: some View {
        Button(retryTitle, action: retry).buttonStyle(.bordered)
        if let dismiss {
            Button(action: dismiss) { Label("닫기", systemImage: "xmark") }
                .buttonStyle(.bordered)
                .accessibilityLabel("복구 안내 닫기")
        }
    }
}

struct AsOfDateBadge: View {
    let dateLabel: String

    var body: some View {
        StatusBadge(label: "\(dateLabel) 종료 기준", systemImage: "clock", tone: .warning)
    }
}

struct PastDateBadge: View {
    /// A formatted date, for example "10월 4일(일)". Calendar logic stays with the caller.
    let label: String
    let onReset: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { contents }
            VStack(alignment: .leading, spacing: 8) { contents }
        }
    }

    @ViewBuilder private var contents: some View {
        StatusBadge(label: "과거 날짜 · \(label)", systemImage: "clock", tone: .warning)
        Button("오늘로", action: onReset)
            .font(.callout)
            .buttonStyle(.bordered)
            .accessibilityLabel("업무일을 오늘로 변경")
    }
}

struct ShortcutLabel: View {
    let title: String
    let keys: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.callout).fixedSize(horizontal: false, vertical: true)
            Keycap(keys).accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(title), 단축키 \(keys)"))
        .worklogHelp(title, keys: keys)
    }
}

struct SectionDisclosure<Content: View>: View {
    let title: String
    let summary: String
    @Binding private var isExpanded: Bool
    private let content: Content

    init(title: String, summary: String, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self.summary = summary
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(WorkLogTheme.text)
                if !isExpanded {
                    Text(summary).font(.callout).foregroundStyle(WorkLogTheme.muted)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        }
        .accessibilityValue(Text(isExpanded ? "펼침" : "접힘"))
        .worklogAnimation(.easeInOut(duration: 0.16), value: isExpanded)
    }
}

struct ChipView: View {
    let label: String
    let systemImage: String?
    private let onRemove: (() -> Void)?
    @Environment(\.colorSchemeContrast) private var contrast

    init(label: String, systemImage: String? = nil, onRemove: (() -> Void)? = nil) {
        self.label = label
        self.systemImage = systemImage
        self.onRemove = onRemove
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).accessibilityHidden(true)
            }
            Text(label).fixedSize(horizontal: false, vertical: true)
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(Text("\(label) 제거"))
            }
        }
        .font(.callout)
        .foregroundStyle(WorkLogTheme.text)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(WorkLogTheme.elevated, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(WorkLogTheme.outlineColor(for: contrast),
                              lineWidth: WorkLogTheme.outlineWidth(for: contrast))
                .allowsHitTesting(false)
        }
    }
}

/// No value input, selection, tooltip, or accessibility value can originate here.
struct MaskedValueText: View {
    init() {}

    var body: some View {
        Text("••••••")
            .font(.body)
            .foregroundStyle(WorkLogTheme.text)
            .textSelection(.disabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("가려진 값")
    }
}

extension View {
    func worklogHelp(_ title: String, keys: String? = nil) -> some View {
        help(keys.map { $0.isEmpty ? title : "\(title) (\($0))" } ?? title)
    }

    func worklogAnimation<Value: Equatable>(_ animation: Animation?, value: Value) -> some View {
        modifier(WorkLogAnimationModifier(animation: animation, value: value))
    }
}

private struct WorkLogAnimationModifier<Value: Equatable>: ViewModifier {
    let animation: Animation?
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
            .transaction { transaction in
                if reduceMotion {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
    }
}
#endif
