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
    /// 보관 기간(settings.backupRetentionDays)이 지나 삭제한 백업 id. 백업이 실패한 실행에서는 지우지 않는다.
    public var removedBackups: [String]

    public init(seededTemplates: Int = 0, recoveredAIJobs: Int = 0,
                backupCreated: Bool = false, backupError: String? = nil, removedBackups: [String] = []) {
        self.seededTemplates = seededTemplates
        self.recoveredAIJobs = recoveredAIJobs
        self.backupCreated = backupCreated
        self.backupError = backupError
        self.removedBackups = removedBackups
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
    /// 제출용 주간보고·상세 성과 리포트 생성. AI가 꺼져 있으면 결정적 초안만 만든다.
    public let reports: ReportService
    /// Secret 접근은 반드시 vaultSession을 통해서만 한다. SecretVault 인스턴스는 노출하지 않는다.
    public let vaultSession: VaultSession
    public let clipboard: ClipboardGuard
    public let backup: BackupService
    public let aiRunner: AIJobRunner?
    /// 설정의 작업별 스킬 바인딩 해석기. AI가 꺼져 있어도 설정을 읽을 수 있게 항상 존재한다.
    public let skillResolver: SkillBindingResolver
    public let memoLinks: MemoLinkSuggestionService?
    public let quiz: EvidenceQuizService?
    /// 사용자가 명시적으로 실행하는 기록 기반 AI 답변(타이핑 중 자동 실행 없음)
    public let groundedAnswers: GroundedAnswerService?

    /// 가장 최근 catch-up이 계획한 since(가장 이른 기록 업무일, 92일 상한 적용).
    /// 가져오기마다 같은 92일 계획을 다시 돌리지 않도록 재계획이 필요한지만 판단한다.
    private var lastCatchUpSince: WorkDate?
    /// 그 catch-up을 실행한 업무일(자정을 넘기면 다시 계획해야 한다).
    private var lastCatchUpToday: WorkDate?

    private init(options: AppEnvironmentOptions, settings: AppSettings, settingsStore: SettingsStore,
                 calendar: WorkCalendar, periods: Periods, repo: WorkRepository, search: SearchIndex,
                 tasks: TaskService, plans: WeekPlanService, dayBox: DayBoxService,
                 templates: TemplateStore, evaluationPeriods: EvaluationPeriodService,
                 factsBuilder: ReportFactsBuilder, reportStore: ReportStore, reports: ReportService,
                 vaultSession: VaultSession, clipboard: ClipboardGuard, backup: BackupService,
                 aiRunner: AIJobRunner?, memoLinks: MemoLinkSuggestionService?,
                 quiz: EvidenceQuizService?, groundedAnswers: GroundedAnswerService?,
                 skillResolver: SkillBindingResolver) {
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
        self.reports = reports
        self.vaultSession = vaultSession
        self.clipboard = clipboard
        self.backup = backup
        self.aiRunner = aiRunner
        self.memoLinks = memoLinks
        self.quiz = quiz
        self.groundedAnswers = groundedAnswers
        self.skillResolver = skillResolver
    }

    // MARK: - 열기

    /// 1) paths.createDirectories() 2) settings = settingsStore.load() (파일 없으면 기본값)
    /// 3) work.sqlite / vault.sqlite를 각각 별도 SQLiteDatabase로 연다(두 파일 분리) 4) 서비스 조립
    /// 5) AIPayloadGuard.blockedSubstrings = [vault DB 경로, vault 디렉터리, backupRoot]
    /// 6) aiProvider가 nil이거나 settings.aiEnabled == false면 aiRunner/memoLinks/quiz/groundedAnswers = nil
    public static func open(_ options: AppEnvironmentOptions,
                            onStorageError: @escaping @Sendable (Int32) -> Void = { _ in }) throws -> AppEnvironment {
        let paths = options.paths
        try paths.createDirectories()

        let settingsStore = SettingsStore(fileURL: paths.settingsFile)
        let settings = try settingsStore.load()

        let timeZone = TimeZone(identifier: settings.timeZoneIdentifier)
            ?? TimeZone(identifier: "Asia/Seoul")!
        let calendar = WorkCalendar(timeZone: timeZone)

        let workDB = try SQLiteDatabase(path: paths.workDatabase.path, onError: onStorageError)
        let vaultDB = try SQLiteDatabase(path: paths.vaultDatabase.path, onError: onStorageError)

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
                                    ids: options.ids, calendar: calendar, deferKeyAccess: true)
        let vaultSession = VaultSession(vault: vault, authenticator: options.authenticator,
                                        clock: options.clock,
                                        idleTimeout: TimeInterval(settings.secretIdleLockMinutes * 60))
        let clipboard = ClipboardGuard(pasteboard: options.pasteboard, clock: options.clock,
                                       clearAfter: TimeInterval(settings.clipboardClearSeconds))
        let backup = BackupService(paths: paths, workDB: workDB, vaultDB: vaultDB,
                                   clock: options.clock, ids: options.ids)
        let skillResolver = SkillBindingResolver(
            bindings: settings.skillBindings,
            blockedPathPrefixes: [paths.dataRoot.path, paths.backupRoot.path,
                                  paths.vaultDatabase.deletingLastPathComponent().path])

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
                                     guard: payloadGuard, skillResolver: skillResolver)
            aiRunner = runner
            memoLinks = MemoLinkSuggestionService(repo: repo, runner: runner, templates: templates)
            quiz = EvidenceQuizService(repo: repo, runner: runner, templates: templates,
                                       maxQuestions: settings.maxQuizQuestions)
            groundedAnswers = GroundedAnswerService(index: search, runner: runner, templates: templates)
        }
        let reports = ReportService(repo: repo, periods: periods, factsBuilder: factsBuilder,
                                    store: reportStore, templates: templates, runner: aiRunner,
                                    evaluationPeriods: evaluationPeriods)

        return AppEnvironment(options: options, settings: settings, settingsStore: settingsStore,
                              calendar: calendar, periods: periods, repo: repo, search: search,
                              tasks: tasks, plans: plans, dayBox: dayBox, templates: templates,
                              evaluationPeriods: evaluationPeriods, factsBuilder: factsBuilder,
                              reportStore: reportStore, reports: reports, vaultSession: vaultSession, clipboard: clipboard,
                              backup: backup, aiRunner: aiRunner, memoLinks: memoLinks, quiz: quiz,
                              groundedAnswers: groundedAnswers, skillResolver: skillResolver)
    }

    // MARK: - 시작 회복

    /// 앱 시작 시: 기본 템플릿 시드, 중단된 AI 작업 회복, 상태 캐시 재계산, 원문 검색 색인 재구성,
    /// 일일 백업, 보관 기간 정리. 백업 실패는 throw하지 않고 결과에 기록한다.
    public func onLaunch() -> LaunchReport {
        var report = LaunchReport()

        report.seededTemplates = (try? templates.seedDefaults()) ?? 0
        report.recoveredAIJobs = aiRunner.map { (try? $0.recoverInterrupted()) ?? 0 } ?? 0
        try? tasks.rebuildCachedStatuses()
        // 이전 버전에서 제목만 색인된 업무 등 오래된 색인 문서만 복구한다.
        // 색인이 최신이면 쓰기가 없으므로 일일 백업 판정(work.sqlite 해시)을 흔들지 않는다.
        // 실패해도 앱 시작을 막지 않는다(다음 시작에서 다시 시도).
        _ = try? search.repairStaleTaskDocs()

        do {
            let info = try backup.createDailyBackupIfChanged(calendar: calendar)
            report.backupCreated = info != nil
        } catch {
            report.backupError = String(describing: error)
        }
        report.removedBackups = (try? backup.applyRetention(keepDays: settings.backupRetentionDays,
                                                            lastBackupSucceeded: report.backupError == nil)) ?? []
        return report
    }

    // MARK: - 설정 반영

    /// 설정을 검증·저장한 뒤 vault idle 잠금·클립보드 지우기 시간을 반영한다.
    public func updateSettings(_ new: AppSettings) throws {
        try settingsStore.save(new)
        settings = new
        vaultSession.idleTimeout = TimeInterval(new.secretIdleLockMinutes * 60)
        clipboard.clearAfter = TimeInterval(new.clipboardClearSeconds)
        skillResolver.update(bindings: new.skillBindings)
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

    /// 놓친 예약 작업을 실행하고 리포트 생성에 연결한다(자동 모드: 확정본을 덮어쓰지 않고,
    /// 원본 변화가 없으면 새 버전을 만들지 않는다). AI는 사용 가능할 때만 쓰고 실패하면 결정적 초안.
    /// - dailyClose → 전날 Daily 성과 리포트
    /// - weekly/monthly/quarterlyPerformance → 해당 기간 성과 리포트
    /// - mondayReview → 그 주 월요일 제출용 주간보고 초안(게시하지 않음)
    @discardableResult
    public func runScheduledReports(since: WorkDate, maxAttempts: Int = 3) async throws -> [ScheduledJob] {
        let useAI = aiRunner != nil && settings.aiEnabled
        return try await runScheduled(since: since, maxAttempts: maxAttempts) { _ in useAI }
    }

    /// 앱 시작 시 놓친 예약 리포트를 만든다.
    /// since = max(가장 이른 기록 업무일, 오늘 - maxLookbackDays). 기록이 없으면 어제.
    /// AI는 scheduledFor가 최근 aiRecentDays 이내인 작업에만 쓰고(설정상 AI 사용 가능할 때),
    /// 그보다 오래된 catch-up은 결정적 초안만 만든다.
    @discardableResult
    public func runStartupCatchUp(maxLookbackDays: Int = 92,
                                  aiRecentDays: Int = 7) async throws -> [ScheduledJob] {
        let now = options.clock.now()
        let today = calendar.workDate(of: now)
        let since = try catchUpStart(maxLookbackDays: maxLookbackDays, today: today)

        let baseUseAI = aiRunner != nil && settings.aiEnabled
        let aiCutoff = now.addingTimeInterval(-Double(max(0, aiRecentDays)) * 86_400)
        let processed = try await runScheduled(since: since) { job in
            baseUseAI && job.scheduledFor >= aiCutoff
        }
        // 같은 업무일 안에서 가장 이른 기록 업무일이 그대로면 재계획할 필요가 없다.
        lastCatchUpSince = since
        lastCatchUpToday = today
        return processed
    }

    /// catch-up 계획의 시작 업무일: max(가장 이른 기록 업무일, 오늘 - maxLookbackDays).
    /// 기록이 하나도 없으면 어제(전날 하루만 복구).
    private func catchUpStart(maxLookbackDays: Int, today: WorkDate) throws -> WorkDate {
        let yesterday = calendar.adding(days: -1, to: today)
        let floor = calendar.adding(days: -max(0, maxLookbackDays), to: today)
        return max(try repo.earliestRecordedWorkDate() ?? yesterday, floor)
    }

    /// 활동 가져오기가 catch-up 뒤에 도착했을 때, 영향을 받은 기간의 성공한 예약 리포트만
    /// 자동 모드로 다시 평가한다.
    ///
    /// - 먼저 `runStartupCatchUp`과 같은 계획·실행이 필요한지 판단해, 첫 가져오기로 가장 이른 기록
    ///   업무일이 앞당겨졌거나 지금 새로 실행할 작업이 생겼을 때(예: 월요일 알림 시각 도달)만
    ///   새 작업을 계획·실행한다(이미 있는 작업 키는 중복 생성하지 않는다). 그 외에는 같은 92일
    ///   계획을 다시 돌리지 않는다.
    /// - 이어서 `succeeded` 상태이면서 `range`와 겹치고 `range.endExclusive > floor`(오늘 - maxLookbackDays)
    ///   인 작업만 다시 평가한다. 작업의 상태·시도 횟수는 바꾸지 않는다(성공 상태 유지).
    /// - 자동 모드라 원본 digest가 같으면 AI 호출도 새 버전도 만들지 않는다. 확정본·편집본은
    ///   덮어쓰지 않고 그 위에 새 버전을 만든다. 92일 catch-up 상한과 7일 AI 상한도 그대로 지킨다.
    /// - 기간별 오류는 삼키고 다음 기간을 계속 평가한다(계획 단계 오류만 throw).
    ///   취소(CancellationError)는 오류가 아니므로 다음 기간을 시작하지 않고 그대로 전파한다.
    /// - 반환값: 다시 평가한 작업 중 새 버전을 만든 작업 수.
    @discardableResult
    public func reevaluateScheduledReports(affecting range: DateRange,
                                           maxLookbackDays: Int = 92,
                                           aiRecentDays: Int = 7) async throws -> Int {
        let now = options.clock.now()
        let today = calendar.workDate(of: now)

        // (a) 가장 이른 기록 업무일이 앞당겨졌거나 업무일이 바뀐 경우, 또는 지금 새로 실행할 작업이
        //     생긴 경우(예: 월요일 알림 시각 도달)에만 누락 업무일을 계획·실행한다. 가져오기마다
        //     92일 계획을 다시 돌려 실패 작업을 매시간 재시도하던 비용을 막는다.
        //     이미 있는 작업 키(실패 포함)는 dueJobs에서 제외되므로 실패 작업은 다시 시도하지 않는다.
        let plannedSince = try catchUpStart(maxLookbackDays: maxLookbackDays, today: today)
        var needsPlan = lastCatchUpSince == nil
            || lastCatchUpToday != today
            || plannedSince < (lastCatchUpSince ?? plannedSince)
        if !needsPlan {
            let due = SchedulePlanner.dueJobs(now: now, since: plannedSince,
                                              existingKeys: try repo.scheduledJobKeys(),
                                              settings: settings, periods: periods)
            needsPlan = !due.isEmpty
        }
        if needsPlan {
            _ = try await runStartupCatchUp(maxLookbackDays: maxLookbackDays, aiRecentDays: aiRecentDays)
        }

        // (b) 영향 범위와 겹치는 성공 작업만 자동 모드로 다시 평가한다.
        let floor = calendar.adding(days: -max(0, maxLookbackDays), to: today)
        let baseUseAI = aiRunner != nil && settings.aiEnabled
        let aiCutoff = now.addingTimeInterval(-Double(max(0, aiRecentDays)) * 86_400)

        let candidates = try repo.scheduledJobs(states: [.succeeded]).compactMap { job -> DueJob? in
            guard let jobRange = SchedulePlanner.range(for: job.type, periodKey: job.periodKey,
                                                       periods: periods),
                  jobRange.endExclusive > floor,
                  jobRange.intersection(range) != nil else { return nil }
            return DueJob(type: job.type, periodKey: job.periodKey, range: jobRange,
                          scheduledFor: job.scheduledFor)
        }

        var reevaluated = 0
        for job in candidates {
            // 취소(앱 종료·세션 정리)면 다음 기간을 시작하지 않고 즉시 멈춘다.
            try Task.checkCancellation()
            let useAI = baseUseAI && job.scheduledFor >= aiCutoff
            do {
                if try await Self.handleScheduled(job, reports: reports, useAI: useAI) {
                    reevaluated += 1
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 개별 기간 실패는 다른 기간 재평가를 막지 않는다. 작업 상태는 건드리지 않는다.
                continue
            }
        }
        return reevaluated
    }

    /// 공통 실행기. 작업별로 AI 사용 여부를 판정하는 클로저를 받아 처리한다.
    private func runScheduled(since: WorkDate, maxAttempts: Int = 3,
                              useAIFor: (DueJob) -> Bool) async throws -> [ScheduledJob] {
        let reports = self.reports
        return try await makeScheduler(since: since).runDue(maxAttempts: maxAttempts) { job in
            _ = try await Self.handleScheduled(job, reports: reports, useAI: useAIFor(job))
        }
    }

    /// 작업 하나를 처리한다. 새 버전을 만들었으면 true, 원본 변화가 없어 그대로면 false.
    @discardableResult
    static func handleScheduled(_ job: DueJob, reports: ReportService, useAI: Bool) async throws -> Bool {
        switch job.type {
        case .dailyClose:
            let result = try await reports.generatePerformance(periodType: .daily,
                                                               containing: job.range.start,
                                                               mode: .automatic, useAI: useAI)
            return created(result)
        case .weeklyPerformance:
            let result = try await reports.generatePerformance(periodType: .weekly,
                                                               containing: job.range.start,
                                                               mode: .automatic, useAI: useAI)
            return created(result)
        case .monthlyPerformance:
            let result = try await reports.generatePerformance(periodType: .monthly,
                                                               containing: job.range.start,
                                                               mode: .automatic, useAI: useAI)
            return created(result)
        case .quarterlyPerformance:
            let result = try await reports.generatePerformance(periodType: .quarterly,
                                                               containing: job.range.start,
                                                               mode: .automatic, useAI: useAI)
            return created(result)
        case .mondayReview:
            // range = 지난주 [월, 이번 월) → 보고 월요일은 endExclusive.
            let result = try await reports.generateSubmission(reportDate: job.range.endExclusive,
                                                              mode: .automatic, useAI: useAI)
            return created(result)
        case .backup:
            return false
        }
    }

    private static func created(_ result: ReportGenerationResult) -> Bool {
        if case .created = result.outcome { return true }
        return false
    }
}
