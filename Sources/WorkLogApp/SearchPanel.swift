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

    init(model: SearchModel, environment: AppEnvironment, secrets: SecretsModel, onOpenSecrets: @escaping () -> Void) {
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
        guard let model, let environment else { return }
        if !panel.isVisible {
            previousApp = NSWorkspace.shared.frontmostApplication
            // Reuse hosting to preserve scope, title/key selection, filters and scroll.
            if panel.contentView == nil {
                let hosting = NSHostingView(rootView: AnyView(SearchPanelContent(
                    model: model, environment: environment, secrets: secrets, onOpenSecrets: { [weak self] in
                        self?.dismiss(restorePreviousApp: false)
                        self?.onOpenSecrets?()
                    }, onClose: { [weak self] in self?.dismiss() })))
                // The controller owns window bounds; content must not override their constraints.
                hosting.sizingOptions = []
                panel.contentView = hosting
            }
            panel.contentMinSize = NSSize(width: 580, height: 480)
            FloatingPanelPositioning.place(panel)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if let sheet = panel.attachedSheet {
            sheet.makeKeyAndOrderFront(nil)
        } else {
            panel.requestSearchFocus()
        }
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
            SearchScreen(model: model, environment: environment, secrets: secrets, onOpenSecrets: onOpenSecrets)
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
    private var forwardingIME = false
    private var focusRequest = 0
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private var hasMarkedText: Bool {
        (firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }

    override func sendEvent(_ event: NSEvent) {
        guard attachedSheet == nil, event.type == .keyDown, event.keyCode == 53 else {
            super.sendEvent(event)
            return
        }
        if hasMarkedText {
            forwardingIME = true
            defer { forwardingIME = false }
            firstResponder?.keyDown(with: event)
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty {
            if !event.isARepeat { onEscape?() }
            return
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        guard attachedSheet == nil, !forwardingIME, !hasMarkedText else { return }
        onEscape?()
    }

    func requestSearchFocus() {
        focusRequest += 1
        let request = focusRequest
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, self.attachedSheet == nil, request == self.focusRequest else { return }
            self.contentView?.layoutSubtreeIfNeeded()
            _ = self.focusSearchField(in: self.contentView)
        }
    }

    private func focusSearchField(in root: Any?, depth: Int = 0) -> Bool {
        guard depth < 40, let element = root as? NSAccessibilityProtocol else { return false }
        if element.accessibilityLabel() == "원문 검색 또는 AI 질문" || element.accessibilityLabel() == "Secret 제목 검색" {
            element.setAccessibilityFocused(true)
            return true
        }
        for child in element.accessibilityChildren() ?? [] {
            if focusSearchField(in: child, depth: depth + 1) { return true }
        }
        return false
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

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
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
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
#endif
