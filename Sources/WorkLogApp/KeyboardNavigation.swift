#if os(macOS)
import AppKit
import SwiftUI

private struct WorkLogContentFocusKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct WorkLogSidebarFocusKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
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
            Button("키보드 단축키") { openWindow(id: "keyboard-shortcuts") }
                .keyboardShortcut("/", modifiers: [.command, .shift])
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
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, window.isVisible,
                          window.isKeyWindow, event.window === window, window.attachedSheet == nil,
                          !self.isHiddenOrHasHiddenAncestor,
                          (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return event }
                    return self.handle?(event) == true ? nil : event
                }
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
                        ("⌘N / ⌘F", "빠른 입력 / 검색 패널 열기"),
                        ("⌘1…6", "오늘 · 업무 · 프로젝트 · 주간보고 · 성과자료 · Secret"),
                        ("⌘7 / ⌘8 / ⌘9", "검색 화면 / 관계 그래프 / 휴지통"),
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
                        ("⌃1 / ⌃2 / ⌃3", "전체 / 기록 / Secret 범위 (패널에서는 ⌘숫자도 가능)"),
                        ("⌃Tab / ⌃⇧Tab", "다음 / 이전 범위"),
                        ("↑↓ / Return", "결과 선택 / 원문 열기"),
                        ("⌘E", "선택한 메모 편집 / 업무 관리"),
                        ("⌘F", "검색어로 포커스 이동"),
                        ("Esc", "원문에서 결과로 복귀 / 패널 닫기"),
                    ])
                    shortcuts("오늘 · 상세 편집", rows: [
                        ("⌘⌥1 / ⌘⌥2 / ⌘⌥3", "활동 기록 / 업무 상태 / 메모"),
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
