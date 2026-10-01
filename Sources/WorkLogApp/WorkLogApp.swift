#if os(macOS)
import SwiftUI
import AppKit
import WorkLogCore

@main @MainActor struct WorkLogApp: App {
    @State private var controller = AppController()
    var body: some Scene {
        WindowGroup("WorkLog", id: "main") {
            AppRootView(controller: controller)
                .frame(minWidth: 720, minHeight: 480)
                .task { await controller.start() }
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("빠른 입력") { controller.showCapture() }.keyboardShortcut("n", modifiers: .command)
                Button("검색") { controller.showSearch() }.keyboardShortcut("f", modifiers: .command)
            }
        }
        MenuBarExtra("WorkLog", systemImage: "square.and.pencil") {
            ResidentMenu(controller: controller)
        }
    }
}

private struct ResidentMenu: View {
    let controller: AppController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("WorkLog 열기") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("빠른 입력") { controller.showCapture() }.disabled(controller.environment == nil)
        Button("검색") { controller.showSearch() }.disabled(controller.environment == nil)
        Divider()
        Button("종료") { controller.environment?.lockSecrets(.appQuit); NSApp.terminate(nil) }
    }
}
#else
@main struct WorkLogApp {
    static func main() {
        print("WorkLogApp은 macOS 전용입니다. Linux에서는 WorkLogCore와 worklog CLI만 빌드·테스트합니다.")
    }
}
#endif
