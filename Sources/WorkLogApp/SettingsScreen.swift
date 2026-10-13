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
    @Environment(\.hotkeyDiagnostics) private var hotkeyDiagnostics
    @FocusState private var errorFocused: Bool
    @FocusState private var headingFocused: Bool
    @FocusState private var navigationFocus: SettingsDestination?
    @State private var query = ""
    @State private var destination: SettingsDestination = .general
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

    private var matchingDestinations: [SettingsDestination] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return SettingsDestination.allCases.filter { item in
            terms.allSatisfy { item.searchText.localizedCaseInsensitiveContains($0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(title: "설정", purpose: "입력부터 AI까지, 내 작업 방식에 맞게")
                .padding(WorkLogTheme.contentInset)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                navigation
                Divider()
                detail
            }
            Divider()
            footer
        }
        .buttonStyle(WorkLogButtonStyle())
        .multilineTextAlignment(.leading)
        .navigationTitle("설정")
        .worklogFocusContent { errorFocused = false; headingFocused = true }
        .onAppear { backups?.load() }
        .onChange(of: query) { _, _ in
            if !matchingDestinations.contains(destination), let first = matchingDestinations.first {
                destination = first
            }
        }
        .sheet(item: $promptEditor) { selection in
            PromptEditorView(prompts: prompts, job: selection.job)
        }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(WorkLogTheme.muted)
                TextField("설정 검색", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("설정 항목 검색")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(WorkLogTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("설정 검색 지우기")
                }
            }
            .padding(8)
            .background(WorkLogTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(matchingDestinations) { item in
                        Button { destination = item } label: {
                            HStack(spacing: 9) {
                                Image(systemName: item.symbol)
                                    .frame(width: 18)
                                    .foregroundStyle(destination == item ? WorkLogTheme.accent : WorkLogTheme.muted)
                                Text(item.title)
                                    .font(.callout.weight(destination == item ? .semibold : .regular))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(WorkLogSourceRowStyle(isSelected: destination == item,
                                                         isFocused: navigationFocus == item))
                        .focusable().focusEffectDisabled()
                        .focused($navigationFocus, equals: item)
                        .worklogKeyboardActivation { destination = item }
                        .accessibilityAddTraits(destination == item ? [.isSelected] : [])
                        .accessibilityHint(item.subtitle)
                    }
                    if matchingDestinations.isEmpty {
                        Text("일치하는 설정이 없습니다")
                            .font(.caption).foregroundStyle(WorkLogTheme.muted)
                            .padding(.horizontal, 8)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(12)
        .frame(width: 188)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(WorkLogTheme.rowHover)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("설정 목차")
    }

    private var detail: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    feedback
                    if matchingDestinations.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("검색 결과가 없습니다").font(.title2.weight(.semibold))
                            hint("단축키, 모델, 백업처럼 바꾸려는 설정을 검색해 보세요.")
                            Button("모든 설정 보기") { query = "" }
                                .worklogKeyboardActivation { query = "" }.focusable()
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(destination.title)
                                .font(.title2.weight(.semibold))
                                .focusable().focusEffectDisabled().focused($headingFocused)
                                .accessibilityAddTraits(.isHeader)
                            hint(destination.subtitle)
                        }
                        selectedContent
                    }
                }
                .id("settings-top")
                .frame(maxWidth: 760, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: destination) { _, _ in proxy.scrollTo("settings-top", anchor: .top) }
            .onChange(of: model.errors) { _, errors in
                if !errors.isEmpty { proxy.scrollTo("settings-top", anchor: .top) }
            }
        }
    }

    @ViewBuilder private var feedback: some View {
        if !model.errors.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("설정을 확인하세요", systemImage: "exclamationmark.triangle")
                    .font(.headline).foregroundStyle(StatusTone.warning.color)
                    .focusable().focused($errorFocused)
                ForEach(model.errors, id: \.self) { error in
                    Text(error).fixedSize(horizontal: false, vertical: true)
                }
                hint("오류를 고친 뒤 다시 저장하세요. 기존 설정과 단축키는 유지됩니다.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(StatusTone.warning.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        if let message = model.message { InlineNotice(message: message) }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("변경 되돌리기") { model.reset() }
                .worklogKeyboardActivation { model.reset() }.disabled(!model.hasChanges)
                .focusable().worklogHelp("마지막 저장 설정으로 되돌리기")
            Spacer(minLength: 8)
            if model.hasChanges {
                Text("저장하지 않은 변경사항")
                    .font(.caption).foregroundStyle(WorkLogTheme.muted)
            }
            Button(action: save) { ShortcutLabel(title: "설정 저장", keys: "⌘S") }
                .buttonStyle(WorkLogButtonStyle(prominent: true))
                .worklogKeyboardActivation(save)
                .keyboardShortcut("s", modifiers: .command).disabled(!model.hasChanges)
                .focusable().worklogHelp("설정 검증 후 저장 · 단축키 적용", keys: "⌘S")
        }
        .padding(WorkLogTheme.cardInset)
    }

    private func save() { onSave(); errorFocused = !model.errors.isEmpty }

    @ViewBuilder private var selectedContent: some View {
        switch destination {
        case .general: generalSection
        case .shortcuts: shortcutsSection
        case .aiConnection: aiConnectionSection
        case .aiTasks: aiTasksSection
        case .backups: backupSection
        case .secret: secretSection
        case .reminders: reminderSection
        case .updates: UpdateSettingsSection()
        }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("기본 입력 유형") {
                Picker("기본 입력 유형", selection: $model.defaultCaptureKind) {
                    Text("메모").tag(CaptureKind.memo)
                    Text("업무").tag(CaptureKind.task)
                    Text("Secret").tag(CaptureKind.secret)
                }
                .labelsHidden().pickerStyle(.menu)
                .frame(maxWidth: 280, alignment: .leading)
            }
            hint("빠른 입력을 열 때 처음 표시할 유형입니다.")
            hint("Secret을 선택하면 보관함의 새 항목을 엽니다. 잠금 상태에서는 기기 인증이 필요합니다.")
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                hotkeyRow(.capture, title: "빠른 입력", value: model.draft.captureHotkey, field: .capture)
                Divider()
                hotkeyRow(.search, title: "검색", value: model.draft.searchHotkey, field: .search)
            }
            Button("단축키 기본값으로 되돌리기") { model.restoreDefaultHotkeys() }
                .worklogKeyboardActivation { model.restoreDefaultHotkeys() }
                .focusable().worklogHelp("빠른 입력·검색 전역 단축키 기본값 복원 · 저장 후 적용")
            hint("조합을 누른 뒤 새 단축키를 입력하세요. 기본값은 빠른 입력 ⌃⌥Space, 검색 ⌃⌥D입니다. 변경은 설정 저장 후 적용됩니다.")
            hint("다른 앱과 충돌해 등록에 실패하면 기존 단축키를 유지합니다.")
            Divider()
            Text("앱 내 단축키").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                shortcutRow("빠른 입력", keys: "⌘N")
                shortcutRow("검색", keys: "⌘F")
                shortcutRow("앱 화면 이동", keys: "⌘1…9")
                shortcutRow("사이드바 / 현재 화면 내용", keys: "⌘0 / ⌘⇧0")
                shortcutRow("이전 / 다음 화면", keys: "⌘⌥← / ⌘⌥→")
                shortcutRow("이전 / 다음 탭", keys: "⌃⇧Tab / ⌃Tab")
                shortcutRow("다음 / 이전 제어", keys: "Tab / ⇧Tab")
                shortcutRow("목록 선택 / 열기", keys: "↑↓ / Return")
                shortcutRow("메모 편집 / 업무 진행 기록", keys: "⌘E")
                shortcutRow("업무 이름 검색", keys: "⌘⌥F")
                shortcutRow("전체 단축키 도움말", keys: "⌘⌥K")
                shortcutRow("입력 저장 / 검색 AI 답변", keys: "⌘↩")
                shortcutRow("본문·설정 저장", keys: "⌘S")
                shortcutRow("후보·시트·패널 닫기", keys: "Esc")
                shortcutRow("보고서 복사", keys: "⇧⌘C")
                shortcutRow("사이드바 접기 / 펼치기", keys: "⌃⌘S")
                shortcutRow("복사 / 붙여넣기 / 실행 취소", keys: "⌘C / ⌘V / ⌘Z")
            }
            hint("단축키는 해당 화면에서 적용됩니다. 입력·검색·오늘 화면에서는 이전·다음 탭으로 이동할 수 있습니다. Return은 텍스트 입력 중 줄바꿈입니다.")
        }
    }

    private func hotkeyRow(_ action: HotkeyAction, title: String, value: String,
                           field: SettingsHotkeyField) -> some View {
        let diagnostic = hotkeyDiagnostics[action] ?? HotkeyDiagnostic()
        let registered = diagnostic.registrationText == "등록됨"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                HotkeyRecorder(title: title, binding: try? HotkeyBinding(parsing: value), rawValue: value,
                               onRecord: { model.setHotkey($0, for: field) },
                               onBeginRecording: onBeginHotkeyRecording, onEndRecording: onEndHotkeyRecording)
                if registered {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(WorkLogTheme.muted)
                        .frame(width: 16, height: 32)
                        .help([diagnostic.registrationText, diagnostic.recentPressText].compactMap { $0 }.joined(separator: " · "))
                        .accessibilityLabel("\(title) 단축키 등록됨")
                }
            }
            if !registered {
                Label(diagnostic.registrationText, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(WorkLogTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = diagnostic.lastFailure, failure != diagnostic.registrationText {
                Label("최근 등록 시도 · \(failure)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(StatusTone.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func shortcutRow(_ title: String, keys: String) -> some View {
        GridRow {
            Text(title).fixedSize(horizontal: false, vertical: true)
            Text(keys).font(.system(.callout, design: .monospaced)).foregroundStyle(WorkLogTheme.muted)
                .fixedSize()
        }
        .accessibilityElement(children: .combine).accessibilityLabel("\(title), \(keys)")
    }

    private var aiConnectionSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Label(model.aiConnectionSummary.title, systemImage: aiStatusSymbol).font(.headline)
                hint(model.aiConnectionSummary.detail)
            }
            Divider()
            Toggle("일반 기록에 AI 사용", isOn: $model.draft.aiEnabled).toggleStyle(.switch)
            hint(SettingsModel.transmissionNotice)
            field("Codex 실행 경로") {
                TextField("비우면 자동으로 찾습니다", text: Binding(
                    get: { model.draft.codexExecutablePath ?? "" },
                    set: { model.draft.codexExecutablePath = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Codex 실행 경로")
            }
            HStack(spacing: 12) {
                Button("로그인 상태 확인") { Task { await model.checkAccount() } }
                    .worklogKeyboardActivation { Task { await model.checkAccount() } }
                    .disabled(model.isCheckingAccount).focusable()
                    .worklogHelp("설치된 Codex의 로그인 상태 확인")
                if model.isCheckingAccount {
                    ProgressView().controlSize(.small).accessibilityLabel("Codex 로그인 상태 확인 중")
                }
            }
            Text(model.accountMessage)
                .font(.callout).foregroundStyle(WorkLogTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Codex 계정 상태: \(model.accountMessage)")
            hint("설치된 Codex와 회사 정책에서 허용하는 기능만 사용합니다. AI에 연결하지 않아도 일반 기록과 검색을 사용할 수 있습니다.")
        }
    }

    private var aiTasksSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                hint("작업마다 모델과 사고 수준(Effort)을 정할 수 있습니다. 기본 설정은 작업 성격에 맞춰 적용되며, 변경사항을 저장하면 다음 AI 작업부터 사용합니다.")
                HStack(spacing: 12) {
                    Button("모델 목록 불러오기") { Task { await model.refreshModels() } }
                        .worklogKeyboardActivation { Task { await model.refreshModels() } }
                        .disabled(model.isLoadingModels).focusable()
                    if model.isLoadingModels {
                        ProgressView().controlSize(.small).accessibilityLabel("사용 가능한 모델 확인 중")
                    }
                    Spacer(minLength: 0)
                }
                if !model.modelCatalogMessage.isEmpty { hint(model.modelCatalogMessage) }
                Button("작업별 기본값으로 되돌리기") { model.restoreDefaultAIProfiles() }
                    .worklogKeyboardActivation { model.restoreDefaultAIProfiles() }
                    .focusable().worklogHelp("모든 작업의 모델과 사고 수준을 기본값으로 복원 · 저장 후 적용")
            }
            ForEach(AIJobType.allCases, id: \.rawValue) { type in
                aiTaskCard(type)
            }
            hint("스킬 이름 또는 SKILL.md 경로를 입력하세요. 비우면 추가 스킬 없이 작업 프롬프트를 사용합니다. 기존 스킬 파일은 수정하지 않습니다.")
            hint("프롬프트 편집 창의 저장은 일반 설정 저장과 별도로 적용됩니다.")
        }
    }

    private func aiTaskCard(_ type: AIJobType) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(jobTitle(type)).font(.headline).accessibilityAddTraits(.isHeader)
                hint(model.defaultProfileDescription(for: type))
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) { modelPicker(type); effortPicker(type) }
                VStack(alignment: .leading, spacing: 12) { modelPicker(type); effortPicker(type) }
            }
            field("추가 스킬") {
                TextField("스킬 이름 또는 SKILL.md 경로", text: Binding(
                    get: { model.skillBinding(for: type) }, set: { model.setSkill($0, for: type) }))
                    .textFieldStyle(.roundedBorder).accessibilityLabel("\(jobTitle(type)) 스킬")
            }
            Button { promptEditor = PromptEditorSelection(job: type) } label: {
                Label("프롬프트 편집", systemImage: "square.and.pencil")
            }
            .worklogKeyboardActivation { promptEditor = PromptEditorSelection(job: type) }
            .focusable().accessibilityLabel("\(jobTitle(type)) 프롬프트 편집")
            .worklogHelp("\(jobTitle(type)) 지침과 출력 예시 편집")
            if let note = PromptCatalog.usageNote(for: type) { hint(note) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(WorkLogTheme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func modelPicker(_ type: AIJobType) -> some View {
        field("모델") {
            Picker("\(jobTitle(type)) 모델", selection: Binding(
                get: { model.modelSelection(for: type) }, set: { model.setModel($0, for: type) })) {
                ForEach(model.modelOptions(for: type), id: \.id) { option in
                    Text(option.title).tag(option.id)
                }
            }
            .labelsHidden().pickerStyle(.menu)
        }
        .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
    }

    private func effortPicker(_ type: AIJobType) -> some View {
        field("사고 수준 · Effort") {
            Picker("\(jobTitle(type)) 사고 수준", selection: Binding(
                get: { model.effortSelection(for: type) }, set: { model.setEffort($0, for: type) })) {
                ForEach(model.effortOptions(for: type), id: \.id) { option in
                    Text(option.title).tag(option.id)
                }
            }
            .labelsHidden().pickerStyle(.menu)
        }
        .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
    }

    private var aiStatusSymbol: String {
        switch model.aiConnectionSummary {
        case .connected: return "checkmark.circle"
        case .notConfigured: return "link"
        case .unavailable: return "exclamationmark.triangle"
        }
    }

    private var backupSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let backups {
                field("백업 위치") {
                    Text(backups.backupLocationLabel).font(.callout)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("백업 위치: \(backups.backupLocationLabel)")
                }
                Text(backups.lastSuccessLabel).font(.callout)
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
                hint("백업 위치와 복원 지점은 사이드바의 백업 화면에서 확인하세요.")
                if let onOpenBackups {
                    Button("백업·복원 열기", action: onOpenBackups)
                        .worklogKeyboardActivation(onOpenBackups).focusable()
                        .worklogHelp("백업 위치와 복원 지점 확인")
                }
            }
            Divider()
            numberField("백업 보관 기간", value: $model.draft.backupRetentionDays, unit: "일", range: "1~3650일")
        }
    }

    @ViewBuilder private func backupActions(_ backups: BackupModel) -> some View {
        Button("지금 백업") { Task { await backups.create() } }
            .worklogKeyboardActivation { Task { await backups.create() } }.disabled(backups.isBusy)
            .focusable().worklogHelp("현재 기록·설정과 암호화된 Secret을 백업")
        if let onOpenBackups {
            Button("복원…", action: onOpenBackups).worklogKeyboardActivation(onOpenBackups)
                .disabled(backups.isBusy).focusable().worklogHelp("백업 화면에서 복원 지점 선택")
        } else {
            hint("복원: 사이드바 → 백업")
        }
    }

    private var secretSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            numberField("미사용 시 자동 잠금", value: $model.draft.secretIdleLockMinutes, unit: "분", range: "1~1440분")
            numberField("복사 후 클립보드 지우기", value: $model.draft.clipboardClearSeconds, unit: "초", range: "10~3600초")
            Divider()
            hint("앱이 복사한 항목이 그대로 남아 있을 때만 클립보드를 지웁니다. 다른 앱의 클립보드 이력이나 사본은 지우지 못합니다.")
            hint("Secret의 key와 값은 저장할 때 앞뒤 공백·탭·개행을 제거합니다. 내부 문자열은 그대로 보존합니다.")
        }
    }

    private var reminderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("월요일 검토 알림") {
                TextField("HH:mm", text: $model.draft.mondayReminderTime)
                    .textFieldStyle(.roundedBorder).frame(width: 100)
                    .accessibilityLabel("월요일 검토 알림 시각, HH:mm")
            }
            hint("업무 시간대(\(model.draft.timeZoneIdentifier)) 기준입니다. 예: 09:00")
        }
    }

    private func numberField(_ title: String, value: Binding<Int>, unit: String, range: String) -> some View {
        field(title) {
            HStack(spacing: 8) {
                TextField(title, value: value, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 100)
                    .accessibilityLabel("\(title), \(range)")
                Text(unit).font(.callout)
                Text(range).font(.caption).foregroundStyle(WorkLogTheme.muted)
            }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout.weight(.medium))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(WorkLogTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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

private enum SettingsDestination: String, CaseIterable, Identifiable {
    case general, shortcuts, aiConnection, aiTasks, backups, secret, reminders, updates
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "일반"
        case .shortcuts: return "단축키"
        case .aiConnection: return "AI 연결"
        case .aiTasks: return "작업별 AI"
        case .backups: return "백업"
        case .secret: return "Secret 보호"
        case .reminders: return "검토 알림"
        case .updates: return "앱 업데이트"
        }
    }
    var subtitle: String {
        switch self {
        case .general: return "빠른 입력의 기본 동작을 정합니다."
        case .shortcuts: return "자주 쓰는 동작을 키보드로 빠르게 실행합니다."
        case .aiConnection: return "회사 Codex 연결과 AI 전송 범위를 확인합니다."
        case .aiTasks: return "작업에 맞는 모델·사고 수준·스킬·프롬프트를 선택합니다."
        case .backups: return "기록을 안전하게 보관하고 필요할 때 복원합니다."
        case .secret: return "보관함 잠금과 클립보드 보호 시간을 정합니다."
        case .reminders: return "한 주의 기록을 돌아볼 시간을 정합니다."
        case .updates: return "WorkLog 버전을 확인하고 업데이트를 관리합니다."
        }
    }
    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .shortcuts: return "keyboard"
        case .aiConnection: return "network"
        case .aiTasks: return "sparkles"
        case .backups: return "externaldrive"
        case .secret: return "lock.shield"
        case .reminders: return "bell"
        case .updates: return "arrow.down.circle"
        }
    }
    var searchText: String {
        let keywords: String
        switch self {
        case .general: keywords = "기본 입력 유형 메모 업무 memo task secret"
        case .shortcuts: keywords = "빠른 입력 검색 키보드 hotkey shortcut 등록 충돌"
        case .aiConnection: keywords = "로그인 계정 실행 경로 Codex 회사 전송 보안"
        case .aiTasks: keywords = "모델 model effort low medium high 사고 수준 스킬 skill prompt 프롬프트 주간보고 팀 제출용 성과자료 성과 질문 메모 업무 연결 제안 검색 계획 기록 기반 답변"
        case .backups: keywords = "위치 보관 기간 복원 backup retention"
        case .secret: keywords = "잠금 복사 클립보드 보호 key 값 비밀"
        case .reminders: keywords = "월요일 시각 시간대 HH:mm reminder"
        case .updates: keywords = "버전 자동 확인 다운로드 update"
        }
        return "\(title) \(subtitle) \(keywords)"
    }
}
#endif
