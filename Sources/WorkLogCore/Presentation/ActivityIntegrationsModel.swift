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
    public var isDirty: Bool { draft != saved || !githubToken.isEmpty || !jiraToken.isEmpty }

    public init(dataRoot: URL, repo: WorkRepository, credentials: any ServiceCredentialStore,
                client: ActivityAPIClient = ActivityAPIClient()) {
        store = ActivityIntegrationSettingsStore(dataRoot: dataRoot)
        self.repo = repo; self.credentials = credentials; self.client = client
        load()
    }

    public func load() {
        guard repo != nil else { return }
        do { saved = try store.load(); draft = saved; isLoaded = true }
        catch { message = "활동 수집 설정을 읽지 못했습니다. 기존 파일을 확인하세요." }
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
            let prior = try updates.map { (account: $0.0.credentialAccount, value: try credentials.read(account: $0.0.credentialAccount)) }
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
        } catch { message = safeMessage(error) }
    }

    public func removeToken(for source: ActivitySource) {
        guard repo != nil, !isRunning else { return }
        let connection = source == .github ? draft.github : draft.jira
        do {
            try credentials.delete(account: connection.credentialAccount)
            if source == .github { githubToken = "" } else { jiraToken = "" }
            message = "\(source.title) 토큰을 삭제했습니다. 수집을 계속하려면 새 토큰을 입력하세요."
        } catch { message = "API 토큰을 삭제하지 못했습니다." }
    }

    /// One automatic attempt per work day. Manual sync is an explicit retry; no background retry loops.
    public func sync(manual: Bool = false) async {
        guard let repo, isLoaded, !isRunning else { return }
        if manual && isDirty { message = "수집 전에 설정을 저장하세요."; return }
        let today = repo.calendar.workDate(of: repo.clock.now())
        var connections: [ActivityConnection] = []
        do {
            for connection in saved.connections where connection.enabled {
                let attempted = try repo.activitySyncAttemptedOn(connection: connection)
                if manual || attempted != today { connections.append(connection) }
            }
        } catch { message = "활동 수집 상태를 읽지 못했습니다."; return }
        guard !connections.isEmpty else {
            if manual { message = "수집할 서비스를 켜고 설정을 저장하세요." }
            return
        }
        isRunning = true
        defer { isRunning = false }
        var results: [String] = []
        for connection in connections {
            do {
                try Task.checkCancellation()
                try repo.recordActivitySyncAttempt(connection: connection)
                guard let token = try credentials.read(account: connection.credentialAccount), !token.isEmpty else {
                    throw WorkLogError.validation("\(connection.source.title) API 토큰을 입력하고 저장하세요.")
                }
                let last = try repo.activitySyncCompletedAt(connection: connection).map { repo.calendar.workDate(of: $0) }
                let earliest = repo.calendar.adding(days: -29, to: today)
                let start = max(earliest, repo.calendar.adding(days: -7, to: last ?? today))
                let range = DateRange(start: start, endExclusive: repo.calendar.adding(days: 1, to: today))
                let response = try await client.fetch(connection: connection, token: token, range: range, calendar: repo.calendar)
                try Task.checkCancellation()
                let count = try repo.importActivities(response.activities, connection: connection)
                try repo.recordActivitySyncAttempt(connection: connection, completed: true)
                results.append("\(connection.source.title): 새 기록 \(count)개")
                results.append(contentsOf: response.warnings)
                if let last, last < earliest { results.append("30일 이전 누락 기록은 API 보존 범위 밖일 수 있습니다.") }
            } catch is CancellationError { break }
            catch { results.append(safeMessage(error)) }
        }
        if !results.isEmpty { message = results.joined(separator: "\n") }
    }

    /// Call only after an active sync finishes. Stale UI tasks must not reopen the old database after restore.
    public func detach() {
        guard !isRunning else { return }
        repo = nil; isLoaded = false; githubToken = ""; jiraToken = ""
    }

    private func safeMessage(_ error: Error) -> String {
        if case WorkLogError.validation(let message) = error { return message }
        return "활동 수집을 완료하지 못했습니다. 설정·Keychain 접근·사내망 연결을 확인하세요."
    }
}
