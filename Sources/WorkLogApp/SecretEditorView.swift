#if os(macOS)
import SwiftUI
import AppKit
import WorkLogCore

/// Shares only the authenticated vault editor. The capture host supplies its explicit key loop.
@MainActor struct SecretEditorView: View {
    enum KeyboardMode { case cellNavigation, panel }

    @Bindable var model: SecretsModel
    let host: SecretEditorHost
    let keyboardMode: KeyboardMode
    let onSave: () -> Bool
    var titleFocusRequest = 0
    var onMoveToTrash: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    var captureNavigation: CaptureKeyboardNavigation? = nil
    private enum FieldFocus: Hashable {
        case title, group, paste, key(String), value(String), previewKey(Int), previewValue(Int)
    }
    @FocusState private var focusedField: FieldFocus?
    @State private var pasteExpanded = false

    init(model: SecretsModel, host: SecretEditorHost, keyboardMode: KeyboardMode,
         onSave: @escaping () -> Bool, titleFocusRequest: Int = 0,
         onMoveToTrash: (() -> Void)? = nil, onCancel: (() -> Void)? = nil,
         captureNavigation: CaptureKeyboardNavigation? = nil) {
        self.model = model
        self.host = host
        self.keyboardMode = keyboardMode
        self.onSave = onSave
        self.titleFocusRequest = titleFocusRequest
        self.onMoveToTrash = onMoveToTrash
        self.onCancel = onCancel
        self.captureNavigation = captureNavigation
    }

    private var canEdit: Bool {
        !model.isLocked && model.isEditing && model.canEdit(from: host) && !model.hasRecoverableDraft
    }
    private var keyboardHint: String {
        let navigation = "Tab / ⇧Tab 이동 · ⌘⇧Return 행 추가 · ⌘⇧⌫ 현재 행 삭제"
        let saveKey = keyboardMode == .panel ? "⌘Return" : "⌘S 또는 ⌘Return"
        return "\(navigation) · \(saveKey) 저장 · key·값의 앞뒤 공백만 저장 시 제거"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.canEdit(from: host) {
                Text("다른 화면에서 편집 중입니다").foregroundStyle(.secondary)
            }
            if host == .main {
                ScrollViewReader { proxy in
                    ScrollView { editorContent.padding(.trailing, 4) }
                        .onChange(of: focusedField) { _, focus in
                            switch focus {
                            case .key(let id), .value(let id): proxy.scrollTo(id)
                            default: break
                            }
                        }
                }
            } else {
                editorContent
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { editorActions }
                VStack(alignment: .leading, spacing: 8) { editorActions }
            }
            .disabled(!canEdit)
        }
        .textFieldStyle(.roundedBorder)
        .background {
            // Retain the original main-window save shortcut alongside the visible ⌘S action.
            if keyboardMode == .cellNavigation {
                Button("Secret 저장") { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .hidden().accessibilityHidden(true)
            }
            Button("현재 Secret 행 삭제", action: removeFocusedRow)
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(!canEdit || focusedRowID == nil)
                .hidden().accessibilityHidden(true)
        }
        .onAppear {
            if canEdit && (host == .capture || titleFocusRequest > 0) && captureNavigation?.keepTabFocus != true {
                focusedField = .title
            }
        }
        .onChange(of: titleFocusRequest) { _, _ in if canEdit { focusedField = .title } }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Secret 편집", systemImage: "pencil").font(.headline)
                Spacer(minLength: 8)
                SecretValueVisibilityButton(model: model, host: host)
                    .secretControlFocus(captureNavigation, "secretVisibility", order: 190, action: toggleValues)
            }
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("제목") {
                    TextField("비우면 임시 제목", text: $model.title)
                        .accessibilityLabel("Secret 제목")
                        .modifier(fieldFocus(.title, id: "secretTitle", order: 200))
                }
                LabeledContent("그룹") {
                    TextField("선택 사항", text: $model.groupName).accessibilityLabel("그룹 (선택 사항)")
                        .modifier(fieldFocus(.group, id: "secretGroup", order: 210))
                }
            }
            HStack(spacing: 8) {
                Text("key").frame(width: 132, alignment: .leading)
                Text("값").frame(maxWidth: .infinity, alignment: .leading)
                Text("삭제").frame(width: 28)
            }.font(.callout.weight(.medium)).foregroundStyle(.secondary).accessibilityHidden(true)
            if model.rows.isEmpty { Text("‘행 추가’ 또는 붙여넣기로 값을 입력하세요.").foregroundStyle(.secondary) }
            editorRows
            Text(keyboardHint).font(.callout).foregroundStyle(.secondary)
            Divider()
            pasteControls
        }.disabled(!canEdit)
    }

    private var editorRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows.map(\.id), id: \.self) { rowID in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 8) {
                            TextField("key", text: rowText(rowID, \.key)).frame(width: 132)
                                .accessibilityLabel("행 \(rowNumber(rowID)) key")
                                .modifier(fieldFocus(.key(rowID), id: "secretKey:\(rowID)", order: rowFocusOrder(rowID)))
                                .secretCellNavigation(keyboardMode) { moveCell(from: .key(rowID), backwards: $0.modifiers.contains(.shift)) }
                            Group {
                                if model.showsValues && model.canEdit(from: host) {
                                    TextField("값", text: rowText(rowID, \.value), axis: .vertical).lineLimit(1...6)
                                        .accessibilityLabel("행 \(rowNumber(rowID)) 값")
                                } else {
                                    SecureField("값", text: rowText(rowID, \.value)).accessibilityLabel("가려진 값")
                                        .accessibilityHint("행 \(rowNumber(rowID)) 값 편집")
                                }
                            }
                            .modifier(fieldFocus(.value(rowID), id: "secretValue:\(rowID)", order: rowFocusOrder(rowID) + 1))
                            .secretCellNavigation(keyboardMode) { moveCell(from: .value(rowID), backwards: $0.modifiers.contains(.shift)) }
                            Button { removeRow(rowID) } label: { Image(systemName: "minus.circle") }
                                .accessibilityLabel("행 \(rowNumber(rowID)) 삭제")
                                .secretControlFocus(captureNavigation, "secretDelete:\(rowID)", order: rowFocusOrder(rowID) + 2,
                                                    action: { removeRow(rowID) })
                                .worklogHelp("현재 행 삭제 · 저장하면 이전 버전에서 복원 가능", keys: "⌘⇧⌫")
                        }.frame(minHeight: 34)
                        if model.duplicateRowIds.contains(rowID) {
                            Label("중복 key · 수정 후 저장하세요", systemImage: "exclamationmark.circle")
                                .font(.callout).foregroundStyle(WorkLogTheme.text)
                        }
                        if model.maskedRowIds.contains(rowID) {
                            Label("가림 문자만 있는 값은 저장하지 않습니다 · 실제 값을 입력하세요", systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(WorkLogTheme.text)
                        }
                    }.padding(.vertical, 3).id(rowID)
                    Divider()
                }
            }
            Button("행 추가", systemImage: "plus", action: addRow)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .secretControlFocus(captureNavigation, "secretAddRow", order: rowControlsOrder, action: addRow)
                .worklogHelp("표에 새 행 추가", keys: "⌘⇧Return")
        }
    }

    private var pasteControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                pasteExpanded.toggle()
            } label: {
                Label("여러 줄 붙여넣기", systemImage: pasteExpanded ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.plain)
            .secretControlFocus(captureNavigation, "secretPasteToggle", order: rowControlsOrder + 1,
                                action: { pasteExpanded.toggle() })
            .accessibilityValue(pasteExpanded ? "펼쳐짐" : "접힘")
            if pasteExpanded {
            VStack(alignment: .leading, spacing: 8) {
                Text("A=B 또는 A : B 형식의 텍스트를 붙여 넣으세요. 첫 구분자 뒤는 값 전체로 보존합니다.").foregroundStyle(.secondary)
                Group {
                    if model.showsValues && model.canEdit(from: host) {
                        TextEditor(text: $model.pasteText).frame(height: 90).accessibilityLabel("붙여넣을 텍스트")
                    } else {
                        SecureField("여러 줄 텍스트 붙여넣기", text: $model.pasteText)
                            .accessibilityLabel("붙여넣을 가려진 텍스트")
                    }
                }
                .modifier(fieldFocus(.paste, id: "secretPaste", order: rowControlsOrder + 2))
                HStack {
                    Button("클립보드에서 분리 미리보기", action: previewClipboard)
                        .secretControlFocus(captureNavigation, "secretClipboardPreview", order: rowControlsOrder + 3,
                                            action: previewClipboard)
                    Button("입력 분리 미리보기") { model.makePastePreview() }
                        .secretControlFocus(captureNavigation, "secretInputPreview", order: rowControlsOrder + 4,
                                            action: { model.makePastePreview() })
                        .disabled(model.pasteText.isEmpty)
                }
                ForEach(model.preview.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("자동 key", text: previewText(index, \.key)).frame(maxWidth: 180)
                                .accessibilityLabel("미리보기 행 \(index + 1) key")
                                .modifier(fieldFocus(.previewKey(index), id: "secretPreviewKey:\(index)", order: rowControlsOrder + 5 + index * 2))
                            Group {
                                if model.showsValues && model.canEdit(from: host) {
                                    TextField("값", text: previewText(index, \.value), axis: .vertical)
                                        .accessibilityLabel("미리보기 행 \(index + 1) 값")
                                } else {
                                    SecureField("가려진 값", text: previewText(index, \.value))
                                        .accessibilityLabel("가려진 값")
                                        .accessibilityHint("미리보기 행 \(index + 1) 값 편집")
                                }
                            }
                            .modifier(fieldFocus(.previewValue(index), id: "secretPreviewValue:\(index)", order: rowControlsOrder + 6 + index * 2))
                        }
                        if model.preview.indices.contains(index), model.preview[index].ambiguous {
                            Label("구분이 모호해 원문 전체를 값으로 보존했습니다. 확인하세요.", systemImage: "exclamationmark.circle")
                                .font(.caption)
                        }
                    }
                }
                if !model.preview.isEmpty {
                    HStack {
                        Button("표에 행 추가") { model.appendPreview() }
                            .secretControlFocus(captureNavigation, "secretAppendPreview", order: actionControlsOrder - 2,
                                                action: { model.appendPreview() })
                        Button("붙여넣기 취소") { model.cancelPreview() }
                            .secretControlFocus(captureNavigation, "secretCancelPreview", order: actionControlsOrder - 1,
                                                action: { model.cancelPreview() })
                    }
                }
            }.padding(.top, 8)
            }
        }
    }

    @ViewBuilder private var editorActions: some View {
        Button { save() } label: {
            ShortcutLabel(title: "저장", keys: keyboardMode == .panel ? "⌘Return" : "⌘S")
        }
        .keyboardShortcut(keyboardMode == .panel ? .return : KeyEquivalent("s"), modifiers: .command)
        .buttonStyle(.borderedProminent)
        .secretControlFocus(captureNavigation, "secretSave", order: actionControlsOrder, action: save)
        .worklogHelp("Secret 저장", keys: keyboardMode == .panel ? "⌘Return" : "⌘S / ⌘Return")
        if let onCancel {
            Button("취소") {
                guard canEdit, !hasMarkedText else { return }
                onCancel()
            }
            .secretControlFocus(captureNavigation, "secretCancel", order: actionControlsOrder + 1, action: {
                guard canEdit, !hasMarkedText else { return }
                onCancel()
            })
            .worklogHelp("Secret 편집 취소")
        }
        if model.selectedId != nil, let onMoveToTrash {
            Button("휴지통으로 이동…", role: .destructive, action: onMoveToTrash)
                .worklogHelp("항목과 이전 버전을 휴지통으로 이동")
        }
    }

    private func save() {
        guard canEdit, !hasMarkedText else { return }
        if !onSave() {
            if let row = model.rows.first(where: { model.maskedRowIds.contains($0.id) }) {
                focusedField = .value(row.id)
            } else if let row = model.rows.first(where: { model.duplicateRowIds.contains($0.id) }) {
                focusedField = .key(row.id)
            }
        }
    }
    private var hasMarkedText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }
    private var isRepeatingKey: Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return event.isARepeat
    }

    private var rowControlsOrder: Int { 300 + model.rows.count * 3 }
    private var actionControlsOrder: Int { rowControlsOrder + 8 + model.preview.count * 2 }
    private func rowNumber(_ id: String) -> Int {
        (model.rows.first { $0.id == id }?.order ?? 0) + 1
    }
    /// SwiftUI may read or finish editing a removed field after a row deletion
    /// or panel dismissal. Resolve the current row by identity on every access;
    /// never retain a collection-index binding or resurrect a deleted row.
    private func rowText(_ id: String, _ keyPath: WritableKeyPath<SecretRow, String>) -> Binding<String> {
        Binding(get: {
            guard canEdit, let row = model.rows.first(where: { $0.id == id }) else { return "" }
            return row[keyPath: keyPath]
        }, set: { value in
            guard canEdit, let index = model.rows.firstIndex(where: { $0.id == id }) else { return }
            model.rows[index][keyPath: keyPath] = value
        })
    }
    /// Applying or canceling a paste clears the preview before its native text
    /// fields are necessarily detached. Late accesses must tolerate that clear.
    private func previewText(_ index: Int, _ keyPath: WritableKeyPath<SecretRowInput, String>) -> Binding<String> {
        Binding(get: {
            guard canEdit, model.preview.indices.contains(index) else { return "" }
            return model.preview[index].input[keyPath: keyPath]
        }, set: { value in
            guard canEdit, model.preview.indices.contains(index) else { return }
            model.preview[index].input[keyPath: keyPath] = value
        })
    }
    private func rowFocusOrder(_ id: String) -> Int {
        300 + (model.rows.firstIndex { $0.id == id } ?? 0) * 3
    }
    private func fieldFocus(_ value: FieldFocus, id: String, order: Int) -> SecretFieldFocus<FieldFocus> {
        SecretFieldFocus(navigation: captureNavigation, focus: $focusedField, value: value,
                         id: id, order: order, isEnabled: canEdit)
    }
    private var focusedRowID: String? {
        switch focusedField {
        case .key(let id), .value(let id): return id
        default: return nil
        }
    }
    private func addRow() {
        guard canEdit, !hasMarkedText, !isRepeatingKey else { return }
        model.addRow()
        if let row = model.rows.last { focusedField = .key(row.id) }
    }
    private func removeFocusedRow() {
        guard let id = focusedRowID else { return }
        removeRow(id)
    }
    private func removeRow(_ id: String) {
        guard canEdit, !hasMarkedText, !isRepeatingKey,
              let index = model.rows.firstIndex(where: { $0.id == id }) else { return }
        model.removeRow(id)
        if !model.rows.isEmpty {
            focusedField = .key(model.rows[min(index, model.rows.count - 1)].id)
        } else {
            focusedField = .group
        }
    }
    private func toggleValues() {
        guard canEdit, !hasMarkedText else { return }
        model.showsValues.toggle()
    }
    private func previewClipboard() {
        // Explicit native paste input; retain every newline without a single-line field conversion.
        guard canEdit, !hasMarkedText, let text = NSPasteboard.general.string(forType: .string) else { return }
        model.acceptPaste(text)
    }
    private func moveCell(from cell: FieldFocus, backwards: Bool) -> KeyPress.Result {
        guard canEdit, !hasMarkedText else { return .ignored }
        let cells = model.rows.flatMap { [FieldFocus.key($0.id), .value($0.id)] }
        guard let index = cells.firstIndex(of: cell) else { return .ignored }
        let next = index + (backwards ? -1 : 1)
        guard cells.indices.contains(next) else { return .ignored }
        focusedField = cells[next]
        return .handled
    }
}

/// Text inputs retain their native editing semantics while joining the panel's key loop.
/// A nil navigation is the main-window editor and never requires a capture environment.
@MainActor private struct SecretFieldFocus<Value: Hashable>: ViewModifier {
    let navigation: CaptureKeyboardNavigation?
    let focus: FocusState<Value?>.Binding
    let value: Value
    let id: String
    let order: Int
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content
            .focused(focus, equals: value)
            .id(id)
            .onAppear { register() }
            .onDisappear { navigation?.remove(id) }
            .onChange(of: isEnabled) { _, _ in register() }
            .onChange(of: order) { _, _ in register() }
            .onChange(of: focus.wrappedValue) { _, focused in
                if focused == value { navigation?.current = id }
            }
    }

    private func register() {
        guard let navigation else { return }
        if isEnabled {
            navigation.register(id, order: order) { focus.wrappedValue = value }
            if focus.wrappedValue == value { navigation.current = id }
        }
        else { navigation.remove(id) }
    }
}

private extension View {
    @MainActor @ViewBuilder func secretControlFocus(_ navigation: CaptureKeyboardNavigation?, _ id: String,
                                                    order: Int, action: @escaping () -> Void) -> some View {
        if navigation != nil { captureFocus(id, order: order, action: action) }
        else { self.focusable() }
    }

    /// The panel owns Tab; the main window retains its row-to-row cell shortcuts.
    @ViewBuilder func secretCellNavigation(_ mode: SecretEditorView.KeyboardMode,
                                          action: @escaping (KeyPress) -> KeyPress.Result) -> some View {
        switch mode {
        case .cellNavigation:
            onKeyPress(.tab, phases: .down) { press in
                guard press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
                return action(press)
            }
        case .panel: self
        }
    }
}
#endif
