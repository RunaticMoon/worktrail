#if os(macOS)
import SwiftUI
import AppKit
import Observation
import WorkLogCore

/// Shared composition point for the main window, menu extra and panels. AE/AF reuse environment.
@Observable @MainActor final class AppController {
    private(set) var environment: AppEnvironment?
    private(set) var capture: CaptureModel?
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
            capture = CaptureModel(environment: env); day = DayViewModel(environment: env)
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
            let keys = GlobalHotkeys()
            let failures = keys.register(capture: settings.captureHotkey, search: settings.searchHotkey,
                onCapture: { [weak self] in self?.showCapture() }, onSearch: { [weak self] in self?.showSearch() })
            hotkeys = keys
            if !failures.isEmpty { notice = failures.joined(separator: "\n") }
            // Catch up from the oldest ordinary source, never from Secret data.
            let today = env.calendar.workDate(of: env.options.clock.now())
            let sources = try env.search.search(SearchQuery(text: "", limit: Int.max))
            let dates = sources.compactMap(\.workDate) + (try env.repo.allEvents()).map(\.effectiveDate)
            let since = dates.min() ?? env.calendar.adding(days: -1, to: today)
            do { try await env.runScheduledReports(since: since) }
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
    }
    func openTask(_ id: String, asOf: WorkDate? = nil) {
        selectedTaskId = id
        taskDetail?.load(taskId: id, asOf: asOf)
    }
    func openMemo(_ id: String) { selectedMemoId = id; memoDetail?.load(id: id) }
    func showCapture() {
        guard let capture, let environment else { return }
        if capture.requiresSecretEditor {
            capturePanel?.closeForSecretEntry()
            selectedTaskId = nil; selectedMemoId = nil
            secrets?.requestNewEntry()
            route = .secrets
            if let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain }) {
                window.makeKeyAndOrderFront(nil)
            } else { openMainWindow?() }
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        capture.reloadCandidates()
        if capture.text.isEmpty && capture.selectedProjectIds.isEmpty && capture.selectedTagIds.isEmpty {
            capture.resetDefaults()
        }
        if capturePanel == nil {
            capturePanel = CapturePanelController(model: capture, calendar: environment.calendar,
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
        guard let environment, let settingsModel else { return }
        _ = settingsModel.save { [weak self] changed in
            guard let self else { throw WorkLogError.storage("설정 적용 중단") }
            let old = environment.settings
            let needsRegistration = old.captureHotkey != changed.captureHotkey || old.searchHotkey != changed.searchHotkey
            if needsRegistration {
                self.hotkeys = nil
                var candidate: GlobalHotkeys? = GlobalHotkeys()
                let errors = candidate!.register(capture: changed.captureHotkey, search: changed.searchHotkey,
                    onCapture: { [weak self] in self?.showCapture() }, onSearch: { [weak self] in self?.showSearch() })
                if !errors.isEmpty {
                    candidate = nil
                    self.restoreHotkeys(old)
                    throw WorkLogError.validation("단축키 등록 실패")
                }
                self.hotkeys = candidate
            }
            do { try environment.updateSettings(changed) }
            catch {
                if needsRegistration { self.hotkeys = nil; self.restoreHotkeys(old) }
                throw error
            }
            self.secrets?.tick()
        }
    }
    private func restoreHotkeys(_ settings: AppSettings) {
        let keys = GlobalHotkeys()
        let errors = keys.register(capture: settings.captureHotkey, search: settings.searchHotkey,
            onCapture: { [weak self] in self?.showCapture() }, onSearch: { [weak self] in self?.showSearch() })
        hotkeys = keys
        if !errors.isEmpty { notice = "기존 단축키를 다시 등록하지 못했습니다. 메뉴에서 입력·검색을 열고 설정을 확인하세요." }
    }

    func restoreBackup(_ backup: BackupInfo, includeVault: Bool) async {
        guard !isRestoring, let options = environment?.options, let model = backups, !model.isBusy else { return }
        isRestoring = true
        // Weak lifetime checks ensure SQLite deinit has closed both databases before file replacement.
        weak var previousEnvironment = environment
        weak var previousCapture = capture
        weak var previousDay = day
        weak var previousSearch = search
        weak var previousTask = taskDetail
        weak var previousMemo = memoDetail
        weak var previousReports = reports
        weak var previousPlan = plan
        weak var previousQuiz = quiz
        selectedTaskId = nil; selectedMemoId = nil
        secrets?.detach(); settingsModel?.detach(); model.detach()
        protectionTimer?.invalidate(); protectionTimer = nil
        if capturePanel != nil {
            for window in NSApp.windows where window.contentView is NSHostingView<CaptureScreen> {
                window.delegate = nil; window.close(); window.contentView = nil
            }
        }
        capturePanel = nil
        searchPanel?.close(); searchPanel?.contentView = nil; searchPanel = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []; hotkeys = nil
        capture = nil; day = nil; search = nil; taskDetail = nil; memoDetail = nil
        reports = nil; plan = nil; quiz = nil
        secrets = nil; settingsModel = nil; backups = nil; environment = nil
        startupError = "복원을 준비하고 있습니다. 저장소 연결을 닫는 중입니다."
        for _ in 0..<30 {
            if previousEnvironment == nil && previousCapture == nil && previousDay == nil && previousSearch == nil && previousTask == nil && previousMemo == nil && previousReports == nil && previousPlan == nil && previousQuiz == nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard previousEnvironment == nil && previousCapture == nil && previousDay == nil && previousSearch == nil && previousTask == nil && previousMemo == nil && previousReports == nil && previousPlan == nil && previousQuiz == nil else {
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
