#if os(macOS)
import SwiftUI
import WorkLogCore

@MainActor struct MemoDetailScreen: View {
    @Bindable var model: MemoDetailModel
    let onClose: () -> Void
    var onSaveBody: ((String) throws -> Void)? = nil
    var initiallyEditing = false
    @State private var isEditing = false
    @State private var draft = ""
    @State private var originalBody = ""
    @State private var saveError: String?
    @State private var showsUnsavedChanges = false
    @FocusState private var editorFocused: Bool
    @FocusState private var editButtonFocused: Bool

    private var hasChanges: Bool { isEditing && draft != originalBody }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isEditing ? "메모 편집" : "메모와 업무 연결").font(.title2)
                Spacer()
                if onSaveBody != nil, model.memo != nil {
                    if isEditing {
                        Button("저장 ⌘S") { save() }
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !hasChanges)
                            .focusable()
                    } else {
                        Button("편집 ⌘E") { beginEditing() }
                            .focusable().focused($editButtonFocused)
                    }
                }
                Button("닫기") { requestClose() }.keyboardShortcut(.cancelAction).focusable()
            }
            if let saveError { InlineNotice(message: saveError) }
            if isEditing {
                TextEditor(text: $draft)
                    .font(.body).focused($editorFocused)
                    .accessibilityLabel("메모 본문 편집")
                    .frame(minHeight: 240)
                    .padding(8)
                    .worklogCard(padding: 0)
                Text("Return 줄바꿈 · ⌘S 또는 ⌘Return 저장 · Esc 닫기")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let memo = model.memo {
                        Text(memo.workDate.iso).font(.caption).foregroundStyle(.secondary)
                        Text(memo.body).textSelection(.enabled)
                    }
                    Text("제안은 승인 후 연결됩니다. 메모 원문과 업무 상태는 유지됩니다.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("AI 업무 연결 제안") { Task { await model.suggest() } }
                        .disabled(!model.isAIAvailable || model.isSuggesting)
                    if !model.isAIAvailable {
                        StateView(kind: .aiUnavailable, title: "AI 업무 연결 제안은 연결 후 사용할 수 있습니다",
                                  detail: "메모 원문과 기존 업무 연결은 계속 확인할 수 있습니다.")
                    }
                    if model.isSuggesting { ProgressView("연결 후보 찾는 중…") }
                    if let message = model.message { InlineNotice(message: message) }
                    if model.links.isEmpty {
                        StateView(kind: .empty, title: "연결 제안 없음",
                                  detail: "메모 원문과 업무 상태는 유지됩니다. AI가 연결되어 있으면 제안을 요청할 수 있습니다.")
                    }
                    ForEach(model.links) { link in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.tasks.first { $0.id == link.taskId }?.title ?? "찾을 수 없는 업무").font(.headline)
                            Text(link.reason)
                            Text(label(link.status)).font(.callout)
                            if link.status != .accepted && link.status != .rejected {
                                HStack {
                                    Button("승인") { model.decide(linkId: link.id, status: .accepted) }
                                    Button("거절") { model.decide(linkId: link.id, status: .rejected) }
                                    Button("나중에") { model.decide(linkId: link.id, status: .deferred) }
                                }
                            }
                        }
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            }
        }.padding(WorkLogTheme.contentInset).frame(minWidth: 540, minHeight: 440)
        .interactiveDismissDisabled(hasChanges)
        .background(WorkLogKeyHandler { event in
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard modifiers == .command else { return false }
            if event.keyCode == 13 {
                if !event.isARepeat { requestClose() }
                return true
            }
            if event.keyCode == 14, onSaveBody != nil {
                if !event.isARepeat { beginEditing() }
                return true
            }
            if isEditing, event.keyCode == 1 || event.keyCode == 36 || event.keyCode == 76 {
                if !event.isARepeat { save() }
                return true
            }
            return false
        })
        .onAppear {
            if initiallyEditing { beginEditing() }
            else if onSaveBody != nil { editButtonFocused = true }
        }
        .alert("메모 수정을 저장할까요?", isPresented: $showsUnsavedChanges) {
            Button("저장하고 닫기") { if save() { onClose() } }.keyboardShortcut(.defaultAction)
            Button("수정 버리고 닫기", role: .destructive) { onClose() }
                .keyboardShortcut("d", modifiers: .command)
            Button("계속 편집", role: .cancel) { editorFocused = true }
        } message: {
            Text("저장하지 않은 수정이 있습니다. 기존 원문은 저장하기 전까지 유지됩니다.")
        }
    }

    private func beginEditing() {
        guard !worklogHasMarkedText, onSaveBody != nil, let memo = model.memo else { return }
        if !isEditing { draft = memo.body; originalBody = memo.body; saveError = nil }
        isEditing = true
        editorFocused = true
    }

    @discardableResult private func save() -> Bool {
        guard !worklogHasMarkedText, let onSaveBody, isEditing else { return false }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            saveError = "메모 내용을 입력하세요."; editorFocused = true; return false
        }
        do {
            if hasChanges { try onSaveBody(draft) }
            isEditing = false; saveError = nil
            editButtonFocused = true
            return true
        } catch {
            saveError = "메모를 저장하지 못했습니다. 수정 내용은 유지됩니다. 다시 저장하세요."
            editorFocused = true
            return false
        }
    }

    private func requestClose() {
        guard !worklogHasMarkedText else { return }
        if hasChanges { showsUnsavedChanges = true }
        else { onClose() }
    }
    private func label(_ status: MemoTaskLinkStatus) -> String {
        switch status { case .proposed: return "검토 대기"; case .accepted: return "연결 승인"; case .rejected: return "연결 거절"; case .deferred: return "나중에 검토" }
    }
}
#endif
