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
        panel = KeyboardPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 540),
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
        panel.contentMinSize = NSSize(width: 520, height: 440)
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
    private var ordinarySize = NSSize(width: 620, height: 540)
    private var taskSize = NSSize(width: 920, height: 540)
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
        if event.keyCode == 48 && !modifiers.contains(.command) && !modifiers.contains(.control) {
            if modifiers.contains(.option) {
                if modifiers.contains(.shift) { selectPreviousKeyView(nil) }
                else { selectNextKeyView(nil) }
            } else if !event.isARepeat {
                onCycleTab?(modifiers.contains(.shift))
            }
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

    /// Keep the three task columns readable, and remember each layout's resized size.
    func prepareLayout(for tab: CaptureKind, opening: Bool = false) {
        let isTask = tab == .task
        if let layoutTab, (layoutTab == .task) == isTask, !opening { return }
        rememberLayoutSize()
        layoutTab = tab
        let minimum = NSSize(width: isTask ? 800 : 520, height: 440)
        let preferred = isTask ? taskSize : ordinarySize
        var target = NSRect(x: frame.minX, y: frame.maxY - preferred.height,
                            width: max(preferred.width, minimum.width),
                            height: max(preferred.height, minimum.height))
        let targetScreen = opening
            ? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? screen ?? NSScreen.main
            : screen ?? NSScreen.main
        if let visible = targetScreen?.visibleFrame {
            target.size.width = min(target.width, visible.width)
            target.size.height = min(target.height, visible.height)
            target.origin.x = min(max(target.minX, visible.minX), visible.maxX - target.width)
            target.origin.y = min(max(target.minY, visible.minY), visible.maxY - target.height)
        }
        contentMinSize = NSSize(width: min(minimum.width, target.width),
                                height: min(minimum.height, target.height))
        setFrame(target, display: isVisible)
    }

    private func rememberLayoutSize() {
        guard let layoutTab else { return }
        // A screen-constrained frame must not replace the user's preferred size.
        if layoutTab == .task {
            if frame.width >= 800 { taskSize.width = frame.width }
            if frame.height >= 440 { taskSize.height = frame.height }
        } else {
            if frame.width >= 520 { ordinarySize.width = frame.width }
            if frame.height >= 440 { ordinarySize.height = frame.height }
        }
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
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            HStack(spacing: 6) {
                tab(.memo, title: "메모", symbol: "square.and.pencil")
                tab(.task, title: "업무", symbol: "checkmark.circle")
                tab(.secret, title: "Secret", symbol: "lock")
            }
            .padding(3)
            .background(WorkLogTheme.elevated, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Rectangle().fill(WorkLogTheme.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                if let draft = session.activeDraft {
                    workDate(draft: draft)
                }
                switch session.tab {
                case .memo:
                    ScrollView {
                        CaptureDraftEditor(model: session.memoDraft, label: "무엇을 기록할까요?", showsTokens: true)
                            .padding(1)
                    }
                case .task:
                    CaptureTaskContent(model: session.taskDraft, onConfirmCompletion: onConfirmCompletion)
                case .secret:
                    SecretCaptureView(model: secrets, onSaved: onSecretSaved, onCancel: onDismiss)
                }
            }
            .padding(14)
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

    private var header: some View {
        HStack(spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: "bolt.fill")
                    .accessibilityHidden(true)
                    .font(.headline)
                    .foregroundStyle(WorkLogTheme.accent)
                    .frame(width: 30, height: 30)
                    .background(WorkLogTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text("빠른 기록").font(.headline)
                    Text("WORKLOG").font(.caption2.weight(.semibold))
                        .tracking(2).foregroundStyle(WorkLogTheme.muted)
                }
                Spacer(minLength: 0)
            }
            .overlay(CaptureWindowDragArea())
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WorkLogTheme.muted)
                    .frame(width: 28, height: 28)
                    .background(WorkLogTheme.elevated, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("빠른 입력 닫기")
            .worklogHelp("닫기 (초안 보존)", keys: "Esc")
            .disabled(saveState.isSaving)
        }
    }

    private func tab(_ kind: CaptureKind, title: String, symbol: String) -> some View {
        let selected = session.tab == kind
        return Button { session.select(kind) } label: {
            Label(title, systemImage: symbol)
                .font(.callout.weight(selected ? .semibold : .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .foregroundStyle(selected ? WorkLogTheme.text : WorkLogTheme.muted)
                .background(selected ? WorkLogTheme.surface : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(selected ? WorkLogTheme.border : .clear)
                }
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
            Keycap("↩").accessibilityHidden(true)
            Text("줄바꿈")
            Keycap("⌘↩").accessibilityHidden(true)
            Text("저장")
            Keycap("Esc").accessibilityHidden(true)
            Text("닫기 (초안 보존)")
        }
        .font(.caption)
        .foregroundStyle(WorkLogTheme.muted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Return 줄바꿈, Command Return 저장, Escape 닫기. 닫아도 초안은 보존됩니다.")
        .worklogHelp("Tab 유형 전환 · Option Tab 필드 이동 · 업무 목록 ↑↓ 선택 / ←→ 단계 이동")
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
    @State private var visibleColumn = 0
    @State private var actionsExpanded = false
    @State private var trackingExpanded = false
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var focusedRow: String?

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
        if !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "새 업무 만들기 (작성 중인 내용 유지)"
        }
        let name = model.taskQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "새 업무 만들기" : "‘\(name)’ 새 업무 만들기"
    }
    private var actionKeys: [String] {
        if isNewTask {
            return ["detail"] + (actionsExpanded ? TaskStatus.allCases.map { "initial:\($0.rawValue)" } : [])
        }
        return ["activity"] + (actionsExpanded ? ["status"] : [])
    }
    private var selectedActionKey: String {
        isNewTask ? "detail" : (model.taskAction == .addActivity ? "activity" : "status")
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 880 {
                HStack(alignment: .top, spacing: 0) {
                    taskColumn.padding(12).frame(width: 240)
                    columnDivider
                    actionColumn.padding(12).frame(width: 200)
                    columnDivider
                    detailColumn.padding(12).frame(maxWidth: .infinity)
                }
            } else {
                // A constrained screen uses the same three columns one at a time,
                // preserving query, selection and draft when crossing the threshold.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        stageButton(0, "업무 선택")
                        stageButton(1, "동작")
                        stageButton(2, model.pendingCompletion == nil ? "내용" : "완료 확인")
                    }
                    .padding(.horizontal, 12).padding(.top, 8)
                    Group {
                        switch visibleColumn {
                        case 1: actionColumn
                        case 2: detailColumn
                        default: taskColumn
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .background(WorkLogTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(WorkLogTheme.outlineColor(for: contrast),
                          lineWidth: WorkLogTheme.outlineWidth(for: contrast)))
        .onChange(of: model.taskQuery) { _, _ in
            highlighted = keys.contains(selectedTaskKey) ? selectedTaskKey : "new"
        }
        .onAppear {
            highlighted = selectedTaskKey
            actionsExpanded = model.taskAction == .changeStatus && !isNewTask
            if model.pendingCompletion != nil { visibleColumn = 2 }
        }
        .onChange(of: focusedRow) { _, row in
            guard let row else { return }
            if row == "new" || row.hasPrefix("task:") { visibleColumn = 0 }
            else if row.hasPrefix("target:") || row == "cancelCompletion" { visibleColumn = 2 }
            else { visibleColumn = 1 }
        }
        .onChange(of: model.pendingCompletion != nil) { _, pending in
            if pending { visibleColumn = 2; focusedRow = "cancelCompletion" }
        }
    }

    private func stageButton(_ column: Int, _ title: String) -> some View {
        Button {
            visibleColumn = column
            switch column {
            case 0: focusSearch()
            case 1: focusedRow = selectedActionKey
            default: focusDetail()
            }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                if visibleColumn == column { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
            .font(.callout)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(WorkLogButtonStyle(prominent: visibleColumn == column))
        .accessibilityValue(visibleColumn == column ? "선택됨" : "")
        .worklogHelp("\(title) 단계로 이동")
        .disabled(isLocked)
    }

    private var columnDivider: some View {
        Rectangle().fill(WorkLogTheme.border.opacity(0.7)).frame(width: 0.5)
    }

    private func stepHeader(_ number: String, _ title: String) -> some View {
        HStack(spacing: 6) {
            Text(number).font(.caption).accessibilityHidden(true)
                .foregroundStyle(WorkLogTheme.accent)
            Text(title).font(.callout.weight(.medium))
        }
        .padding(.bottom, 3)
        .accessibilityElement(children: .combine)
    }

    private var taskColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            stepHeader("01", "업무 검색 또는 새 업무 이름")
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .accessibilityHidden(true)
                    .font(.caption).foregroundStyle(WorkLogTheme.muted)
                CaptureTaskSearchField(text: $model.taskQuery, isDisabled: isLocked,
                    onMove: { moveTask($0, focusRow: false) },
                    onSelect: { chooseTask(highlighted, advance: true) })
                    .frame(minHeight: 24)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(WorkLogTheme.elevated, in: RoundedRectangle(cornerRadius: 5))
            if !keys.contains(selectedTaskKey) {
                Label(selectedTaskTitle, systemImage: "checkmark")
                    .font(.caption).lineLimit(2).foregroundStyle(WorkLogTheme.text)
                    .accessibilityLabel("현재 선택한 업무: \(selectedTaskTitle). 검색 결과 밖에 있습니다.")
            }
            taskRow(key: "new", title: newTaskLabel, status: nil)
            Rectangle().fill(WorkLogTheme.border.opacity(0.7)).frame(height: 0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.filteredTasks) { task in
                            taskRow(key: "task:\(task.id)", title: task.title,
                                    status: task.cachedStatus?.koreanLabel ?? "상태 없음")
                                .id("task:\(task.id)")
                        }
                        if model.filteredTasks.isEmpty {
                            Text("검색된 업무가 없어요.\n위에서 새 업무를 만드세요.")
                                .font(.caption).foregroundStyle(WorkLogTheme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                        }
                    }
                }
                .onChange(of: highlighted) { _, key in proxy.scrollTo(key) }
            }
            Text("↑↓ 선택 · → 다음")
                .font(.caption).foregroundStyle(WorkLogTheme.muted)
        }
        .disabled(isLocked)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("1단계 업무 선택")
    }

    private func taskRow(key: String, title: String, status: String?) -> some View {
        Button { chooseTask(key, advance: true) } label: {
            browserRow(title: title, subtitle: status,
                       symbol: key == "new" ? "plus" : "checklist",
                       selected: selectedTaskKey == key,
                       highlighted: highlighted == key && selectedTaskKey != key, forward: true)
        }
        .buttonStyle(.plain).focusable().focused($focusedRow, equals: key)
        .worklogHelp("업무 선택 후 동작으로 이동", keys: "Return / →")
        .accessibilityLabel(status.map { "\(title), \($0)" } ?? title)
        .accessibilityValue(selectedTaskKey == key ? "선택됨" : "")
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return], phases: [.down, .repeat]) { press in
            guard press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
                  !isLocked else { return .ignored }
            if press.phase == .repeat && press.key != .upArrow && press.key != .downArrow { return .handled }
            switch press.key {
            case .upArrow: moveTask(-1, focusRow: true)
            case .downArrow: moveTask(1, focusRow: true)
            case .leftArrow: focusSearch()
            case .rightArrow, .return: chooseTask(key, advance: true)
            default: return .ignored
            }
            return .handled
        }
    }

    private var actionColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            stepHeader("02", "동작 선택")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if isNewTask {
                        Toggle("완료한 일로 등록", isOn: $model.registersAsCompleted)
                            .font(.callout)
                            .worklogHelp("새 업무를 처음부터 완료 상태로 등록")
                        actionRow(key: "detail", title: "내용 입력", symbol: "square.and.pencil")
                    } else {
                        actionRow(key: "activity", title: "진행 기록 추가", symbol: "text.badge.plus")
                    }
                    SectionDisclosure(title: isNewTask ? "등록 상태" : "상태 변경",
                                      summary: isNewTask ? model.initialStatus.koreanLabel : "Task 전체 상태 변경",
                                      isExpanded: $actionsExpanded) {
                        VStack(spacing: 4) {
                            if isNewTask {
                                ForEach(TaskStatus.allCases, id: \.self) { status in
                                    actionRow(key: "initial:\(status.rawValue)", title: status.koreanLabel,
                                              symbol: statusSymbol(status))
                                }
                            } else {
                                actionRow(key: "status", title: "Task 전체 상태 변경", symbol: "arrow.triangle.2.circlepath")
                            }
                        }
                    }
                }
            }
            Text("← 이전 · → 내용").font(.caption).foregroundStyle(WorkLogTheme.muted)
        }
        .disabled(isLocked)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("2단계 동작 선택")
    }

    private func actionRow(key: String, title: String, symbol: String) -> some View {
        Button { chooseAction(key); focusDetail() } label: {
            browserRow(title: title, symbol: symbol, selected: selectedActionKey == key || (isNewTask && key == "initial:\(model.initialStatus.rawValue)"), forward: true)
        }
        .buttonStyle(.plain).focusable().focused($focusedRow, equals: key)
        .worklogHelp("동작 선택 후 내용으로 이동", keys: "Return / →")
        .accessibilityValue(selectedActionKey == key || (isNewTask && key == "initial:\(model.initialStatus.rawValue)") ? "선택됨" : "")
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return], phases: [.down, .repeat]) { press in
            guard press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
                  !isLocked else { return .ignored }
            if press.phase == .repeat && press.key != .upArrow && press.key != .downArrow { return .handled }
            switch press.key {
            case .upArrow: moveAction(-1)
            case .downArrow: moveAction(1)
            case .leftArrow: focusedRow = keys.contains(selectedTaskKey) ? selectedTaskKey : "new"
            case .rightArrow, .return: chooseAction(key); focusDetail()
            default: return .ignored
            }
            return .handled
        }
    }

    private var detailColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            stepHeader("03", model.pendingCompletion != nil ? "완료 확인" : "내용 및 저장")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !isNewTask {
                        Text(selectedTaskTitle)
                            .font(.callout.weight(.medium)).lineLimit(2)
                            .foregroundStyle(WorkLogTheme.muted)
                    }
                    if isNewTask {
                        CaptureDraftEditor(model: model, label: "첫 줄은 업무명, 다음 줄은 진행 내용", showsTokens: true)
                        SectionDisclosure(title: "프로젝트별 상태 관리",
                                          summary: model.projectTrackingMode == .perProject ? "프로젝트별 추적" : "공통 상태",
                                          isExpanded: $trackingExpanded) {
                            Toggle("프로젝트별로 추적", isOn: Binding(
                                get: { model.projectTrackingMode == .perProject },
                                set: { model.projectTrackingMode = $0 ? .perProject : .shared }))
                                .font(.callout).disabled(model.isSubmitting)
                        }
                    } else if model.taskAction == .addActivity {
                        CaptureDraftEditor(model: model, label: "진행 내용", showsTokens: true)
                    } else {
                        statusContent
                    }
                }
                .padding(1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("3단계 내용 및 저장")
    }

    @ViewBuilder private var statusContent: some View {
        if let check = model.pendingCompletion {
            VStack(alignment: .leading, spacing: 8) {
                Text("남은 항목이 있어요. 그래도 완료할까요?")
                    .font(.callout.weight(.medium))
                ForEach(check.remainingChecklist) { item in
                    Label(item.text, systemImage: "square").font(.caption)
                }
                ForEach(check.unfinishedProjects.indices, id: \.self) { index in
                    let project = check.unfinishedProjects[index]
                    Text("\(model.projects.first { $0.id == project.projectId }?.name ?? "프로젝트") · \(project.status.koreanLabel)")
                        .font(.caption)
                }
                HStack(spacing: 6) {
                    Button("취소") {
                        model.cancelCompletion()
                        focusDetail()
                    }
                    .focused($focusedRow, equals: "cancelCompletion")
                    .worklogHelp("완료를 취소하고 입력 보존")
                    .accessibilityLabel("완료 확인 취소")
                    Button("그래도 완료", action: onConfirmCompletion)
                        .worklogHelp("남은 항목을 확인하고 Task 전체 완료")
                        .buttonStyle(WorkLogButtonStyle(prominent: true))
                        .disabled(model.isSubmitting)
                }
            }
        } else {
            Text("변경할 상태").font(.callout.weight(.medium))
            VStack(spacing: 3) {
                ForEach(model.availableStatusTargets(), id: \.self) { status in
                    targetStatusRow(status)
                }
            }
            if model.availableStatusTargets().isEmpty {
                Text("현재 상태에서 변경할 수 있는 상태가 없습니다.")
                    .font(.caption).foregroundStyle(WorkLogTheme.muted)
            } else {
                Text("상태를 고른 뒤 ⌘Return으로 저장하세요.")
                    .font(.caption).foregroundStyle(WorkLogTheme.muted)
            }
        }
    }

    private func targetStatusRow(_ status: TaskStatus) -> some View {
        Button { model.statusTarget = status } label: {
            browserRow(title: status.koreanLabel, symbol: statusSymbol(status),
                       selected: model.statusTarget == status)
        }
        .buttonStyle(.plain).focusable().focused($focusedRow, equals: "target:\(status.rawValue)")
        .disabled(model.isSubmitting)
        .accessibilityValue(model.statusTarget == status ? "선택됨" : "")
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .return], phases: [.down, .repeat]) { press in
            guard press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
                  !isLocked else { return .ignored }
            if press.phase == .repeat && press.key != .upArrow && press.key != .downArrow { return .handled }
            switch press.key {
            case .upArrow: moveTarget(-1, from: status)
            case .downArrow: moveTarget(1, from: status)
            case .leftArrow: focusedRow = selectedActionKey
            case .return: model.statusTarget = status
            default: return .ignored
            }
            return .handled
        }
    }

    private func browserRow(title: String, subtitle: String? = nil, symbol: String,
                            selected: Bool, highlighted: Bool = false, forward: Bool = false) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.callout)
                .accessibilityHidden(true)
                .foregroundStyle(selected ? WorkLogTheme.text : WorkLogTheme.muted)
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(selected ? .medium : .regular))
                    .lineLimit(2).multilineTextAlignment(.leading)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(WorkLogTheme.muted)
                }
            }
            Spacer(minLength: 2)
            if forward || selected {
                Image(systemName: forward ? "chevron.right" : "checkmark")
                    .font(.caption)
                    .foregroundStyle(selected ? WorkLogTheme.accent : WorkLogTheme.muted.opacity(0.5))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? WorkLogTheme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(highlighted ? WorkLogTheme.outlineColor(for: contrast) : .clear,
                          lineWidth: WorkLogTheme.outlineWidth(for: contrast)))
        .contentShape(Rectangle())
    }

    private func statusSymbol(_ status: TaskStatus) -> String {
        switch status {
        case .planned: return "circle.dashed"
        case .inProgress: return "circle.lefthalf.filled"
        case .onHold: return "pause.circle"
        case .completed: return "checkmark.circle"
        case .cancelled: return "xmark.circle"
        }
    }

    private func moveTask(_ delta: Int, focusRow: Bool) {
        let rows = keys
        let index = rows.firstIndex(of: highlighted) ?? 0
        let key = rows[min(max(index + delta, 0), rows.count - 1)]
        chooseTask(key, advance: false)
        if focusRow { focusedRow = key }
    }

    private func chooseTask(_ key: String, advance: Bool) {
        guard !isLocked else { return }
        highlighted = key
        if key == "new" {
            model.taskSelection = .newTask
            if advance, model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.text = model.taskQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if let task = model.filteredTasks.first(where: { "task:\($0.id)" == key }) {
            if model.taskSelection != .existing(task.id) {
                model.statusTarget = nil
                model.taskAction = .addActivity
                actionsExpanded = false
                // A project scope from another task must not leak into this task.
                for id in model.selectedProjectIds { model.removeProject(id) }
            }
            model.taskSelection = .existing(task.id)
        }
        if advance { visibleColumn = 1; focusedRow = selectedActionKey }
    }

    private func chooseAction(_ key: String) {
        guard !isLocked else { return }
        if isNewTask, let status = TaskStatus.allCases.first(where: { "initial:\($0.rawValue)" == key }) {
            model.initialStatus = status
        } else if !isNewTask {
            model.taskAction = key == "status" ? .changeStatus : .addActivity
        }
    }

    private func moveAction(_ delta: Int) {
        let rows = actionKeys
        let index = rows.firstIndex(of: focusedRow ?? selectedActionKey) ?? 0
        let key = rows[min(max(index + delta, 0), rows.count - 1)]
        chooseAction(key)
        focusedRow = key
    }

    private func moveTarget(_ delta: Int, from status: TaskStatus) {
        let targets = model.availableStatusTargets()
        guard !targets.isEmpty else { return }
        let index = targets.firstIndex(of: status) ?? 0
        let target = targets[min(max(index + delta, 0), targets.count - 1)]
        model.statusTarget = target
        focusedRow = "target:\(target.rawValue)"
    }

    private func focusDetail() {
        visibleColumn = 2
        if !isNewTask && model.taskAction == .changeStatus {
            if let target = model.statusTarget ?? model.availableStatusTargets().first {
                focusedRow = "target:\(target.rawValue)"
            }
        } else {
            focusedRow = nil
            (NSApp.keyWindow as? KeyboardPanel)?.requestDraftFocus()
        }
    }

    private func focusSearch() {
        visibleColumn = 0
        focusedRow = nil
        (NSApp.keyWindow as? KeyboardPanel)?.requestDefaultFocus(for: .task)
    }
}

@MainActor private struct CaptureDraftEditor: View {
    @Bindable var model: CaptureModel
    let label: String
    let showsTokens: Bool
    private var placeholder: String {
        if model.kind == .memo { return "회의에서 나눈 이야기, 해결한 문제, 떠오른 아이디어…" }
        return isActivity ? "진행한 일과 다음에 할 일을 적어주세요…" : "업무명과 진행 내용을 적어주세요…"
    }
    private var excluding: Set<RecordReference> {
        if case .existing(let id) = model.taskSelection { return [RecordReference(kind: .task, id: id)] }
        return []
    }

    @State private var relatedExpanded = false
    @Environment(\.colorSchemeContrast) private var contrast
    private var isActivity: Bool { isCaptureActivity(model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.callout.weight(.medium)).foregroundStyle(WorkLogTheme.text)
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
            .frame(height: model.kind == .task ? 138 : 160)
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
                }
                if isActivity {
                    Text(model.selectedProjectIds.isEmpty ? "공통 진행 기록" : "선택한 프로젝트의 진행 기록")
                        .font(.caption).foregroundStyle(WorkLogTheme.muted)
                }
                if !model.selectedProjectIds.isEmpty || (!isActivity && !model.selectedTagIds.isEmpty) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(model.selectedProjectIds, id: \.self) { id in
                            ChipView(label: "@\(model.projects.first { $0.id == id }?.name ?? "프로젝트")",
                                     onRemove: { model.removeProject(id) })
                        }
                        if !isActivity {
                            ForEach(model.selectedTagIds, id: \.self) { id in
                                ChipView(label: "#\(model.tags.first { $0.id == id }?.name ?? "태그")",
                                         onRemove: { model.removeTag(id) })
                            }
                        }
                    }
                    .accessibilityLabel("선택된 프로젝트와 태그")
                }
            }
            SectionDisclosure(title: "관련 기록", summary: model.relatedRecords.isEmpty ? "선택 사항" : "\(model.relatedRecords.count)개 연결",
                              isExpanded: $relatedExpanded) {
                RelatedRecordPicker(selection: $model.relatedRecords, search: model.searchRelated,
                                    excluding: excluding, isDisabled: model.isSubmitting)
            }
        }
        .disabled(model.isSubmitting)
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
        field.setAccessibilityHelp("위아래 화살표로 업무를 고르고 Return으로 동작 선택 단계로 이동합니다.")
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
        super.keyDown(with: event)
    }
}
#endif
