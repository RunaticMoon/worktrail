import XCTest
@testable import WorkLogCore

final class KeychainInteractionTests: XCTestCase {
    private enum Failure: Error { case fixture }

    func testBackgroundOperationSuppressesUIAndRestoresPolicyOnSuccessAndFailure() throws {
        for shouldThrow in [false, true] {
            var allowed = true
            var changes: [Bool] = []
            let gate = KeychainInteractionGate(getAllowed: { allowed }, setAllowed: {
                allowed = $0; changes.append($0)
            })
            do {
                try gate.perform(allowUserInteraction: false) {
                    XCTAssertFalse(allowed)
                    if shouldThrow { throw Failure.fixture }
                }
                XCTAssertFalse(shouldThrow)
            } catch { XCTAssertTrue(shouldThrow) }
            XCTAssertTrue(allowed)
            XCTAssertEqual(changes, [false, true])
        }
    }

    func testInteractiveAndNestedOperationsNeverOverrideDisabledOuterPolicy() throws {
        for initial in [false, true] {
            var allowed = initial
            var changes: [Bool] = []
            let gate = KeychainInteractionGate(getAllowed: { allowed }, setAllowed: {
                allowed = $0; changes.append($0)
            })
            try gate.perform(allowUserInteraction: true) { XCTAssertEqual(allowed, initial) }
            XCTAssertTrue(changes.isEmpty)
            try gate.perform(allowUserInteraction: false) {
                try gate.perform(allowUserInteraction: false) { XCTAssertFalse(allowed) }
                try gate.perform(allowUserInteraction: true) { XCTAssertFalse(allowed) }
            }
            XCTAssertEqual(allowed, initial)
            XCTAssertEqual(changes, initial ? [false, true] : [])
        }
    }

    func testPolicyReadOrDisableFailureNeverCallsCredentialOperation() {
        for failingRead in [true, false] {
            let gate = KeychainInteractionGate(getAllowed: {
                if failingRead { throw Failure.fixture }
                return true
            }, setAllowed: { _ in throw Failure.fixture })
            XCTAssertThrowsError(try gate.perform(allowUserInteraction: false) {
                XCTFail("A failed UI suppression must not attempt Keychain access")
            })
        }
    }

    func testPolicyRestoreFailureIsReportedRatherThanReturningCredential() {
        let gate = KeychainInteractionGate(getAllowed: { true }, setAllowed: { value in
            if value { throw Failure.fixture }
        })
        XCTAssertThrowsError(try gate.perform(allowUserInteraction: false) { "fake-value" })
    }

    func testConcurrentInteractiveOperationWaitsForBackgroundPolicyRestore() throws {
        let entered = expectation(description: "background entered")
        let interactiveStarted = expectation(description: "interactive queued")
        let finished = expectation(description: "both finished"); finished.expectedFulfillmentCount = 2
        let resume = DispatchSemaphore(value: 0)
        var allowed = true
        let gate = KeychainInteractionGate(getAllowed: { allowed }, setAllowed: { allowed = $0 })
        DispatchQueue.global().async {
            try? gate.perform(allowUserInteraction: false) {
                XCTAssertFalse(allowed); entered.fulfill()
                _ = resume.wait(timeout: .now() + 5)
            }
            finished.fulfill()
        }
        wait(for: [entered], timeout: 5)
        DispatchQueue.global().async {
            interactiveStarted.fulfill()
            try? gate.perform(allowUserInteraction: true) { XCTAssertTrue(allowed) }
            finished.fulfill()
        }
        wait(for: [interactiveStarted], timeout: 5)
        resume.signal()
        wait(for: [finished], timeout: 5)
    }
}
