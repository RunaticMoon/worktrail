#if os(macOS)
import AppKit

/// A failed draft save keeps the process and its editors alive, including Command-Q and Dock quit.
@MainActor final class WorkLogApplicationDelegate: NSObject, NSApplicationDelegate {
    var prepareToTerminate: (() -> Bool)?
    var prepareAsyncTermination: (() async -> Bool)?
    /// Tests can observe the async decision without calling AppKit's real quit reply.
    var replyToTermination: ((Bool) -> Void)?
    private var terminationTask: Task<Void, Never>?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let prepareAsyncTermination {
            guard terminationTask == nil else { return .terminateLater }
            terminationTask = Task { [weak self] in
                let allowed = await prepareAsyncTermination()
                self?.terminationTask = nil
                if let reply = self?.replyToTermination { reply(allowed) }
                else { sender.reply(toApplicationShouldTerminate: allowed) }
            }
            return .terminateLater
        }
        return prepareToTerminate?() == false ? .terminateCancel : .terminateNow
    }
}
#endif
