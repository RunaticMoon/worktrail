#if os(macOS)
import SwiftUI
import WorkLogCore

@MainActor
struct SettingsScreen: View {
    @Bindable var model: SettingsModel
    let prompts: PromptSettingsModel
    let onSave: () -> Void
    let onBeginHotkeyRecording: () -> Void
    let onEndHotkeyRecording: () -> Void
    @FocusState private var errorFocused: Bool
    @State private var promptEditor: PromptEditorSelection?

    init(model: SettingsModel, prompts: PromptSettingsModel, onSave: @escaping () -> Void,
         onBeginHotkeyRecording: @escaping () -> Void, onEndHotkeyRecording: @escaping () -> Void) {
        self.model = model
        self.prompts = prompts
        self.onSave = onSave
        self.onBeginHotkeyRecording = onBeginHotkeyRecording
        self.onEndHotkeyRecording = onEndHotkeyRecording
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                if !model.errors.isEmpty {
                    Section("설정을 확인하세요") {
                        ForEach(model.errors, id: \.self) { Text($0).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                        Text("검증·단축키 충돌이 발생하면 기존 설정과 단축키를 유지합니다.")
                    }.focusable().focused($errorFocused)
                }
                if let message = model.message { Section { InlineNotice(message: message) } }
                Section("회사 AI") {
                    Toggle("일반 기록에 AI 사용", isOn: $model.draft.aiEnabled)
                    Text(SettingsModel.transmissionNotice).fixedSize(horizontal: false, vertical: true)
                    Text("설치된 Codex와 회사 정책에서 허용하는 기능만 사용합니다. AI 연결 실패 시 일반 기록과 검색은 계속 사용할 수 있습니다.")
                        .foregroundStyle(.secondary)
                    TextField("Codex 실행 경로 (비우면 자동 탐색)", text: Binding(
                        get: { model.draft.codexExecutablePath ?? "" }, set: { model.draft.codexExecutablePath = $0.isEmpty ? nil : $0 }))
                    HStack {
                        Button("로그인 상태 확인") { Task { await model.checkAccount() } }.disabled(model.isCheckingAccount)
                        if model.isCheckingAccount { ProgressView().controlSize(.small) }
                    }
                    Text(model.accountMessage).accessibilityLabel("Codex 계정 상태: \(model.accountMessage)")
                }
                Section("작업별 스킬") {
                    Text("스킬 이름 또는 SKILL.md 경로를 입력하세요. 비우면 추가 스킬 없이 이 작업의 프롬프트를 사용합니다. 기존 스킬 파일은 수정하지 않습니다.")
                        .foregroundStyle(.secondary)
                    ForEach(AIJobType.allCases, id: \.rawValue) { type in
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent(jobTitle(type)) {
                                HStack {
                                    TextField("스킬 이름 또는 SKILL.md 경로", text: Binding(
                                        get: { model.skillBinding(for: type) }, set: { model.setSkill($0, for: type) }))
                                        .labelsHidden()
                                        .accessibilityLabel("\(jobTitle(type)) 스킬")
                                    Button("프롬프트 편집…") { promptEditor = PromptEditorSelection(job: type) }
                                        .accessibilityLabel("\(jobTitle(type)) 프롬프트 편집")
                                }
                            }
                            if let note = PromptCatalog.usageNote(for: type) {
                                Text(note).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                Section("전역 단축키") {
                    Picker("기본 입력 유형", selection: $model.defaultCaptureKind) {
                        Text("Memo · 메모").tag(CaptureKind.memo)
                        Text("Task · 업무").tag(CaptureKind.task)
                        Text("Secret · 보관함").tag(CaptureKind.secret)
                    }
                    Text("Secret을 선택하면 입력 단축키로 보관함의 새 항목을 엽니다. 잠금 상태에서는 기기 인증이 필요합니다.")
                        .foregroundStyle(.secondary)
                    HotkeyRecorder(title: "빠른 입력", binding: try? HotkeyBinding(parsing: model.draft.captureHotkey),
                                   rawValue: model.draft.captureHotkey,
                                   onRecord: { model.setHotkey($0, for: .capture) },
                                   onBeginRecording: onBeginHotkeyRecording, onEndRecording: onEndHotkeyRecording)
                    HotkeyRecorder(title: "검색", binding: try? HotkeyBinding(parsing: model.draft.searchHotkey),
                                   rawValue: model.draft.searchHotkey,
                                   onRecord: { model.setHotkey($0, for: .search) },
                                   onBeginRecording: onBeginHotkeyRecording, onEndRecording: onEndHotkeyRecording)
                    Button("기본값으로 되돌리기") { model.restoreDefaultHotkeys() }
                    Text("칸을 누른 뒤 원하는 조합을 누르세요. 기본값: 빠른 입력 ⌃⌥Space, 검색 ⌃⌥D. 변경은 '설정 저장' 후 적용됩니다.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("Secret 보호") {
                    TextField("미사용 시 잠금 (분, 1~1440)", value: $model.draft.secretIdleLockMinutes, format: .number)
                    TextField("복사 후 지우기 (초, 10~3600)", value: $model.draft.clipboardClearSeconds, format: .number)
                    Text("앱이 복사한 항목이 그대로 남아 있을 때만 클립보드를 지웁니다. 다른 앱의 클립보드 이력이나 사본은 지우지 못합니다.")
                        .foregroundStyle(.secondary)
                    Text("Secret의 key와 값은 저장 시 앞뒤 공백·탭·개행을 제거합니다. 내부 문자열은 그대로 보존합니다.")
                        .foregroundStyle(.secondary)
                }
                UpdateSettingsSection()
                Section("백업·알림") {
                    TextField("백업 보관 (일, 1~3650)", value: $model.draft.backupRetentionDays, format: .number)
                    TextField("월요일 검토 알림 (HH:mm)", text: $model.draft.mondayReminderTime)
                    Text("알림 시각은 업무 시간대(\(model.draft.timeZoneIdentifier)) 기준입니다.").foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Button("변경 되돌리기") { model.reset() }.disabled(!model.hasChanges)
                Spacer()
                Button("설정 저장") { onSave(); errorFocused = !model.errors.isEmpty }
                    .keyboardShortcut("s", modifiers: .command).disabled(!model.hasChanges)
            }.padding(12)
        }.navigationTitle("설정")
            .sheet(item: $promptEditor) { selection in
                PromptEditorView(prompts: prompts, job: selection.job)
            }
    }
    private func jobTitle(_ type: AIJobType) -> String {
        switch type {
        case .submissionWeekly: return "제출용 주간보고"
        case .performanceReport: return "성과 리포트"
        case .evidenceQuiz: return "성과 질문"
        case .memoTaskSuggestions: return "메모·업무 연결 제안"
        case .queryPlan: return "검색 계획"
        case .groundedAnswer: return "기록 기반 답변"
        }
    }

    private struct PromptEditorSelection: Identifiable {
        let job: AIJobType
        var id: String { job.rawValue }
    }
}
#endif
