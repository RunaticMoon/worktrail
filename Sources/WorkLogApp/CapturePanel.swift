#if os(macOS)
import SwiftUI
import AppKit
import WorkLogCore
import Observation

/// The session keeps task drafts as `.task`, including existing-task activities.
/// Keep tag/create affordances out of that path even before the Core scope fix.
@MainActor private func isCaptureActivity(_ model: CaptureModel) -> Bool {
    if model.kind == .activity { return true }
    if case .existing = model.taskSelection {
        return model.kind == .task && model.taskAction == .addActivity
    }
    return false
}

@MainActor private func captureEditorCandidates(_ model: CaptureModel) -> [CaptureCandidate] {
    isCaptureActivity(model) ? model.candidates.filter { $0.kind == .project && !$0.isNew } : model.candidates
}

@Observable @MainActor private final class CaptureSaveState {
    var isSaving = false
    var failedDraft: CaptureModel?
}

@MainActor final class CapturePanelController: NSObject, NSWindowDelegate {
    private let panel: KeyboardPanel
    private var session: CaptureSessionModel?
    private var secrets: SecretsModel?
    private let calendar: WorkCalendar
    private var onSaved: (() -> Void)?
    private var previousApp: NSRunningApplication?
    private let saveState = CaptureSaveState()
    private var saveRequest = 0

    init(session: CaptureSessionModel, secrets: SecretsModel, calendar: WorkCalendar,
         onSaved: @escaping () -> Void) {
        self.session = session
        self.secrets = secrets
        self.calendar = calendar
        self.onSaved = onSaved
        panel = KeyboardPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 500),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.title = "빠른 입력"
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: 520, height: 420)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isSaving = { [weak self] in self?.saveState.isSaving == true }
        panel.onSelectTab = { [weak self] tab in
            guard let self, self.session?.activeDraft?.pendingCompletion == nil else { return }
            self.session?.select(tab)
        }
        panel.onEscape = { [weak self] in
            guard let self else { return }
            if let draft = self.session?.activeDraft, !captureEditorCandidates(draft).isEmpty {
                draft.dismissCandidates()
                self.panel.requestDraftFocus()
            } else { self.dismiss() }
        }
        panel.onCycleTab = { [weak self] backwards in
            guard let self, self.session?.activeDraft?.pendingCompletion == nil else { return }
            self.session?.cycleTab(backwards: backwards)
        }
        panel.onOrdinarySave = { [weak self] in
            guard let self, self.session?.isSecretTab == false else { return false }
            self.saveOrdinary()
            return true
        }
    }

    func show() {
        guard let session, let secrets else { return }
        session.beginSession()
        panel.prepareLayout(for: session.tab, opening: !panel.isVisible)
        if !panel.isVisible {
            previousApp = NSWorkspace.shared.frontmostApplication
            let hosting = NSHostingView(rootView: AnyView(CaptureScreen(
                session: session, secrets: secrets, calendar: calendar, saveState: saveState,
                onSave: { [weak self] in self?.saveOrdinary() },
                onConfirmCompletion: { [weak self] in
                    self?.saveOrdinary(confirmCompletion: true)
                },
                onSecretSaved: { [weak self] in self?.finishSave() },
                onDismiss: { [weak self] in self?.dismiss() })))
            hosting.sizingOptions = []
            panel.contentView = hosting
            FloatingPanelPositioning.place(panel)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel)
        panel.requestDefaultFocus(for: session.tab)
    }

    /// Called before backup restoration. A torn-down controller is not reusable.
    func teardown() {
        saveRequest += 1
        saveState.isSaving = false
        saveState.failedDraft = nil
        dismiss(restorePreviousApp: false)
        panel.isSaving = nil
        panel.onSelectTab = nil
        panel.onEscape = nil
        panel.onCycleTab = nil
        panel.onOrdinarySave = nil
        panel.delegate = nil
        session?.detach()
        session = nil
        secrets = nil
        onSaved = nil
        previousApp = nil
    }

    private func saveOrdinary(confirmCompletion: Bool = false) {
        guard let session, let draft = session.activeDraft,
              (panel.firstResponder as? NSTextInputClient)?.hasMarkedText() != true,
              !saveState.isSaving, !draft.isSubmitting,
              confirmCompletion || draft.pendingCompletion == nil else { return }
        saveState.isSaving = true
        saveState.failedDraft = nil
        saveRequest += 1
        let request = saveRequest
        // Yield once so the disabled save button and progress indicator can render.
        // Only local Core storage is involved; no AI or network wait.
        DispatchQueue.main.async { [weak self] in
            guard let self, request == self.saveRequest, self.session === session else { return }
            if session.tab == .task, draft.taskSelection == .newTask,
               draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.text = draft.taskQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let saved = confirmCompletion ? draft.confirmCompletion() : session.submitOrdinary()
            self.saveState.isSaving = false
            if saved {
                // The confirmation API also starts the next record on today's date.
                draft.resetWorkDateToToday()
                self.finishSave()
            }
            else if draft.pendingCompletion == nil { self.saveState.failedDraft = draft }
        }
    }

    private func finishSave() {
        onSaved?()
        session?.markSessionCompleted()
        dismiss()
    }

    private func dismiss(restorePreviousApp: Bool = true) {
        panel.makeFirstResponder(nil)
        // orderOut alone keeps SecretCaptureView mounted. Replace the root first so
        // onDisappear preserves the encrypted draft and releases the capture owner.
        if let hosting = panel.contentView as? NSHostingView<AnyView> {
            hosting.rootView = AnyView(EmptyView())
        }
        panel.contentView = nil
        panel.initialFirstResponder = nil
        panel.orderOut(nil)
        if restorePreviousApp,
           previousApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp?.activate(options: [])
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !saveState.isSaving { dismiss() }
        return false
    }
}

/// All panel shortcuts are routed here exactly once, before SwiftUI or field editors.
@MainActor private final class KeyboardPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onCycleTab: ((Bool) -> Void)?
    var onSelectTab: ((CaptureKind) -> Void)?
    var isSaving: (() -> Bool)?
    /// false means the Secret editor must receive its own Command-Return shortcut.
    var onOrdinarySave: (() -> Bool)?
    private var focusRequest = 0
    private var forwardingIME = false
    private var layoutTab: CaptureKind?
    private var preferredSize = NSSize(width: 660, height: 500)
    override var canBecomeKey: Bool { true }

    private var hasMarkedText: Bool {
        if let input = firstResponder as? NSTextInputClient { return input.hasMarkedText() }
        return false
    }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown else { super.sendEvent(event); return }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let isTypeShortcut = modifiers == [.command] && [18, 19, 20].contains(event.keyCode)
        if hasMarkedText && (event.keyCode == 48 || event.keyCode == 53 || isReturn
                             || event.keyCode == 125 || event.keyCode == 126 || isTypeShortcut) {
            // Bypass key equivalents as well: a composed Command-Return must not save.
            forwardingIME = true
            defer { forwardingIME = false }
            firstResponder?.keyDown(with: event)
            return
        }
        if isSaving?() == true {
            if event.keyCode == 48 || event.keyCode == 53 || isReturn || isTypeShortcut { return }
        }
        // Candidate commands are implemented by the body NSTextView, before the
        // panel can consume Escape/Tab. A nil highlight leaves native Return intact.
        if let editor = firstResponder as? CaptureNSTextView,
           editor.handleCandidateKey(event) { return }
        if isTypeShortcut {
            if !event.isARepeat {
                onSelectTab?(event.keyCode == 18 ? .memo : event.keyCode == 19 ? .task : .secret)
            }
            return
        }
        // Tab follows native field/cell navigation. Type switching stays explicit.
        if event.keyCode == 48 && modifiers.contains(.control) && !modifiers.contains(.command) {
            if !event.isARepeat { onCycleTab?(modifiers.contains(.shift)) }
            return
        }
        if event.keyCode == 53 && modifiers.isEmpty {
            if !event.isARepeat { onEscape?() }
            return
        }
        if isReturn && modifiers == [.command] {
            if event.isARepeat { return }
            if onOrdinarySave?() == true { return }
            // SecretCaptureView -> SecretEditorView owns the save callback and guards.
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        guard !forwardingIME, !hasMarkedText, isSaving?() != true else { return }
        if let editor = firstResponder as? CaptureNSTextView, editor.dismissCandidatesIfShowing() { return }
        onEscape?()
    }

    /// All capture types share a user-resizable window; switching never changes its size.
    func prepareLayout(for tab: CaptureKind, opening: Bool = false) {
        if layoutTab != nil, frame.width >= 520, frame.height >= 420 { preferredSize = frame.size }
        layoutTab = tab
        guard opening else { return }
        let minimum = NSSize(width: 520, height: 420)
        var target = NSRect(x: frame.minX, y: frame.maxY - preferredSize.height,
                            width: max(preferredSize.width, minimum.width),
                            height: max(preferredSize.height, minimum.height))
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? screen ?? NSScreen.main
        if let visible = targetScreen?.visibleFrame {
            target.size.width = min(target.width, visible.width)
            target.size.height = min(target.height, visible.height)
            target.origin.x = min(max(target.minX, visible.minX), visible.maxX - target.width)
            target.origin.y = min(max(target.minY, visible.minY), visible.maxY - target.height)
        }
        contentMinSize = NSSize(width: min(minimum.width, target.width), height: min(minimum.height, target.height))
        setFrame(target, display: isVisible)
    }

    func requestDraftFocus() {
        focusRequest += 1
        let request = focusRequest
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, request == self.focusRequest else { return }
            self.contentView?.layoutSubtreeIfNeeded()
            if let editor = self.findView(in: self.contentView, matching: { $0 is CaptureNSTextView }) {
                self.makeFirstResponder(editor)
            }
        }
    }

    func requestDefaultFocus(for tab: CaptureKind) {
        prepareLayout(for: tab)
        focusRequest += 1
        let request = focusRequest
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, request == self.focusRequest else { return }
            self.contentView?.layoutSubtreeIfNeeded()
            switch tab {
            case .memo:
                if let editor = self.findView(in: self.contentView, matching: { $0 is CaptureNSTextView }) {
                    self.makeFirstResponder(editor)
                }
            case .task:
                if let search = self.findView(in: self.contentView, matching: { $0 is CaptureTaskSearchTextField }) as? NSTextField,
                   search.isEnabled {
                    self.makeFirstResponder(search)
                } else {
                    _ = self.focusAccessibleElement(in: self.contentView, label: "완료 확인 취소")
                }
            case .secret:
                // SecretEditorView focuses its title on appearance. Its locked/draft
                // states use SwiftUI buttons, represented in the accessibility tree.
                for label in ["Secret 제목", "잠금 해제", "이어서 편집", "다시 시도"] {
                    if self.focusAccessibleElement(in: self.contentView, label: label) { break }
                }
            }
        }
    }

    private func findView(in root: NSView?, matching predicate: (NSView) -> Bool) -> NSView? {
        guard let root else { return nil }
        if predicate(root) { return root }
        for child in root.subviews {
            if let match = findView(in: child, matching: predicate) { return match }
        }
        return nil
    }

    private func focusAccessibleElement(in root: Any?, label: String, depth: Int = 0) -> Bool {
        guard depth < 40, let element = root as? NSAccessibilityProtocol else { return false }
        if element.accessibilityLabel() == label || element.accessibilityTitle() == label {
            element.setAccessibilityFocused(true)
            return true
        }
        for child in element.accessibilityChildren() ?? [] {
            if focusAccessibleElement(in: child, label: label, depth: depth + 1) { return true }
        }
        return false
    }
}

@MainActor private struct CaptureScreen: View {
    @Bindable var session: CaptureSessionModel
    let secrets: SecretsModel
    let calendar: WorkCalendar
    let saveState: CaptureSaveState
    @State private var dateExpanded = false
    @Environment(\.colorSchemeContrast) private var contrast
    let onSave: () -> Void
    let onConfirmCompletion: () -> Void
    let onSecretSaved: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    tab(.memo, title: "메모", symbol: "square.and.pencil")
                    tab(.task, title: "업무", symbol: "checkmark.circle")
                    tab(.secret, title: "Secret", symbol: "lock")
                }
                Spacer(minLength: 4)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .overlay(CaptureWindowDragArea())
                Button(action: onDismiss) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("빠른 입력 닫기")
                    .worklogHelp("닫기 (초안 보존)", keys: "Esc")
                    .disabled(saveState.isSaving)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            Rectangle().fill(WorkLogTheme.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                if let draft = session.activeDraft {
                    workDate(draft: draft)
                }
                switch session.tab {
                case .memo:
                    CaptureDraftEditor(model: session.memoDraft, label: "메모 본문", showsTokens: true,
                                       fillsAvailableSpace: true)
                case .task:
                    CaptureTaskContent(model: session.taskDraft, onConfirmCompletion: onConfirmCompletion)
                case .secret:
                    SecretCaptureView(model: secrets, onSaved: onSecretSaved, onCancel: onDismiss)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .disabled(saveState.isSaving)

            if let draft = session.activeDraft {
                footer(draft: draft)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(WorkLogTheme.text)
        .tint(WorkLogTheme.accent)
        .buttonStyle(WorkLogButtonStyle())
        .background(WorkLogTheme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(WorkLogTheme.outlineColor(for: contrast),
                              lineWidth: WorkLogTheme.outlineWidth(for: contrast))
                .allowsHitTesting(false)
        }
        .background(CaptureFocusAnchor(tab: session.tab))
    }

    private func workDate(draft: CaptureModel) -> some View {
        let pastLabel = KoreanDateLabel.monthDayWeekday(draft.workDate, calendar: calendar)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { dateContents(draft: draft, pastLabel: pastLabel) }
            VStack(alignment: .leading, spacing: 8) { dateContents(draft: draft, pastLabel: pastLabel) }
        }
        .disabled(draft.isSubmitting || draft.pendingCompletion != nil)
    }

    @ViewBuilder private func dateContents(draft: CaptureModel, pastLabel: String) -> some View {
        if draft.isPastWorkDate {
            PastDateBadge(label: pastLabel, onReset: draft.resetWorkDateToToday)
        } else if draft.isFutureWorkDate {
            HStack(spacing: 8) {
                StatusBadge(label: draft.workDateLabel, systemImage: "clock", tone: .warning)
                Button("오늘로", action: draft.resetWorkDateToToday)
                    .accessibilityLabel("업무일을 오늘로 변경")
                    .worklogHelp("업무일을 오늘로 변경")
            }
        } else {
            Text(draft.workDateLabel).font(.caption).foregroundStyle(WorkLogTheme.muted)
        }
        Button { dateExpanded = true } label: {
            Label("날짜 변경", systemImage: "calendar")
        }
        .font(.caption)
        .worklogHelp("기록할 업무일 변경")
        .popover(isPresented: $dateExpanded, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                WorkDatePicker(title: "업무일", value: Binding(
                    get: { draft.workDate }, set: { draft.workDate = $0 }), calendar: calendar)
                Button("완료") { dateExpanded = false }
            }
            .padding(16)
        }
    }

    private func tab(_ kind: CaptureKind, title: String, symbol: String) -> some View {
        let selected = session.tab == kind
        return Button { session.select(kind) } label: {
            Label(title, systemImage: symbol)
                .font(.callout.weight(selected ? .semibold : .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(selected ? WorkLogTheme.text : WorkLogTheme.muted)
                .background(selected ? WorkLogTheme.surface : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(saveState.isSaving || session.activeDraft?.pendingCompletion != nil)
        .worklogHelp("\(title) 입력", keys: kind == .memo ? "⌘1" : kind == .task ? "⌘2" : "⌘3")
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "선택됨" : "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func footer(draft: CaptureModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if saveState.failedDraft === draft {
                ScrollView {
                    RecoveryNotice(failed: "저장하지 못했습니다", preserved: "입력은 그대로 있습니다",
                                   retryTitle: "다시 저장", retry: onSave)
                    if let error = draft.errorMessage {
                        Text(error).font(.caption).foregroundStyle(WorkLogTheme.muted)
                    }
                }
                .frame(maxHeight: 130)
                .disabled(saveState.isSaving)
            } else if let error = draft.errorMessage {
                Text(error).font(.callout).foregroundStyle(WorkLogTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    keyboardHints
                    Spacer(minLength: 8)
                    saveButton(draft: draft)
                }
                VStack(alignment: .leading, spacing: 8) {
                    keyboardHints
                    HStack { Spacer(); saveButton(draft: draft) }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(WorkLogTheme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(WorkLogTheme.border).frame(height: 1)
        }
    }

    private var keyboardHints: some View {
        HStack(spacing: 6) {
            Text("Esc 닫기 · 초안 보존")
        }
        .font(.caption)
        .foregroundStyle(WorkLogTheme.muted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Return 줄바꿈, Command Return 저장, Escape 닫기. 닫아도 초안은 보존됩니다.")
        .worklogHelp("Tab 필드 이동 · ⌘1/2/3 유형 전환 · 업무 검색 ↑↓ 선택 / Return 입력")
    }

    private func saveButton(draft: CaptureModel) -> some View {
        Button(action: onSave) {
            HStack(spacing: 8) {
                if saveState.isSaving || draft.isSubmitting {
                    ProgressView().controlSize(.small).accessibilityLabel("저장 중")
                }
                Text(saveState.isSaving || draft.isSubmitting ? "저장 중…" : "저장")
                    .font(.callout.weight(.semibold))
                Keycap("⌘↩").accessibilityHidden(true)
            }
        }
        .buttonStyle(WorkLogButtonStyle(prominent: true))
        .disabled(saveState.isSaving || draft.isSubmitting || draft.pendingCompletion != nil)
        .accessibilityLabel("저장하고 이전 앱으로 돌아가기")
        .worklogHelp("저장하고 이전 앱으로 돌아가기", keys: "⌘Return")
    }

}

/// A native drag region keeps the custom header movable without handling editor events.
@MainActor private struct CaptureWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

/// Refocus after a tab switch, including switches made with the tab buttons.
@MainActor private struct CaptureFocusAnchor: NSViewRepresentable {
    let tab: CaptureKind
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.tab != tab || context.coordinator.window !== view.window else { return }
        context.coordinator.tab = tab
        context.coordinator.window = view.window
        (view.window as? KeyboardPanel)?.requestDefaultFocus(for: tab)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var tab: CaptureKind?
        weak var window: NSWindow?
    }
}

@MainActor private struct CaptureTaskContent: View {
    @Bindable var model: CaptureModel
    let onConfirmCompletion: () -> Void
    @State private var highlighted = "new"
    @State private var choosingTask = true
    @State private var trackingExpanded = false
    @FocusState private var cancelFocused: Bool
    @FocusState private var focusedTaskRow: String?

    private var keys: [String] { ["new"] + model.filteredTasks.map { "task:\($0.id)" } }
    private var isLocked: Bool { model.isSubmitting || model.pendingCompletion != nil }
    private var isNewTask: Bool { model.taskSelection == .newTask }
    private var selectedTaskKey: String {
        if case .existing(let id) = model.taskSelection { return "task:\(id)" }
        return "new"
    }
    private var selectedTaskTitle: String {
        guard case .existing(let id) = model.taskSelection else { return "새 업무" }
        return model.tasks.first { $0.id == id }?.title ?? "선택한 업무"
    }
    private var newTaskLabel: String {
        let name = model.taskQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "새 업무 만들기" : "‘\(name)’ 새 업무 만들기"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if choosingTask {
                    taskPicker
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(selectedTaskTitle).font(.body.weight(.semibold))
                            .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                        Button("업무 변경") {
                            choosingTask = true
                            DispatchQueue.main.async { (NSApp.keyWindow as? KeyboardPanel)?.requestDefaultFocus(for: .task) }
                        }
                        .controlSize(.small).disabled(isLocked)
                    }
                }
                if model.pendingCompletion != nil {
                    completionConfirmation
                } else {
                    if isNewTask {
                        HStack(spacing: 12) {
                            Picker("등록 상태", selection: $model.initialStatus) {
                                ForEach(TaskStatus.allCases, id: \.self) { Text($0.koreanLabel).tag($0) }
                            }.fixedSize()
                            Spacer(minLength: 0)
                        }
                        .controlSize(.small)
                    } else {
                        Picker("업무 동작", selection: Binding(
                            get: { model.taskAction == .changeStatus },
                            set: { model.taskAction = $0 ? .changeStatus : .addActivity })) {
                            Text("진행 기록 추가").tag(false)
                            Text("전체 상태 변경").tag(true)
                        }
                        .pickerStyle(.segmented).fixedSize()
                    }
                    if !isNewTask && model.taskAction == .changeStatus {
                        statusContent
                    } else {
                        CaptureDraftEditor(model: model,
                            label: isNewTask ? "첫 줄은 업무명, 다음 줄은 진행 내용" : "진행 내용", showsTokens: true)
                        if isNewTask {
                            DisclosureGroup("프로젝트별 상태 관리", isExpanded: $trackingExpanded) {
                                Toggle("프로젝트별로 추적", isOn: Binding(
                                    get: { model.projectTrackingMode == .perProject },
                                    set: { model.projectTrackingMode = $0 ? .perProject : .shared }))
                                    .font(.callout).padding(.top, 8)
                            }.font(.caption).foregroundStyle(WorkLogTheme.muted)
                        }
                    }
                }
            }
            .padding(1)
        }
        .onChange(of: model.taskQuery) { _, _ in
            highlighted = keys.contains(selectedTaskKey) ? selectedTaskKey : "new"
        }
        .onAppear { highlighted = selectedTaskKey }
        .onChange(of: model.pendingCompletion != nil) { _, pending in
            if pending { cancelFocused = true }
        }
    }

    private var taskPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            CaptureTaskSearchField(text: $model.taskQuery, isDisabled: isLocked,
                onMove: moveTask, onSelect: { chooseTask(highlighted) })
                .frame(height: 28)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        taskRow(key: "new", title: newTaskLabel, status: nil)
                        ForEach(model.filteredTasks) { task in
                            taskRow(key: "task:\(task.id)", title: task.title,
                                    status: task.cachedStatus?.koreanLabel)
                        }
                    }
                }
                .frame(height: min(CGFloat(keys.count) * 36, 132))
                .onChange(of: highlighted) { _, key in proxy.scrollTo(key) }
            }
        }
        .disabled(isLocked)
    }

    private func taskRow(key: String, title: String, status: String?) -> some View {
        Button { chooseTask(key) } label: {
            HStack(spacing: 8) {
                Image(systemName: key == "new" ? "plus" : "checklist").accessibilityHidden(true)
                    .foregroundStyle(WorkLogTheme.muted).frame(width: 16)
                Text(title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if let status { Text(status).font(.caption).foregroundStyle(WorkLogTheme.muted) }
                Image(systemName: "return").font(.caption).accessibilityHidden(true)
                    .foregroundStyle(highlighted == key ? WorkLogTheme.accent : .clear)
            }
            .font(.callout).padding(.horizontal, 8).padding(.vertical, 8)
            .background(highlighted == key ? WorkLogTheme.accentSoft : .clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedTaskRow, equals: key)
        .onKeyPress(keys: [.upArrow, .downArrow, .return], phases: [.down, .repeat]) { press in
            guard !isLocked,
                  (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true,
                  press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return .ignored }
            switch press.key {
            case .upArrow: moveTask(-1)
            case .downArrow: moveTask(1)
            case .return: if press.phase != .repeat { chooseTask(key) }
            default: return .ignored
            }
            return .handled
        }
        .onChange(of: focusedTaskRow) { _, row in if let row { highlighted = row } }
        .accessibilityValue(highlighted == key ? "선택됨" : "")
        .worklogHelp("선택하고 바로 내용 입력", keys: "↑↓ 선택 · Return 입력")
        .id(key)
    }

    @ViewBuilder private var statusContent: some View {
        let targets = model.availableStatusTargets()
        if targets.isEmpty {
            Text("현재 상태에서 변경할 수 있는 상태가 없습니다.").font(.callout)
        } else {
            Picker("변경할 전체 상태", selection: $model.statusTarget) {
                Text("상태 선택").tag(Optional<TaskStatus>.none)
                ForEach(targets, id: \.self) { Text($0.koreanLabel).tag(Optional($0)) }
            }
            .fixedSize().disabled(model.isSubmitting)
            Text("프로젝트별 상태와 체크리스트는 따로 유지됩니다.")
                .font(.caption).foregroundStyle(WorkLogTheme.muted)
        }
    }

    @ViewBuilder private var completionConfirmation: some View {
        if let check = model.pendingCompletion {
            VStack(alignment: .leading, spacing: 8) {
                Text("남은 항목이 있어요. 그래도 완료할까요?").font(.body.weight(.semibold))
                ForEach(check.remainingChecklist) { Label($0.text, systemImage: "square").font(.callout) }
                ForEach(check.unfinishedProjects.indices, id: \.self) { index in
                    let project = check.unfinishedProjects[index]
                    Text("\(model.projects.first { $0.id == project.projectId }?.name ?? "프로젝트") · \(project.status.koreanLabel)")
                        .font(.callout)
                }
                HStack(spacing: 8) {
                    Button("취소") { model.cancelCompletion() }
                        .focused($cancelFocused).accessibilityLabel("완료 확인 취소")
                    Button("그래도 완료", action: onConfirmCompletion)
                        .buttonStyle(WorkLogButtonStyle(prominent: true)).disabled(model.isSubmitting)
                }
            }
        }
    }

    private func moveTask(_ delta: Int) {
        let rows = keys
        let index = rows.firstIndex(of: highlighted) ?? 0
        highlighted = rows[min(max(index + delta, 0), rows.count - 1)]
        if focusedTaskRow != nil { focusedTaskRow = highlighted }
    }

    private func chooseTask(_ key: String) {
        guard !isLocked else { return }
        highlighted = key
        if key == "new" {
            model.taskSelection = .newTask
            if model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.text = model.taskQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if let task = model.filteredTasks.first(where: { "task:\($0.id)" == key }) {
            if model.taskSelection != .existing(task.id) {
                model.statusTarget = nil
                model.taskAction = .addActivity
                for id in model.selectedProjectIds { model.removeProject(id) }
            }
            model.taskSelection = .existing(task.id)
        }
        choosingTask = false
        focusedTaskRow = nil
        (NSApp.keyWindow as? KeyboardPanel)?.requestDraftFocus()
    }
}

@MainActor private struct CaptureDraftEditor: View {
    @Bindable var model: CaptureModel
    let label: String
    let showsTokens: Bool
    var fillsAvailableSpace = false
    private var editorHeight: CGFloat {
        let lines = model.text.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, ($1.count + 65) / 66) }
        return min(320, max(120, CGFloat(lines) * 20 + 24))
    }
    private var placeholder: String {
        if model.kind == .memo { return "회의에서 나눈 이야기, 해결한 문제, 떠오른 아이디어…" }
        return isActivity ? "진행한 일과 다음에 할 일을 적어주세요…" : "업무명과 진행 내용을 적어주세요…"
    }
    private var excluding: Set<RecordReference> {
        if case .existing(let id) = model.taskSelection { return [RecordReference(kind: .task, id: id)] }
        return []
    }

    @State private var relatedExpanded = false
    @State private var tokensExpanded = false
    @Environment(\.colorSchemeContrast) private var contrast
    private var isActivity: Bool { isCaptureActivity(model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.kind != .memo {
                Text(label).font(.caption).foregroundStyle(WorkLogTheme.muted)
            }
            ZStack(alignment: .topLeading) {
                CaptureTextEditor(text: $model.text, selectionRange: $model.selectionRange, model: model, label: label)
                if model.text.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(WorkLogTheme.muted)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: fillsAvailableSpace ? 120 : editorHeight,
                   maxHeight: fillsAvailableSpace ? .infinity : editorHeight)
            .background(WorkLogTheme.surface, in: RoundedRectangle(cornerRadius: 7))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(WorkLogTheme.outlineColor(for: contrast),
                              lineWidth: WorkLogTheme.outlineWidth(for: contrast)))
            if !captureEditorCandidates(model).isEmpty {
                candidateList
            }
            if showsTokens {
                HStack(spacing: 8) {
                    CaptureTokenPicker(model: model, kind: .project, allowsCreation: !isActivity,
                                       onClose: restoreEditorFocus)
                    if !isActivity {
                        CaptureTokenPicker(model: model, kind: .tag, allowsCreation: true,
                                           onClose: restoreEditorFocus)
                    }
                    Spacer(minLength: 4)
                    relatedPickerButton
                }
                if isActivity {
                    Text(model.selectedProjectIds.isEmpty ? "공통 진행 기록" : "선택한 프로젝트의 진행 기록")
                        .font(.caption).foregroundStyle(WorkLogTheme.muted)
                }
                if !selectedTokenNames.isEmpty {
                    Button { tokensExpanded = true } label: {
                        HStack(spacing: 6) {
                            Text(selectedTokenNames.joined(separator: " · ")).lineLimit(1)
                            Text("\(selectedTokenNames.count)개 연결").fixedSize()
                            Image(systemName: "chevron.down").accessibilityHidden(true)
                        }.font(.caption).foregroundStyle(WorkLogTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("프로젝트와 태그 연결 관리: \(selectedTokenNames.joined(separator: ", "))")
                    .popover(isPresented: $tokensExpanded) { selectedTokens }
                    .onChange(of: tokensExpanded) { _, expanded in if !expanded { restoreEditorFocus() } }
                }
            } else {
                relatedPickerButton
            }

        }
        .disabled(model.isSubmitting)
    }

    private var selectedTokenNames: [String] {
        model.selectedProjectIds.map { id in "@\(model.projects.first { $0.id == id }?.name ?? "프로젝트")" }
            + (isActivity ? [] : model.selectedTagIds.map { id in "#\(model.tags.first { $0.id == id }?.name ?? "태그")" })
    }

    private var selectedTokens: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("연결한 프로젝트와 태그").font(.headline)
                Spacer()
                Button("완료") { tokensExpanded = false }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.selectedProjectIds, id: \.self) { id in
                        HStack {
                            Text("@\(model.projects.first { $0.id == id }?.name ?? "프로젝트")")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("연결 해제") { model.removeProject(id) }.controlSize(.small)
                        }
                    }
                    if !isActivity {
                        ForEach(model.selectedTagIds, id: \.self) { id in
                            HStack {
                                Text("#\(model.tags.first { $0.id == id }?.name ?? "태그")")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button("연결 해제") { model.removeTag(id) }.controlSize(.small)
                            }
                        }
                    }
                }.font(.callout)
            }.frame(maxHeight: 240)
        }.padding(16).frame(width: 400)
    }

    private var relatedPickerButton: some View {
        Button { relatedExpanded = true } label: {
            Label(model.relatedRecords.isEmpty ? "관련 기록" : "관련 기록 \(model.relatedRecords.count)개",
                  systemImage: "link").font(.caption)
        }
        .buttonStyle(.plain).foregroundStyle(WorkLogTheme.muted)
        .popover(isPresented: $relatedExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("관련 기록").font(.headline)
                    Spacer()
                    Button("완료") { relatedExpanded = false }
                }
                RelatedRecordPicker(selection: $model.relatedRecords, search: model.searchRelated,
                                    excluding: excluding, isDisabled: model.isSubmitting)
            }.padding(16).frame(width: 420)
        }
        .onChange(of: relatedExpanded) { _, expanded in if !expanded { restoreEditorFocus() } }
    }

    private var candidateList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(captureEditorCandidates(model)) { candidate in
                        let highlighted = candidate.id == model.highlightedCandidate?.id
                        Button {
                            guard (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return }
                            model.select(candidate)
                            restoreEditorFocus()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: candidate.isNew ? "plus" : candidate.kind == .project ? "folder" : "number")
                                    .accessibilityHidden(true)
                                Text(candidate.isNew ? "‘\(candidate.name)’ 새로 만들기" : candidate.name)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                if highlighted { Image(systemName: "chevron.right").accessibilityHidden(true) }
                            }
                            .font(.callout)
                            .foregroundStyle(WorkLogTheme.text)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(highlighted ? WorkLogTheme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(highlighted ? WorkLogTheme.outlineColor(for: contrast) : .clear,
                                              lineWidth: WorkLogTheme.outlineWidth(for: contrast)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(highlighted ? "강조됨" : "")
                        .worklogHelp("자동완성 선택", keys: "↑↓ / Return / Tab")
                        .id(candidate.id)
                    }
                }
            }
            .frame(maxHeight: 104)
            .accessibilityLabel("자동완성 후보, 위아래 이동, Return 또는 Tab 선택, Escape 후보 닫기")
            .onChange(of: model.highlightedCandidate?.id) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func restoreEditorFocus() {
        // A popover may still be key during the isPresented transition.
        DispatchQueue.main.async {
            (NSApp.keyWindow as? KeyboardPanel)?.requestDraftFocus()
        }
    }

}

/// Search-field commands stay local and defer to the input method during composition.
@MainActor private struct CaptureTaskSearchField: NSViewRepresentable {
    @Binding var text: String
    @Environment(\.isEnabled) private var isEnabled
    let isDisabled: Bool
    let onMove: (Int) -> Void
    let onSelect: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = CaptureTaskSearchTextField()
        field.placeholderString = "업무 검색 또는 새 업무 이름"
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        field.drawsBackground = false
        field.font = NSFont.preferredFont(forTextStyle: .callout, options: [:])
        field.delegate = context.coordinator
        field.setAccessibilityLabel("업무 검색 또는 새 업무 이름")
        field.setAccessibilityHelp("위아래 화살표로 업무를 고르고 Return으로 선택하고 바로 내용을 입력합니다.")
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = !isDisabled && isEnabled
        if field.stringValue != text && (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CaptureTaskSearchField
        init(_ parent: CaptureTaskSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !parent.isDisabled, parent.isEnabled, !textView.hasMarkedText(),
                  NSApp.currentEvent?.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty != false else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.moveRight(_:)):
                // Inside a query, preserve ordinary caret movement. At the end, enter the next column.
                let selection = textView.selectedRange()
                guard selection.length == 0, selection.location == (textView.string as NSString).length else { return false }
                if NSApp.currentEvent?.isARepeat != true { parent.onSelect() }
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.isARepeat != true { parent.onSelect() }
            default: return false
            }
            return true
        }
    }
}

@MainActor private final class CaptureTaskSearchTextField: NSTextField {}

/// Plain Return remains native text insertion; shortcuts are exclusively panel-owned.
@MainActor private struct CaptureTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectionRange: NSRange?
    let model: CaptureModel
    let label: String
    @Environment(\.isEnabled) private var isEnabled
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let editor = CaptureNSTextView()
        editor.isRichText = false
        editor.allowsUndo = true
        editor.focusRingType = .exterior
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.font = NSFont.preferredFont(forTextStyle: .body, options: [:])
        editor.textColor = .labelColor
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 8, height: 10)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.minSize = NSSize(width: 0, height: 120)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.model = model
        editor.setAccessibilityLabel(label)
        editor.setAccessibilityHelp("Return 줄바꿈, Command Return 저장. 자동완성은 위아래로 이동하고 Return 또는 Tab으로 선택합니다.")
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = editor
        context.coordinator.editor = editor
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = context.coordinator.editor else { return }
        editor.model = model
        editor.isEditable = isEnabled && !model.isSubmitting
        editor.font = NSFont.preferredFont(forTextStyle: .body, options: [:])
        editor.setAccessibilityLabel(label)
        if editor.string != text && !editor.hasMarkedText() {
            let desiredSelection = selectionRange ?? NSRange(location: (text as NSString).length, length: 0)
            editor.string = text
            if NSMaxRange(desiredSelection) <= (text as NSString).length { editor.setSelectedRange(desiredSelection) }
        } else if let selectionRange, !editor.hasMarkedText(),
                  NSMaxRange(selectionRange) <= (text as NSString).length,
                  editor.selectedRange() != selectionRange {
            editor.setSelectedRange(selectionRange)
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CaptureTextEditor
        weak var editor: CaptureNSTextView?
        init(_ parent: CaptureTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor else { return }
            parent.text = editor.string
            if !editor.hasMarkedText() { parent.selectionRange = editor.selectedRange() }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor, !editor.hasMarkedText() else { return }
            parent.selectionRange = editor.selectedRange()
        }
    }
}

/// Completion decisions live beside the actual text input client, not in SwiftUI
/// key equivalents. Standard editing and unaccepted Return remain AppKit-owned.
@MainActor private final class CaptureNSTextView: NSTextView {
    weak var model: CaptureModel?

    @discardableResult func handleCandidateKey(_ event: NSEvent) -> Bool {
        guard !hasMarkedText(), isEditable, let model, !model.isSubmitting,
              !captureEditorCandidates(model).isEmpty,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 126: model.moveCandidateHighlight(by: -1)
        case 125: model.moveCandidateHighlight(by: 1)
        case 36, 76, 48:
            guard captureEditorCandidates(model).contains(where: { $0.id == model.highlightedCandidate?.id }) else { return false }
            if !event.isARepeat { return model.acceptHighlightedCandidate() }
        case 53:
            if !event.isARepeat { model.dismissCandidates() }
        default: return false
        }
        return true
    }

    @discardableResult func dismissCandidatesIfShowing() -> Bool {
        guard !hasMarkedText(), let model, !captureEditorCandidates(model).isEmpty else { return false }
        model.dismissCandidates()
        return true
    }

    override func keyDown(with event: NSEvent) {
        if handleCandidateKey(event) { return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 48, !hasMarkedText(), isEditable,
           modifiers.isEmpty || modifiers == .shift {
            if modifiers == .shift { window?.selectPreviousKeyView(nil) }
            else { window?.selectNextKeyView(nil) }
            return
        }
        super.keyDown(with: event)
    }
}
#endif
