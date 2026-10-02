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
    private(set) var taskDetail: TaskDetailModel?
    private(set) var memoDetail: MemoDetailModel?
    private(set) var reports: ReportsModel?
    private(set) var plan: PlanModel?
    private(set) var quiz: QuizModel?
    private(set) var secrets: SecretsModel?
    private(set) var settingsModel: SettingsModel?
    private(set) var backups: BackupModel?
    private var protectionTimer: Timer?
    private var isRestoring = false
    var route: SidebarRoute? = .day
    var selectedTaskId: String?
    var selectedMemoId: String?
    private(set) var tasks: [WorkTask] = []
    private(set) var startupError: String?
    private(set) var notice: String?
    private var didStart = false
    private var hotkeys: GlobalHotkeys?
    private var hotkeyCoordinator: HotkeySettingsCoordinator?
    private var capturePanel: CapturePanelController?
    private var searchPanel: NSPanel?
    private var observers: [NSObjectProtocol] = []
    var openMainWindow: (() -> Void)?

    func start() async {
        guard !isRestoring else { return }
        guard !didStart else { return }; didStart = true
        clearRegistrations()
        do {
            let paths = AppPaths.standard()
            let settings = try SettingsStore(fileURL: paths.settingsFile).load()
            var provider: AIProvider?
            if settings.aiEnabled {
                let candidate = CodexAppServerProvider(config: CodexProviderConfig(
                    executablePath: settings.codexExecutablePath, stagingRoot: paths.aiJobsDirectory))
                let capabilities = await candidate.checkCapabilities()
                if capabilities.installed && capabilities.protocolCompatible { provider = candidate }
                else { notice = "AI 연결을 사용할 수 없습니다. 기록과 원문 검색은 정상 동작합니다." }
            }
            let env = try AppEnvironment.open(AppEnvironmentOptions(paths: paths,
                keyStore: KeychainVaultKeyStore(service: AppIdentity.default.bundleIdentifier),
                authenticator: LocalDeviceAuthenticator(), pasteboard: SystemPasteboard(), aiProvider: provider))
            environment = env
            captureSession = CaptureSessionModel(environment: env)
            graph = GraphModel(environment: env)
            prompts = PromptSettingsModel(templates: env.templates)
            day = DayViewModel(environment: env)
            search = SearchModel(environment: env); taskDetail = TaskDetailModel(environment: env)
            memoDetail = MemoDetailModel(environment: env)
            reports = ReportsModel(environment: env)
            plan = PlanModel(environment: env)
            quiz = QuizModel(environment: env)
            secrets = SecretsModel(environment: env)
            settingsModel = SettingsModel(environment: env)
            backups = BackupModel(environment: env)
            installProtectionTimer()
            let launch = env.onLaunch()
            if launch.backupError != nil { notice = "시작 백업을 만들지 못했습니다. 기록은 계속 사용할 수 있습니다." }
            refresh()
            installLifecycleObservers()
            let keys = GlobalHotkeys(handlers: [
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
        } catch {
            clearRegistrations()
            startupError = "WorkLog 저장소를 열지 못했습니다. 저장소 권한과 설정 파일을 확인하고 다시 시도하세요."
        }
    }

    func retryStart() async { didStart = false; startupError = nil; await start() }
    func dismissNotice() { notice = nil }
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
        day?.load()
        do { tasks = try environment?.repo.tasks() ?? [] }
        catch { notice = "업무 목록을 불러오지 못했습니다. 다시 시도하세요." }
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
            guard let reports else { return }
            guard !reports.isGenerating, !reports.hasChanges else {
                notice = "리포트 작업을 마치거나 본문 변경을 저장한 뒤 다른 버전을 여세요."
                return
            }
            reports.requestVersionSelection(node.id.id)
            route = .reports
        case .project, .tag, .supplement, .historicalSource:
            break
        }
    }
    func showCapture() {
        guard let captureSession, let secrets, let environment else { return }
        if capturePanel == nil {
            capturePanel = CapturePanelController(session: captureSession, secrets: secrets, calendar: environment.calendar,
                onSaved: { [weak self] in self?.refresh() })
        }
        capturePanel?.show()
    }
    func showSearch() {
        guard let search, let environment else { return }
        if searchPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 740, height: 620),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = "WorkLog 검색"; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: SearchScreen(model: search, environment: environment))
            panel.center(); searchPanel = panel
        }
        NSApp.activate(ignoringOtherApps: true)
        searchPanel?.makeKeyAndOrderFront(nil)
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
    func endHotkeyRecording() {
        let messages = hotkeyCoordinator?.endRecording() ?? []
        if !messages.isEmpty { notice = messages.joined(separator: "\n") }
    }

    func restoreBackup(_ backup: BackupInfo, includeVault: Bool) async {
        guard !isRestoring, let options = environment?.options, let model = backups, !model.isBusy else { return }
        isRestoring = true
        // Weak lifetime checks ensure SQLite deinit has closed both databases before file replacement.
        weak var previousEnvironment = environment
        weak var previousCapture = captureSession
        weak var previousGraph = graph
        weak var previousPrompts = prompts
        weak var previousDay = day
        weak var previousSearch = search
        weak var previousTask = taskDetail
        weak var previousMemo = memoDetail
        weak var previousReports = reports
        weak var previousPlan = plan
        weak var previousQuiz = quiz
        selectedTaskId = nil; selectedMemoId = nil
        capturePanel?.teardown(); capturePanel = nil
        captureSession?.detach(); graph?.detach(); prompts?.detach()
        secrets?.detach(); settingsModel?.detach(); model.detach()
        searchPanel?.close(); searchPanel?.contentView = nil; searchPanel = nil
        clearRegistrations()
        captureSession = nil; graph = nil; prompts = nil
        day = nil; search = nil; taskDetail = nil; memoDetail = nil
        reports = nil; plan = nil; quiz = nil
        secrets = nil; settingsModel = nil; backups = nil; environment = nil
        startupError = "복원을 준비하고 있습니다. 저장소 연결을 닫는 중입니다."
        for _ in 0..<30 {
            if previousEnvironment == nil && previousCapture == nil && previousGraph == nil && previousPrompts == nil && previousDay == nil && previousSearch == nil && previousTask == nil && previousMemo == nil && previousReports == nil && previousPlan == nil && previousQuiz == nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard previousEnvironment == nil && previousCapture == nil && previousGraph == nil && previousPrompts == nil && previousDay == nil && previousSearch == nil && previousTask == nil && previousMemo == nil && previousReports == nil && previousPlan == nil && previousQuiz == nil else {
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
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.environment?.lockSecrets(.appQuit) }
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
