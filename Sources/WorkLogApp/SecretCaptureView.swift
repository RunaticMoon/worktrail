#if os(macOS)
import SwiftUI
import AppKit
import WorkLogCore

/// The quick-input Secret tab uses the same vault model as the main window.
/// Mount only while this tab and the panel are visible; NSPanel.orderOut alone is not disappearance.
@MainActor struct SecretCaptureView: View {
    @Bindable var model: SecretsModel
    let onSaved: () -> Void
    let onCancel: () -> Void
    private enum Phase { case waiting, draftChoice, editing }
    @State private var phase: Phase = .waiting
    @State private var isActive = false
    @State private var confirmsDiscard = false
    @State private var confirmsCancel = false

    init(model: SecretsModel, onSaved: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.model = model
        self.onSaved = onSaved
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StatusBadge(label: model.isLocked ? "잠김" : "잠금 해제됨",
                            systemImage: model.isLocked ? "lock.fill" : "lock.open", tone: .neutral)
                Spacer()
                if model.isUnlocking { ProgressView().controlSize(.small) }
                if !model.isLocked {
                    Button("지금 잠금") { model.lock() }.worklogHelp("Secret 보관함 잠금")
                }
                Button("닫기") { leaveEditor(); onCancel() }.worklogHelp("초안을 보존하고 닫기", keys: "Esc")
            }
            if let message = model.message { InlineNotice(message: message) }
            if model.isLocked {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Secret 입력은 기기 인증 후 사용할 수 있습니다.").foregroundStyle(.secondary)
                    Button("잠금 해제") {
                        Task {
                            await model.unlock()
                            prepareEditor()
                        }
                    }.disabled(model.isUnlocking).worklogHelp("기기 인증으로 Secret 잠금 해제")
                }
            } else if !model.canEdit(from: .capture) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("메인 창에서 편집 중입니다.")
                    Text("메인 창의 Secret 화면을 나간 뒤 다시 시도하세요. 초안은 보존됩니다.")
                        .foregroundStyle(.secondary)
                    Button("다시 시도") { prepareEditor() }
                }
            } else if phase == .draftChoice {
                VStack(alignment: .leading, spacing: 12) {
                    Text("저장하지 않은 Secret 초안이 있습니다.")
                    Text("이어서 편집하거나 초안을 버리고 새 항목을 입력하세요.").foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Button("이어서 편집") { continueDraft() }
                            Button("초안 버리고 새 항목", role: .destructive) { confirmsDiscard = true }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Button("이어서 편집") { continueDraft() }
                            Button("초안 버리고 새 항목", role: .destructive) { confirmsDiscard = true }
                        }
                    }
                }
            } else if phase == .editing {
                ScrollView {
                    SecretEditorView(model: model, host: .capture, keyboardMode: .panel, onSave: save,
                                     onCancel: requestCancel)
                        .padding(12)
                }
            }
            if phase != .editing || model.isLocked || !model.canEdit(from: .capture) {
                Spacer(minLength: 0)
            }
            Text("⌘1–3 유형 · ⌃Tab 유형 순환 · Tab 이동 · ⌘Return 저장 · Esc 초안 보존")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            isActive = true
            model.tick()
            prepareEditor()
        }
        .onChange(of: model.isLocked) { _, locked in
            if locked { phase = .waiting; confirmsDiscard = false; confirmsCancel = false }
            else { prepareEditor() }
        }
        .onChange(of: model.editorOwner) { _, owner in
            if owner != .capture { phase = .waiting; confirmsDiscard = false; confirmsCancel = false }
        }
        .onDisappear { leaveEditor() }
        .alert("암호화 초안을 버릴까요?", isPresented: $confirmsDiscard) {
            Button("취소", role: .cancel) {}
            Button("초안 버리고 새 항목", role: .destructive) { discardAndBeginNew() }
        } message: {
            Text("저장하지 않은 제목·그룹·행을 복구할 수 없게 됩니다.")
        }
        .alert("입력한 변경을 버릴까요?", isPresented: $confirmsCancel) {
            Button("계속 편집", role: .cancel) {}
            Button("변경 버리고 닫기", role: .destructive) { cancelEditing() }
        } message: { Text("저장하지 않은 제목·그룹·행을 버립니다. 초안 보존은 ‘닫기’ 또는 Esc를 사용하세요.") }
    }

    private func prepareEditor() {
        guard isActive, !model.isLocked, !model.isUnlocking, phase == .waiting,
              model.acquireEditor(.capture) else { return }
        model.showsValues = false
        if model.hasUnsavedDraft || model.hasRecoverableDraft {
            phase = .draftChoice
        } else {
            model.beginNew()
            phase = .editing
        }
    }

    private func continueDraft() {
        guard isActive, !model.isLocked, model.canEdit(from: .capture) else { return }
        if model.hasRecoverableDraft { model.recoverDraft() }
        guard !model.hasRecoverableDraft else { return }
        model.showsValues = false
        if !model.isEditing { model.beginEditing() }
        phase = .editing
    }

    private func discardAndBeginNew() {
        guard isActive, !model.isLocked, model.canEdit(from: .capture) else { return }
        model.discardDraft()
        guard !model.hasRecoverableDraft else { return }
        model.beginNew()
        phase = .editing
    }

    private func save() -> Bool {
        guard isActive, phase == .editing, !model.isLocked,
              model.canEdit(from: .capture), !model.hasRecoverableDraft, model.save() else { return false }
        leaveEditor()
        onSaved()
        return true
    }

    private func leaveEditor() {
        isActive = false
        if model.canEdit(from: .capture) {
            if !model.isLocked && model.hasUnsavedDraft && !model.hasRecoverableDraft {
                model.preserveDraft()
            }
            model.showsValues = false
        }
        model.releaseEditor(.capture)
        phase = .waiting
        confirmsDiscard = false
        confirmsCancel = false
    }

    private func requestCancel() {
        guard isActive, !model.isLocked, model.canEdit(from: .capture),
              (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return }
        if model.hasUnsavedDraft { confirmsCancel = true } else { cancelEditing() }
    }

    private func cancelEditing() {
        guard isActive, !model.isLocked, model.canEdit(from: .capture) else { return }
        model.cancelEditing()
        model.discardDraft()
        leaveEditor()
        onCancel()
    }
}
#endif
