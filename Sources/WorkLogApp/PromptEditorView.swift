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

    init(prompts: PromptSettingsModel, job: AIJobType) {
        self.prompts = prompts
        self.job = job
        _selectedPurpose = State(initialValue: PromptCatalog.purposes(for: job).first ?? .submissionWeekly)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("프롬프트 편집").font(.title2).fontWeight(.semibold)
                Text(PromptCatalog.title(for: selectedPurpose)).font(.headline)
                HStack(spacing: 12) {
                    if let version = prompts.activeVersionNumber {
                        Text("활성 버전 \(version)")
                        Text(prompts.isBuiltInActive ? "기본값 사용 중" : "사용자 수정")
                            .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                    } else {
                        Text("활성 버전 없음").foregroundStyle(.secondary)
                    }
                    if prompts.hasChanges { Text("저장하지 않은 변경").font(.caption).foregroundStyle(.secondary) }
                }
            }.padding(12)
            Divider()

            Form {
                if let error = prompts.errorMessage {
                    Section("프롬프트를 확인하세요") {
                        InlineNotice(message: error).accessibilityLabel("프롬프트 오류: \(error)")
                        if prompts.activeVersionNumber == nil {
                            Button("다시 불러오기") { prompts.load(purpose: selectedPurpose) }
                        }
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
                Button("변경 취소") { prompts.discardChanges() }.disabled(!prompts.hasChanges)
                Spacer(minLength: 8)
                Button("닫기") { requestClose() }.keyboardShortcut(.cancelAction)
                Button("저장") { prompts.save() }
                    .keyboardShortcut(.defaultAction)
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
                    Button("기본값으로 복원") { prompts.restoreBuiltInDefault() }
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
        prompts.load(purpose: purpose)
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
