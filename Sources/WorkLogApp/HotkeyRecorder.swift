#if os(macOS)
import AppKit
import SwiftUI
import WorkLogCore

/// Settings owns persistence and global hotkey suspension; this view only records a binding.
@MainActor
struct HotkeyRecorder: View {
    let title: String
    let binding: HotkeyBinding?
    let rawValue: String
    let onRecord: (HotkeyBinding) -> Void
    let onBeginRecording: () -> Void
    let onEndRecording: () -> Void

    @StateObject private var recorder = HotkeyRecordingState()

    init(title: String, binding: HotkeyBinding?, rawValue: String,
         onRecord: @escaping (HotkeyBinding) -> Void,
         onBeginRecording: @escaping () -> Void,
         onEndRecording: @escaping () -> Void) {
        self.title = title
        self.binding = binding
        self.rawValue = rawValue
        self.onRecord = onRecord
        self.onBeginRecording = onBeginRecording
        self.onEndRecording = onEndRecording
    }

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 6) {
                HotkeyRecorderButton(
                    recorder: recorder, title: title,
                    display: binding?.displayString ?? rawValue,
                    onRecord: onRecord, onBegin: onBeginRecording, onEnd: onEndRecording
                )
                .frame(minWidth: 170, minHeight: 28)
                .overlay {
                    if recorder.isRecording {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
                if recorder.isRecording {
                    Text(recorder.errorMessage ?? "Esc로 취소")
                        .font(.caption)
                        .foregroundStyle(recorder.errorMessage == nil ? Color.secondary : Color.primary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } label: {
            Text(title)
        }
        .onDisappear { recorder.finish() }
    }
}

@MainActor
private final class HotkeyRecordingState: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var modifierDisplay = ""
    @Published private(set) var errorMessage: String?

    weak var button: HotkeyRecordingButton?
    var onRecord: (HotkeyBinding) -> Void = { _ in }
    var onBegin: () -> Void = {}
    var onEnd: () -> Void = {}

    private var callbacks: (record: (HotkeyBinding) -> Void, end: () -> Void)?
    private var isEnding = false
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private static let willBegin = Notification.Name("WorkLog.HotkeyRecorder.willBegin")

    @objc func begin() {
        guard !isRecording, !isEnding, let button, let window = button.window,
              window.isKeyWindow, window.makeFirstResponder(button) else { return }

        // End the previous recorder synchronously, before suspending hotkeys for this one.
        NotificationCenter.default.post(name: Self.willBegin, object: self)
        guard button.window === window, window.isKeyWindow,
              window.firstResponder === button else { return }
        callbacks = (onRecord, onEnd)
        isRecording = true
        modifierDisplay = ""
        errorMessage = nil
        observe(Self.willBegin) { [weak self] notification in
            guard let self, notification.object as? HotkeyRecordingState !== self else { return }
            self.finish()
        }
        observe(NSApplication.didResignActiveNotification) { [weak self] _ in self?.finish() }
        observe(NSWindow.didResignKeyNotification, object: window) { [weak self] _ in self?.finish() }
        observe(NSWindow.willCloseNotification, object: window) { [weak self] _ in self?.finish() }

        onBegin()
        // The callback may close the settings window or otherwise cancel recording.
        guard isRecording else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isRecording else { return event }
                self.receive(event)
                return nil
            }
        }
        // Buttons and empty areas do not always change AppKit's first responder.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isRecording, let button = self.button else { return event }
                let point = button.convert(event.locationInWindow, from: nil)
                if event.window !== button.window || !button.bounds.contains(point) { self.finish() }
                return event
            }
        }
        guard keyMonitor != nil, mouseMonitor != nil else { finish(); return }
        announce("단축키를 누르세요. 수정자와 키를 함께 누르세요. Esc로 취소합니다.")
    }

    /// Consume the session before invoking callbacks so every exit path is idempotent.
    func finish(with binding: HotkeyBinding? = nil) {
        guard let callbacks else { return }
        self.callbacks = nil
        isEnding = true
        isRecording = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        keyMonitor = nil
        mouseMonitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        modifierDisplay = ""
        errorMessage = nil
        // Update the draft before asking the caller to resume its global registrations.
        if let binding { callbacks.record(binding) }
        callbacks.end()
        isEnding = false
    }

    private func receive(_ event: NSEvent) {
        guard let button, event.window === button.window,
              button.window?.firstResponder === button else { finish(); return }
        guard !event.isARepeat else { return }
        let modifiers = Self.modifiers(from: event.modifierFlags)
        if event.type == .flagsChanged {
            errorMessage = nil
            modifierDisplay = modifiers.sorted().map { modifier in
                switch modifier {
                case .control: return "⌃"
                case .option: return "⌥"
                case .shift: return "⇧"
                case .command: return "⌘"
                }
            }.joined()
            return
        }
        if event.keyCode == 53, modifiers.isEmpty {
            finish()
            announce("단축키 변경을 취소했습니다.")
            return
        }
        do {
            guard let key = HotkeyKey.fromMacVirtualKeyCode(event.keyCode) else {
                throw HotkeyBindingError.unsupportedKey("키 코드 \(event.keyCode)")
            }
            let binding = try HotkeyBinding(key: key, modifiers: modifiers)
            finish(with: binding)
            announce("단축키를 \(binding.displayString)로 변경했습니다.")
        } catch {
            errorMessage = error.localizedDescription
            announce(error.localizedDescription)
        }
    }

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> Set<HotkeyModifier> {
        var result: Set<HotkeyModifier> = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    private func observe(_ name: Notification.Name, object: AnyObject? = nil,
                         action: @escaping @MainActor (Notification) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { notification in
            MainActor.assumeIsolated { action(notification) }
        })
    }

    private func announce(_ message: String) {
        guard let button else { return }
        NSAccessibility.post(element: button, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

@MainActor
private struct HotkeyRecorderButton: NSViewRepresentable {
    @ObservedObject var recorder: HotkeyRecordingState
    let title: String
    let display: String
    let onRecord: (HotkeyBinding) -> Void
    let onBegin: () -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> HotkeyRecordingButton {
        let button = HotkeyRecordingButton()
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.focusRingType = .exterior
        button.cell?.lineBreakMode = .byTruncatingMiddle
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.target = recorder
        button.action = #selector(HotkeyRecordingState.begin)
        button.onFocusLost = { [weak recorder] in recorder?.finish() }
        return button
    }

    func updateNSView(_ button: HotkeyRecordingButton, context: Context) {
        recorder.button = button
        recorder.onRecord = onRecord
        recorder.onBegin = onBegin
        recorder.onEnd = onEnd
        button.title = recorder.isRecording
            ? (recorder.modifierDisplay.isEmpty ? "단축키를 누르세요…" : recorder.modifierDisplay + "…")
            : (display.isEmpty ? "설정되지 않음" : display)
        button.toolTip = recorder.isRecording ? "수정자와 키를 함께 누르세요. Esc로 취소합니다." : display
        button.setAccessibilityLabel("\(title) 단축키, 현재 \(display.isEmpty ? "설정되지 않음" : display). 눌러서 변경")
        button.setAccessibilityHelp(recorder.isRecording ? "단축키를 누르세요. Esc로 취소합니다." : "Space 또는 Return으로 단축키 녹화를 시작합니다.")
    }

    // The coordinator retains the state until dismantling, even if the SwiftUI view disappears.
    func makeCoordinator() -> HotkeyRecordingState { recorder }

    static func dismantleNSView(_ button: HotkeyRecordingButton, coordinator: HotkeyRecordingState) {
        coordinator.finish()
        button.onFocusLost = nil
        button.target = nil
        coordinator.button = nil
    }
}

@MainActor
private final class HotkeyRecordingButton: NSButton {
    var onFocusLost: (@MainActor () -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusLost?() }
        return resigned
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window != nil, newWindow !== window { onFocusLost?() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func keyDown(with event: NSEvent) {
        if !event.isARepeat, event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty,
           event.keyCode == 49 || event.keyCode == 36 {
            performClick(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
#endif
