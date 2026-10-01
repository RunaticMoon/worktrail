import Foundation

// MARK: - 개발용 worklog CLI
//
// Linux 개발 서버에서 기록·검색·리포트·백업 흐름을 시연하기 위한 얇은 CLI다.
// 모든 동작은 이미 있는 AppEnvironment를 통해서만 하며 새 비즈니스 로직을 만들지 않는다.
// - Core 코드이므로 print/로그를 하지 않고 stdout/stderr 문자열만 돌려준다(main.swift가 출력).
// - 실제 사용자 홈의 앱 데이터 경로(AppPaths.standard)를 기본값으로 쓰지 않는다.
//   `--data-dir` 또는 WORKLOG_DATA_DIR가 반드시 있어야 한다(개발 도구가 실데이터를 건드리지 않게).
// - Secret 명령은 제공하지 않는다. AI는 비활성(결정적 초안만)이다.

/// CLI 실행 결과. main.swift가 그대로 stdout/stderr로 출력하고 종료 코드로 쓴다.
public struct CLIResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum WorkLogCLI {

    // MARK: - 사용법

    public static let usage: String = """
    worklog — 개발용 CLI (WorkLogCore·AppEnvironment 기반)

    사용법:
      worklog --data-dir <경로> [--now <ISO8601>] <명령> [옵션]
      (데이터 위치는 --data-dir 또는 WORKLOG_DATA_DIR 환경 변수로 반드시 지정합니다)

    명령:
      help
      memo <본문...> [--date YYYY-MM-DD]
      task add <제목...> [--date D] [--project P]... [--tag T]...
      task done <taskId> [--date D]
      task show <taskId>
      activity <taskId> <본문...> [--date D]
      search <질의...> [--limit N]
      report submission <보고 월요일 D>
      report performance <daily|weekly|monthly|quarterly> <D>
      schedule run --since D
      backup create
      backup list
      backup verify <디렉터리이름>

    전역 옵션:
      --data-dir <경로>    데이터 루트(<경로>/data, <경로>/backups)
      --now <ISO8601>      현재 시각 고정(시연용). run의 now 인자가 있으면 그쪽이 우선.

    참고:
      - Secret 명령 없음: Secret은 macOS 앱의 기기 인증 뒤에서만 다룹니다.
      - AI 비활성: 이 CLI는 AI를 호출하지 않고 결정적 초안만 생성합니다.
    """

    // MARK: - 진입점

    /// args는 프로그램 이름 제외. env: 환경 변수(테스트 주입). now: 테스트용 시각 주입(nil이면 --now/SystemClock).
    public static func run(_ args: [String], environment env: [String: String],
                           now: Date? = nil) async -> CLIResult {
        let globals = extractGlobals(args)
        if let error = globals.error {
            return usageError(error)
        }

        let rest = globals.rest
        if rest.isEmpty || rest[0] == "help" || rest[0] == "--help" || rest[0] == "-h" {
            return CLIResult(exitCode: 0, stdout: usage + "\n", stderr: "")
        }

        // 데이터 위치는 반드시 있어야 한다(실데이터 보호).
        guard let dataDirText = globals.dataDir ?? env["WORKLOG_DATA_DIR"],
              !dataDirText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return usageError("데이터 디렉터리가 필요합니다. --data-dir <경로> 또는 WORKLOG_DATA_DIR 환경 변수를 지정하세요.")
        }

        // 시계: run의 now 인자 > --now > SystemClock.
        let clock: Clock
        if let now {
            clock = FixedClock(now)
        } else if let nowText = globals.nowText {
            guard let parsed = parseISO8601(nowText) else {
                return usageError("잘못된 --now 형식입니다: \(nowText) (예: 2026-10-05T01:00:00Z)")
            }
            clock = FixedClock(parsed)
        } else {
            clock = SystemClock()
        }

        let root = URL(fileURLWithPath: dataDirText, isDirectory: true)
        let paths = AppPaths(dataRoot: root.appendingPathComponent("data", isDirectory: true),
                             backupRoot: root.appendingPathComponent("backups", isDirectory: true))
        let options = AppEnvironmentOptions(paths: paths, keyStore: InMemoryVaultKeyStore(),
                                            authenticator: MockDeviceAuthenticator(),
                                            pasteboard: InMemoryPasteboard(), aiProvider: nil,
                                            clock: clock, ids: UUIDGenerator())

        let environment: AppEnvironment
        do {
            environment = try AppEnvironment.open(options)
        } catch {
            return CLIResult(exitCode: 1, stdout: "", stderr: "환경을 여는 중 오류: \(describe(error))\n")
        }
        _ = environment.onLaunch()

        return await dispatch(rest, env: environment)
    }

    // MARK: - 명령 분기

    private static func dispatch(_ args: [String], env: AppEnvironment) async -> CLIResult {
        let command = args[0]
        let rest = Array(args.dropFirst())
        switch command {
        case "memo": return commandMemo(rest, env: env)
        case "task": return commandTask(rest, env: env)
        case "activity": return commandActivity(rest, env: env)
        case "search": return commandSearch(rest, env: env)
        case "report": return await commandReport(rest, env: env)
        case "schedule": return await commandSchedule(rest, env: env)
        case "backup": return commandBackup(rest, env: env)
        default: return usageError("알 수 없는 명령: \(command)")
        }
    }

    // MARK: - memo

    private static func commandMemo(_ args: [String], env: AppEnvironment) -> CLIResult {
        let parsed = parseArgs(args, valueOptions: ["--date"])
        if let error = parsed.error { return usageError(error) }
        guard let workDate = resolveDate(parsed.values["--date"]?.last) else {
            return usageError("--date 형식이 올바르지 않습니다 (YYYY-MM-DD).")
        }
        let body = parsed.positionals.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return usageError("memo 본문이 필요합니다.") }
        do {
            let memo = try env.tasks.captureMemo(body: body, workDate: workDate.value)
            return ok("memo \(memo.id)\n")
        } catch {
            return domainError(error)
        }
    }

    // MARK: - task

    private static func commandTask(_ args: [String], env: AppEnvironment) -> CLIResult {
        guard let sub = args.first else {
            return usageError("task 하위 명령이 필요합니다: add, done, show")
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "add": return taskAdd(rest, env: env)
        case "done": return taskDone(rest, env: env)
        case "show": return taskShow(rest, env: env)
        default: return usageError("알 수 없는 task 하위 명령: \(sub)")
        }
    }

    private static func taskAdd(_ args: [String], env: AppEnvironment) -> CLIResult {
        let parsed = parseArgs(args, valueOptions: ["--date", "--project", "--tag"])
        if let error = parsed.error { return usageError(error) }
        guard let workDate = resolveDate(parsed.values["--date"]?.last) else {
            return usageError("--date 형식이 올바르지 않습니다 (YYYY-MM-DD).")
        }
        let title = parsed.positionals.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return usageError("task 제목이 필요합니다.") }
        do {
            let task = try env.tasks.createTask(title: title, workDate: workDate.value,
                                                projectNames: parsed.values["--project"] ?? [],
                                                tagNames: parsed.values["--tag"] ?? [])
            return ok("task \(task.id)\n")
        } catch {
            return domainError(error)
        }
    }

    private static func taskDone(_ args: [String], env: AppEnvironment) -> CLIResult {
        let parsed = parseArgs(args, valueOptions: ["--date"])
        if let error = parsed.error { return usageError(error) }
        guard let taskId = parsed.positionals.first else {
            return usageError("task done에는 taskId가 필요합니다.")
        }
        guard let workDate = resolveDate(parsed.values["--date"]?.last) else {
            return usageError("--date 형식이 올바르지 않습니다 (YYYY-MM-DD).")
        }
        do {
            let check = try env.tasks.completeTask(taskId: taskId, workDate: workDate.value,
                                                   confirmRemaining: true)
            return ok("task \(taskId) \(check.completed ? "completed" : "not-completed")\n")
        } catch {
            return domainError(error)
        }
    }

    private static func taskShow(_ args: [String], env: AppEnvironment) -> CLIResult {
        let parsed = parseArgs(args, valueOptions: [])
        if let error = parsed.error { return usageError(error) }
        guard let taskId = parsed.positionals.first else {
            return usageError("task show에는 taskId가 필요합니다.")
        }
        do {
            let detail = try env.tasks.detail(taskId: taskId)
            var lines: [String] = []
            lines.append("title: \(detail.task.title)")
            lines.append("status: \(detail.status?.rawValue ?? "unknown")")
            lines.append("activities: \(detail.activities.count)")
            return ok(lines.joined(separator: "\n") + "\n")
        } catch {
            return domainError(error)
        }
    }

    // MARK: - activity

    private static func commandActivity(_ args: [String], env: AppEnvironment) -> CLIResult {
        let parsed = parseArgs(args, valueOptions: ["--date"])
        if let error = parsed.error { return usageError(error) }
        guard let taskId = parsed.positionals.first else {
            return usageError("activity에는 taskId가 필요합니다.")
        }
        guard let workDate = resolveDate(parsed.values["--date"]?.last) else {
            return usageError("--date 형식이 올바르지 않습니다 (YYYY-MM-DD).")
        }
        let body = parsed.positionals.dropFirst().joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return usageError("activity 본문이 필요합니다.") }
        do {
            let activity = try env.tasks.addActivity(taskId: taskId, body: body,
                                                     workDate: workDate.value)
            return ok("activity \(activity.id)\n")
        } catch {
            return domainError(error)
        }
    }

    // MARK: - search

    private static func commandSearch(_ args: [String], env: AppEnvironment) -> CLIResult {
        let parsed = parseArgs(args, valueOptions: ["--limit"])
        if let error = parsed.error { return usageError(error) }
        let text = parsed.positionals.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return usageError("search 질의가 필요합니다.") }
        var limit = 50
        if let limitText = parsed.values["--limit"]?.last {
            guard let parsedLimit = Int(limitText) else {
                return usageError("--limit 값이 정수가 아닙니다: \(limitText)")
            }
            limit = parsedLimit
        }
        do {
            let hits = try env.search.search(SearchQuery(text: text, limit: limit))
            let lines = hits.map { hit -> String in
                let date = hit.workDate?.iso ?? "-"
                return "\(hit.sourceType.rawValue)\t\(hit.sourceId)\t\(date)\t\(oneLine(hit.snippet))"
            }
            return ok(joinedLines(lines))
        } catch {
            return domainError(error)
        }
    }

    // MARK: - report

    private static func commandReport(_ args: [String], env: AppEnvironment) async -> CLIResult {
        guard let sub = args.first else {
            return usageError("report 하위 명령이 필요합니다: submission, performance")
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "submission": return await reportSubmission(rest, env: env)
        case "performance": return await reportPerformance(rest, env: env)
        default: return usageError("알 수 없는 report 하위 명령: \(sub)")
        }
    }

    private static func reportSubmission(_ args: [String], env: AppEnvironment) async -> CLIResult {
        let parsed = parseArgs(args, valueOptions: [])
        if let error = parsed.error { return usageError(error) }
        guard let dateText = parsed.positionals.first, let reportDate = WorkDate(dateText) else {
            return usageError("보고 월요일 날짜(YYYY-MM-DD)가 필요합니다.")
        }
        do {
            let result = try await env.reports.generateSubmission(reportDate: reportDate,
                                                                  mode: .userRequested, useAI: false)
            let body = try latestContent(env, reportId: result.report.id)
            let range = result.facts.range
            var header = "[제출용 주간보고] 실적 기간 \(inclusiveText(range))"
            if let plan = result.facts.planRange {
                header += " · 계획 기간 \(inclusiveText(plan))"
            }
            return ok(header + "\n" + body + "\n")
        } catch {
            return domainError(error)
        }
    }

    private static func reportPerformance(_ args: [String], env: AppEnvironment) async -> CLIResult {
        let parsed = parseArgs(args, valueOptions: [])
        if let error = parsed.error { return usageError(error) }
        guard parsed.positionals.count >= 2,
              let type = PeriodType(rawValue: parsed.positionals[0]),
              let date = WorkDate(parsed.positionals[1]) else {
            return usageError("report performance에는 <daily|weekly|monthly|quarterly> <YYYY-MM-DD>가 필요합니다.")
        }
        guard [.daily, .weekly, .monthly, .quarterly].contains(type) else {
            return usageError("성과 리포트 기간은 daily|weekly|monthly|quarterly 중 하나여야 합니다: \(type.rawValue)")
        }
        do {
            let result = try await env.reports.generatePerformance(periodType: type, containing: date,
                                                                   mode: .userRequested, useAI: false)
            let body = try latestContent(env, reportId: result.report.id)
            let range = result.facts.range
            let header = "[상세 성과 리포트] \(type.rawValue) 기간 \(inclusiveText(range))"
            return ok(header + "\n" + body + "\n")
        } catch {
            return domainError(error)
        }
    }

    /// 생성 결과의 최신 버전 본문. generate 직후에는 반드시 1개 이상 있다.
    private static func latestContent(_ env: AppEnvironment, reportId: String) throws -> String {
        let versions = try env.repo.reportVersions(reportId: reportId)
        return versions.last?.content ?? ""
    }

    // MARK: - schedule

    private static func commandSchedule(_ args: [String], env: AppEnvironment) async -> CLIResult {
        guard args.first == "run" else {
            return usageError("schedule 하위 명령이 필요합니다: run --since D")
        }
        let parsed = parseArgs(Array(args.dropFirst()), valueOptions: ["--since"])
        if let error = parsed.error { return usageError(error) }
        guard let sinceText = parsed.values["--since"]?.last, let since = WorkDate(sinceText) else {
            return usageError("schedule run에는 --since YYYY-MM-DD가 필요합니다.")
        }
        do {
            let jobs = try await env.runScheduledReports(since: since)
            let lines = jobs.map { "\($0.type.rawValue) \($0.periodKey) \($0.state.rawValue)" }
            return ok(joinedLines(lines))
        } catch {
            return domainError(error)
        }
    }

    // MARK: - backup

    private static func commandBackup(_ args: [String], env: AppEnvironment) -> CLIResult {
        guard let sub = args.first else {
            return usageError("backup 하위 명령이 필요합니다: create, list, verify")
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "create": return backupCreate(env: env)
        case "list": return backupList(env: env)
        case "verify": return backupVerify(rest, env: env)
        default: return usageError("알 수 없는 backup 하위 명령: \(sub)")
        }
    }

    private static func backupCreate(env: AppEnvironment) -> CLIResult {
        do {
            let info = try env.backup.createBackup(reason: .manual)
            return ok("backup \(info.id) \(info.directory.lastPathComponent)\n")
        } catch {
            return domainError(error)
        }
    }

    private static func backupList(env: AppEnvironment) -> CLIResult {
        do {
            let infos = try env.backup.listBackups()
            let lines = infos.map {
                "\($0.directory.lastPathComponent) \($0.manifest.reason.rawValue) \($0.manifest.files.count)"
            }
            return ok(joinedLines(lines))
        } catch {
            return domainError(error)
        }
    }

    private static func backupVerify(_ args: [String], env: AppEnvironment) -> CLIResult {
        let parsed = parseArgs(args, valueOptions: [])
        if let error = parsed.error { return usageError(error) }
        guard let name = parsed.positionals.first else {
            return usageError("backup verify에는 디렉터리 이름이 필요합니다.")
        }
        do {
            let found = try env.backup.verify(directoryNamed: name)
            guard found else {
                return CLIResult(exitCode: 1, stdout: "", stderr: "백업을 찾을 수 없습니다: \(name)\n")
            }
            return ok("verify ok \(name)\n")
        } catch {
            return CLIResult(exitCode: 1, stdout: "", stderr: describe(error) + "\n")
        }
    }

    // MARK: - 인자 파싱

    private struct ParsedArgs {
        var positionals: [String]
        var values: [String: [String]]
        var error: String?
    }

    /// `--옵션 값`을 모으고 나머지는 위치 인자로 둔다. 알 수 없는 `--옵션`은 오류다.
    private static func parseArgs(_ args: [String],
                                  valueOptions: Set<String>) -> ParsedArgs {
        var positionals: [String] = []
        var values: [String: [String]] = [:]
        var i = 0
        while i < args.count {
            let token = args[i]
            if token.hasPrefix("--") {
                guard valueOptions.contains(token) else {
                    return ParsedArgs(positionals: [], values: [:], error: "알 수 없는 옵션: \(token)")
                }
                guard i + 1 < args.count else {
                    return ParsedArgs(positionals: [], values: [:], error: "옵션 \(token)에 값이 필요합니다.")
                }
                values[token, default: []].append(args[i + 1])
                i += 2
            } else {
                positionals.append(token)
                i += 1
            }
        }
        return ParsedArgs(positionals: positionals, values: values, error: nil)
    }

    private struct ResolvedDate {
        var value: WorkDate?

        static let unspecified = ResolvedDate(value: nil)
    }

    /// nil 입력(옵션 없음)이면 값 없는 상태, 값이 있으면 파싱한다. 파싱 실패면 nil(사용법 오류).
    private static func resolveDate(_ text: String?) -> ResolvedDate? {
        guard let text else { return .unspecified }
        guard let date = WorkDate(text) else { return nil }
        return ResolvedDate(value: date)
    }

    private static func extractGlobals(_ args: [String])
        -> (rest: [String], dataDir: String?, nowText: String?, error: String?) {
        var rest: [String] = []
        var dataDir: String?
        var nowText: String?
        var i = 0
        while i < args.count {
            let token = args[i]
            if token == "--data-dir" || token == "--now" {
                guard i + 1 < args.count else {
                    return ([], nil, nil, "옵션 \(token)에 값이 필요합니다.")
                }
                if token == "--data-dir" { dataDir = args[i + 1] } else { nowText = args[i + 1] }
                i += 2
            } else {
                rest.append(token)
                i += 1
            }
        }
        return (rest, dataDir, nowText, nil)
    }

    // MARK: - 결과 헬퍼

    /// 배타 종료일 구간 [start, endExclusive)을 사람이 읽는 포함 종료일(마지막 업무일)로 바꾼다.
    private static func inclusiveText(_ range: DateRange) -> String {
        let lastDay = WorkCalendar().adding(days: -1, to: range.endExclusive)
        return "\(range.start.iso) ~ \(lastDay.iso)"
    }

    private static func ok(_ stdout: String) -> CLIResult {
        CLIResult(exitCode: 0, stdout: stdout, stderr: "")
    }

    private static func usageError(_ message: String) -> CLIResult {
        CLIResult(exitCode: 2, stdout: "", stderr: message + "\n\n" + usage + "\n")
    }

    private static func domainError(_ error: Error) -> CLIResult {
        CLIResult(exitCode: 1, stdout: "", stderr: describe(error) + "\n")
    }

    private static func describe(_ error: Error) -> String {
        if let workLogError = error as? WorkLogError {
            return workLogError.errorDescription ?? String(describing: workLogError)
        }
        return String(describing: error)
    }

    private static func joinedLines(_ lines: [String]) -> String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }

    private static func parseISO8601(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
