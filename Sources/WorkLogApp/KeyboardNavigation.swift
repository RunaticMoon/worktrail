#if os(macOS)
import AppKit
import SwiftUI

/// Native sidebar selection changes the destination while the list keeps focus.
/// Screens may autofocus on normal entry, but must not interrupt that navigation.
private struct WorkLogContentAutofocusKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var worklogContentAutofocus: Bool {
        get { self[WorkLogContentAutofocusKey.self] }
        set { self[WorkLogContentAutofocusKey.self] = newValue }
    }
}

private struct WorkLogContentFocusKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct WorkLogSidebarFocusKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct WorkLogProjectCreationKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var worklogCreateProject: (() -> Void)? {
        get { self[WorkLogProjectCreationKey.self] }
        set { self[WorkLogProjectCreationKey.self] = newValue }
    }
    var worklogFocusContent: (() -> Void)? {
        get { self[WorkLogContentFocusKey.self] }
        set { self[WorkLogContentFocusKey.self] = newValue }
    }
    var worklogFocusSidebar: (() -> Void)? {
        get { self[WorkLogSidebarFocusKey.self] }
        set { self[WorkLogSidebarFocusKey.self] = newValue }
    }
}

extension View {
    /// Scene focus values keep menu actions in the active window, including sheets.
    func worklogFocusContent(_ action: @escaping () -> Void) -> some View {
        focusedSceneValue(\.worklogFocusContent, action)
    }

    /// SwiftUI focus can live in the hosting view instead of the native button.
    /// Keep activation available with Full Keyboard Access off as well.
    func worklogKeyboardActivation(_ action: @escaping () -> Void) -> some View {
        modifier(WorkLogKeyboardActivation(action: action))
    }
}

private struct WorkLogKeyboardActivation: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onKeyPress(keys: [.return, .space], phases: [.down, .repeat]) { press in
            guard isEnabled, press.modifiers.isEmpty, !worklogHasMarkedText else { return .ignored }
            if press.phase == .down { action() }
            return .handled
        }
    }
}

@MainActor struct WorkLogFocusCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.worklogFocusSidebar) private var focusSidebar
    @FocusedValue(\.worklogFocusContent) private var focusContent

    private var canMoveFocus: Bool {
        guard let window = NSApp.keyWindow else { return false }
        return !(window is NSPanel) && window.attachedSheet == nil && window.sheetParent == nil
    }

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("사이드바로 이동") {
                guard canMoveFocus, !worklogHasMarkedText else { return }
                focusSidebar?()
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(focusSidebar == nil || !canMoveFocus)
            Button("현재 화면 내용으로 이동") {
                guard canMoveFocus, !worklogHasMarkedText else { return }
                focusContent?()
            }
            .keyboardShortcut("0", modifiers: [.command, .shift])
            .disabled(focusContent == nil || !canMoveFocus)
        }
        CommandGroup(replacing: .help) {
            Button("키보드 단축키") { KeyboardHelpFocusRestoration.shared.open(using: openWindow) }
                .keyboardShortcut("k", modifiers: [.command, .option])
        }
    }
}

/// Help is a separate window, so AppKit does not always restore the originating
/// sheet's text editor when it closes. Keep only weak references to that context.
@MainActor final class KeyboardHelpFocusRestoration {
    static let shared = KeyboardHelpFocusRestoration()
    private weak var originWindow: NSWindow?
    private weak var originResponder: NSResponder?
    private weak var helpWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var request = 0

    func open(using openWindow: OpenWindowAction) {
        request += 1
        if let window = NSApp.keyWindow, window !== helpWindow {
            var origin = window
            while let sheet = origin.attachedSheet, sheet.isVisible { origin = sheet }
            originWindow = origin
            if let editor = origin.firstResponder as? NSTextView, editor.isFieldEditor,
               let field = editor.delegate as? NSView {
                // A shared field editor can detach on focus loss; restore its control.
                originResponder = field
            } else {
                originResponder = origin.firstResponder
            }
        }
        openWindow(id: "keyboard-shortcuts")
    }

    fileprivate func observe(_ window: NSWindow) {
        guard helpWindow !== window || closeObserver == nil else { return }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        helpWindow = window
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.helpWillClose() }
            }
    }

    private func helpWillClose() {
        // SwiftUI can reopen this same NSWindow without moving its hosting view.
        // Keep its observer until observe(_:) attaches to a different window.
        let currentRequest = request
        // Wait only for this close event to finish; never reactivate the app or
        // retain a closed editor while the user switches to another application.
        DispatchQueue.main.async { [weak self, weak window = originWindow, weak responder = originResponder] in
            guard let self, self.request == currentRequest else { return }
            self.originWindow = nil
            self.originResponder = nil
            guard NSApp.isActive, let window, window.isVisible else { return }
            var parent = window
            while let sheetParent = parent.sheetParent { parent = sheetParent }
            guard parent.isVisible else { return }
            parent.makeKeyAndOrderFront(nil)
            var destination = window
            while let sheet = destination.attachedSheet, sheet.isVisible { destination = sheet }
            destination.makeKeyAndOrderFront(nil)
            // A newly presented sheet takes precedence over the old responder.
            guard destination === window, let responder else { return }
            if let view = responder as? NSView {
                guard view.window === destination, !view.isHiddenOrHasHiddenAncestor else { return }
            }
            destination.makeFirstResponder(responder)
        }
    }
}

@MainActor private struct KeyboardHelpWindowObserver: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowView { WindowView() }
    func updateNSView(_ view: WindowView, context: Context) {}

    final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { KeyboardHelpFocusRestoration.shared.observe(window) }
        }
    }
}

@MainActor var worklogHasMarkedText: Bool {
    (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
}

/// Shortcuts that must work while a text control is first responder. Callers
/// handle only their explicit chords; ordinary typing stays with the responder.
@MainActor struct WorkLogKeyHandler: NSViewRepresentable {
    let handle: (NSEvent) -> Bool

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.handle = handle
        return view
    }
    func updateNSView(_ view: KeyView, context: Context) { view.handle = handle }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.stopMonitoring() }

    final class KeyView: NSView {
        var handle: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                var handled = false
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, window.isVisible,
                          window.isKeyWindow, event.window === window, window.attachedSheet == nil,
                          !self.isHiddenOrHasHiddenAncestor,
                          (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return }
                    handled = self.handle?(event) == true
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

struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("키보드로 WorkLog 사용하기").font(.title2.bold())
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    shortcuts("앱 화면", rows: [
                        ("⌘N", "프로젝트: 새 프로젝트 · 업무: 새 업무 · 그 외: 빠른 입력"),
                        ("⌘F", "검색 패널 열기"),
                        ("⌘1…5", "오늘 · 업무 · 프로젝트 · 주간보고 · 성과자료"),
                        ("⌘6 / ⌘7 / ⌘8 / ⌘9", "리포트 보관함 / Secret / 검색 화면 / 관계 그래프"),
                        ("휴지통 / 백업", "사이드바 또는 보기 메뉴의 이전·다음 화면으로 이동"),
                        ("⌘,", "설정"),
                        ("⌘⌥← / ⌘⌥→", "이전 / 다음 화면 (백업·설정 포함)"),
                        ("⌘0 / ⌘⇧0", "사이드바 / 현재 화면 내용으로 포커스 이동"),
                        ("↑↓ / Return", "목록 선택 / 선택 항목 열기"),
                        ("⌘⌥F", "업무·Secret 이름 검색 / 검색 화면 필터"),
                        ("→ / ←", "프로젝트에서 업무 목록 / 프로젝트 목록 복귀"),
                    ])
                    shortcuts("빠른 입력", rows: [
                        ("⌘1 / ⌘2 / ⌘3", "메모 / 업무 / Secret 탭"),
                        ("⌃Tab / ⌃⇧Tab", "다음 / 이전 탭"),
                        ("⌘⇧] / ⌘⇧[", "다음 / 이전 탭"),
                        ("Tab / ⇧Tab", "다음 / 이전 입력 항목"),
                        ("⌘E / ⌘L", "본문·Secret 제목 편집 / 업무 선택"),
                        ("⌘⇧Return / ⌘⇧⌫", "Secret 행 추가 / 현재 행 삭제"),
                        ("Return / ⌘Return", "본문 줄바꿈 / 저장하고 닫기"),
                        ("Esc", "초안을 보존하고 닫기"),
                    ])
                    shortcuts("검색", rows: [
                        ("⌃1…5 / 패널 ⌘1…5", "1 전체 / 2 기록 / 3 업무 / 4 Secret / 5 리포트"),
                        ("Control / 패널 Command", "누르고 있는 동안 범위 탭에 단축키 표시"),
                        ("⌃Tab / ⌃⇧Tab", "다음 / 이전 범위"),
                        ("Tab / ⇧Tab", "검색어에서 결과로 / 결과에서 검색어로 포커스 이동"),
                        ("↑↓ / Return", "결과 선택 / 원문 열기"),
                        ("⌘E", "선택한 메모 편집 / 업무 관리"),
                        ("⌘F", "검색어로 포커스 이동"),
                        ("Esc", "원문에서 결과로 복귀 / 패널 닫기"),
                    ])
                    shortcuts("오늘 · 상세 편집", rows: [
                        ("⌘⌥1…5", "활동 기록 / 업무 상태 / 메모 / GitHub / Jira"),
                        ("⌃Tab / ⌃⇧Tab", "오늘 화면의 다음 / 이전 탭"),
                        ("⌘E", "메모 본문 편집 / 업무 진행 기록 입력"),
                        ("⌘L / ⌘⇧J", "업무 상세 동작 / 체크리스트 입력"),
                        ("⌘S / ⌘Return", "메모 수정 저장"),
                        ("Esc", "상세 닫기 (저장하지 않은 메모 수정은 확인 후 처리)"),
                    ])
                    Text("한글 조합 중에는 입력기가 키를 먼저 처리합니다. 전역 입력·검색 핫키는 설정에서 변경할 수 있습니다.")
                        .font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 480, idealHeight: 720)
        .background(KeyboardHelpWindowObserver())
    }

    private func shortcuts(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(rows[index].0).font(.system(.callout, design: .monospaced))
                        .frame(width: 180, alignment: .leading)
                    Text(rows[index].1).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
#endif
