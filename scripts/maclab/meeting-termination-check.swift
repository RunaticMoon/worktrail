// Compiles with the actual application delegate. Calls the decision method only;
// no application event loop, terminate(), storage, account, or microphone access.
import AppKit

@main struct MeetingTerminationCheck {
    @MainActor static func main() async {
        let application = NSApplication.shared
        let delegate = WorkLogApplicationDelegate()

        requireThat(delegate.applicationShouldTerminate(application) == .terminateNow,
                    "Startup without a save callback should permit termination")
        print("PASS: an unset startup callback permits termination")

        var canSave = false
        var attempts = 0
        delegate.prepareToTerminate = {
            attempts += 1
            return canSave
        }
        requireThat(delegate.applicationShouldTerminate(application) == .terminateCancel && attempts == 1,
                    "A failed draft save must cancel termination")
        print("PASS: a failed save returns terminateCancel")

        requireThat(delegate.applicationShouldTerminate(application) == .terminateCancel && attempts == 2,
                    "A repeated quit request must recheck the failed save")
        print("PASS: repeated quit requests recheck the save callback")

        canSave = true
        requireThat(delegate.applicationShouldTerminate(application) == .terminateNow && attempts == 3,
                    "A successful retry must permit termination")
        print("PASS: a successful save retry returns terminateNow")

        delegate.prepareToTerminate = nil
        requireThat(delegate.applicationShouldTerminate(application) == .terminateNow && attempts == 3,
                    "An unset callback must not call a stale save handler")
        print("PASS: clearing the callback does not retain a stale cancellation")

        var replies: [Bool] = []
        var asynchronousAttempts = 0
        var firstDecision: CheckedContinuation<Bool, Never>?
        delegate.replyToTermination = { replies.append($0) }
        delegate.prepareAsyncTermination = {
            asynchronousAttempts += 1
            return await withCheckedContinuation { firstDecision = $0 }
        }
        requireThat(delegate.applicationShouldTerminate(application) == .terminateLater,
                    "Recording shutdown must defer the quit decision")
        requireThat(delegate.applicationShouldTerminate(application) == .terminateLater,
                    "A second request must wait for the same async shutdown")
        await waitUntil { firstDecision != nil }
        requireThat(asynchronousAttempts == 1 && replies.isEmpty, "Concurrent quit requests must not duplicate draining or reply early")
        print("PASS: async shutdown defers termination and concurrent quit requests share one drain")

        firstDecision?.resume(returning: false)
        await waitUntil { replies.count == 1 }
        requireThat(replies == [false], "Failed async save must reply with cancellation")
        print("PASS: failed async save returns a cancellation through the injected reply")

        delegate.prepareAsyncTermination = { asynchronousAttempts += 1; return true }
        requireThat(delegate.applicationShouldTerminate(application) == .terminateLater,
                    "Successful retry must still wait for async drain")
        await waitUntil { replies.count == 2 }
        requireThat(replies == [false, true] && asynchronousAttempts == 2, "A completed shutdown must permit a fresh successful retry")
        print("PASS: async retry succeeds without invoking real application termination")
        delegate.prepareAsyncTermination = nil
        delegate.replyToTermination = nil
    }

    @MainActor static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        requireThat(false, "Timed out waiting for fake asynchronous quit decision")
    }

    static func requireThat(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { print("FAIL: \(message)"); exit(1) }
    }
}
