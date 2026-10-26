#if os(macOS)
import AppKit

/// A failed draft save keeps the process and its editors alive, including Command-Q and Dock quit.
@MainActor final class WorkLogApplicationDelegate: NSObject, NSApplicationDelegate {
    var prepareToTerminate: (() -> Bool)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        prepareToTerminate?() == false ? .terminateCancel : .terminateNow
    }
}
#endif
