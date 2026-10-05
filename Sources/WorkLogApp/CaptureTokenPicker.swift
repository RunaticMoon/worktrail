#if os(macOS)
import SwiftUI
import AppKit
import WorkLogCore

/// Explicit project/tag selection never edits the body or inserts token syntax.
@MainActor struct CaptureTokenPicker: View {
    enum Kind { case project, tag }
    @Bindable var model: CaptureModel
    let kind: Kind
    let allowsCreation: Bool
    let onClose: () -> Void
    @State private var isPresented = false
    @State private var query = ""
    @State private var highlighted: String?
    @FocusState private var rowFocus: String?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    private struct Option: Identifiable {
        let id: String
        let name: String
        var isNew = false
    }

    private var title: String { kind == .project ? "프로젝트" : "태그" }
    private var symbol: String { kind == .project ? "folder" : "number" }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var options: [Option] {
        var rows = kind == .project
            ? model.projectOptions(matching: query).map { Option(id: $0.id, name: $0.name) }
            : model.tagOptions(matching: query).map { Option(id: $0.id, name: $0.name) }
        let names = kind == .project ? model.projects.map(\.name) : model.tags.map(\.name)
        if allowsCreation, !trimmedQuery.isEmpty,
           !names.contains(where: { $0.caseInsensitiveCompare(trimmedQuery) == .orderedSame }) {
            rows.append(Option(id: "create:\(trimmedQuery)", name: trimmedQuery, isNew: true))
        }
        return rows
    }

    var body: some View {
        Button {
            query = ""
            highlighted = options.first(where: { !$0.isNew })?.id
            isPresented = true
        } label: {
            Text(kind == .project ? "@ 프로젝트" : "# 태그").font(.callout)
        }
        .buttonStyle(.bordered)
        .worklogHelp("\(title) 검색 및 선택")
        .accessibilityHint("검색 가능한 목록을 엽니다. 본문은 바뀌지 않습니다.")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) { pickerContent }
        .disabled(model.isSubmitting)
        .onChange(of: isPresented) { _, presented in
            if !presented { onClose() }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { isPresented = false }
        }
    }

    private var pickerContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(title) 선택").font(.headline)
                Spacer()
                Button("닫기") { isPresented = false }
                    .worklogHelp("선택 목록 닫기", keys: "Esc")
            }
            CaptureTokenSearchField(text: $query, label: "\(title) 검색", isDisabled: model.isSubmitting,
                                    onMove: moveHighlight, onSelect: selectHighlighted,
                                    onClose: { isPresented = false })
                .frame(minHeight: 28)
                .onChange(of: query) { _, _ in
                    // A create-only result requires explicit ↓ or a click.
                    highlighted = options.first(where: { !$0.isNew })?.id
                    rowFocus = nil
                }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(options) { option in optionRow(option) }
                        if options.isEmpty {
                            Text(allowsCreation ? "선택할 항목이 없습니다. 새 이름을 입력하세요." : "연결된 프로젝트가 없습니다. 공통으로 기록할 수 있습니다.")
                                .font(.callout).foregroundStyle(WorkLogTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 8)
                        }
                    }
                }
                .frame(height: 210)
                .onChange(of: highlighted) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(WorkLogTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("↑↓ 이동 · Return 선택 · Esc 닫기")
                .font(.caption).foregroundStyle(WorkLogTheme.muted)
        }
        .padding(16)
        .frame(width: 340)
        .foregroundStyle(WorkLogTheme.text)
        .tint(WorkLogTheme.accent)
        .onChange(of: rowFocus) { _, id in
            if let id { highlighted = id }
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .return, .escape], phases: [.down, .repeat]) { press in
            guard isEnabled, !model.isSubmitting, !hasMarkedText,
                  press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return .ignored }
            if press.phase == .repeat && press.key != .upArrow && press.key != .downArrow { return .handled }
            switch press.key {
            case .upArrow: moveHighlight(-1)
            case .downArrow: moveHighlight(1)
            case .return: selectHighlighted()
            case .escape: isPresented = false
            default: return .ignored
            }
            return .handled
        }
    }

    private func optionRow(_ option: Option) -> some View {
        let selected = highlighted == option.id
        return Button { select(option) } label: {
            HStack(spacing: 8) {
                Image(systemName: option.isNew ? "plus" : symbol).accessibilityHidden(true)
                Text(option.isNew ? "‘\(option.name)’ 새로 만들기" : option.name)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if selected { Image(systemName: "chevron.right").accessibilityHidden(true) }
            }
            .font(.callout)
            .foregroundStyle(WorkLogTheme.text)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? WorkLogTheme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? WorkLogTheme.outlineColor(for: contrast) : .clear,
                              lineWidth: WorkLogTheme.outlineWidth(for: contrast)))
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($rowFocus, equals: option.id)
        .accessibilityValue(selected ? "강조됨" : "")
        .worklogHelp(option.isNew ? "\(title) 만들고 선택" : "\(title) 선택", keys: "Return")
        .id(option.id)
    }

    private var hasMarkedText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }

    private func moveHighlight(_ delta: Int) {
        let rows = options
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == highlighted }
        let next = index.map { min(max($0 + delta, 0), rows.count - 1) } ?? (delta > 0 ? 0 : rows.count - 1)
        highlighted = rows[next].id
        if rowFocus != nil { rowFocus = highlighted }
    }

    private func selectHighlighted() {
        guard let option = options.first(where: { $0.id == highlighted }) else { return }
        select(option)
    }

    private func select(_ option: Option) {
        guard isEnabled, !model.isSubmitting, !hasMarkedText else { return }
        if option.isNew {
            if kind == .project { model.addNewProject(name: option.name) }
            else { model.addNewTag(name: option.name) }
            // Creation errors retain the query and list for a retry.
            guard model.errorMessage == nil else { return }
        } else {
            if kind == .project { model.addProject(id: option.id) }
            else { model.addTag(id: option.id) }
        }
        isPresented = false
    }
}

/// Native field-editor handling preserves composition and ordinary text editing.
@MainActor private struct CaptureTokenSearchField: NSViewRepresentable {
    @Binding var text: String
    let label: String
    let isDisabled: Bool
    let onMove: (Int) -> Void
    let onSelect: () -> Void
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = SearchField()
        field.placeholderString = label
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = NSFont.preferredFont(forTextStyle: .body, options: [:])
        field.delegate = context.coordinator
        field.setAccessibilityLabel(label)
        field.setAccessibilityHelp("위아래로 후보 이동, Return 선택, Escape 목록 닫기")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = !isDisabled
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CaptureTokenSearchField
        init(_ parent: CaptureTokenSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !parent.isDisabled, !textView.hasMarkedText(),
                  NSApp.currentEvent?.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty != false else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.isARepeat != true { parent.onSelect() }
            case #selector(NSResponder.cancelOperation(_:)):
                if NSApp.currentEvent?.isARepeat != true { parent.onClose() }
            default: return false
            }
            return true
        }
    }

    private final class SearchField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, self.isEnabled else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}
#endif
