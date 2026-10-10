#if os(macOS)
import AppKit
import SwiftUI
import WorkLogCore

/// Read mode has actions, never text-field bindings or value-bearing tooltips.
@MainActor struct SecretViewerTable: View {
    @Bindable var model: SecretsModel
    var host: SecretEditorHost = .main
    private enum Control: Hashable { case row(String), copy(String) }
    @FocusState private var focusedControl: Control?

    private var canRead: Bool {
        !model.isLocked && !model.isEditing && model.canEdit(from: host) && !model.hasRecoverableDraft
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("key").frame(width: 132, alignment: .leading)
                    Text("값").frame(maxWidth: .infinity, alignment: .leading)
                    Text("복사").frame(width: 48)
                }
                .font(.callout.weight(.medium)).foregroundStyle(WorkLogTheme.muted)
                .padding(.horizontal, 8).accessibilityHidden(true)
                Divider()
                if model.rows.isEmpty {
                    StateView(kind: .empty, title: "저장된 행이 없습니다", detail: "‘편집’을 눌러 행을 추가하세요.")
                }
                LazyVStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        HStack(spacing: 8) {
                            Button { copy(row) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Text(row.key)
                                        .frame(width: 132, alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Group {
                                        if model.showsValues && canRead {
                                            Text(row.value).textSelection(.disabled)
                                                .fixedSize(horizontal: false, vertical: true)
                                        } else { MaskedValueText() }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(8).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focusable()
                            .focused($focusedControl, equals: .row(row.id))
                            .accessibilityElement(children: .ignore)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(Text("\(row.key), \(model.showsValues && canRead ? "값 표시됨" : "값 가려짐"), Return으로 복사"))
                            .worklogHelp("값 복사", keys: "Return / ⌘C")
                            .onKeyPress(.return, phases: .down) { press in
                                guard accepts(press), canRead else { return .ignored }
                                focus(row.id)
                                model.copyFocusedRow()
                                return .handled
                            }
                            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat], action: move)
                            Button("복사") { copy(row) }
                                .buttonStyle(.bordered)
                                .accessibilityLabel(Text("\(row.key) 값 복사"))
                                .worklogHelp("값 복사", keys: "Return / ⌘C")
                                .focused($focusedControl, equals: .copy(row.id))
                                .onKeyPress(.return, phases: .down) { press in
                                    guard accepts(press), canRead else { return .ignored }
                                    copy(row)
                                    return .handled
                                }
                                .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat], action: move)
                        }
                        .padding(.trailing, 8)
                        .frame(minHeight: 36)
                        .background(model.focusedRowId == row.id ? WorkLogTheme.accentSoft : Color.clear)
                        .overlay(alignment: .leading) {
                            if model.focusedRowId == row.id {
                                Rectangle().fill(WorkLogTheme.accent).frame(width: 2).allowsHitTesting(false)
                            }
                        }
                        .id(row.id)
                        Divider()
                    }
                }
                Text("클릭·Return·⌘C 복사 · ↑↓ 선택 이동")
                    .font(.callout).foregroundStyle(WorkLogTheme.muted)
            }
            .disabled(!canRead)
            .onKeyPress(characters: CharacterSet(charactersIn: "c"), phases: .down) { press in
                guard press.modifiers == .command, focusedControl != nil, canRead,
                      (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return .ignored }
                model.copyFocusedRow()
                return .handled
            }
            .onChange(of: focusedControl) { _, control in
                switch control {
                case .row(let id), .copy(let id): focus(id)
                case nil: break
                }
            }
            .onChange(of: model.focusedRowId) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func accepts(_ press: KeyPress) -> Bool {
        press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty &&
            (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true
    }

    private func focus(_ id: String) {
        guard canRead, let target = model.rows.firstIndex(where: { $0.id == id }) else { return }
        if let current = model.focusedRowId.flatMap({ id in model.rows.firstIndex { $0.id == id } }) {
            model.moveFocus(by: target - current)
        } else { model.moveFocus(by: target + 1) }
    }

    private func copy(_ row: SecretRow) {
        guard canRead else { return }
        focusedControl = .row(row.id)
        focus(row.id)
        model.copyRow(row)
    }

    private func move(_ press: KeyPress) -> KeyPress.Result {
        guard accepts(press), canRead, !model.rows.isEmpty else { return .ignored }
        model.moveFocus(by: press.key == .upArrow ? -1 : 1)
        if let id = model.focusedRowId { focusedControl = .row(id) }
        return .handled
    }
}

/// One explicit reveal control shared by viewing, editing, and revision previews.
@MainActor struct SecretValueVisibilityButton: View {
    @Bindable var model: SecretsModel
    var host: SecretEditorHost = .main

    var body: some View {
        Button {
            guard !model.isLocked, model.canEdit(from: host) else { return }
            model.showsValues.toggle()
        } label: {
            Label(model.showsValues ? "값 가리기" : "값 보기", systemImage: model.showsValues ? "eye.slash" : "eye")
        }
        .buttonStyle(.bordered)
        .worklogHelp(model.showsValues ? "값 가리기" : "값 보기")
        .disabled(model.isLocked || !model.canEdit(from: host) || model.hasRecoverableDraft)
    }
}
#endif
