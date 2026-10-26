// Compiles with the actual application delegate. Calls the decision method only;
// no application event loop, terminate(), storage, account, or microphone access.
import AppKit

@main struct MeetingTerminationCheck {
    @MainActor static func main() {
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
    }

    static func requireThat(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { print("FAIL: \(message)"); exit(1) }
    }
}
