#if os(macOS)
import AppKit
import SwiftUI
import WorkLogCore

/// Selects manual related records for a draft. It does not approve report evidence
/// or memo/task suggestions, and never persists links itself.
@MainActor
struct RelatedRecordPicker: View {
    @Binding var selection: [RelatedRecordCandidate]
    let search: (String) throws -> [RelatedRecordCandidate]
    var excluding: Set<RecordReference> = []
    var isDisabled: Bool = false

    @State private var isPresented = false
    @State private var query = ""
    @State private var candidates: [RelatedRecordCandidate] = []
    @State private var failed = false
    @State private var highlighted: RecordReference?
    @FocusState private var focus: Focus?

    private enum Focus: Hashable {
        case add, search, candidate(RecordReference)
    }

    init(
        selection: Binding<[RelatedRecordCandidate]>,
        search: @escaping (String) throws -> [RelatedRecordCandidate],
        excluding: Set<RecordReference> = [],
        isDisabled: Bool = false
    ) {
        self._selection = selection
        self.search = search
        self.excluding = excluding
        self.isDisabled = isDisabled
    }

    var body: some View {
        HStack(spacing: 8) {
            if !selection.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(unique(selection), id: \.reference) { candidate in
                            chip(candidate)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                .frame(height: 36)
                .accessibilityLabel("선택된 관련 기록")
            }
            Button {
                query = ""
                loadCandidates()
                isPresented = true
            } label: {
                Label("관련 기록 추가", systemImage: "plus")
            }
            .fixedSize()
            .focused($focus, equals: .add)
            .accessibilityHint("기록을 검색하여 여러 개 선택합니다")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                pickerContent
            }
            if selection.isEmpty { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(isDisabled)
        .onAppear { normalizeSelection() }
        .onChange(of: selection) { _, _ in normalizeSelection() }
        .onChange(of: excluding) { _, _ in
            if isPresented { loadCandidates() }
        }
        .onChange(of: isDisabled) { _, disabled in
            if disabled { isPresented = false }
        }
        .onChange(of: isPresented) { _, presented in
            if !presented && !isDisabled { focus = .add }
        }
    }

    private func chip(_ candidate: RelatedRecordCandidate) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol(for: candidate.reference.kind))
                .foregroundStyle(.secondary)
                .accessibilityLabel(kindLabel(candidate.reference.kind))
            Text(candidate.title)
                .lineLimit(1)
                .frame(maxWidth: 160, alignment: .leading)
                .help(candidate.title)
            Button {
                guard !isDisabled else { return }
                selection.removeAll { $0.reference == candidate.reference }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("관련 기록 \(candidate.title) 제거")
            .help("관련 기록 \(candidate.title) 제거")
        }
        .font(.callout)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().stroke(Color(nsColor: .separatorColor)))
    }

    private var pickerContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("관련 기록").font(.headline)
                Spacer()
                Button("완료") { close() }
            }
            Text("수동 관련 연결이며, 보고서 근거나 메모·업무 연결을 승인하지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            RelatedRecordSearchField(text: $query, isDisabled: isDisabled,
                onFocus: { focus = .search },
                onMove: { moveHighlight(by: $0) },
                onToggle: { toggleHighlighted() }, onClose: { close() })
                .frame(height: 24)
                .focused($focus, equals: .search)
                .onChange(of: query) { _, _ in loadCandidates() }
            results
            Text("↑↓ 이동 · Return 선택/해제 · Esc 닫기")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 360)
        .disabled(isDisabled)
        .onChange(of: focus) { _, value in
            if case let .candidate(reference) = value { highlighted = reference }
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .return, .escape], phases: [.down, .repeat]) { press in
            guard !isDisabled, !hasMarkedText,
                  press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return .ignored }
            switch press.key {
            case .upArrow:
                moveHighlight(by: -1)
            case .downArrow:
                moveHighlight(by: 1)
            case .return:
                // The native text field handles its own commands; row focus is
                // handled here so Return and Space both toggle native buttons.
                guard case .candidate = focus else { return .ignored }
                if press.phase == .down { toggleHighlighted() }
            case .escape:
                close()
            default:
                return .ignored
            }
            return .handled
        }
        .onExitCommand {
            if !hasMarkedText { close() }
        }
    }

    @ViewBuilder private var results: some View {
        if failed {
            VStack(spacing: 8) {
                Text("관련 기록을 불러오지 못했습니다")
                    .foregroundStyle(.secondary)
                Button("다시 시도") { loadCandidates() }
            }
            .frame(maxWidth: .infinity, minHeight: 100)
        } else if candidates.isEmpty {
            Text("일치하는 기록이 없습니다")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 100)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(candidates, id: \.reference) { candidate in
                            resultRow(candidate).id(candidate.reference)
                        }
                    }
                    .padding(2)
                }
                .frame(height: min(CGFloat(candidates.count) * 58 + 4, 240))
                .onChange(of: highlighted) { _, reference in
                    if let reference { proxy.scrollTo(reference) }
                }
            }
            .accessibilityLabel("관련 기록 검색 결과")
        }
    }

    private func resultRow(_ candidate: RelatedRecordCandidate) -> some View {
        let selected = selection.contains { $0.reference == candidate.reference }
        let active = activeReference == candidate.reference
        return Button {
            highlighted = candidate.reference
            focus = .candidate(candidate.reference)
            toggle(candidate)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol(for: candidate.reference.kind))
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.title).lineLimit(1)
                    Text([kindLabel(candidate.reference.kind), candidate.subtitle]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "checkmark")
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .contentShape(Rectangle())
            .background(active ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.15) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(active ? Color.accentColor : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .focused($focus, equals: .candidate(candidate.reference))
        .help([candidate.title, candidate.subtitle].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityLabel([kindLabel(candidate.reference.kind), candidate.title, candidate.subtitle]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(selected ? "선택됨" : "선택 안 됨")
        .accessibilityHint("관련 기록 선택을 전환합니다")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var activeReference: RecordReference? {
        if case let .candidate(reference) = focus { return reference }
        return highlighted
    }

    private var hasMarkedText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }

    private func loadCandidates() {
        guard !isDisabled else { return }
        do {
            // Preserve the callback's relevance/recent order. Its caller caps
            // the result count; references remain unique even for faulty input.
            candidates = unique(try search(query)).filter { !excluding.contains($0.reference) }
            failed = false
            if !candidates.contains(where: { $0.reference == highlighted }) {
                highlighted = candidates.first?.reference
            }
            if case let .candidate(reference) = focus,
               !candidates.contains(where: { $0.reference == reference }) {
                focus = .search
            }
        } catch {
            candidates = []
            highlighted = nil
            failed = true
        }
    }

    private func moveHighlight(by offset: Int) {
        guard !candidates.isEmpty else { return }
        let index = candidates.firstIndex { $0.reference == activeReference }
        let next = index.map { min(max($0 + offset, 0), candidates.count - 1) }
            ?? (offset > 0 ? 0 : candidates.count - 1)
        highlighted = candidates[next].reference
        if case .candidate = focus { focus = .candidate(candidates[next].reference) }
    }

    private func toggleHighlighted() {
        guard !hasMarkedText,
              let candidate = candidates.first(where: { $0.reference == activeReference }) else { return }
        toggle(candidate)
    }

    private func toggle(_ candidate: RelatedRecordCandidate) {
        guard !isDisabled, !excluding.contains(candidate.reference) else { return }
        var updated = unique(selection)
        if updated.contains(where: { $0.reference == candidate.reference }) {
            updated.removeAll { $0.reference == candidate.reference }
        } else {
            updated.append(candidate)
        }
        selection = updated
    }

    private func normalizeSelection() {
        let normalized = unique(selection)
        if selection != normalized { selection = normalized }
    }

    private func unique(_ records: [RelatedRecordCandidate]) -> [RelatedRecordCandidate] {
        var seen = Set<RecordReference>()
        return records.filter { seen.insert($0.reference).inserted }
    }

    private func close() { isPresented = false }

    private func kindLabel(_ kind: RecordReferenceKind) -> String {
        switch kind {
        case .memo: return "메모"
        case .task: return "업무"
        case .activity: return "진행기록"
        case .reportVersion: return "리포트"
        }
    }

    private func symbol(for kind: RecordReferenceKind) -> String {
        switch kind {
        case .memo: return "note.text"
        case .task: return "checklist"
        case .activity: return "clock.arrow.circlepath"
        case .reportVersion: return "doc.text"
        }
    }
}

/// Native field-editor commands keep arrows available while typing and let the
/// input method finish marked text before Return/Escape change picker state.
@MainActor
private struct RelatedRecordSearchField: NSViewRepresentable {
    @Binding var text: String
    let isDisabled: Bool
    let onFocus: () -> Void
    let onMove: (Int) -> Void
    let onToggle: () -> Void
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = SearchTextField()
        field.placeholderString = "기록 검색"
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        field.font = NSFont.preferredFont(forTextStyle: .body, options: [:])
        field.delegate = context.coordinator
        field.setAccessibilityLabel("관련 기록 검색")
        field.setAccessibilityHelp("빈 검색어는 최근 기록을 표시합니다. 위아래 화살표로 이동하고 Return으로 선택합니다.")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = !isDisabled
        if field.stringValue != text && (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RelatedRecordSearchField
        init(_ parent: RelatedRecordSearchField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) { parent.onFocus() }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !parent.isDisabled, !textView.hasMarkedText() else { return false }
            if let event = NSApp.currentEvent,
               !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                return false
            }
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.isARepeat != true { parent.onToggle() }
            case #selector(NSResponder.cancelOperation(_:)): parent.onClose()
            default: return false
            }
            return true
        }
    }

    @MainActor private final class SearchTextField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, self.isEnabled else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}
#endif
