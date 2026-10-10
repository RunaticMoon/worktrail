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

/// An explicit local key loop keeps mixed SwiftUI/AppKit controls in visual order.
/// Popovers and the Secret editor retain their native key loops.
@Observable @MainActor final class CaptureKeyboardNavigation {
    var current: String?
    var isPopoverPresented = false
    @ObservationIgnored var tokenActions: [Bool: () -> Void] = [:]
    @ObservationIgnored private var stops: [String: (order: Int, focus: () -> Void)] = [:]

    func register(_ id: String, order: Int, focus: @escaping () -> Void) {
        stops[id] = (order, focus)
    }
    func remove(_ id: String) { stops[id] = nil }
    func focus(_ id: String) {
        guard let stop = stops[id] else { return }
        current = id
        stop.focus()
    }
    func move(backwards: Bool) {
        let ids = stops.keys.sorted {
            let left = stops[$0]!.order, right = stops[$1]!.order
            return left == right ? $0 < $1 : left < right
        }
        guard !ids.isEmpty else { return }
        let index = current.flatMap { ids.firstIndex(of: $0) }
        let next = index.map { ($0 + (backwards ? -1 : 1) + ids.count) % ids.count }
            ?? (backwards ? ids.count - 1 : 0)
        focus(ids[next])
    }
}

@MainActor private struct CaptureControlFocus: ViewModifier {
    let id: String
    let order: Int
    let action: (() -> Void)?
    @Environment(CaptureKeyboardNavigation.self) private var navigation
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($focused)
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(focused ? Color(nsColor: .keyboardFocusIndicatorColor) : .clear, lineWidth: 2)
                    .padding(-2).allowsHitTesting(false)
            }
            .id(id)
            .onAppear { register() }
            .onDisappear { navigation.remove(id) }
            .onChange(of: isEnabled) { _, _ in register() }
            .onChange(of: order) { _, _ in register() }
            .onChange(of: focused) { _, value in
                if value { navigation.current = id }
            }
            .onKeyPress(keys: [.return, .space], phases: [.down, .repeat]) { press in
                guard isEnabled, let action,
                      (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true,
                      press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return .ignored }
                if press.phase == .down { action() }
                return .handled
            }
    }
    private func register() {
        if isEnabled { navigation.register(id, order: order) { focused = true } }
        else { navigation.remove(id) }
    }
}

extension View {
    @MainActor func captureFocus(_ id: String, order: Int, action: (() -> Void)? = nil) -> some View {
        modifier(CaptureControlFocus(id: id, order: order, action: action))
    }
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
        panel.navigation = nil
        panel.onDate = nil
        panel.onStatus = nil
        panel.onBackToActions = nil
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
    weak var navigation: CaptureKeyboardNavigation?
    var onDate: (() -> Void)?
    var onStatus: ((TaskStatus) -> Void)?
    var onBackToActions: (() -> Void)?
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
        // Every custom shortcut defers to marked text, including Option-number and Command-Left.
        if hasMarkedText {
            forwardingIME = true
            defer { forwardingIME = false }
            firstResponder?.keyDown(with: event)
            return
        }
        if isSaving?() == true { return }
        if navigation?.isPopoverPresented == true { super.sendEvent(event); return }
        if let editor = firstResponder as? CaptureNSTextView,
           editor.handleCandidateKey(event) { return }
        if isTypeShortcut {
            if !event.isARepeat {
                switch event.keyCode {
                case 18: onSelectTab?(.memo)
                case 19: onSelectTab?(.task)
                default: onSelectTab?(.secret)
                }
            }
            return
        }
        if event.keyCode == 48 && (modifiers == [.control] || modifiers == [.control, .shift]) {
            if !event.isARepeat { onCycleTab?(modifiers.contains(.shift)) }
            return
        }
        if modifiers == [.option], let index = [18, 19, 20, 21, 23].firstIndex(of: event.keyCode),
           let onStatus {
            if !event.isARepeat { onStatus(TaskStatus.allCases[index]) }
            return
        }
        if modifiers == [.command], event.keyCode == 2, let onDate {
            if !event.isARepeat { onDate() }
            return
        }
        if modifiers == [.command], event.keyCode == 123, firstResponder is CaptureNSTextView,
           let onBackToActions {
            if !event.isARepeat { onBackToActions() }
            return
        }
        if modifiers == [.command, .shift], event.keyCode == 35 || event.keyCode == 17,
           let navigation {
            if !event.isARepeat {
                navigation.focus(event.keyCode == 35 ? "project" : "tag")
                // Button activation is supplied by the root shortcut callback below.
                navigation.tokenActions[event.keyCode == 35]?()
            }
            return
        }
        if event.keyCode == 48 && (modifiers.isEmpty || modifiers == [.shift]) {
            if let navigation { navigation.move(backwards: modifiers.contains(.shift)) }
            else if modifiers.contains(.shift) { selectPreviousKeyView(nil) }
            else { selectNextKeyView(nil) }
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
        guard !forwardingIME, !hasMarkedText, isSaving?() != true, navigation?.isPopoverPresented != true else { return }
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
                } else if let editor = self.findView(in: self.contentView, matching: { $0 is CaptureNSTextView }) {
                    self.makeFirstResponder(editor)
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
    @State private var navigation = CaptureKeyboardNavigation()
    @State private var dateExpanded = false
    @State private var dateBeforeEditing: WorkDate?
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
                    .captureFocus("close", order: 950, action: onDismiss)
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
        .environment(navigation)
        .background(CaptureFocusAnchor(tab: session.tab, navigation: session.isSecretTab ? nil : navigation,
            onDate: dateHandler, onStatus: statusHandler, onBackToActions: backHandler))
    }

    private var dateHandler: (() -> Void)? {
        guard session.activeDraft != nil else { return nil }
        return { openDate() }
    }
    private var statusHandler: ((TaskStatus) -> Void)? {
        guard session.tab == .task else { return nil }
        return { status in selectStatus(status) }
    }
    private var backHandler: (() -> Void)? {
        guard session.tab == .task else { return nil }
        return { backToActions() }
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
                .captureFocus("today", order: 101, action: draft.resetWorkDateToToday)
        } else if draft.isFutureWorkDate {
            HStack(spacing: 8) {
                StatusBadge(label: draft.workDateLabel, systemImage: "clock", tone: .warning)
                Button("오늘로", action: draft.resetWorkDateToToday)
                    .captureFocus("today", order: 101, action: draft.resetWorkDateToToday)
                    .accessibilityLabel("업무일을 오늘로 변경")
                    .worklogHelp("업무일을 오늘로 변경")
            }
        } else {
            Text(draft.workDateLabel).font(.caption).foregroundStyle(WorkLogTheme.muted)
        }
        Button(action: openDate) {
            Label("날짜 변경", systemImage: "calendar")
        }
        .font(.caption)
        .captureFocus("date", order: 100, action: openDate)
        .worklogHelp("업무일 변경 · ↑↓ 하루 · T 오늘 · Return 확정 · Esc 취소", keys: "⌘D")
        .popover(isPresented: $dateExpanded, arrowEdge: .bottom) {
            CaptureDateField(model: draft, calendar: calendar,
                onConfirm: { dateBeforeEditing = nil; dateExpanded = false },
                onCancel: cancelDate)
                .padding(16)
        }
        .onChange(of: dateExpanded) { _, expanded in
            navigation.isPopoverPresented = expanded
            if !expanded {
                if let original = dateBeforeEditing { draft.workDate = original }
                dateBeforeEditing = nil
                DispatchQueue.main.async { navigation.focus("date") }
            }
        }
    }

    private func openDate() {
        guard let draft = session.activeDraft, !saveState.isSaving,
              draft.pendingCompletion == nil, !draft.isSubmitting else { return }
        dateBeforeEditing = draft.workDate
        navigation.isPopoverPresented = true
        dateExpanded = true
    }
    private func cancelDate() {
        if let original = dateBeforeEditing { session.activeDraft?.workDate = original }
        dateBeforeEditing = nil
        dateExpanded = false
    }
    private func selectStatus(_ status: TaskStatus) {
        let draft = session.taskDraft
        guard !draft.isSubmitting, draft.pendingCompletion == nil else { return }
        if draft.taskSelection == .newTask { draft.initialStatus = status }
        else if draft.availableStatusTargets().contains(status) {
            draft.statusTarget = status
            draft.taskAction = .changeStatus
        } else { NSSound.beep() }
    }
    private func backToActions() {
        let draft = session.taskDraft
        navigation.focus(draft.taskSelection == .newTask ? "initialStatus"
            : draft.taskAction == .changeStatus ? "statusAction" : "action")
    }

    private func tab(_ kind: CaptureKind, title: String, symbol: String) -> some View {
        let selected = session.tab == kind
        let hasDraft = kind == .secret ? secrets.hasUnsavedRows : session.hasDraft(kind)
        return Button { session.select(kind) } label: {
            HStack(spacing: 6) {
                Label(title, systemImage: symbol)
                if hasDraft {
                    Circle().fill(WorkLogTheme.muted).frame(width: 4, height: 4)
                        .accessibilityHidden(true)
                }
            }
                .font(.callout.weight(selected ? .semibold : .medium))
                .padding(.horizontal, 10)
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
        .worklogHelp("\(title) 입력", keys: kind == .memo ? "⌘1" : kind == .task ? "⌘2" : "⌘3")
        .captureFocus("tab:\(kind.rawValue)", order: 960 + (kind == .memo ? 0 : kind == .task ? 1 : 2),
                      action: { session.select(kind) })
        .disabled(saveState.isSaving || session.activeDraft?.pendingCompletion != nil)
        .accessibilityLabel(hasDraft ? "\(title), 초안 있음" : title)
        .accessibilityValue(selected ? "선택됨" : "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func footer(draft: CaptureModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if saveState.failedDraft === draft {
                ScrollView {
                    Text("저장하지 못했습니다 · 입력은 그대로 있습니다")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Button("다시 저장", action: onSave)
                        .captureFocus("retrySave", order: 810, action: onSave)
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
        Text("Esc 닫기 · 초안 보존")
            .font(.caption).foregroundStyle(WorkLogTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(session.tab == .task
                ? "Command 1, 2, 3 유형. Tab 이동. Option 1부터 5 상태. Command D 날짜. Command Return 저장. Escape 닫기, 초안 보존."
                : "Command 1, 2, 3 유형. Tab 이동. Command D 날짜. Command Return 저장. Escape 닫기, 초안 보존.")
            .worklogHelp("⌃Tab 유형 순환 · 본문 Return 줄바꿈 · ⌘← 동작으로 · ⌘⇧P 프로젝트 · ⌘⇧T 태그")
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
        .captureFocus("save", order: 800, action: onSave)
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
    let navigation: CaptureKeyboardNavigation?
    let onDate: (() -> Void)?
    let onStatus: ((TaskStatus) -> Void)?
    let onBackToActions: (() -> Void)?
    func makeNSView(context: Context) -> NSView { AnchorView() }
    func updateNSView(_ view: NSView, context: Context) {
        let attach = { [weak view] in
            guard let view, let panel = view.window as? KeyboardPanel else { return }
            panel.navigation = navigation
            panel.onDate = onDate
            panel.onStatus = onStatus
            panel.onBackToActions = onBackToActions
            guard context.coordinator.tab != tab || context.coordinator.window !== panel else { return }
            context.coordinator.tab = tab
            context.coordinator.window = panel
            panel.requestDefaultFocus(for: tab)
        }
        (view as? AnchorView)?.attach = attach
        attach()
    }
    private final class AnchorView: NSView {
        var attach: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.attach?() }
        }
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
    @Environment(CaptureKeyboardNavigation.self) private var navigation

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

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if choosingTask {
                    taskPicker
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(selectedTaskTitle).font(.body.weight(.semibold))
                            .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                        Button("업무 변경", action: changeTask)
                            .controlSize(.small).disabled(isLocked)
                            .captureFocus("changeTask", order: 200, action: changeTask)
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
                            .captureFocus("initialStatus", order: 400)
                            .worklogHelp("등록 상태", keys: "⌥1–5")
                            Spacer(minLength: 0)
                        }
                        .controlSize(.small)
                    } else {
                        HStack(spacing: 4) {
                            actionButton("진행 기록 추가", changesStatus: false)
                            actionButton("전체 상태 변경", changesStatus: true)
                        }
                    }
                    if !isNewTask && model.taskAction == .changeStatus {
                        statusContent
                    } else {
                        CaptureDraftEditor(model: model,
                            label: isNewTask ? "첫 줄은 업무명, 다음 줄은 진행 내용" : "진행 내용", showsTokens: true)
                        if isNewTask {
                            CaptureDisclosure(title: "프로젝트별 상태 관리", id: "tracking", order: 700,
                                summary: model.projectTrackingMode == .perProject ? "프로젝트별 추적" : "공통 상태",
                                isExpanded: $trackingExpanded) {
                                Toggle("프로젝트별로 추적", isOn: Binding(
                                    get: { model.projectTrackingMode == .perProject },
                                    set: { model.projectTrackingMode = $0 ? .perProject : .shared }))
                                    .font(.callout).padding(.top, 8)
                                    .captureFocus("trackingToggle", order: 710, action: {
                                        model.projectTrackingMode = model.projectTrackingMode == .perProject ? .shared : .perProject
                                    })
                            }
                        }
                    }
                }
            }
            .padding(1)
        }
        .onChange(of: navigation.current) { _, id in if let id { proxy.scrollTo(id) } }
        }
        .onChange(of: model.taskQuery) { _, _ in
            highlighted = keys.contains(selectedTaskKey) ? selectedTaskKey : "new"
        }
        .onAppear { highlighted = selectedTaskKey }
        .onChange(of: model.pendingCompletion != nil) { _, pending in
            if pending { DispatchQueue.main.async { navigation.focus("cancelCompletion") } }
        }
    }

    private var taskPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            CaptureTaskSearchField(text: $model.taskQuery, isDisabled: isLocked,
                onMove: { moveTask($0, focusRow: false) }, onSelect: { chooseTask(highlighted, advance: true) })
                .frame(height: 28).id("search")
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
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
        Button { chooseTask(key, advance: true) } label: {
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
        .captureFocus(key, order: 300 + (keys.firstIndex(of: key) ?? 0),
                      action: { chooseTask(key, advance: true) })
        .worklogHelp("선택하고 바로 내용 입력", keys: "Return / →")
        .accessibilityLabel(status.map { "\(title), \($0)" } ?? title)
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return], phases: [.down, .repeat]) { press in
            guard press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
                  !isLocked else { return .ignored }
            if press.phase == .repeat && press.key != .upArrow && press.key != .downArrow { return .handled }
            switch press.key {
            case .upArrow: moveTask(-1, focusRow: true)
            case .downArrow: moveTask(1, focusRow: true)
            case .leftArrow: navigation.focus("search")
            case .rightArrow, .return: chooseTask(key, advance: true)
            default: return .ignored
            }
            return .handled
        }
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
            .captureFocus("targetStatus", order: 410)
            .worklogHelp("Task 전체 상태 선택", keys: "⌥1–5")
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
                        .captureFocus("cancelCompletion", order: 500, action: { model.cancelCompletion() })
                        .accessibilityLabel("완료 확인 취소")
                    Button("그래도 완료", action: onConfirmCompletion)
                        .captureFocus("confirmCompletion", order: 501, action: onConfirmCompletion)
                        .buttonStyle(WorkLogButtonStyle(prominent: true)).disabled(model.isSubmitting)
                }
            }
        }
    }

    private func moveTask(_ delta: Int, focusRow: Bool) {
        let rows = keys
        let index = rows.firstIndex(of: highlighted) ?? 0
        let key = rows[min(max(index + delta, 0), rows.count - 1)]
        chooseTask(key, advance: false)
        if focusRow { navigation.focus(key) }
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
                // A project scope from another task must not leak into this task.
                for id in model.selectedProjectIds { model.removeProject(id) }
            }
            model.taskSelection = .existing(task.id)
        }
        if advance {
            choosingTask = false
            DispatchQueue.main.async {
                navigation.focus(!isNewTask && model.taskAction == .changeStatus ? "targetStatus" : "body")
            }
        }
    }

    private func changeTask() {
        choosingTask = true
        DispatchQueue.main.async { navigation.focus("search") }
    }

    private func actionButton(_ title: String, changesStatus: Bool) -> some View {
        let selected = (model.taskAction == .changeStatus) == changesStatus
        let select = { model.taskAction = changesStatus ? .changeStatus : .addActivity }
        return Button(action: select) { Text(title).font(.callout).padding(.horizontal, 10).padding(.vertical, 6) }
            .buttonStyle(.plain)
            .background(selected ? WorkLogTheme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 5))
            .captureFocus(changesStatus ? "statusAction" : "action", order: changesStatus ? 401 : 400, action: select)
            .accessibilityValue(selected ? "선택됨" : "선택 안 됨")
            .disabled(isLocked)
            .onKeyPress(keys: [.leftArrow, .rightArrow], phases: .down) { press in
                guard press.modifiers.isEmpty else { return .ignored }
                if press.key == .leftArrow { changeTask() }
                else { DispatchQueue.main.async { navigation.focus(changesStatus ? "targetStatus" : "body") } }
                return .handled
            }
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
    @Environment(CaptureKeyboardNavigation.self) private var navigation
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
            .id("body")
            .frame(minHeight: fillsAvailableSpace ? 120 : editorHeight,
                   maxHeight: fillsAvailableSpace ? .infinity : editorHeight)
            .background(WorkLogTheme.surface, in: RoundedRectangle(cornerRadius: 7))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(navigation.current == "body" ? Color(nsColor: .keyboardFocusIndicatorColor) : WorkLogTheme.outlineColor(for: contrast),
                              lineWidth: navigation.current == "body" ? 2 : WorkLogTheme.outlineWidth(for: contrast)))
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
                    .captureFocus("tokens", order: 530, action: { tokensExpanded = true })
                    .accessibilityLabel("프로젝트와 태그 연결 관리: \(selectedTokenNames.joined(separator: ", "))")
                    .popover(isPresented: $tokensExpanded) { selectedTokens }
                    .onChange(of: tokensExpanded) { _, expanded in
                        navigation.isPopoverPresented = expanded
                        if !expanded { restoreEditorFocus() }
                    }
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
        .captureFocus("related", order: 600, action: { relatedExpanded = true })
        .popover(isPresented: $relatedExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("관련 기록").font(.headline)
                    Spacer()
                    Button("완료") { relatedExpanded = false }
                }
                ScrollView { CaptureRelatedRecords(model: model, excluding: excluding) }.frame(maxHeight: 300)
            }.padding(16).frame(width: 420)
        }
        .onChange(of: relatedExpanded) { _, expanded in
            navigation.isPopoverPresented = expanded
            if !expanded { restoreEditorFocus() }
        }
    }

    private var candidateList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
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
                        .captureFocus("candidate:\(candidate.id)",
                            order: 501 + (captureEditorCandidates(model).firstIndex(of: candidate) ?? 0), action: {
                                model.select(candidate)
                                restoreEditorFocus()
                            })
                        .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                            guard press.modifiers.isEmpty else { return .ignored }
                            model.moveCandidateHighlight(by: press.key == .upArrow ? -1 : 1)
                            if let id = model.highlightedCandidate?.id { navigation.focus("candidate:\(id)") }
                            return .handled
                        }
                        .accessibilityValue(highlighted ? "강조됨" : "")
                        .worklogHelp("자동완성 선택", keys: "↑↓ / Return / Tab")
                        .id("candidate:\(candidate.id)")
                    }
                }
            }
            .frame(maxHeight: 104)
            .accessibilityLabel("자동완성 후보, 위아래 이동, Return 또는 Tab 선택, Escape 후보 닫기")
            .onChange(of: navigation.current) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .onChange(of: model.highlightedCandidate?.id) { _, id in
                if let id { proxy.scrollTo("candidate:\(id)") }
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

/// Local disclosure headers are real buttons with a visible keyboard focus ring.
@MainActor private struct CaptureDisclosure<Content: View>: View {
    let title: String
    let id: String
    let order: Int
    let summary: String
    @Binding var isExpanded: Bool
    let content: () -> Content
    @Environment(CaptureKeyboardNavigation.self) private var navigation

    init(title: String, id: String, order: Int, summary: String,
         isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.id = id; self.order = order; self.summary = summary
        self._isExpanded = isExpanded; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { isExpanded.toggle() } label: {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.callout.weight(.medium))
                        if !isExpanded {
                            Text(summary).font(.caption).foregroundStyle(WorkLogTheme.muted)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .captureFocus(id, order: order, action: { isExpanded.toggle() })
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "펼침" : "접힘, \(summary)")
            .worklogHelp("펼침/접힘", keys: "Space")
            .onKeyPress(keys: [.downArrow, .upArrow], phases: .down) { press in
                guard press.modifiers.isEmpty else { return .ignored }
                if press.key == .downArrow && !isExpanded { isExpanded = true }
                else { navigation.move(backwards: press.key == .upArrow) }
                return .handled
            }
            if isExpanded { content().padding(.leading, 4) }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

/// Inline recent/search rows avoid a second mouse-only control inside the disclosure.
@MainActor private struct CaptureRelatedRecords: View {
    @Bindable var model: CaptureModel
    let excluding: Set<RecordReference>
    @State private var query = ""
    @State private var candidates: [RelatedRecordCandidate] = []
    @State private var failed = false
    @Environment(CaptureKeyboardNavigation.self) private var navigation
    @FocusState private var searchFocused: Bool

    private func key(_ reference: RecordReference) -> String {
        "related:\(reference.kind.rawValue):\(reference.id)"
    }
    private var rows: [RelatedRecordCandidate] {
        var seen = Set<RecordReference>()
        return (model.relatedRecords + candidates).filter {
            !excluding.contains($0.reference) && seen.insert($0.reference).inserted
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("관련 기록 검색", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityLabel("관련 기록 검색")
                .id("relatedSearch")
                .onAppear {
                    navigation.register("relatedSearch", order: 610) { searchFocused = true }
                    reload()
                }
                .onDisappear { navigation.remove("relatedSearch") }
                .onChange(of: searchFocused) { _, focused in
                    if focused { navigation.current = "relatedSearch" }
                }
                .onChange(of: query) { _, _ in reload() }
                .onKeyPress(keys: [.upArrow, .downArrow, .return], phases: [.down, .repeat]) { press in
                    guard canHandle(press) else { return .ignored }
                    if press.key == .upArrow { navigation.focus("related") }
                    else if let first = rows.first { navigation.focus(key(first.reference)) }
                    return .handled
                }
            if failed {
                Text("관련 기록을 불러오지 못했습니다. 입력은 보존됩니다.")
                    .font(.caption).foregroundStyle(WorkLogTheme.muted)
                Button("다시 시도", action: reload)
                    .captureFocus("relatedRetry", order: 611, action: reload)
            } else if rows.isEmpty {
                Text("일치하는 기록이 없습니다. 검색어를 바꿔보세요.")
                    .font(.caption).foregroundStyle(WorkLogTheme.muted)
            }
            ForEach(rows, id: \.reference) { candidate in
                let selected = model.relatedRecords.contains { $0.reference == candidate.reference }
                Button { toggle(candidate) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: selected ? "checkmark.square" : "square").accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.title).font(.callout)
                            if let subtitle = candidate.subtitle {
                                Text(subtitle).font(.caption).foregroundStyle(WorkLogTheme.muted)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selected ? WorkLogTheme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .captureFocus(key(candidate.reference), order: 620 + (rows.firstIndex(of: candidate) ?? 0),
                              action: { toggle(candidate) })
                .accessibilityValue(selected ? "선택됨" : "선택 안 됨")
                .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                    guard canHandle(press) else { return .ignored }
                    let index = rows.firstIndex(of: candidate) ?? 0
                    if press.key == .upArrow && index == 0 { navigation.focus("relatedSearch") }
                    else {
                        let next = min(max(index + (press.key == .upArrow ? -1 : 1), 0), rows.count - 1)
                        navigation.focus(key(rows[next].reference))
                    }
                    return .handled
                }
            }
            Text("↑↓ 이동 · Space / Return 연결·해제")
                .font(.caption).foregroundStyle(WorkLogTheme.muted)
        }
    }
    private func canHandle(_ press: KeyPress) -> Bool {
        !model.isSubmitting && press.modifiers.isEmpty &&
            (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true
    }
    private func reload() {
        do { candidates = try model.searchRelated(query); failed = false }
        catch { candidates = []; failed = true }
    }
    private func toggle(_ candidate: RelatedRecordCandidate) {
        guard !model.isSubmitting else { return }
        if model.relatedRecords.contains(where: { $0.reference == candidate.reference }) {
            model.relatedRecords.removeAll { $0.reference == candidate.reference }
        } else { model.relatedRecords.append(candidate) }
    }
}

/// Edits a WorkDate using the injected calendar/Clock-backed model, never Date().
@MainActor private struct CaptureDateField: View {
    @Bindable var model: CaptureModel
    let calendar: WorkCalendar
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @State private var invalidDate = false
    @State private var dateText: String

    init(model: CaptureModel, calendar: WorkCalendar, onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.model = model; self.calendar = calendar
        self.onConfirm = onConfirm; self.onCancel = onCancel
        self._dateText = State(initialValue: model.workDate.iso)
    }
    private func confirm() {
        guard let date = WorkDate(dateText) else { invalidDate = true; return }
        model.workDate = date
        onConfirm()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("업무일").font(.headline)
            CaptureDateTextField(text: $dateText, model: model, calendar: calendar,
                onConfirm: confirm, onCancel: onCancel,
                onInvalid: { invalidDate = true })
                .frame(width: 220, height: 28)
            if invalidDate {
                Text("날짜를 YYYY-MM-DD 형식으로 입력하세요.")
                    .font(.caption).foregroundStyle(WorkLogTheme.muted)
            }
            WorkDatePicker(title: "달력", value: Binding(
                get: { WorkDate(dateText) ?? model.workDate },
                set: { dateText = $0.iso }), calendar: calendar)
            Text("↑↓ 하루 이동 · T 오늘 · Return 확정 · Esc 취소")
                .font(.caption).foregroundStyle(WorkLogTheme.muted)
            HStack {
                Button("취소", action: onCancel)
                Button("완료", action: confirm)
            }
        }
        .onChange(of: dateText) { _, _ in invalidDate = false }
        .onExitCommand {
            if (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true { onCancel() }
        }
    }
}

@MainActor private struct CaptureDateTextField: NSViewRepresentable {
    @Binding var text: String
    let model: CaptureModel
    let calendar: WorkCalendar
    let onConfirm: () -> Void
    let onCancel: () -> Void
    let onInvalid: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = DateTextField()
        field.stringValue = text
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        field.delegate = context.coordinator
        field.setAccessibilityLabel("업무일, YYYY-MM-DD")
        field.setAccessibilityHelp("위아래 하루 이동, T 오늘, Return 확정, Escape 취소")
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text && (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CaptureDateTextField
        init(_ parent: CaptureDateTextField) { self.parent = parent }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText(),
                  NSApp.currentEvent?.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty != false else { return false }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel(); return true
            }
            guard let field = control as? NSTextField else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
                let base = WorkDate(field.stringValue) ?? parent.model.workDate
                let delta = commandSelector == #selector(NSResponder.moveUp(_:)) ? 1 : -1
                parent.model.workDate = parent.calendar.adding(days: delta, to: base)
                field.stringValue = parent.model.workDate.iso
                parent.text = field.stringValue
                field.selectText(nil)
            case #selector(NSResponder.insertNewline(_:)):
                guard NSApp.currentEvent?.isARepeat != true else { return true }
                guard let date = WorkDate(field.stringValue) else { parent.onInvalid(); return true }
                parent.text = date.iso
                parent.onConfirm()
            default: return false
            }
            return true
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            if field.stringValue.lowercased().contains("t") {
                parent.model.resetWorkDateToToday()
                field.stringValue = parent.model.workDate.iso
                parent.text = field.stringValue
                field.selectText(nil)
            }
            parent.text = field.stringValue
        }
    }
    private final class DateTextField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
                self.selectText(nil)
            }
        }
    }
}

/// Search-field commands stay local and defer to the input method during composition.
@MainActor private struct CaptureTaskSearchField: NSViewRepresentable {
    @Binding var text: String
    @Environment(CaptureKeyboardNavigation.self) private var navigation
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
        (field as? CaptureTaskSearchTextField)?.navigation = navigation
        if field.isEnabled {
            navigation.register("search", order: 200) { [weak field] in
                guard let field else { return }
                field.window?.makeFirstResponder(field)
            }
        } else { navigation.remove("search") }
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

@MainActor private final class CaptureTaskSearchTextField: NSTextField {
    weak var navigation: CaptureKeyboardNavigation?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { navigation?.current = "search" }
        return accepted
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { navigation?.remove("search") }
        super.viewWillMove(toWindow: newWindow)
    }
}

/// Plain Return remains native text insertion; shortcuts are exclusively panel-owned.
@MainActor private struct CaptureTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectionRange: NSRange?
    let model: CaptureModel
    let label: String
    @Environment(CaptureKeyboardNavigation.self) private var navigation
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
        editor.navigation = navigation
        if isEnabled && !model.isSubmitting {
            navigation.register("body", order: 500) { [weak editor] in
                guard let editor else { return }
                editor.window?.makeFirstResponder(editor)
            }
        } else { navigation.remove("body") }
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
    weak var navigation: CaptureKeyboardNavigation?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { navigation?.current = "body" }
        return accepted
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { navigation?.remove("body") }
        super.viewWillMove(toWindow: newWindow)
    }

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
