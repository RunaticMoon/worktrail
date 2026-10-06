#if os(macOS)
import SwiftUI
import AppKit
import WorkLogCore

@MainActor final class SearchPanelController: NSObject, NSWindowDelegate {
    private let panel: SearchKeyboardPanel
    private var model: SearchModel?
    private var environment: AppEnvironment?
    private var secrets: SecretsModel?
    private var onOpenSecrets: (() -> Void)?
    private var previousApp: NSRunningApplication?

    init(model: SearchModel, environment: AppEnvironment, secrets: SecretsModel?, onOpenSecrets: @escaping () -> Void) {
        self.model = model
        self.environment = environment
        self.secrets = secrets
        self.onOpenSecrets = onOpenSecrets
        panel = SearchKeyboardPanel(contentRect: NSRect(x: 0, y: 0, width: 740, height: 640),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.title = "WorkLog 검색"
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: 580, height: 480)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
        panel.onEscape = { [weak self] in self?.dismiss() }
    }

    func show() {
        guard model != nil, environment != nil else { return }
        if !panel.isVisible {
            previousApp = NSWorkspace.shared.frontmostApplication
            ensureHosting()
            panel.contentMinSize = NSSize(width: 580, height: 480)
            FloatingPanelPositioning.place(panel)
        }
        ensureHosting()
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        if let sheet = panel.attachedSheet {
            sheet.makeKeyAndOrderFront(nil)
        } else {
            panel.requestSearchFocus { [weak self] in
                guard let self else { return }
                self.installHosting()
                self.panel.requestSearchFocus()
            }
        }
    }

    private func ensureHosting() {
        guard let hosting = panel.contentView as? NSHostingView<AnyView>,
              hosting.window === panel, !hosting.isHidden else {
            installHosting(); return
        }
    }

    private func installHosting() {
        guard let model, let environment else { return }
        let hosting = NSHostingView(rootView: AnyView(SearchPanelContent(
            model: model, environment: environment, secrets: secrets, onOpenSecrets: { [weak self] in
                self?.dismiss(restorePreviousApp: false)
                self?.onOpenSecrets?()
            }, onClose: { [weak self] in self?.dismiss() })))
        hosting.sizingOptions = []
        panel.contentView = hosting
    }

    func dismiss(restorePreviousApp: Bool = true) {
        // Leave an open source sheet to handle its own Escape / Close action.
        guard panel.attachedSheet == nil else { return }
        hidePanel()
        if restorePreviousApp,
           previousApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp?.activate(options: [])
        }
        previousApp = nil
    }

    /// Release all repository owners before backup restoration replaces the database.
    func teardown() {
        if let sheet = panel.attachedSheet { panel.endSheet(sheet); sheet.orderOut(nil) }
        hidePanel()
        panel.onEscape = nil
        panel.searchKeyHandler = nil
        panel.delegate = nil
        model = nil
        environment = nil
        secrets = nil
        onOpenSecrets = nil
        if let hosting = panel.contentView as? NSHostingView<AnyView> { hosting.rootView = AnyView(EmptyView()) }
        panel.contentView = nil
        previousApp = nil
    }

    private func hidePanel() {
        panel.makeFirstResponder(nil)
        panel.initialFirstResponder = nil
        panel.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }
}

@MainActor private struct SearchPanelContent: View {
    let model: SearchModel
    let environment: AppEnvironment
    let secrets: SecretsModel?
    let onOpenSecrets: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.callout).fontWeight(.semibold)
                        .foregroundStyle(WorkLogTheme.accent)
                        .frame(width: 28, height: 28)
                        .background(WorkLogTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                    Text("WorkLog").font(.headline)
                    Text("/ 검색").font(.callout).foregroundStyle(WorkLogTheme.muted)
                    Spacer()
                    Keycap("esc")
                }
                .overlay(SearchWindowDragArea())
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.callout).fontWeight(.semibold)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(WorkLogButtonStyle())
                .accessibilityLabel("검색 패널 닫기")
                .worklogHelp("닫고 이전 앱으로 돌아가기", keys: "Esc")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(WorkLogTheme.surface)
            Rectangle().fill(WorkLogTheme.border).frame(height: 1)
            SearchScreen(model: model, environment: environment, secrets: secrets,
                onOpenSecrets: onOpenSecrets, isPanel: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(WorkLogTheme.text)
        .tint(WorkLogTheme.accent)
        .background(WorkLogTheme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: WorkLogTheme.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: WorkLogTheme.cornerRadius, style: .continuous)
                .strokeBorder(WorkLogTheme.border, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

/// Keep the header draggable without intercepting the close button or search controls.
@MainActor private struct SearchWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

/// Escape cancels input composition before dismissing the panel.
@MainActor private final class SearchKeyboardPanel: NSPanel {
    var onEscape: (() -> Void)?
    var searchKeyHandler: ((NSEvent, Bool) -> Bool)?
    private var forwardingIME = false
    private var focusRequest = 0
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private var hasMarkedText: Bool {
        (firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }

    override func sendEvent(_ event: NSEvent) {
        guard attachedSheet == nil, event.type == .keyDown else { super.sendEvent(event); return }
        if hasMarkedText {
            if event.keyCode == 53 {
                forwardingIME = true
                defer { forwardingIME = false }
                firstResponder?.keyDown(with: event)
            } else { super.sendEvent(event) }
            return
        }
        let editing = firstResponder is NSTextView || firstResponder is NSTextField
        if searchKeyHandler?(event, editing) == true { return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53, modifiers.isEmpty {
            if !event.isARepeat { onEscape?() }
            return
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        guard attachedSheet == nil, !forwardingIME, !hasMarkedText else { return }
        onEscape?()
    }

    func requestSearchFocus(recover: (() -> Void)? = nil) {
        focusRequest += 1
        attemptSearchFocus(request: focusRequest, remaining: 3, recover: recover)
    }

    private func attemptSearchFocus(request: Int, remaining: Int, recover: (() -> Void)?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self, self.isVisible, self.attachedSheet == nil, request == self.focusRequest else { return }
            self.contentView?.layoutSubtreeIfNeeded()
            if let field = self.searchField(in: self.contentView), self.makeFirstResponder(field) {
                self.initialFirstResponder = field
                if (field.currentEditor() as? NSTextInputClient)?.hasMarkedText() != true { field.selectText(nil) }
                return
            }
            if remaining > 0 { self.attemptSearchFocus(request: request, remaining: remaining - 1, recover: recover) }
            else { recover?() }
        }
    }

    private func searchField(in root: NSView?) -> SearchQueryTextField? {
        guard let root else { return nil }
        if let field = root as? SearchQueryTextField { return field }
        for child in root.subviews {
            if let field = searchField(in: child) { return field }
        }
        return nil
    }
}

/// A window-scoped monitor handles navigation before NSTextView consumes arrows.
/// It leaves marked text and standard editing chords to the input method/AppKit.
@MainActor struct SearchKeyboardBridge: NSViewRepresentable {
    let handle: (NSEvent, Bool) -> Bool

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView(); view.handle = handle; return view
    }
    func updateNSView(_ view: KeyView, context: Context) { view.handle = handle }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.stopMonitoring() }

    final class KeyView: NSView {
        var handle: ((NSEvent, Bool) -> Bool)?
        private var monitor: Any?

        private weak var keyboardPanel: SearchKeyboardPanel?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            if let panel = window as? SearchKeyboardPanel {
                keyboardPanel = panel
                panel.searchKeyHandler = { [weak self] event, editing in self?.handle?(event, editing) == true }
                return
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                var handled = false
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, window.isVisible,
                          window.isKeyWindow, event.window === window, window.attachedSheet == nil else { return }
                    let responder = window.firstResponder
                    guard (responder as? NSTextInputClient)?.hasMarkedText() != true else { return }
                    let editing = responder is NSTextView || responder is NSTextField
                    handled = self.handle?(event, editing) == true
                }
                return handled ? nil : event
            }
        }
        func stopMonitoring() {
            keyboardPanel?.searchKeyHandler = nil
            keyboardPanel = nil
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
/// A concrete AppKit field lets a borderless panel guarantee first responder and select-all.
@MainActor final class SearchQueryTextField: NSTextField {}

@MainActor struct SearchQueryField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var allowsAIQuestion: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SearchQueryTextField {
        let field = SearchQueryTextField(string: text)
        field.placeholderString = allowsAIQuestion ? "기록·Secret 제목을 찾거나, 업무에 대해 질문하세요" : "Secret 제목·그룹명을 찾으세요"
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.setAccessibilityLabel(allowsAIQuestion ? "통합 검색 또는 AI 질문" : "Secret 제목 검색")
        field.setAccessibilityHelp("↑↓ 결과 선택 · Return 열기 · Secret은 AI로 보내지 않습니다")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: SearchQueryTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = allowsAIQuestion ? "기록·Secret 제목을 찾거나, 업무에 대해 질문하세요" : "Secret 제목·그룹명을 찾으세요"
        field.setAccessibilityLabel(allowsAIQuestion ? "통합 검색 또는 AI 질문" : "Secret 제목 검색")
        if (field.currentEditor() as? NSTextInputClient)?.hasMarkedText() != true, field.stringValue != text { field.stringValue = text }
        if isFocused, field.currentEditor() == nil {
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window, window.isKeyWindow,
                      context.coordinator.parent.isFocused else { return }
                window.makeFirstResponder(field)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchQueryField
        init(_ parent: SearchQueryField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.isFocused = true }
        func controlTextDidEndEditing(_ notification: Notification) { parent.isFocused = false }
    }
}
#endif
