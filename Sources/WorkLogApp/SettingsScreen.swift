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
    let backups: BackupModel?
    let onOpenBackups: (() -> Void)?
    @FocusState private var errorFocused: Bool
    @State private var promptEditor: PromptEditorSelection?

    init(model: SettingsModel, prompts: PromptSettingsModel, onSave: @escaping () -> Void,
         onBeginHotkeyRecording: @escaping () -> Void, onEndHotkeyRecording: @escaping () -> Void,
         backups: BackupModel? = nil, onOpenBackups: (() -> Void)? = nil) {
        self.model = model
        self.prompts = prompts
        self.onSave = onSave
        self.onBeginHotkeyRecording = onBeginHotkeyRecording
        self.onEndHotkeyRecording = onEndHotkeyRecording
        self.backups = backups
        self.onOpenBackups = onOpenBackups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(title: "설정", purpose: "입력·단축키·AI·백업 관리").padding(WorkLogTheme.contentInset)
            Form {
                if !model.errors.isEmpty {
                    Section("설정을 확인하세요") {
                        ForEach(model.errors, id: \.self) { error in
                            Label(error, systemImage: "exclamationmark.triangle")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("검증·등록 실패·단축키 충돌이 발생하면 기존 설정과 단축키를 유지합니다. 오류를 고친 뒤 다시 저장하세요.")
                    }.focusable().focused($errorFocused)
                }
                if let message = model.message { Section { InlineNotice(message: message) } }
                generalSection
                shortcutsSection
                aiSection
                backupSection
                Section("Secret 보호") {
                    TextField("미사용 시 잠금 (분, 1~1440)", value: $model.draft.secretIdleLockMinutes, format: .number)
                    TextField("복사 후 지우기 (초, 10~3600)", value: $model.draft.clipboardClearSeconds, format: .number)
                    Text("앱이 복사한 항목이 그대로 남아 있을 때만 클립보드를 지웁니다. 다른 앱의 클립보드 이력이나 사본은 지우지 못합니다.")
                        .foregroundStyle(WorkLogTheme.muted)
                    Text("Secret의 key와 값은 저장 시 앞뒤 공백·탭·개행을 제거합니다. 내부 문자열은 그대로 보존합니다.")
                        .foregroundStyle(WorkLogTheme.muted)
                }
                Section("검토 알림") {
                    TextField("월요일 검토 알림 (HH:mm)", text: $model.draft.mondayReminderTime)
                    Text("알림 시각은 업무 시간대(\(model.draft.timeZoneIdentifier)) 기준입니다.").foregroundStyle(WorkLogTheme.muted)
                }
                UpdateSettingsSection()
            }.formStyle(.grouped)
            Divider()
            HStack {
                Button("변경 되돌리기") { model.reset() }.disabled(!model.hasChanges)
                    .worklogHelp("마지막 저장 설정으로 되돌리기")
                Spacer()
                Button { onSave(); errorFocused = !model.errors.isEmpty } label: {
                    ShortcutLabel(title: "설정 저장", keys: "⌘S")
                }
                .keyboardShortcut("s", modifiers: .command).disabled(!model.hasChanges)
                .worklogHelp("설정 검증 후 저장 · 단축키 적용", keys: "⌘S")
            }.padding(WorkLogTheme.cardInset)
        }
        .navigationTitle("설정")
        .onAppear { backups?.load() }
        .sheet(item: $promptEditor) { selection in
            PromptEditorView(prompts: prompts, job: selection.job)
        }
    }
    private var generalSection: some View {
        Section("일반") {
            Picker("기본 입력 유형", selection: $model.defaultCaptureKind) {
                Text("Memo · 메모").tag(CaptureKind.memo)
                Text("Task · 업무").tag(CaptureKind.task)
                Text("Secret · 보관함").tag(CaptureKind.secret)
            }
            Text("Secret을 선택하면 입력 단축키로 보관함의 새 항목을 엽니다. 잠금 상태에서는 기기 인증이 필요합니다.")
                .foregroundStyle(WorkLogTheme.muted)
        }
    }
    private var shortcutsSection: some View {
        Section("단축키") {
            HotkeyRecorder(title: "빠른 입력", binding: try? HotkeyBinding(parsing: model.draft.captureHotkey),
                           rawValue: model.draft.captureHotkey,
                           onRecord: { model.setHotkey($0, for: .capture) },
                           onBeginRecording: onBeginHotkeyRecording, onEndRecording: onEndHotkeyRecording)
            HotkeyRecorder(title: "검색", binding: try? HotkeyBinding(parsing: model.draft.searchHotkey),
                           rawValue: model.draft.searchHotkey,
                           onRecord: { model.setHotkey($0, for: .search) },
                           onBeginRecording: onBeginHotkeyRecording, onEndRecording: onEndHotkeyRecording)
            Button("단축키 기본값으로 되돌리기") { model.restoreDefaultHotkeys() }
                .worklogHelp("빠른 입력·검색 전역 단축키 기본값 복원 · 설정 저장 후 적용")
            Text("칸을 누른 뒤 원하는 조합을 누르세요. 기본값: 빠른 입력 ⌃⌥Space, 검색 ⌃⌥D. 변경은 ‘설정 저장’ 후 적용됩니다.")
                .foregroundStyle(WorkLogTheme.muted).fixedSize(horizontal: false, vertical: true)
            Text("다른 앱이 사용하는 조합은 등록되지 않거나 충돌할 수 있습니다. 등록 실패 시 기존 단축키를 유지합니다.")
                .font(.callout).foregroundStyle(WorkLogTheme.muted).fixedSize(horizontal: false, vertical: true)
            Text("앱 내 단축키").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                shortcutRow("빠른 입력", keys: "⌘N")
                shortcutRow("검색", keys: "⌘F")
                shortcutRow("입력 저장 / 검색 AI 답변", keys: "⌘↩")
                shortcutRow("본문·설정 저장", keys: "⌘S")
                shortcutRow("후보·시트·패널 닫기", keys: "Esc")
                shortcutRow("보고서 복사", keys: "⇧⌘C")
                shortcutRow("사이드바 접기 / 펼치기", keys: "⌃⌘S")
                shortcutRow("복사 / 붙여넣기 / 실행 취소", keys: "⌘C / ⌘V / ⌘Z")
            }
            Text("단축키는 해당 화면에서 적용됩니다. Return은 텍스트 입력 중 줄바꿈입니다.")
                .font(.caption).foregroundStyle(WorkLogTheme.muted)
        }
    }
    private func shortcutRow(_ title: String, keys: String) -> some View {
        GridRow {
            Text(title).fixedSize(horizontal: false, vertical: true)
            Text(keys).font(.callout)
        }.accessibilityElement(children: .combine).accessibilityLabel("\(title), \(keys)")
    }
    private var aiSection: some View {
        Section("AI·스킬") {
            Label(model.aiConnectionSummary.title, systemImage: aiStatusSymbol).font(.headline)
                .accessibilityLabel(model.aiConnectionSummary.title)
            Text(model.aiConnectionSummary.detail).fixedSize(horizontal: false, vertical: true)
            Text("나중에 연결해도 기록·검색은 바로 사용할 수 있습니다.")
                .font(.callout).foregroundStyle(WorkLogTheme.muted)
            DisclosureGroup("AI 연결 설정") {
                Toggle("일반 기록에 AI 사용", isOn: $model.draft.aiEnabled)
                Text(SettingsModel.transmissionNotice).fixedSize(horizontal: false, vertical: true)
                Text("설치된 Codex와 회사 정책에서 허용하는 기능만 사용합니다. AI 연결 실패 시 일반 기록과 검색은 계속 사용할 수 있습니다.")
                    .foregroundStyle(WorkLogTheme.muted)
                TextField("Codex 실행 경로 (비우면 자동 탐색)", text: Binding(
                    get: { model.draft.codexExecutablePath ?? "" }, set: { model.draft.codexExecutablePath = $0.isEmpty ? nil : $0 }))
                Button("로그인 상태 확인") { Task { await model.checkAccount() } }.disabled(model.isCheckingAccount)
                    .worklogHelp("설치된 Codex의 로그인 상태 확인")
                if model.isCheckingAccount {
                    ProgressView("로그인 상태 확인 중…").controlSize(.small).accessibilityLabel("Codex 로그인 상태 확인 중")
                }
                Text(model.accountMessage).accessibilityLabel("Codex 계정 상태: \(model.accountMessage)")
            }
            DisclosureGroup("작업별 스킬·프롬프트") {
                Text("스킬 이름 또는 SKILL.md 경로를 입력하세요. 비우면 추가 스킬 없이 이 작업의 프롬프트를 사용합니다. 기존 스킬 파일은 수정하지 않습니다.")
                    .foregroundStyle(WorkLogTheme.muted)
                ForEach(AIJobType.allCases, id: \.rawValue) { type in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(jobTitle(type)).font(.headline)
                        TextField("스킬 이름 또는 SKILL.md 경로", text: Binding(
                            get: { model.skillBinding(for: type) }, set: { model.setSkill($0, for: type) }))
                            .accessibilityLabel("\(jobTitle(type)) 스킬")
                        Button("프롬프트 편집…") { promptEditor = PromptEditorSelection(job: type) }
                            .accessibilityLabel("\(jobTitle(type)) 프롬프트 편집")
                            .worklogHelp("\(jobTitle(type)) 지침과 출력 예시 편집")
                        if let note = PromptCatalog.usageNote(for: type) {
                            Text(note).font(.caption).foregroundStyle(WorkLogTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(.vertical, 4)
                }
            }
        }
    }
    private var aiStatusSymbol: String {
        switch model.aiConnectionSummary {
        case .connected: return "checkmark.circle"
        case .notConfigured: return "link"
        case .unavailable: return "exclamationmark.triangle"
        }
    }
    private var backupSection: some View {
        Section("백업") {
            if let backups {
                LabeledContent("위치", value: backups.backupLocationLabel)
                    .textSelection(.enabled).accessibilityLabel("백업 위치: \(backups.backupLocationLabel)")
                Text(backups.lastSuccessLabel).accessibilityLabel(backups.lastSuccessLabel)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { backupActions(backups) }
                    VStack(alignment: .leading, spacing: 8) { backupActions(backups) }
                }
                if backups.isBusy { ProgressView("백업 처리 중…").accessibilityLabel("백업 처리 중") }
                BackupFeedback(model: backups, retryTitle: onOpenBackups != nil ? "백업 화면 열기" : "다시 백업", retry: {
                    if let onOpenBackups { onOpenBackups() }
                    else { Task { await backups.create() } }
                })
            } else {
                Text("백업 위치와 복원 지점은 사이드바의 백업 화면에서 확인하세요.")
                    .foregroundStyle(WorkLogTheme.muted)
                if let onOpenBackups {
                    Button("백업·복원 열기", action: onOpenBackups).worklogHelp("백업 위치와 복원 지점 확인")
                }
            }
            TextField("백업 보관 (일, 1~3650)", value: $model.draft.backupRetentionDays, format: .number)
        }
    }
    @ViewBuilder private func backupActions(_ backups: BackupModel) -> some View {
        Button("지금 백업") { Task { await backups.create() } }.disabled(backups.isBusy)
            .worklogHelp("현재 기록·설정과 암호화된 Secret을 백업")
        if let onOpenBackups {
            Button("복원…", action: onOpenBackups).disabled(backups.isBusy)
                .worklogHelp("백업 화면에서 복원 지점 선택")
        } else {
            Text("복원: 사이드바 → 백업").font(.callout).foregroundStyle(WorkLogTheme.muted)
        }
    }
    private func jobTitle(_ type: AIJobType) -> String {
        switch type {
        case .submissionWeekly: return "주간보고 · 팀 제출용"
        case .performanceReport: return "성과자료"
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
