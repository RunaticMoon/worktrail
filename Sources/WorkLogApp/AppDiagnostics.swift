#if os(macOS)
import Foundation
import WorkLogCore

/// Only typed, content-free events cross this boundary. Disk I/O stays off audio/UI callbacks.
final class AppDiagnostics: @unchecked Sendable {
    static let shared = AppDiagnostics()
    private let queue = DispatchQueue(label: "dev.worklog.diagnostics", qos: .utility)
    private let store: DiagnosticLogStore?
    private let context: [DiagnosticField: DiagnosticValue]

    init(directory: URL? = nil, clock: any Clock = SystemClock()) {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var context: [DiagnosticField: DiagnosticValue] = [
            .osMajor: .integer(os.majorVersion), .osMinor: .integer(os.minorVersion), .osPatch: .integer(os.patchVersion)
        ]
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            .split(separator: ".")
        if version.count == 3, let major = Int(version[0]), let minor = Int(version[1]), let patch = Int(version[2]) {
            context[.appVersionMajor] = .integer(major)
            context[.appVersionMinor] = .integer(minor)
            context[.appVersionPatch] = .integer(patch)
        }
        self.context = context
        if ProcessInfo.processInfo.environment["WORKLOG_DIAGNOSTICS_DISABLED"] == "1" {
            store = nil
            return
        }
        let root: URL
        if let directory { root = directory }
        else {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-test-fixture") {
                root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("WorkLog-Diagnostics-Fixture-" + UUIDGenerator().make())
            } else { root = Self.standardDirectory }
            #else
            root = Self.standardDirectory
            #endif
        }
        store = DiagnosticLogStore(directory: root, clock: clock)
    }

    private static var standardDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WorkLog", isDirectory: true)
    }

    func record(_ event: DiagnosticEvent, category: DiagnosticCategory,
                level: DiagnosticLevel = .info, fields: [DiagnosticField: DiagnosticValue] = [:]) {
        let fields = fields.merging(context) { _, value in value }
        queue.async { [store] in _ = store?.record(event, category: category, level: level, fields: fields) }
    }

    /// Never serialize NSError descriptions, userInfo, domains, paths, or associated error text.
    func recordFailure(_ error: Error, category: DiagnosticCategory, stage: DiagnosticState? = nil) {
        if let failure = error as? MeetingOperationFailure {
            var fields: [DiagnosticField: DiagnosticValue] = [
                .phase: .state(failure.phase), .reason: .state(failure.reason),
                .errorDomain: .state(failure.errorDomain)
            ]
            if let stage { fields[.stage] = .state(stage) }
            if let code = failure.errorCode { fields[.errorCode] = .integer(code) }
            record(.operationFailed, category: category,
                   level: failure.reason == .cancelled ? .info : .error, fields: fields)
            return
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
        var fields: [DiagnosticField: DiagnosticValue] = [
            .errorDomain: .state(domain), .reason: .state(Self.reason(for: error))
        ]
        if let stage { fields[.stage] = .state(stage) }
        if domain != .other { fields[.errorCode] = .integer(nsError.code) }
        record(.operationFailed, category: category, level: error is CancellationError ? .info : .error, fields: fields)
    }

    private static func reason(for error: Error) -> DiagnosticState {
        if error is CancellationError { return .cancelled }
        if let error = error as? WorkLogError {
            switch error {
            case .notFound: return .notFound
            case .validation, .invalidTransition: return .validation
            case .conflict: return .conflict
            case .storage: return .storage
            case .integrity: return .integrity
            case .vaultLocked: return .vaultLocked
            case .vaultKeyMissing: return .vaultKeyMissing
            case .policyBlocked: return .policyBlocked
            }
        }
        if let error = error as? AIProviderError {
            switch error.errorClass {
            case .notInstalled: return .unavailable
            case .notLoggedIn, .authExpired: return .authentication
            case .policyRestricted: return .policyBlocked
            case .rateLimited: return .rateLimit
            case .network: return .network
            case .protocolMismatch: return .unsupported
            case .outputInvalid: return .schemaInvalid
            case .cancelled: return .cancelled
            case .timeout: return .timeout
            case .unknown: return .unknown
            }
        }
        return .failed
    }

    func maintenance() { queue.async { [store] in _ = store?.maintenance() } }

    func status() async -> DiagnosticLogStatus? {
        await withCheckedContinuation { continuation in
            queue.async { [store] in continuation.resume(returning: store?.status()) }
        }
    }

    func exportReport() async throws -> Data {
        let metadata = DiagnosticReportMetadata(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [store] in
                do {
                    guard let store else { throw CocoaError(.fileReadUnknown) }
                    continuation.resume(returning: try store.exportReport(metadata: metadata))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func deleteAll() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [store] in
                do {
                    guard let store else { throw CocoaError(.fileWriteUnknown) }
                    try store.deleteAll()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func flush() { queue.sync {} }
}
#endif
