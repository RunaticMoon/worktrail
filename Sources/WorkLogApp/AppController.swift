#if os(macOS)
import SwiftUI
import AppKit
import Observation
import WorkLogCore

/// Shared composition point for the main window, menu extra and panels.
@Observable @MainActor final class AppController {
    private(set) var environment: AppEnvironment?
    private(set) var captureSession: CaptureSessionModel?
    private(set) var graph: GraphModel?
    private(set) var prompts: PromptSettingsModel?
    private(set) var day: DayViewModel?
    private(set) var search: SearchModel?
    private(set) var searchSurface: SearchSurfaceState?
    private(set) var taskDetail: TaskDetailModel?
    private(set) var memoDetail: MemoDetailModel?
    /// Submission and performance screens retain independent selection and editing state.
    private(set) var reportModel: ReportsModel?
    private(set) var performanceReports: ReportsModel?
    private(set) var reportLibrary: ReportLibraryModel?
    private(set) var plan: PlanModel?
    private(set) var quiz: QuizModel?
    private(set) var secrets: SecretsModel?
    private(set) var settingsModel: SettingsModel?
    private(set) var backups: BackupModel?
    private(set) var meetings: MeetingsModel?
    private(set) var chatGPTLogin: ChatGPTLoginCoordinator?
    private var protectionTimer: Timer?
    private var isRestoring = false
    var route: SidebarRoute? = .day
    var selectedTaskId: String?
    var selectedMemoId: String?
    private(set) var taskList: TaskListModel?
    private(set) var projects: ProjectsModel?
    var sidebarExpanded = true
    private(set) var isPanelKeyWindow = false
    private(set) var startupError: String?
    private(set) var notice: String?
    private var didStart = false
    private var hotkeys: GlobalHotkeys?
    private var hotkeyCoordinator: HotkeySettingsCoordinator?
    private var capturePanel: CapturePanelController?
    private var searchPanel: SearchPanelController?
    private var observers: [NSObjectProtocol] = []
    var openMainWindow: (() -> Void)?

    func start() async {
        guard !isRestoring else { return }
        guard !didStart else { return }; didStart = true
        clearRegistrations()
        do {
            let env = try await openEnvironment()
            let settings = env.settings
            environment = env
            captureSession = CaptureSessionModel(environment: env)
            graph = GraphModel(environment: env)
            prompts = PromptSettingsModel(templates: env.templates)
            day = DayViewModel(environment: env)
            taskList = TaskListModel(environment: env)
            projects = ProjectsModel(environment: env)
            searchSurface = SearchSurfaceState()
            search = SearchModel(environment: env); taskDetail = TaskDetailModel(environment: env)
            memoDetail = MemoDetailModel(environment: env)
            reportModel = ReportsModel(environment: env)
            reportModel?.family = .submission
            performanceReports = ReportsModel(environment: env)
            performanceReports?.family = .performance
            reportLibrary = ReportLibraryModel(environment: env)
            plan = PlanModel(environment: env)
            quiz = QuizModel(environment: env)
            secrets = SecretsModel(environment: env)
            settingsModel = SettingsModel(environment: env)
            backups = BackupModel(environment: env)
            meetings = MeetingsModel(environment: env)
            installProtectionTimer()
            let launch = env.onLaunch()
            if launch.backupError != nil { notice = "시작 백업을 만들지 못했습니다. 기록은 계속 사용할 수 있습니다." }
            refresh()
            installLifecycleObservers()
            let keys = GlobalHotkeys(clock: env.options.clock, timeZone: env.calendar.timeZone, handlers: [
                .capture: { [weak self] in self?.showCapture() },
                .search: { [weak self] in self?.showSearch() },
            ])
            let coordinator = HotkeySettingsCoordinator(registrar: keys)
            hotkeys = keys
            hotkeyCoordinator = coordinator
            let failures = coordinator.start(capture: settings.captureHotkey, search: settings.searchHotkey)
            if !failures.isEmpty { notice = failures.joined(separator: "\n") }
            do { try await env.runStartupCatchUp() }
            catch { notice = "예약 리포트 처리가 완료되지 않았습니다. 기록과 검색은 사용할 수 있습니다." }
            // Scheduled reports bypass the editors, including any saved before a failure.
            reportLibrary?.load()
        } catch {
            clearRegistrations()
            startupError = "WorkLog 저장소를 열지 못했습니다. 저장소 권한과 설정 파일을 확인하고 다시 시도하세요."
        }
    }

    private func openEnvironment() async throws -> AppEnvironment {
        #if DEBUG
        if let fixture = try UITestFixture.requested() {
            return try await fixture.makeEnvironment()
        }
        #endif
        let paths = AppPaths.standard()
        let profileStore = AITaskProfileStore(dataRoot: paths.dataRoot)
        let transport = ChatGPTURLSessionTransport()
        let session = ChatGPTOAuthSession(
            store: ChatGPTKeychainCredentialStore(service: AppIdentity.default.bundleIdentifier + ".chatgpt-oauth"),
            transport: transport, identityValidator: ChatGPTJWKSIdentityValidator(transport: transport))
        let provider = ChatGPTResponsesProvider(session: session,
            blockedSkillPathPrefixes: [paths.dataRoot.path, paths.backupRoot.path],
            profileResolver: { type in
                guard try SettingsStore(fileURL: paths.settingsFile).load().aiEnabled else {
                    throw AIProviderError(.policyRestricted, "설정에서 AI 사용이 꺼져 있습니다.")
                }
                return try profileStore.load()[type]
            })
        chatGPTLogin = ChatGPTLoginCoordinator(session: session, cancelRequests: { await provider.cancelAll() })
        return try AppEnvironment.open(AppEnvironmentOptions(paths: paths,
            keyStore: KeychainVaultKeyStore(service: AppIdentity.default.bundleIdentifier),
            authenticator: LocalDeviceAuthenticator(), pasteboard: SystemPasteboard(), aiProvider: provider))
    }

    func retryStart() async { didStart = false; startupError = nil; await start() }
    func dismissNotice() { notice = nil }
    func navigate(to route: SidebarRoute) {
        guard let window = NSApp.keyWindow, !(window is NSPanel),
              window.attachedSheet == nil, window.sheetParent == nil,
              !NSApp.windows.contains(where: { $0.isVisible && ($0.attachedSheet != nil || $0.sheetParent != nil) }),
              selectedTaskId == nil, selectedMemoId == nil, !worklogHasMarkedText else { return }
        self.route = route
    }

    func moveRoute(by offset: Int) {
        let routes = SidebarRoute.allCases
        let current = routes.firstIndex(of: route ?? .day) ?? 0
        navigate(to: routes[(current + offset + routes.count) % routes.count])
    }
    private func clearRegistrations() {
        protectionTimer?.invalidate(); protectionTimer = nil
        hotkeyCoordinator?.shutdown(); hotkeyCoordinator = nil
        hotkeys?.shutdown()
        hotkeys = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
    }
    func refresh() {
        // Both report models reload through their screen's guarded loadSelection path.
        // Do not reset pending drafts or version requests during a general refresh.
        day?.load()
        taskList?.load()
        projects?.load()
        reportLibrary?.load()
        if let selectedTaskId { taskDetail?.load(taskId: selectedTaskId, asOf: taskDetail?.asOf) }
        search?.search()
        if let graph, graph.phase != .idle { graph.reload() }
    }
    func openTask(_ id: String, asOf: WorkDate? = nil) {
        selectedTaskId = id
        taskDetail?.load(taskId: id, asOf: asOf)
    }
    func openMemo(_ id: String) { selectedMemoId = id; memoDetail?.load(id: id) }
    func openGraphNode(_ node: GraphNode) {
        switch node.id.kind {
        case .memo:
            openMemo(node.id.id)
        case .task:
            openTask(node.id.id)
        case .activity:
            do {
                if let activity = try environment?.repo.activity(id: node.id.id) { openTask(activity.taskId) }
            } catch { notice = "진행기록의 업무를 불러오지 못했습니다. 다시 시도하세요." }
        case .reportVersion:
            openReportVersion(node.id.id,
                family: node.reportFamily == ReportFamily.performance.rawValue ? .performance : .submission)
        case .project, .tag, .supplement, .historicalSource:
            break
        }
    }
    /// Graph and library navigation share the same draft/generation protection.
    func openReportVersion(_ id: String, family: ReportFamily) {
        guard let reports = reportEditor(for: family) else { return }
        reports.requestVersionSelection(id)
        route = family == .performance ? .performance : .weekly
    }

    func openLibraryReport(_ id: String) {
        guard let library = reportLibrary else { return }
        // Resolve again at activation so a newly saved version is the one opened.
        library.load()
        guard library.errorMessage == nil else { return }
        library.select(id)
        guard let item = library.selectedItem, let version = item.latestVersion else {
            notice = "리포트 본문을 찾을 수 없습니다. 보관함을 새로고침하세요."
            return
        }
        openReportVersion(version.id, family: item.report.family)
    }

    func openReportCreation(family: ReportFamily, periodType: PeriodType) {
        guard let reports = reportEditor(for: family) else { return }
        if family == .performance {
            if periodType == .yearly {
                do {
                    reports.evaluationPeriodId = try environment?.repo.evaluationPeriods().first?.id
                    if reports.evaluationPeriodId == nil {
                        notice = "성과자료의 ‘평가 기간 만들기’에서 기간을 저장한 뒤 리포트를 만드세요."
                    }
                } catch {
                    notice = "평가 기간을 불러오지 못했습니다. 다시 시도하세요."
                    return
                }
            } else {
                reports.evaluationPeriodId = nil
                reports.periodType = periodType
            }
        }
        route = family == .performance ? .performance : .weekly
    }

    private func reportEditor(for family: ReportFamily) -> ReportsModel? {
        guard let reports = family == .performance ? performanceReports : reportModel else { return nil }
        guard !reports.isGenerating, !reports.hasChanges else {
            notice = "리포트 작업을 마치거나 본문 변경을 저장한 뒤 다른 버전을 여세요."
            return nil
        }
        return reports
    }

    func showCapture() {
        guard let captureSession, let secrets, let environment else { return }
        if capturePanel == nil {
            capturePanel = CapturePanelController(session: captureSession, secrets: secrets, calendar: environment.calendar,
                onSaved: { [weak self] in self?.refresh() })
        }
        capturePanel?.show()
    }

    var newItemTitle: String {
        switch route ?? .day {
        case .projects: return "프로젝트 추가"
        case .tasks: return "새 업무"
        case .meetings: return "새 회의"
        default: return "빠른 입력"
        }
    }

    func createNewItem(onCreateProject: (() -> Void)?) {
        guard !isPanelKeyWindow, !worklogHasMarkedText,
              NSApp.keyWindow?.attachedSheet == nil, NSApp.keyWindow?.sheetParent == nil,
              selectedTaskId == nil, selectedMemoId == nil else { return }
        switch route ?? .day {
        case .projects: onCreateProject?()
        case .tasks: showTaskCapture()
        case .meetings: meetings?.create()
        default: showCapture()
        }
    }

    func showTaskCapture() {
        captureSession?.taskDraft.cancelCompletion()
        captureSession?.taskDraft.taskSelection = .newTask
        showCapture()
        captureSession?.select(.task)
    }
    var hotkeyDiagnostics: [HotkeyAction: HotkeyDiagnostic] { hotkeys?.diagnostics ?? [:] }

    func hotkeyDisplay(_ action: HotkeyAction) -> String {
        guard let settings = environment?.settings else { return "단축키 준비 중" }
        let raw = action == .capture ? settings.captureHotkey : settings.searchHotkey
        return (try? HotkeyBinding(parsing: raw).displayString) ?? raw
    }

    func showSearch() {
        guard let search, let environment else {
            notice = "검색을 아직 준비하지 못했습니다. 메인 창에서 저장소 연결 상태를 확인하세요."
            openMainWindow?()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if searchPanel == nil {
            searchPanel = SearchPanelController(model: search, environment: environment, secrets: secrets,
                onOpenSecrets: { [weak self] in
                    self?.route = .secrets
                    // The search panel is non-activating, so activate explicitly before
                    // bringing the main window forward.
                    NSApp.activate()
                    self?.openMainWindow?()
                })
        }
        searchPanel?.show()
    }
    // AJ: keep idle masking and conditional clipboard clearing active on every route.
    private func installProtectionTimer() {
        protectionTimer?.invalidate()
        protectionTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.secrets?.tick() }
        }
        if let protectionTimer { RunLoop.main.add(protectionTimer, forMode: .common) }
    }

    func saveSettings() {
        guard let environment, let settingsModel, let coordinator = hotkeyCoordinator else { return }
        _ = settingsModel.save { [weak self] changed in
            try coordinator.apply(capture: changed.captureHotkey, search: changed.searchHotkey) {
                try environment.updateSettings(changed)
            }
            self?.secrets?.tick()
        }
    }
    func beginHotkeyRecording() { hotkeyCoordinator?.beginRecording() }
    func prepareToTerminate() -> Bool {
        guard meetings?.leaveScreen() != false else {
            route = .meetings
            notice = "회의록을 저장하지 못해 종료를 취소했습니다. 입력 오류를 수정하고 저장한 뒤 다시 종료하세요."
            openMainWindow?()
            NSApp.activate(ignoringOtherApps: true)
            return false
        }
        return true
    }
    func prepareAudioAndTerminate() async -> Bool {
        guard prepareToTerminate() else { return false }
        guard await meetings?.shutdownAudio() != false else {
            notice = "녹음 원본을 마무리하지 못했습니다. 녹음 상태를 확인한 뒤 다시 종료하세요."
            route = .meetings; openMainWindow?(); NSApp.activate(ignoringOtherApps: true)
            return false
        }
        return prepareToTerminate()
    }
    func endHotkeyRecording() {
        let messages = hotkeyCoordinator?.endRecording() ?? []
        if !messages.isEmpty { notice = messages.joined(separator: "\n") }
    }

    func restoreBackup(_ backup: BackupInfo, includeVault: Bool) async {
        guard meetings?.isBusy != true, meetings?.recorder.recordingURL == nil else {
            notice = "회의 작업을 마치고 남은 녹음을 내보내거나 삭제한 뒤 백업을 복원하세요."
            return
        }
        guard !isRestoring, let options = environment?.options, let model = backups, !model.isBusy else { return }
        guard meetings?.save() != false else {
            notice = "회의록 저장을 완료하지 못했습니다. 회의록의 입력을 확인한 뒤 복원하세요."
            return
        }
        isRestoring = true
        // Weak lifetime checks ensure SQLite deinit has closed both databases before file replacement.
        weak var previousEnvironment = environment
        weak var previousCapture = captureSession
        weak var previousGraph = graph
        weak var previousPrompts = prompts
        weak var previousDay = day
        weak var previousTaskList = taskList
        weak var previousProjects = projects
        weak var previousSearch = search
        weak var previousTask = taskDetail
        weak var previousMemo = memoDetail
        weak var previousReports = reportModel
        weak var previousPerformanceReports = performanceReports
        weak var previousReportLibrary = reportLibrary
        weak var previousPlan = plan
        weak var previousQuiz = quiz
        selectedTaskId = nil; selectedMemoId = nil
        capturePanel?.teardown(); capturePanel = nil
        captureSession?.detach(); graph?.detach(); prompts?.detach()
        meetings?.detach(); meetings = nil
        secrets?.detach(); settingsModel?.detach(); model.detach()
        searchPanel?.teardown(); searchPanel = nil
        chatGPTLogin?.cancel(); chatGPTLogin = nil
        clearRegistrations()
        captureSession = nil; graph = nil; prompts = nil
        // These read models own an immutable environment and expose no detach API.
        // Release them and check their weak lifetimes before replacing the stores.
        taskList = nil; projects = nil
        searchSurface = nil
        day = nil; search = nil; taskDetail = nil; memoDetail = nil
        reportModel = nil; performanceReports = nil; reportLibrary = nil; plan = nil; quiz = nil
        secrets = nil; settingsModel = nil; backups = nil; environment = nil
        startupError = "복원을 준비하고 있습니다. 저장소 연결을 닫는 중입니다."
        for _ in 0..<30 {
            if previousEnvironment == nil && previousCapture == nil && previousGraph == nil && previousPrompts == nil && previousDay == nil && previousTaskList == nil && previousProjects == nil && previousSearch == nil && previousTask == nil && previousMemo == nil && previousReports == nil && previousPerformanceReports == nil && previousReportLibrary == nil && previousPlan == nil && previousQuiz == nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard previousEnvironment == nil && previousCapture == nil && previousGraph == nil && previousPrompts == nil && previousDay == nil && previousTaskList == nil && previousProjects == nil && previousSearch == nil && previousTask == nil && previousMemo == nil && previousReports == nil && previousPerformanceReports == nil && previousReportLibrary == nil && previousPlan == nil && previousQuiz == nil else {
            startupError = "저장소 연결을 안전하게 닫지 못해 복원을 중단했습니다. 앱을 다시 열고 시도하세요."
            isRestoring = false
            return
        }
        let restored = await model.restoreAfterClosing(backup, into: options.paths, keyStore: options.keyStore,
            includeVault: includeVault, clock: options.clock)
        isRestoring = false; didStart = false; startupError = nil
        await start()
        route = .backups
        if restored { notice = "백업 복원을 완료하고 저장소를 다시 열었습니다." }
        else {
            notice = model.message
            if let current = backups {
                await current.requestRestore(backup)
                current.includeSecrets = model.includeSecrets
                if model.offersOrdinaryOnlyRestore {
                    current.recordFailure(BackupFailure.vaultKeyMissing(keyVersion: nil))
                }
            }
        }
    }

    private func installLifecycleObservers() {
        isPanelKeyWindow = NSApp.keyWindow is NSPanel
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated { self?.isPanelKeyWindow = notification.object is NSPanel }
            })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: nil, queue: .main) { [weak self] _ in
                // A previous window can resign after the panel becomes key.
                // Resolve the current key window after the notification sequence.
                DispatchQueue.main.async { [weak self] in
                    self?.isPanelKeyWindow = NSApp.keyWindow is NSPanel
                }
            })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.meetings?.leaveScreen()
                    self?.environment?.lockSecrets(.appQuit)
                }
            })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.environment?.lockSecrets(.screenLocked) }
            })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.environment?.lockSecrets(.screenLocked) }
            })
    }
}
#endif
