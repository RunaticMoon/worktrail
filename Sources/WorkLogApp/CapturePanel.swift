#if os(macOS)
import SwiftUI
import AppKit
import WorkLogCore

@MainActor final class CapturePanelController: NSObject, NSWindowDelegate {
    private let panel: KeyboardPanel
    private var session: CaptureSessionModel?
    private var secrets: SecretsModel?
    private let calendar: WorkCalendar
    private var onSaved: (() -> Void)?
    private var previousApp: NSRunningApplication?

    init(session: CaptureSessionModel, secrets: SecretsModel, calendar: WorkCalendar,
         onSaved: @escaping () -> Void) {
        self.session = session
        self.secrets = secrets
        self.calendar = calendar
        self.onSaved = onSaved
        panel = KeyboardPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.title = "빠른 입력"
        panel.level = .floating
        panel.contentMinSize = NSSize(width: 480, height: 480)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.onEscape = { [weak self] in self?.dismiss() }
        panel.onCycleTab = { [weak self] backwards in
            self?.session?.cycleTab(backwards: backwards)
        }
        panel.onOrdinarySave = { [weak self] in
            guard let self, self.session?.isSecretTab == false else { return false }
            self.saveOrdinary()
            return true
        }
        panel.center()
    }

    func show() {
        guard let session, let secrets else { return }
        session.beginSession()
        if !panel.isVisible {
            previousApp = NSWorkspace.shared.frontmostApplication
            panel.contentView = NSHostingView(rootView: AnyView(CaptureScreen(
                session: session, secrets: secrets, calendar: calendar,
                onSave: { [weak self] in self?.saveOrdinary() },
                onConfirmCompletion: { [weak self] in
                    guard let self, self.session?.taskDraft.confirmCompletion() == true else { return }
                    self.finishSave()
                },
                onSecretSaved: { [weak self] in self?.finishSave() },
                onDismiss: { [weak self] in self?.dismiss() })))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel)
        panel.requestDefaultFocus(for: session.tab)
    }

    /// Called before backup restoration. A torn-down controller is not reusable.
    func teardown() {
        dismiss(restorePreviousApp: false)
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

    private func saveOrdinary() {
        guard let session, !session.isSecretTab, session.submitOrdinary() else { return }
        finishSave()
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

    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }
}

/// All panel shortcuts are routed here exactly once, before SwiftUI or field editors.
@MainActor private final class KeyboardPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onCycleTab: ((Bool) -> Void)?
    /// false means the Secret editor must receive its own Command-Return shortcut.
    var onOrdinarySave: (() -> Bool)?
    private var focusRequest = 0
    private var forwardingIME = false
    override var canBecomeKey: Bool { true }

    private var hasMarkedText: Bool {
        if let input = firstResponder as? NSTextInputClient { return input.hasMarkedText() }
        return false
    }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown else { super.sendEvent(event); return }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if hasMarkedText && (event.keyCode == 48 || event.keyCode == 53 || isReturn) {
            // Bypass key equivalents as well: a composed Command-Return must not save.
            forwardingIME = true
            defer { forwardingIME = false }
            firstResponder?.keyDown(with: event)
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
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
        guard !forwardingIME, !hasMarkedText else { return }
        onEscape?()
    }

    func requestDefaultFocus(for tab: CaptureKind) {
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
                if let search = self.findView(in: self.contentView, matching: { $0 is CaptureTaskSearchTextField }) {
                    self.makeFirstResponder(search)
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
    let onSave: () -> Void
    let onConfirmCompletion: () -> Void
    let onSecretSaved: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("입력 탭", selection: Binding(get: { session.tab }, set: { session.select($0) })) {
                Text("메모").tag(CaptureKind.memo)
                Text("업무").tag(CaptureKind.task)
                Text("시크릿").tag(CaptureKind.secret)
            }.pickerStyle(.segmented)
            HStack {
                Text("Tab ⇥ 다음 · ⇧Tab 이전").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let draft = session.activeDraft {
                    WorkDatePicker(title: "업무일", value: Binding(
                        get: { draft.workDate }, set: { draft.workDate = $0 }), calendar: calendar)
                        .disabled(draft.isSubmitting || draft.pendingCompletion != nil)
                }
            }
            Divider()
            switch session.tab {
            case .memo:
                ScrollView {
                    CaptureDraftEditor(model: session.memoDraft, label: "기록 내용", showsTokens: true)
                        .padding(1)
                }
            case .task:
                CaptureTaskContent(model: session.taskDraft, onConfirmCompletion: onConfirmCompletion)
            case .secret:
                SecretCaptureView(model: secrets, onSaved: onSecretSaved, onCancel: onDismiss)
            }
            if let draft = session.activeDraft {
                if let error = draft.errorMessage { InlineNotice(message: error) }
                Divider()
                Text("⇥ 탭 전환 · ⌘↩ 저장 · ↩ 줄바꿈 · Esc 닫기(초안 보존)")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("⌥⇥ 필드 이동").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if draft.isSubmitting { ProgressView().controlSize(.small) }
                    Button("닫기", action: onDismiss)
                    Button("저장", action: onSave).disabled(draft.isSubmitting)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CaptureFocusAnchor(tab: session.tab))
    }
}

/// Refocus after a tab switch, including switches made with the segmented control.
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
    @FocusState private var focusedRow: String?
    private var keys: [String] { ["new"] + model.filteredTasks.map { "task:\($0.id)" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("업무 검색").font(.callout)
                CaptureTaskSearchField(text: $model.taskQuery,
                    isDisabled: model.isSubmitting || model.pendingCompletion != nil,
                    onMove: { move($0, focusRow: false) }, onSelect: { choose(highlighted) })
                    .frame(height: 24)
                VStack(spacing: 0) {
                    taskRow(key: "new", title: "+ New task", status: nil)
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(model.filteredTasks) { task in
                                    taskRow(key: "task:\(task.id)", title: task.title,
                                            status: task.cachedStatus?.koreanLabel ?? "상태 없음")
                                        .id("task:\(task.id)")
                                }
                                if model.filteredTasks.isEmpty {
                                    Text("검색된 업무가 없습니다. 위에서 새 업무를 만드세요.")
                                        .font(.callout).foregroundStyle(.secondary).padding(8)
                                }
                            }.padding(4)
                        }
                        .frame(height: model.filteredTasks.isEmpty ? 48 : 112)
                        .onChange(of: highlighted) { _, key in proxy.scrollTo(key) }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                .disabled(model.isSubmitting || model.pendingCompletion != nil)
                .accessibilityLabel("업무 선택 목록")
                switch model.taskSelection {
                case .newTask:
                    Picker("등록 상태", selection: $model.initialStatus) {
                        ForEach(TaskStatus.allCases, id: \.self) { Text($0.koreanLabel).tag($0) }
                    }
                    Toggle("프로젝트별 적용 상태 관리", isOn: Binding(
                        get: { model.projectTrackingMode == .perProject },
                        set: { model.projectTrackingMode = $0 ? .perProject : .shared }))
                    CaptureDraftEditor(model: model, label: "첫 줄은 업무명, 다음 줄은 진행 내용입니다.", showsTokens: true)
                case .existing(let id):
                    HStack(alignment: .top) {
                        Text(model.tasks.first { $0.id == id }?.title ?? "선택한 업무")
                            .font(.headline).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("다른 업무 선택") { focusSearch() }
                    }
                    .disabled(model.pendingCompletion != nil)
                    Picker("업무 동작", selection: $model.taskAction) {
                        Text("진행기록 추가").tag(CaptureTaskAction.addActivity)
                        Text("상태 변경").tag(CaptureTaskAction.changeStatus)
                    }.pickerStyle(.segmented).disabled(model.pendingCompletion != nil)
                    if model.taskAction == .addActivity {
                        CaptureDraftEditor(model: model, label: "진행기록 내용", showsTokens: false)
                    } else {
                        statusContent
                    }
                }
            }.padding(1)
        }
        .onChange(of: model.taskQuery) { _, _ in highlighted = "new" }
        .onAppear {
            if case .existing(let id) = model.taskSelection { highlighted = "task:\(id)" }
        }
    }

    private func taskRow(key: String, title: String, status: String?) -> some View {
        Button { choose(key) } label: {
            HStack {
                Text(title).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if let status {
                    Text(status).font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                }
                if highlighted == key { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted == key ? Color.accentColor.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusable().focused($focusedRow, equals: key)
        .accessibilityLabel(status.map { "\(title), \($0)" } ?? title)
        .accessibilityValue(highlighted == key ? "선택됨" : "")
        .onKeyPress(.upArrow) { move(-1, focusRow: true); return .handled }
        .onKeyPress(.downArrow) { move(1, focusRow: true); return .handled }
        .onKeyPress(.return) { choose(key); return .handled }
    }

    @ViewBuilder private var statusContent: some View {
        if let check = model.pendingCompletion {
            VStack(alignment: .leading, spacing: 8) {
                Text("남은 항목이 있습니다. 그래도 완료할까요?").font(.headline)
                ForEach(check.remainingChecklist) { item in
                    Label(item.text, systemImage: "square").font(.callout)
                }
                ForEach(check.unfinishedProjects.indices, id: \.self) { index in
                    let project = check.unfinishedProjects[index]
                    Text("\(model.projects.first { $0.id == project.projectId }?.name ?? "프로젝트") · \(project.status.koreanLabel)")
                        .font(.callout)
                }
                HStack {
                    Button("취소") { model.cancelCompletion() }
                    Button("그래도 완료", action: onConfirmCompletion).disabled(model.isSubmitting)
                }
            }
        } else {
            Picker("변경할 상태", selection: $model.statusTarget) {
                Text("상태 선택").tag(TaskStatus?.none)
                ForEach(model.availableStatusTargets(), id: \.self) { Text($0.koreanLabel).tag(Optional($0)) }
            }
            if model.availableStatusTargets().isEmpty {
                Text("현재 상태에서 변경할 수 있는 상태가 없습니다.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func move(_ delta: Int, focusRow: Bool) {
        let rows = keys
        let index = rows.firstIndex(of: highlighted) ?? 0
        highlighted = rows[min(max(index + delta, 0), rows.count - 1)]
        if focusRow { focusedRow = highlighted }
    }

    private func choose(_ key: String) {
        guard !model.isSubmitting, model.pendingCompletion == nil else { return }
        highlighted = key
        if key == "new" { model.taskSelection = .newTask }
        else if let task = model.filteredTasks.first(where: { "task:\($0.id)" == key }) {
            if model.taskSelection != .existing(task.id) { model.statusTarget = nil }
            model.taskSelection = .existing(task.id)
        }
    }

    private func focusSearch() { (NSApp.keyWindow as? KeyboardPanel)?.requestDefaultFocus(for: .task) }
}

@MainActor private struct CaptureDraftEditor: View {
    @Bindable var model: CaptureModel
    let label: String
    let showsTokens: Bool
    private var excluding: Set<RecordReference> {
        if case .existing(let id) = model.taskSelection { return [RecordReference(kind: .task, id: id)] }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            CaptureTextEditor(text: $model.text, selectionRange: $model.selectionRange)
                .frame(height: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            if showsTokens {
                Text("@ 프로젝트 · # 태그").font(.caption).foregroundStyle(.secondary)
                if !model.selectedProjectIds.isEmpty || !model.selectedTagIds.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(model.selectedProjectIds, id: \.self) { id in
                                Button("@\(model.projects.first { $0.id == id }?.name ?? "프로젝트") 제거") { model.removeProject(id) }
                            }
                            ForEach(model.selectedTagIds, id: \.self) { id in
                                Button("#\(model.tags.first { $0.id == id }?.name ?? "태그") 제거") { model.removeTag(id) }
                            }
                        }.padding(.vertical, 2)
                    }
                }
                if !model.candidates.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(model.candidates) { candidate in
                                Button(candidate.isNew ? "‘\(candidate.name)’ 새로 만들기" : candidate.name) { model.select(candidate) }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.frame(maxHeight: 100).accessibilityLabel("자동완성 후보")
                }
            }
            RelatedRecordPicker(selection: $model.relatedRecords, search: model.searchRelated,
                                excluding: excluding, isDisabled: model.isSubmitting)
        }.disabled(model.isSubmitting)
    }
}

/// Search-field commands stay local and defer to the input method during composition.
@MainActor private struct CaptureTaskSearchField: NSViewRepresentable {
    @Binding var text: String
    let isDisabled: Bool
    let onMove: (Int) -> Void
    let onSelect: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = CaptureTaskSearchTextField()
        field.placeholderString = "업무명 검색"
        field.bezelStyle = .roundedBezel
        field.font = NSFont.preferredFont(forTextStyle: .body, options: [:])
        field.delegate = context.coordinator
        field.setAccessibilityLabel("업무 검색")
        field.setAccessibilityHelp("위아래 화살표로 업무를 고르고 Return으로 선택합니다.")
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = !isDisabled
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
            guard !parent.isDisabled, !textView.hasMarkedText(),
                  NSApp.currentEvent?.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty != false else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
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
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let editor = CaptureNSTextView()
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.font = NSFont.preferredFont(forTextStyle: .body, options: [:])
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.minSize = NSSize(width: 0, height: 140)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel("기록 내용")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = editor
        context.coordinator.editor = editor
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = context.coordinator.editor else { return }
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

@MainActor private final class CaptureNSTextView: NSTextView {}
#endif
