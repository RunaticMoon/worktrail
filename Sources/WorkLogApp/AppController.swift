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

    func start() async {
        guard !didStart else { return }; didStart = true
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
            if settings.defaultCaptureKind == .secret {
                notice = "Secret 입력은 준비 중입니다. 현재 빠른 입력은 일반 메모로 열립니다."
            }
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
            startupError = "WorkLog 저장소를 열지 못했습니다. 저장소 권한과 설정 파일을 확인하고 다시 시도하세요."
        }
    }

    func retryStart() async { didStart = false; startupError = nil; await start() }
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
