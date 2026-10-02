#if os(macOS)
import SwiftUI
import AppKit
import WorkLogCore

/// Shares only the authenticated vault editor; the panel owns its Tab/Option+Tab routing.
@MainActor struct SecretEditorView: View {
    enum KeyboardMode { case cellNavigation, panel }

    @Bindable var model: SecretsModel
    let host: SecretEditorHost
    let keyboardMode: KeyboardMode
    let onSave: () -> Bool
    var titleFocusRequest = 0
    var onMoveToTrash: (() -> Void)? = nil
    @FocusState private var titleFocused: Bool
    private enum CellFocus: Hashable { case key(String), value(String) }
    @FocusState private var cellFocused: CellFocus?

    init(model: SecretsModel, host: SecretEditorHost, keyboardMode: KeyboardMode,
         onSave: @escaping () -> Bool, titleFocusRequest: Int = 0,
         onMoveToTrash: (() -> Void)? = nil) {
        self.model = model
        self.host = host
        self.keyboardMode = keyboardMode
        self.onSave = onSave
        self.titleFocusRequest = titleFocusRequest
        self.onMoveToTrash = onMoveToTrash
    }

    private var canEdit: Bool {
        !model.isLocked && model.canEdit(from: host) && !model.hasRecoverableDraft
    }
    private var keyboardHint: String {
        let navigation = keyboardMode == .panel ? "Tab 탭 전환 · Option+Tab 필드 이동" : "Tab 셀 이동"
        return "\(navigation) · ⌘Return 저장. 행의 복사 버튼으로 값을 복사하세요. key·값의 앞뒤 공백은 저장 시 제거합니다."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.canEdit(from: host) {
                Text("다른 화면에서 편집 중입니다").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                TextField("제목 (비우면 임시 제목)", text: $model.title)
                    .accessibilityLabel("Secret 제목").focused($titleFocused)
                TextField("그룹 (선택 사항)", text: $model.groupName).accessibilityLabel("그룹 (선택 사항)")
                HStack {
                    Text("key / value").font(.headline)
                    Spacer()
                    Toggle("값 표시", isOn: $model.showsValues).toggleStyle(.checkbox)
                }
                Text(keyboardHint)
                    .font(.callout).foregroundStyle(.secondary)
                if model.rows.isEmpty { Text("‘행 추가’ 또는 붙여넣기로 값을 입력하세요.").foregroundStyle(.secondary) }
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach($model.rows) { $row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .top, spacing: 8) {
                                TextField("key", text: $row.key).frame(minWidth: 90, idealWidth: 140, maxWidth: 180)
                                    .accessibilityLabel("행 \(row.order + 1) key")
                                    .focused($cellFocused, equals: .key(row.id))
                                    .secretCellNavigation(keyboardMode) { moveCell(from: .key(row.id), backwards: $0.modifiers.contains(.shift)) }
                                if model.showsValues && model.canEdit(from: host) {
                                    TextField("값", text: $row.value, axis: .vertical).lineLimit(1...6)
                                        .accessibilityLabel("행 \(row.order + 1) 값")
                                        .focused($cellFocused, equals: .value(row.id))
                                        .secretCellNavigation(keyboardMode) { moveCell(from: .value(row.id), backwards: $0.modifiers.contains(.shift)) }
                                } else {
                                    SecureField("값", text: $row.value).accessibilityLabel("행 \(row.order + 1) 가려진 값")
                                        .focused($cellFocused, equals: .value(row.id))
                                        .secretCellNavigation(keyboardMode) { moveCell(from: .value(row.id), backwards: $0.modifiers.contains(.shift)) }
                                }
                                Button("복사") { model.copyRow(row) }
                                Button { model.removeRow(row.id) } label: { Image(systemName: "minus.circle") }
                                    .accessibilityLabel("행 \(row.order + 1) 삭제")
                            }
                            if model.duplicateRowIds.contains(row.id) {
                                Label("중복 key · 수정 후 저장하세요", systemImage: "exclamationmark.circle")
                                    .font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
                Button("행 추가", systemImage: "plus") { model.addRow() }
                Divider()
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
                                            .accessibilityLabel("미리보기 행 \(index + 1) 가려진 값")
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
                HStack {
                    Button("저장") { save() }.keyboardShortcut(.return, modifiers: .command)
                    if model.selectedId != nil, let onMoveToTrash {
                        Button("휴지통으로 이동…", role: .destructive, action: onMoveToTrash)
                    }
                }
            }.disabled(!canEdit)
        }
        .textFieldStyle(.roundedBorder)
        .onAppear { if host == .capture && canEdit { titleFocused = true } }
        .onChange(of: titleFocusRequest) { _, _ in if canEdit { titleFocused = true } }
    }

    private func save() {
        guard canEdit, !hasMarkedText else { return }
        if !onSave(), let row = model.rows.first(where: { model.duplicateRowIds.contains($0.id) }) {
            cellFocused = .key(row.id)
        }
    }
    private var hasMarkedText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
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
    /// Panel mode installs no Tab handler, so the panel can route it exactly once.
    @ViewBuilder func secretCellNavigation(_ mode: SecretEditorView.KeyboardMode,
                                          action: @escaping (KeyPress) -> KeyPress.Result) -> some View {
        switch mode {
        case .cellNavigation: onKeyPress(.tab, phases: .down, action: action)
        case .panel: self
        }
    }
}
#endif
