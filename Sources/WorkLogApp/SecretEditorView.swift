#if os(macOS)
import SwiftUI
import AppKit
import WorkLogCore

/// Shares only the authenticated vault editor; native Tab navigation stays within fields.
@MainActor struct SecretEditorView: View {
    enum KeyboardMode { case cellNavigation, panel }

    @Bindable var model: SecretsModel
    let host: SecretEditorHost
    let keyboardMode: KeyboardMode
    let onSave: () -> Bool
    var titleFocusRequest = 0
    var onMoveToTrash: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    @FocusState private var titleFocused: Bool
    private enum CellFocus: Hashable { case key(String), value(String) }
    @FocusState private var cellFocused: CellFocus?

    init(model: SecretsModel, host: SecretEditorHost, keyboardMode: KeyboardMode,
         onSave: @escaping () -> Bool, titleFocusRequest: Int = 0,
         onMoveToTrash: (() -> Void)? = nil, onCancel: (() -> Void)? = nil) {
        self.model = model
        self.host = host
        self.keyboardMode = keyboardMode
        self.onSave = onSave
        self.titleFocusRequest = titleFocusRequest
        self.onMoveToTrash = onMoveToTrash
        self.onCancel = onCancel
    }

    private var canEdit: Bool {
        !model.isLocked && model.isEditing && model.canEdit(from: host) && !model.hasRecoverableDraft
    }
    private var keyboardHint: String {
        let navigation = keyboardMode == .panel ? "Tab 필드 이동 · ⌘1–3 유형 · ⌃Tab 유형 순환" : "Tab 셀 이동"
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
                        .onChange(of: cellFocused) { _, focus in
                            switch focus {
                            case .key(let id), .value(let id): proxy.scrollTo(id)
                            case nil: break
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
        }
        .onAppear { if host == .capture && canEdit { titleFocused = true } }
        .onChange(of: titleFocusRequest) { _, _ in if canEdit { titleFocused = true } }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Secret 편집", systemImage: "pencil").font(.headline)
                Spacer(minLength: 8)
                SecretValueVisibilityButton(model: model, host: host)
            }
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("제목") {
                    TextField("비우면 임시 제목", text: $model.title)
                        .accessibilityLabel("Secret 제목").focused($titleFocused)
                }
                LabeledContent("그룹") {
                    TextField("선택 사항", text: $model.groupName).accessibilityLabel("그룹 (선택 사항)")
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
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach($model.rows) { $row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 8) {
                            TextField("key", text: $row.key).frame(width: 132)
                                .accessibilityLabel("행 \(row.order + 1) key")
                                .focused($cellFocused, equals: .key(row.id))
                                .secretCellNavigation(keyboardMode) { moveCell(from: .key(row.id), backwards: $0.modifiers.contains(.shift)) }
                            if model.showsValues && model.canEdit(from: host) {
                                TextField("값", text: $row.value, axis: .vertical).lineLimit(1...6)
                                    .accessibilityLabel("행 \(row.order + 1) 값")
                                    .focused($cellFocused, equals: .value(row.id))
                                    .secretCellNavigation(keyboardMode) { moveCell(from: .value(row.id), backwards: $0.modifiers.contains(.shift)) }
                            } else {
                                SecureField("값", text: $row.value).accessibilityLabel("가려진 값")
                                    .accessibilityHint("행 \(row.order + 1) 값 편집")
                                    .focused($cellFocused, equals: .value(row.id))
                                    .secretCellNavigation(keyboardMode) { moveCell(from: .value(row.id), backwards: $0.modifiers.contains(.shift)) }
                            }
                            Button { model.removeRow(row.id) } label: { Image(systemName: "minus.circle") }
                                .accessibilityLabel("행 \(row.order + 1) 삭제")
                                .worklogHelp("행 삭제 · 저장하면 이전 버전에서 복원 가능")
                        }.frame(minHeight: 34)
                        if model.duplicateRowIds.contains(row.id) {
                            Label("중복 key · 수정 후 저장하세요", systemImage: "exclamationmark.circle")
                                .font(.callout).foregroundStyle(WorkLogTheme.text)
                        }
                        if model.maskedRowIds.contains(row.id) {
                            Label("가림 문자만 있는 값은 저장하지 않습니다 · 실제 값을 입력하세요", systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(WorkLogTheme.text)
                        }
                    }.padding(.vertical, 3).id(row.id)
                    Divider()
                }
            }
            Button("행 추가", systemImage: "plus") {
                guard canEdit, !hasMarkedText else { return }
                model.addRow()
                if let row = model.rows.last { cellFocused = .key(row.id) }
            }.worklogHelp("표에 새 행 추가")
        }
    }

    private var pasteControls: some View {
        DisclosureGroup("여러 줄 붙여넣기") {
            VStack(alignment: .leading, spacing: 8) {
                Text("A=B 또는 A : B 형식의 텍스트를 붙여 넣으세요. 첫 구분자 뒤는 값 전체로 보존합니다.").foregroundStyle(.secondary)
                if model.showsValues && model.canEdit(from: host) {
                    TextEditor(text: $model.pasteText).frame(height: 90).accessibilityLabel("붙여넣을 텍스트")
                } else {
                    SecureField("여러 줄 텍스트 붙여넣기", text: $model.pasteText)
                        .accessibilityLabel("붙여넣을 가려진 텍스트")
                }
                HStack {
                    Button("클립보드에서 분리 미리보기") {
                        // Explicit native paste input; retain every newline without a single-line field conversion.
                        guard canEdit, let text = NSPasteboard.general.string(forType: .string) else { return }
                        model.acceptPaste(text)
                    }
                    Button("입력 분리 미리보기") { model.makePastePreview() }.disabled(model.pasteText.isEmpty)
                }
                ForEach(model.preview.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("자동 key", text: $model.preview[index].input.key).frame(maxWidth: 180)
                                .accessibilityLabel("미리보기 행 \(index + 1) key")
                            if model.showsValues && model.canEdit(from: host) {
                                TextField("값", text: $model.preview[index].input.value, axis: .vertical)
                                    .accessibilityLabel("미리보기 행 \(index + 1) 값")
                            } else {
                                SecureField("가려진 값", text: $model.preview[index].input.value)
                                    .accessibilityLabel("가려진 값")
                                    .accessibilityHint("미리보기 행 \(index + 1) 값 편집")
                            }
                        }
                        if model.preview[index].ambiguous {
                            Label("구분이 모호해 원문 전체를 값으로 보존했습니다. 확인하세요.", systemImage: "exclamationmark.circle")
                                .font(.caption)
                        }
                    }
                }
                if !model.preview.isEmpty {
                    HStack {
                        Button("표에 행 추가") { model.appendPreview() }
                        Button("붙여넣기 취소") { model.cancelPreview() }
                    }
                }
            }.padding(.top, 8)
        }
    }

    @ViewBuilder private var editorActions: some View {
        Button { save() } label: {
            ShortcutLabel(title: "저장", keys: keyboardMode == .panel ? "⌘Return" : "⌘S")
        }
        .keyboardShortcut(keyboardMode == .panel ? .return : KeyEquivalent("s"), modifiers: .command)
        .buttonStyle(.borderedProminent)
        .worklogHelp("Secret 저장", keys: keyboardMode == .panel ? "⌘Return" : "⌘S / ⌘Return")
        if let onCancel {
            Button("취소") {
                guard canEdit, !hasMarkedText else { return }
                onCancel()
            }.worklogHelp("Secret 편집 취소")
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
                cellFocused = .value(row.id)
            } else if let row = model.rows.first(where: { model.duplicateRowIds.contains($0.id) }) {
                cellFocused = .key(row.id)
            }
        }
    }
    private var hasMarkedText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }
    private func moveCell(from cell: CellFocus, backwards: Bool) -> KeyPress.Result {
        guard canEdit, !hasMarkedText else { return .ignored }
        let cells = model.rows.flatMap { [CellFocus.key($0.id), .value($0.id)] }
        guard let index = cells.firstIndex(of: cell) else { return .ignored }
        let next = index + (backwards ? -1 : 1)
        guard cells.indices.contains(next) else { return .ignored }
        cellFocused = cells[next]
        return .handled
    }
}

private extension View {
    /// Panel mode leaves Tab to native field navigation; Control+Tab belongs to the panel.
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
