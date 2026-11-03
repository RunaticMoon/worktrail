import Foundation

/// Process-lifetime cache over the app's service credential store.
/// Keychain approval is requested once in the foreground (launch check, manual sync or
/// settings) and background work reuses the approved value without opening a dialog.
/// Values stay in memory only; never log, persist or expose them.
public final class CachingServiceCredentialStore: ServiceCredentialStore, @unchecked Sendable {
    private enum Entry { case value(String), missing }
    private let base: any ServiceCredentialStore
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Bumped on every write/delete so a read that raced a change cannot cache a stale value.
    private var generations: [String: Int] = [:]

    public init(_ base: any ServiceCredentialStore) { self.base = base }

    public func read(account: String) throws -> String? {
        try read(account: account, allowAuthenticationUI: false)
    }

    public func read(account: String, allowAuthenticationUI: Bool) throws -> String? {
        let (entry, generation) = snapshot(account)
        switch entry {
        case .value(let value)?: return value
        case .missing?: return nil
        case nil: break
        }
        // The base store serializes Keychain access itself; do not hold the cache lock while
        // a Keychain dialog waits for the user.
        let value = try base.read(account: account, allowAuthenticationUI: allowAuthenticationUI)
        lock.lock(); defer { lock.unlock() }
        if generations[account, default: 0] == generation { entries[account] = value.map(Entry.value) ?? .missing }
        return value
    }

    public func write(_ credential: String, account: String) throws {
        invalidate(account)
        try base.write(credential, account: account)
        lock.lock(); defer { lock.unlock() }
        entries[account] = .value(credential)
    }

    public func delete(account: String) throws {
        invalidate(account)
        try base.delete(account: account)
        lock.lock(); defer { lock.unlock() }
        entries[account] = .missing
    }

    /// Reads each account once, allowing the authentication UI, so later background reads
    /// are served from memory. Stops at the first refusal so a cancelled dialog is not followed
    /// by more dialogs, and returns the accounts that remain unapproved.
    @discardableResult
    public func authorize(accounts: [String]) -> [String] {
        var seen = Set<String>(), pending: [String] = []
        for account in accounts where seen.insert(account).inserted {
            guard pending.isEmpty else { pending.append(account); continue }
            do { _ = try read(account: account, allowAuthenticationUI: true) } catch { pending.append(account) }
        }
        return pending
    }

    private func snapshot(_ account: String) -> (Entry?, Int) {
        lock.lock(); defer { lock.unlock() }
        return (entries[account], generations[account, default: 0])
    }

    private func invalidate(_ account: String) {
        lock.lock(); defer { lock.unlock() }
        entries[account] = nil
        generations[account, default: 0] += 1
    }
}
