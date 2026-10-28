import Foundation

/// App-owned service credentials only. Never persist in settings, work.sqlite, logs or backups.
public protocol ServiceCredentialStore: Sendable {
    func read(account: String) throws -> String?
    func write(_ credential: String, account: String) throws
    func delete(account: String) throws
}
