import Foundation
import Observation

@Observable @MainActor
public final class ActivityIntegrationsModel {
    public var draft = ActivityIntegrationSettings()
    public var githubToken = ""
    public var jiraToken = ""
    public private(set) var message: String?
    public private(set) var isRunning = false
    public private(set) var isLoaded = false
    private var saved = ActivityIntegrationSettings()
    private let store: ActivityIntegrationSettingsStore
    private let credentials: any ServiceCredentialStore
    private var repo: WorkRepository?
    private let client: ActivityAPIClient
    private let automaticInterval: TimeInterval
    /// Last attempt per connection in this process; the first pass after launch always collects.
    private var lastAttempts: [String: Date] = [:]
    private let onDiagnostic: @Sendable (DiagnosticEvent, DiagnosticLevel, [DiagnosticField: DiagnosticValue]) -> Void
    public var isDirty: Bool { draft != saved || !githubToken.isEmpty || !jiraToken.isEmpty }

    public init(dataRoot: URL, repo: WorkRepository, credentials: any ServiceCredentialStore,
                client: ActivityAPIClient = ActivityAPIClient(),
                automaticInterval: TimeInterval = ActivityIntegrationsModel.automaticSyncInterval,
                onDiagnostic: @escaping @Sendable (DiagnosticEvent, DiagnosticLevel, [DiagnosticField: DiagnosticValue]) -> Void = { _, _, _ in }) {
        store = ActivityIntegrationSettingsStore(dataRoot: dataRoot)
        self.repo = repo; self.credentials = credentials; self.client = client
        self.automaticInterval = automaticInterval
        self.onDiagnostic = onDiagnostic
        load()
    }

    public func load() {
        guard repo != nil else { return }
        do { saved = try store.load(); draft = saved; isLoaded = true }
        catch {
            onDiagnostic(.operationFailed, .error, [.phase: .state(.starting)])
            message = "활동 수집 설정을 읽지 못했습니다. 기존 파일을 확인하세요."
        }
    }

    public func save() {
        guard repo != nil, isLoaded, !isRunning else { return }
        do {
            for connection in draft.connections where connection.enabled { try connection.validate() }
            let updates = [(draft.github, githubToken), (draft.jira, jiraToken)].filter { !$0.1.isEmpty }
            // Validate every destination before changing any credential, including disabled services.
            for (connection, token) in updates {
                try connection.validate()
                guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !token.contains(where: { $0.isNewline }) else {
                    throw WorkLogError.validation("\(connection.source.title) 토큰 형식을 확인하세요.")
                }
            }
            let prior = try updates.map { (account: $0.0.credentialAccount,
                value: try credentials.read(account: $0.0.credentialAccount, allowAuthenticationUI: true)) }
            var changed: [Int] = []
            do {
                for (index, update) in updates.enumerated() {
                    try credentials.write(update.1.trimmingCharacters(in: .whitespacesAndNewlines), account: update.0.credentialAccount)
                    changed.append(index)
                }
                try store.save(draft)
            } catch {
                var rollbackFailed = false
                for index in changed.reversed() {
                    do {
                        if let value = prior[index].value { try credentials.write(value, account: prior[index].account) }
                        else { try credentials.delete(account: prior[index].account) }
                    } catch { rollbackFailed = true }
                }
                if rollbackFailed { throw WorkLogError.validation("일부 API 토큰을 되돌리지 못했습니다. 각 서비스의 토큰을 다시 저장하세요.") }
                throw error
            }
            saved = draft; githubToken = ""; jiraToken = ""
            message = "활동 수집 설정을 저장했습니다. API 토큰은 Keychain에만 보관합니다."
        } catch {
            onDiagnostic(.operationFailed, .error, [:])
            message = safeMessage(error)
        }
    }

    public func removeToken(for source: ActivitySource) {
        guard repo != nil, !isRunning else { return }
        let connection = source == .github ? draft.github : draft.jira
        do {
            try credentials.delete(account: connection.credentialAccount)
            if source == .github { githubToken = "" } else { jiraToken = "" }
            message = "\(source.title) 토큰을 삭제했습니다. 수집을 계속하려면 새 토큰을 입력하세요."
        } catch {
            onDiagnostic(.operationFailed, .error, [:])
            message = "API 토큰을 삭제하지 못했습니다."
        }
    }

    /// Automatic collection interval while the app runs. Failures wait for the same interval;
    /// there is no tighter retry loop. Manual sync is an explicit retry at any time.
    nonisolated public static let automaticSyncInterval: TimeInterval = 60 * 60

    /// Collects each enabled service when it is due: on the first pass after launch, then once its
    /// last attempt in this process is at least `automaticInterval` old (or the clock moved back).
    public func sync(manual: Bool = false) async {
        guard let repo, isLoaded, !isRunning else { return }
        if manual && isDirty { message = "수집 전에 설정을 저장하세요."; return }
        let now = repo.clock.now()
        let today = repo.calendar.workDate(of: now)
        let connections = saved.connections.filter { connection in
            guard connection.enabled else { return false }
            let elapsed = lastAttempts[connection.credentialAccount].map { now.timeIntervalSince($0) }
            return manual || elapsed.map { $0 >= automaticInterval || $0 < 0 } ?? true
        }
        guard !connections.isEmpty else {
            if manual { message = "수집할 서비스를 켜고 설정을 저장하세요." }
            return
        }
        isRunning = true
        onDiagnostic(.operationStarted, .info, [.itemCount: .integer(connections.count)])
        defer { isRunning = false }
        var results: [String] = []
        var needsApproval = false
        for connection in connections {
            do {
                try Task.checkCancellation()
                lastAttempts[connection.credentialAccount] = repo.clock.now()
                try repo.recordActivitySyncAttempt(connection: connection)
                let stored: String?
                do {
                    stored = try credentials.read(account: connection.credentialAccount, allowAuthenticationUI: manual)
                } catch let error as AIProviderError where error.errorClass == .notLoggedIn {
                    // The app collects after its launch check approves access; report the
                    // remaining approval once instead of once per service.
                    onDiagnostic(.operationFailed, .error, [.reason: .state(.failed)])
                    needsApproval = true; continue
                }
                guard let token = stored, !token.isEmpty else {
                    throw WorkLogError.validation("\(connection.source.title) API 토큰을 입력하고 저장하세요.")
                }
                // A success recorded under a clock that later moved back must not invert the range.
                let last = try repo.activitySyncCompletedAt(connection: connection).map { min(repo.calendar.workDate(of: $0), today) }
                let earliest = repo.calendar.adding(days: -29, to: today)
                let start = max(earliest, repo.calendar.adding(days: -7, to: last ?? today))
                let range = DateRange(start: start, endExclusive: repo.calendar.adding(days: 1, to: today))
                let response = try await client.fetch(connection: connection, token: token, range: range, calendar: repo.calendar)
                try Task.checkCancellation()
                let count = try repo.importActivities(response.activities, connection: connection)
                try repo.recordActivitySyncAttempt(connection: connection, completed: true)
                onDiagnostic(.operationSucceeded, .info, [.itemCount: .integer(count)])
                results.append("\(connection.source.title): 새 기록 \(count)개")
                results.append(contentsOf: response.warnings)
                if let last, last < earliest { results.append("30일 이전 누락 기록은 API 보존 범위 밖일 수 있습니다.") }
            } catch is CancellationError {
                onDiagnostic(.operationFailed, .info, [.reason: .state(.cancelled)])
                break
            } catch {
                onDiagnostic(.operationFailed, .error, [.reason: .state(.failed)])
                results.append(safeMessage(error))
            }
        }
        if needsApproval { results.append(Self.keychainApprovalMessage) }
        if !results.isEmpty { message = results.joined(separator: "\n") }
    }

    /// Enabled saved connections whose tokens the app reads once in the foreground at launch.
    public var launchCredentialAccounts: [String] {
        isLoaded && repo != nil ? saved.connections.filter(\.enabled).map(\.credentialAccount) : []
    }

    /// One message for every service; macOS asks per item and only 항상 허용 keeps later background reads silent.
    public static let keychainApprovalMessage = "Keychain 접근 승인이 필요합니다. ‘지금 가져오기’를 누르고 macOS 창에서 ‘항상 허용’을 선택하면 이후 자동으로 수집합니다."

    /// Call only after an active sync finishes. Stale UI tasks must not reopen the old database after restore.
    public func detach() {
        guard !isRunning else { return }
        repo = nil; isLoaded = false; githubToken = ""; jiraToken = ""
    }

    private func safeMessage(_ error: Error) -> String {
        if let error = error as? AIProviderError, error.errorClass == .notLoggedIn {
            return Self.keychainApprovalMessage
        }
        if case WorkLogError.validation(let message) = error { return message }
        return "활동 수집을 완료하지 못했습니다. 설정·Keychain 접근·사내망 연결을 확인하세요."
    }
}
