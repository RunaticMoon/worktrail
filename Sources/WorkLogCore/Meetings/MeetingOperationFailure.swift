import Foundation

/// A meeting failure may cross actor and diagnostic boundaries without carrying user content.
/// Keep the original reviewed phase when another layer adds context to an already classified error.
public struct MeetingOperationFailure: Error, Equatable, Sendable {
    public let phase: DiagnosticState
    public let reason: DiagnosticState
    public let errorDomain: DiagnosticState
    public let errorCode: Int?

    public init(phase: DiagnosticState, reason: DiagnosticState,
                errorDomain: DiagnosticState = .other, errorCode: Int? = nil) {
        self.phase = phase
        self.reason = reason
        switch errorDomain {
        case .cocoa, .posix, .osStatus, .url, .coreML:
            self.errorDomain = errorDomain
            self.errorCode = errorCode
        default:
            self.errorDomain = .other
            self.errorCode = nil
        }
    }

    /// Never retain NSError descriptions, userInfo, arbitrary domains, paths, or associated text.
    public static func sanitized(_ error: Error, phase: DiagnosticState) -> Self {
        if let failure = error as? Self { return failure }
        if error is CancellationError { return Self(phase: phase, reason: .cancelled) }
        if let error = error as? WorkLogError {
            let reason: DiagnosticState
            switch error {
            case .notFound: reason = .notFound
            case .validation, .invalidTransition: reason = .validation
            case .conflict: reason = .conflict
            case .storage: reason = .storage
            case .integrity: reason = .integrity
            case .vaultLocked: reason = .vaultLocked
            case .vaultKeyMissing: reason = .vaultKeyMissing
            case .policyBlocked: reason = .policyBlocked
            }
            return Self(phase: phase, reason: reason)
        }
        let nsError = error as NSError
        let domain: DiagnosticState
        switch nsError.domain {
        case NSCocoaErrorDomain: domain = .cocoa
        case NSPOSIXErrorDomain: domain = .posix
        case NSOSStatusErrorDomain: domain = .osStatus
        case NSURLErrorDomain: domain = .url
        default: domain = .other
        }
        let cancelled = (domain == .url && nsError.code == NSURLErrorCancelled)
            || (domain == .cocoa && nsError.code == CocoaError.Code.userCancelled.rawValue)
        return Self(phase: phase, reason: cancelled ? .cancelled : .failed,
                    errorDomain: domain, errorCode: nsError.code)
    }
}
