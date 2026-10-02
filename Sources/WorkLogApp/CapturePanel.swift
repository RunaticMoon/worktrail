#if os(macOS)
import SwiftUI
import AppKit
import WorkLogCore

@MainActor final class CapturePanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private var previousApp: NSRunningApplication?
    init(model: CaptureModel, calendar: WorkCalendar, onSaved: @escaping () -> Void) {
        panel = KeyboardPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.title = "빠른 입력"; panel.level = .floating
        panel.contentMinSize = NSSize(width: 480, height: 480)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: CaptureScreen(model: model, calendar: calendar,
            onSave: { [weak self] in
                if model.submit() { onSaved(); self?.dismiss() }
            }, onDismiss: { [weak self] in self?.dismiss() }))
        (panel as? KeyboardPanel)?.onEscape = { [weak self] in self?.dismiss() }
        (panel as? KeyboardPanel)?.onSave = { [weak self] in
            if model.submit() { onSaved(); self?.dismiss() }
        }
        panel.center()
    }
    func show() {
        if !panel.isVisible { previousApp = NSWorkspace.shared.frontmostApplication }
        NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
        if let responder = panel.initialFirstResponder { panel.makeFirstResponder(responder) }
    }
    private func dismiss() {
        panel.orderOut(nil)
        if previousApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp?.activate(options: [])
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }
    func closeForSecretEntry() { panel.orderOut(nil) }
}

private final class KeyboardPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onSave: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if (event.keyCode == 36 || event.keyCode == 76) && event.modifierFlags.contains(.command) {
            if let editor = firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            onSave?(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct CaptureScreen: View {
    @Bindable var model: CaptureModel
    let calendar: WorkCalendar
    let onSave: () -> Void
    let onDismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("기록 종류", selection: $model.kind) {
                    ForEach(RecordCaptureKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                WorkDatePicker(title: "업무일", value: $model.workDate, calendar: calendar)
            }
            if model.kind == .activity {
                Picker("대상 업무", selection: $model.targetTaskId) {
                    Text("업무 선택").tag(String?.none)
                    ForEach(model.tasks) { Text($0.title).tag(Optional($0.id)) }
                }
            }
            if model.kind == .task {
                Picker("등록 상태", selection: $model.initialStatus) {
                    ForEach(TaskStatus.allCases, id: \.self) { Text($0.koreanLabel).tag($0) }
                }
                Toggle("프로젝트별 적용 상태 관리", isOn: Binding(
                    get: { model.projectTrackingMode == .perProject },
                    set: { model.projectTrackingMode = $0 ? .perProject : .shared }))
            }
            Text(model.kind == .task ? "첫 줄은 업무명, 다음 줄은 진행 내용입니다." : "기록 내용")
                .font(.callout).foregroundStyle(.secondary)
            CaptureTextEditor(text: $model.text, selectionRange: $model.selectionRange,
                onSave: onSave, onDismiss: onDismiss)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            if !model.selectedProjectIds.isEmpty || !model.selectedTagIds.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(model.selectedProjectIds, id: \.self) { id in
                            Button("@\(model.projects.first { $0.id == id }?.name ?? "프로젝트") 제거") { model.removeProject(id) }
                        }
                        if model.kind != .activity {
                            ForEach(model.selectedTagIds, id: \.self) { id in
                                Button("#\(model.tags.first { $0.id == id }?.name ?? "태그") 제거") { model.removeTag(id) }
                            }
                        }
                    }
                }
            }
            if !model.candidates.isEmpty {
                ScrollView { VStack(alignment: .leading) {
                    ForEach(model.candidates) { candidate in
                        Button(candidate.isNew ? "‘\(candidate.name)’ 새로 만들기" : candidate.name) { model.select(candidate) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }}.frame(maxHeight: 100).accessibilityLabel("자동완성 후보")
            }
            if let error = model.errorMessage { InlineNotice(message: error) }
            HStack {
                Text("@ 프로젝트 · # 태그\n⌘Return 저장 · Return 줄바꿈 · Esc 초안 보존")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("닫기", action: onDismiss).keyboardShortcut(.cancelAction)
                Button("저장", action: onSave).disabled(model.isSubmitting)
            }
        }.padding(16)
    }
}

/// Intercept Return only after IME composition finishes, so Hangul confirmation cannot submit.
private struct CaptureTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectionRange: NSRange?
    let onSave: () -> Void
    let onDismiss: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let editor = CaptureNSTextView()
        editor.isRichText = false; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.font = NSFont.preferredFont(forTextStyle: .body, options: [:])
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.minSize = NSSize(width: 0, height: 140)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.onSave = onSave; editor.onDismiss = onDismiss
        editor.setAccessibilityLabel("기록 내용")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = editor
        context.coordinator.editor = editor
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = context.coordinator.editor else { return }
        editor.font = NSFont.preferredFont(forTextStyle: .body, options: [:])
        editor.onSave = onSave; editor.onDismiss = onDismiss
        if editor.string != text && !editor.hasMarkedText() {
            // Assigning string can synchronously notify the delegate and reset the selection.
            let desiredSelection = selectionRange ?? NSRange(location: (text as NSString).length, length: 0)
            editor.string = text
            if NSMaxRange(desiredSelection) <= (text as NSString).length {
                editor.setSelectedRange(desiredSelection)
            }
        }
        if view.window?.isKeyWindow == true && view.window?.firstResponder == view.window {
            view.window?.makeFirstResponder(editor)
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

private final class CaptureNSTextView: NSTextView {
    var onSave: (() -> Void)?
    var onDismiss: (() -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // NSHostingView may attach before the panel becomes key; the controller also focuses on show.
        if let window { window.initialFirstResponder = self }
    }
    override func keyDown(with event: NSEvent) {
        if hasMarkedText() { super.keyDown(with: event); return }
        if event.keyCode == 53 { onDismiss?(); return }
        if event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(nil) }
            else { window?.selectNextKeyView(nil) }
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.command) { onSave?() }
            else { insertNewline(nil) }
            return
        }
        super.keyDown(with: event)
    }
}
#endif
