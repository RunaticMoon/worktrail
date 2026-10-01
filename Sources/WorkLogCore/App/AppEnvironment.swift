import Foundation

// 앱 구성 루트(AppEnvironment).
//
// macOS 앱과 개발용 CLI가 공통으로 쓰는 조립 지점이다. 새 비즈니스 로직을 만들지 않고
// 경로·설정·두 DB(work/vault)·서비스를 열어 연결한다.
// - Secret 접근은 vaultSession을 통해서만 하며 SecretVault 인스턴스는 노출하지 않는다.
// - Secret 저장소·백업 경로 문자열은 AI 입력에 섞이면 차단한다(AIPayloadGuard).
// - print/로그 출력을 하지 않는다.

/// AppEnvironment.open에 넘기는 주입 값. 테스트에서는 임시 경로·Mock을 넘긴다.
public struct AppEnvironmentOptions {
    public var paths: AppPaths
    public var keyStore: VaultKeyStore
    public var authenticator: DeviceAuthenticator
    public var pasteboard: Pasteboard
    /// nil이면 AI 기능 비활성(기록·검색·Secret은 정상 동작).
    public var aiProvider: AIProvider?
    public var clock: Clock
    public var ids: IDGenerator

    public init(paths: AppPaths, keyStore: VaultKeyStore, authenticator: DeviceAuthenticator,
                pasteboard: Pasteboard, aiProvider: AIProvider? = nil,
                clock: Clock = SystemClock(), ids: IDGenerator = UUIDGenerator()) {
        self.paths = paths
        self.keyStore = keyStore
        self.authenticator = authenticator
        self.pasteboard = pasteboard
        self.aiProvider = aiProvider
        self.clock = clock
        self.ids = ids
    }
}

/// 앱 시작 시 회복 작업 결과. 실패해도 앱 시작을 막지 않는다.
public struct LaunchReport: Sendable {
    public var seededTemplates: Int
    public var recoveredAIJobs: Int
    public var backupCreated: Bool
    public var backupError: String?

    public init(seededTemplates: Int = 0, recoveredAIJobs: Int = 0,
                backupCreated: Bool = false, backupError: String? = nil) {
        self.seededTemplates = seededTemplates
        self.recoveredAIJobs = recoveredAIJobs
        self.backupCreated = backupCreated
        self.backupError = backupError
    }
}

/// 구성 루트. open으로만 생성하며 모든 서비스가 같은 경로·시계·ID 생성기를 공유한다.
public final class AppEnvironment {
    public let options: AppEnvironmentOptions
    public private(set) var settings: AppSettings

    public let settingsStore: SettingsStore
    public let calendar: WorkCalendar
    public let periods: Periods
    public let repo: WorkRepository
    public let search: SearchIndex
    public let tasks: TaskService
    public let plans: WeekPlanService
    public let dayBox: DayBoxService
    public let templates: TemplateStore
    public let evaluationPeriods: EvaluationPeriodService
    public let factsBuilder: ReportFactsBuilder
    public let reportStore: ReportStore
    /// Secret 접근은 반드시 vaultSession을 통해서만 한다. SecretVault 인스턴스는 노출하지 않는다.
    public let vaultSession: VaultSession
    public let clipboard: ClipboardGuard
    public let backup: BackupService
    public let aiRunner: AIJobRunner?
    public let memoLinks: MemoLinkSuggestionService?
    public let quiz: EvidenceQuizService?
    /// 사용자가 명시적으로 실행하는 기록 기반 AI 답변(타이핑 중 자동 실행 없음)
    public let groundedAnswers: GroundedAnswerService?

    private init(options: AppEnvironmentOptions, settings: AppSettings, settingsStore: SettingsStore,
                 calendar: WorkCalendar, periods: Periods, repo: WorkRepository, search: SearchIndex,
                 tasks: TaskService, plans: WeekPlanService, dayBox: DayBoxService,
                 templates: TemplateStore, evaluationPeriods: EvaluationPeriodService,
                 factsBuilder: ReportFactsBuilder, reportStore: ReportStore,
                 vaultSession: VaultSession, clipboard: ClipboardGuard, backup: BackupService,
                 aiRunner: AIJobRunner?, memoLinks: MemoLinkSuggestionService?,
                 quiz: EvidenceQuizService?, groundedAnswers: GroundedAnswerService?) {
        self.options = options
        self.settings = settings
        self.settingsStore = settingsStore
        self.calendar = calendar
        self.periods = periods
        self.repo = repo
        self.search = search
        self.tasks = tasks
        self.plans = plans
        self.dayBox = dayBox
        self.templates = templates
        self.evaluationPeriods = evaluationPeriods
        self.factsBuilder = factsBuilder
        self.reportStore = reportStore
        self.vaultSession = vaultSession
        self.clipboard = clipboard
        self.backup = backup
        self.aiRunner = aiRunner
        self.memoLinks = memoLinks
        self.quiz = quiz
        self.groundedAnswers = groundedAnswers
    }

    // MARK: - 열기

    /// 1) paths.createDirectories() 2) settings = settingsStore.load() (파일 없으면 기본값)
    /// 3) work.sqlite / vault.sqlite를 각각 별도 SQLiteDatabase로 연다(두 파일 분리) 4) 서비스 조립
    /// 5) AIPayloadGuard.blockedSubstrings = [vault DB 경로, vault 디렉터리, backupRoot]
    /// 6) aiProvider가 nil이거나 settings.aiEnabled == false면 aiRunner/memoLinks/quiz/groundedAnswers = nil
    public static func open(_ options: AppEnvironmentOptions) throws -> AppEnvironment {
        let paths = options.paths
        try paths.createDirectories()

        let settingsStore = SettingsStore(fileURL: paths.settingsFile)
        let settings = try settingsStore.load()

        let timeZone = TimeZone(identifier: settings.timeZoneIdentifier)
            ?? TimeZone(identifier: "Asia/Seoul")!
        let calendar = WorkCalendar(timeZone: timeZone)

        let workDB = try SQLiteDatabase(path: paths.workDatabase.path)
        let vaultDB = try SQLiteDatabase(path: paths.vaultDatabase.path)

        let repo = try WorkRepository(db: workDB, clock: options.clock, ids: options.ids,
                                      calendar: calendar)
        let search = try SearchIndex(repo: repo)
        let periods = Periods(calendar: calendar)
        let tasks = TaskService(repo: repo)
        let plans = WeekPlanService(repo: repo, periods: periods)
        let dayBox = DayBoxService(repo: repo)
        let templates = TemplateStore(repo: repo)
        let evaluationPeriods = EvaluationPeriodService(repo: repo)
        let factsBuilder = ReportFactsBuilder(repo: repo, periods: periods, planService: plans)
        let reportStore = ReportStore(repo: repo)

        let vault = try SecretVault(db: vaultDB, keyStore: options.keyStore, clock: options.clock,
                                    ids: options.ids, calendar: calendar)
        let vaultSession = VaultSession(vault: vault, authenticator: options.authenticator,
                                        clock: options.clock,
                                        idleTimeout: TimeInterval(settings.secretIdleLockMinutes * 60))
        let clipboard = ClipboardGuard(pasteboard: options.pasteboard, clock: options.clock,
                                       clearAfter: TimeInterval(settings.clipboardClearSeconds))
        let backup = BackupService(paths: paths, workDB: workDB, vaultDB: vaultDB,
                                   clock: options.clock, ids: options.ids)

        var aiRunner: AIJobRunner?
        var memoLinks: MemoLinkSuggestionService?
        var quiz: EvidenceQuizService?
        var groundedAnswers: GroundedAnswerService?
        if let provider = options.aiProvider, settings.aiEnabled {
            let payloadGuard = AIPayloadGuard(blockedSubstrings: [
                paths.vaultDatabase.path,
                paths.vaultDatabase.deletingLastPathComponent().path,
                paths.backupRoot.path,
            ])
            let runner = AIJobRunner(repo: repo, provider: provider, stagingRoot: paths.aiJobsDirectory,
                                     guard: payloadGuard)
            aiRunner = runner
            memoLinks = MemoLinkSuggestionService(repo: repo, runner: runner, templates: templates)
            quiz = EvidenceQuizService(repo: repo, runner: runner, templates: templates,
                                       maxQuestions: settings.maxQuizQuestions)
            groundedAnswers = GroundedAnswerService(index: search, runner: runner, templates: templates)
        }

        return AppEnvironment(options: options, settings: settings, settingsStore: settingsStore,
                              calendar: calendar, periods: periods, repo: repo, search: search,
                              tasks: tasks, plans: plans, dayBox: dayBox, templates: templates,
                              evaluationPeriods: evaluationPeriods, factsBuilder: factsBuilder,
                              reportStore: reportStore, vaultSession: vaultSession, clipboard: clipboard,
                              backup: backup, aiRunner: aiRunner, memoLinks: memoLinks, quiz: quiz,
                              groundedAnswers: groundedAnswers)
    }

    // MARK: - 시작 회복

    /// 앱 시작 시: 기본 템플릿 시드, 중단된 AI 작업 회복, 상태 캐시 재계산, 일일 백업.
    /// 백업 실패는 throw하지 않고 결과에 기록한다.
    public func onLaunch() -> LaunchReport {
        var report = LaunchReport()

        report.seededTemplates = (try? templates.seedDefaults()) ?? 0
        report.recoveredAIJobs = aiRunner.map { (try? $0.recoverInterrupted()) ?? 0 } ?? 0
        try? tasks.rebuildCachedStatuses()

        do {
            let info = try backup.createDailyBackupIfChanged(calendar: calendar)
            report.backupCreated = info != nil
        } catch {
            report.backupError = String(describing: error)
        }
        return report
    }

    // MARK: - 설정 반영

    /// 설정을 검증·저장한 뒤 vault idle 잠금·클립보드 지우기 시간을 반영한다.
    public func updateSettings(_ new: AppSettings) throws {
        try settingsStore.save(new)
        settings = new
        vaultSession.idleTimeout = TimeInterval(new.secretIdleLockMinutes * 60)
        clipboard.clearAfter = TimeInterval(new.clipboardClearSeconds)
    }

    /// 화면 잠금·앱 종료 시 호출: Secret 잠금 + 조건부 클립보드 삭제.
    public func lockSecrets(_ reason: VaultLockReason) {
        vaultSession.lock(reason)
        clipboard.clearNowIfUnchanged()
    }

    // MARK: - 예약 실행기

    /// 놓친 예약 작업 실행기를 만든다. 핸들러(리포트 연결)는 호출자가 제공한다.
    public func makeScheduler(since: WorkDate) -> SchedulerRunner {
        SchedulerRunner(repo: repo, periods: periods, clock: options.clock, settings: settings, since: since)
    }
}
