import Foundation
import XCTest
@testable import WorkLogCore

final class MeetingOperationFailureTests: XCTestCase {
    func testNestedClassificationPreservesOriginalPhaseAndKnownCode() {
        let original = MeetingOperationFailure.sanitized(
            NSError(domain: NSCocoaErrorDomain, code: 260,
                    userInfo: [NSLocalizedDescriptionKey: "/fake/private/model-path"]), phase: .modelLoading)
        XCTAssertEqual(original, MeetingOperationFailure(phase: .modelLoading, reason: .failed,
                                                        errorDomain: .cocoa, errorCode: 260))
        XCTAssertEqual(MeetingOperationFailure.sanitized(original, phase: .preview), original)
    }

    func testUnknownDomainsAndUnreviewedDomainStatesDiscardNumericCodes() {
        let failure = MeetingOperationFailure.sanitized(
            NSError(domain: "FAKE_PRIVATE_DOMAIN", code: 123_456,
                    userInfo: [NSLocalizedDescriptionKey: "FAKE_PRIVATE_DESCRIPTION"]), phase: .inference)
        XCTAssertEqual(failure, MeetingOperationFailure(phase: .inference, reason: .failed))
        XCTAssertNil(MeetingOperationFailure(phase: .inference, reason: .failed,
                                            errorDomain: .unknown, errorCode: 123_456).errorCode)
    }

    func testReviewedNSErrorDomainsPreserveOnlyNumericCode() {
        let domains: [(String, DiagnosticState)] = [
            (NSCocoaErrorDomain, .cocoa), (NSPOSIXErrorDomain, .posix),
            (NSOSStatusErrorDomain, .osStatus), (NSURLErrorDomain, .url)
        ]
        for (domain, state) in domains {
            let failure = MeetingOperationFailure.sanitized(NSError(domain: domain, code: 123), phase: .refined)
            XCTAssertEqual(failure.errorDomain, state)
            XCTAssertEqual(failure.errorCode, 123)
            XCTAssertEqual(failure.reason, .failed)
        }
        let modelFailure = MeetingOperationFailure(phase: .modelLoading, reason: .failed,
                                                   errorDomain: .coreML, errorCode: 17)
        XCTAssertEqual(MeetingOperationFailure.sanitized(modelFailure, phase: .preview), modelFailure)
        XCTAssertEqual(modelFailure.errorCode, 17)
    }

    func testCancellationRemainsDistinctAcrossSwiftAndFoundationErrors() {
        let errors: [Error] = [CancellationError(),
                               NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
                               CocoaError(.userCancelled)]
        for error in errors {
            let failure = MeetingOperationFailure.sanitized(error, phase: .diarization)
            XCTAssertEqual(failure.reason, .cancelled)
            XCTAssertEqual(failure.phase, .diarization)
        }
    }

    func testStorageAndSourceValidationKeepTypedReasonsWithoutAssociatedText() {
        let errors: [(WorkLogError, DiagnosticState)] = [
            (.storage("FAKE_PRIVATE_PATH"), .storage),
            (.conflict("FAKE_PRIVATE_TRANSCRIPT"), .conflict),
            (.validation("FAKE_PRIVATE_DESCRIPTION"), .validation)
        ]
        for (error, reason) in errors {
            XCTAssertEqual(MeetingOperationFailure.sanitized(error, phase: .refined),
                           MeetingOperationFailure(phase: .refined, reason: reason))
        }
    }
}
