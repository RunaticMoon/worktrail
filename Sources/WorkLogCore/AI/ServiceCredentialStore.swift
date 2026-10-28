import Foundation

/// App-owned service credentials only. Never persist in settings, work.sqlite, logs or backups.
public protocol ServiceCredentialStore: Sendable {
    func read(account: String) throws -> String?
    /// Background work must fail without opening an authentication dialog.
    /// Explicit settings checks and manual sync may request user interaction.
    func read(account: String, allowAuthenticationUI: Bool) throws -> String?
    func write(_ credential: String, account: String) throws
    func delete(account: String) throws
}

public extension ServiceCredentialStore {
    /// Existing in-memory and non-Keychain implementations need no UI policy.
    func read(account: String, allowAuthenticationUI: Bool) throws -> String? {
        try read(account: account)
    }
}
