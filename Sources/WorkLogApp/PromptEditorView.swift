#if os(macOS)
import SwiftUI
import WorkLogCore

/// 프롬프트는 설정 초안과 독립적으로 저장한다. 저장소와 버전 관리는 모델에 위임한다.
@MainActor
struct PromptEditorView: View {
    @Bindable var prompts: PromptSettingsModel
    let job: AIJobType

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPurpose: TemplatePurpose
    @State private var pendingAction: PendingAction?
    @FocusState private var errorFocused: Bool
    @State private var retryAction: RetryAction = .load
    private enum RetryAction { case load, save, restore }

    init(prompts: PromptSettingsModel, job: AIJobType) {
        self.prompts = prompts
        self.job = job
        _selectedPurpose = State(initialValue: PromptCatalog.purposes(for: job).first ?? .submissionWeekly)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                ScreenHeader(title: "양식·프롬프트 편집", purpose: PromptCatalog.title(for: selectedPurpose))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { versionSummary }
                    VStack(alignment: .leading, spacing: 8) { versionSummary }
                }
            }.padding(12)
            Divider()

            Form {
                if let error = prompts.errorMessage {
                    Section("프롬프트를 확인하세요") {
                        RecoveryNotice(failed: error, preserved: preservedMessage,
                                       retryTitle: "다시 시도", retry: { retry() })
                    }.focusable().focused($errorFocused)
                }
                if let message = prompts.message {
                    Section {
                        Label(message, systemImage: "checkmark.circle")
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                Section {
                    if job == .performanceReport {
                        Picker("편집 대상", selection: Binding(
                            get: { selectedPurpose }, set: { requestPurposeChange($0) })) {
                            Text("일일 (Daily)").tag(TemplatePurpose.performanceDaily)
                            Text("주·월·분기·연간 (Periodic)").tag(TemplatePurpose.performancePeriodic)
                        }.pickerStyle(.segmented)
                    }
                    if let note = PromptCatalog.usageNote(for: job) {
                        Text(note).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("앱 보호 규칙 → 이 작업 지침 → 선택한 스킬 보충 지침 순으로 적용됩니다.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("프롬프트 저장은 일반 '설정 저장'과 독립적이며, 이 창에서 저장하면 바로 적용됩니다.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    DisclosureGroup("공통 보호 지침(수정 불가)") {
                        readOnlyText(prompts.protectedPreamble)
                    }
                }
                Section("지침") {
                    TextEditor(text: $prompts.instructions)
                        .font(.body)
                        .frame(minHeight: 180)
                        .accessibilityLabel("\(PromptCatalog.title(for: selectedPurpose)) 지침")
                        .disabled(prompts.activeVersionNumber == nil)
                }
                Section("출력 예시") {
                    TextEditor(text: $prompts.outputExample)
                        .font(.body)
                        .frame(minHeight: 120)
                        .accessibilityLabel("\(PromptCatalog.title(for: selectedPurpose)) 출력 예시")
                        .accessibilityHint("출력 예시는 비워 둘 수 있습니다.")
                        .disabled(prompts.activeVersionNumber == nil)
                }
                Section {
                    DisclosureGroup("기본 프롬프트 보기") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("기본 지침").font(.headline)
                            readOnlyText(prompts.builtInInstructions)
                            Text("기본 출력 예시").font(.headline)
                            readOnlyText(prompts.builtInOutputExample)
                        }
                    }
                }
            }.formStyle(.grouped)
            Divider()
            HStack(spacing: 12) {
                Button("기본값으로 복원") { pendingAction = .restore }
                    .disabled(prompts.activeVersionNumber == nil || (prompts.isBuiltInActive && !prompts.hasChanges))
                    .worklogHelp("기본 프롬프트를 새 버전으로 저장 · 이전 버전 보존")
                Button("변경 취소") { prompts.discardChanges() }.disabled(!prompts.hasChanges)
                    .worklogHelp("저장하지 않은 프롬프트 변경 되돌리기")
                Spacer(minLength: 8)
                Button("닫기") { requestClose() }.keyboardShortcut(.cancelAction)
                    .worklogHelp("양식·프롬프트 편집 닫기", keys: "Esc")
                Button { retryAction = .save; prompts.save() } label: { ShortcutLabel(title: "저장", keys: "⌘S") }
                    .keyboardShortcut("s", modifiers: .command)
                    .worklogHelp("프롬프트를 새 버전으로 저장 · 바로 적용", keys: "⌘S")
                    .disabled(prompts.activeVersionNumber == nil || !prompts.hasChanges)
            }.padding(12)
        }
        .frame(minWidth: 560, idealWidth: 720, maxWidth: 900,
               minHeight: 420, idealHeight: 640, maxHeight: 800)
        .interactiveDismissDisabled(prompts.hasChanges)
        .onAppear { prompts.load(purpose: selectedPurpose) }
        .onDisappear { prompts.discardChanges() }
        .onChange(of: prompts.errorMessage) { _, error in errorFocused = error != nil }
        .alert(alertTitle, isPresented: Binding(
            get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })) {
                switch pendingAction {
                case .restore:
                    Button("기본값으로 복원") { retryAction = .restore; prompts.restoreBuiltInDefault() }
                case .close:
                    Button("변경 버리고 닫기", role: .destructive) {
                        prompts.discardChanges()
                        dismiss()
                    }
                case .switchPurpose(let purpose):
                    Button("변경 버리고 전환", role: .destructive) {
                        prompts.discardChanges()
                        load(purpose)
                    }
                case nil:
                    EmptyView()
                }
                Button("취소", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
    }

    @ViewBuilder private var versionSummary: some View {
        if let version = prompts.activeVersionNumber {
            Text("활성 버전 \(version)")
            if prompts.isBuiltInActive {
                StatusBadge(label: "기본값 사용 중", systemImage: "doc.text", tone: .neutral)
            } else {
                StatusBadge(label: "사용자 수정", systemImage: "pencil.circle", tone: .info)
            }
        } else {
            Text("활성 버전 없음").foregroundStyle(.secondary)
        }
        if prompts.hasChanges { StatusBadge(label: "저장하지 않은 변경", systemImage: "pencil.circle", tone: .warning) }
    }
    private var preservedMessage: String {
        if case .load = retryAction { return "저장한 이전 양식 버전은 그대로 보존됩니다." }
        return "이전 양식 버전과 입력한 내용은 그대로 보존됩니다."
    }

    private func readOnlyText(_ text: String) -> some View {
        Text(text.isEmpty ? "내용이 없습니다." : text)
            .font(.body).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func requestPurposeChange(_ purpose: TemplatePurpose) {
        guard purpose != selectedPurpose else { return }
        if prompts.hasChanges { pendingAction = .switchPurpose(purpose) }
        else { load(purpose) }
    }

    private func load(_ purpose: TemplatePurpose) {
        selectedPurpose = purpose
        retryAction = .load
        prompts.load(purpose: purpose)
    }

    private func retry() {
        switch retryAction {
        case .load: prompts.load(purpose: selectedPurpose)
        case .save: prompts.save()
        case .restore: prompts.restoreBuiltInDefault()
        }
    }

    private func requestClose() {
        if prompts.hasChanges { pendingAction = .close }
        else { dismiss() }
    }

    private var alertTitle: String {
        switch pendingAction {
        case .restore: return "기본값으로 복원할까요?"
        case .close: return "저장하지 않은 변경을 버리고 닫을까요?"
        case .switchPurpose: return "저장하지 않은 변경을 버리고 전환할까요?"
        case nil: return ""
        }
    }

    private var alertMessage: String {
        switch pendingAction {
        case .restore: return "기본 프롬프트를 새 버전으로 저장합니다. 이전 버전은 보존됩니다."
        case .close, .switchPurpose: return "편집한 내용은 저장되지 않습니다. 계속 편집하려면 취소를 누르세요."
        case nil: return ""
        }
    }

    private enum PendingAction {
        case restore
        case close
        case switchPurpose(TemplatePurpose)
    }
}
#endif
