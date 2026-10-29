#if os(macOS)
import SwiftUI
import WorkLogCore

/// Destinations and their menu order are shared by the sidebar and View menu.
enum SidebarRoute: String, CaseIterable, Identifiable {
    case day, tasks, projects, weekly, performance, reportLibrary, secrets
    case search, graph, meetings, trash, backups, settings
    static let primary: [SidebarRoute] = [.day, .tasks, .projects, .weekly, .performance, .reportLibrary, .secrets]
    static let secondary: [SidebarRoute] = [.search, .graph, .meetings, .trash, .backups, .settings]
    static let numbered = Array((primary + secondary).prefix(9))
    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: return "오늘"
        case .tasks: return "업무"
        case .projects: return "프로젝트"
        case .weekly: return "주간보고"
        case .performance: return "성과자료"
        case .reportLibrary: return "리포트"
        case .secrets: return "Secret"
        case .meetings: return "회의록"
        case .search: return "검색"
        case .graph: return "관계 그래프"
        case .trash: return "휴지통"
        case .backups: return "백업"
        case .settings: return "설정"
        }
    }
    var purpose: String? {
        switch self {
        case .weekly: return "팀 제출용"
        case .performance: return "성과평가용 상세 기록"
        case .reportLibrary: return "기간별 보관함"
        default: return nil
        }
    }
    var symbol: String {
        switch self {
        case .day: return "calendar"
        case .tasks: return "checklist"
        case .projects: return "folder"
        case .weekly: return "doc.text"
        case .performance: return "doc.text.magnifyingglass"
        case .reportLibrary: return "books.vertical"
        case .secrets: return "lock"
        case .meetings: return "waveform"
        case .search: return "magnifyingglass"
        case .graph: return "point.3.connected.trianglepath.dotted"
        case .trash: return "trash"
        case .backups: return "externaldrive"
        case .settings: return "gearshape"
        }
    }
    var shortcut: String? {
        if self == .settings { return "⌘," }
        guard let index = Self.numbered.firstIndex(of: self) else { return nil }
        return "⌘\(index + 1)"
    }
}

struct AppRootView: View {
    @Bindable var controller: AppController
    @Environment(\.openWindow) private var openWindow
    @State private var detailDismissalRevision = 0
    @FocusState private var sidebarFocused: Bool
    private var selectedRoute: SidebarRoute { controller.route ?? .day }

    private var sidebarSelection: Binding<SidebarRoute?> {
        Binding(
            get: { selectedRoute },
            set: { if let route = $0 { controller.route = route } }
        )
    }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { controller.sidebarExpanded ? .all : .detailOnly },
            set: { controller.sidebarExpanded = $0 != .detailOnly }
        )
    }

    var body: some View {
        Group {
            if let error = controller.startupError {
                RecoveryNotice(failed: error,
                    preserved: "기존 기록은 삭제하지 않았습니다. 저장소 권한과 설정 파일을 확인하세요.",
                    retry: { Task { await controller.retryStart() } })
                    .frame(maxWidth: 540)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let environment = controller.environment {
                NavigationSplitView(columnVisibility: columnVisibility) {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
                } detail: {
                    workspace(environment)
                }
                .sheet(isPresented: Binding(get: { controller.selectedTaskId != nil },
                    set: { if !$0 { controller.closeTask() } }), onDismiss: { refreshAfterDetailDismissal() }) {
                    if let detail = controller.taskDetail {
                        TaskDetailScreen(model: detail, onClose: controller.closeTask,
                            confirmsTaskNavigation: $controller.confirmsTaskNavigation,
                            onCancelTaskNavigation: controller.cancelTaskNavigation,
                            onDiscardInputAndNavigate: controller.discardInputAndNavigateTask,
                            onEditorPresentationChanged: controller.setTaskEditorPresented,
                            taskNames: taskNames, onOpenTask: { controller.openTask($0, asOf: detail.asOf) },
                            meetingRepository: environment.repo, onOpenMeeting: { hit in
                                controller.closeTask()
                                controller.openMeeting(hit)
                            })
                            .buttonStyle(.bordered)
                            .frame(minWidth: 560, minHeight: 480)
                    }
                }
                .sheet(isPresented: Binding(get: { controller.selectedMemoId != nil },
                    set: { if !$0 { controller.selectedMemoId = nil } }), onDismiss: { refreshAfterDetailDismissal() }) {
                    if let memo = controller.memoDetail {
                        SourceActivityDetailSheet(model: memo, calendar: environment.calendar,
                            onClose: { controller.selectedMemoId = nil }, onSaved: {
                            controller.refresh()
                        })
                            .buttonStyle(.bordered)
                    }
                }
            } else {
                StateView(kind: .loading, title: "나의 기록을 여는 중…", detail: "로컬 저장소를 준비하고 있습니다.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: controller.reportModel?.versions) { _, _ in controller.reportLibrary?.load() }
        .onChange(of: controller.performanceReports?.versions) { _, _ in controller.reportLibrary?.load() }
        .tint(WorkLogTheme.accent)
        .background(MainWindowIdentity())
        .focusedSceneValue(\.worklogFocusSidebar, focusSidebar)
        .onAppear {
            let action = openWindow
            controller.openMainWindow = { action(id: "main") }
        }
    }

    private func workspace(_ environment: AppEnvironment) -> some View {
        VStack(spacing: 0) {
            if let audio = controller.meetings?.audio, audio.captureIssue, let message = audio.captureMessage {
                HStack(alignment: .top) {
                    InlineNotice(message: message)
                    Button("회의록 보기") { controller.navigate(to: .meetings) }
                    if audio.isSavePending {
                        Button("저장 재시도") { _ = audio.retrySaving() }.disabled(audio.isCapturing)
                    } else {
                        Button("닫기") { audio.dismissCaptureIssue() }
                    }
                }.padding(12)
            }
            if let notice = controller.notice {
                HStack(alignment: .top, spacing: 8) {
                    InlineNotice(message: notice)
                    Button { controller.dismissNotice() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("안내 닫기").worklogHelp("안내 닫기")
                }.padding(12)
            }
            if let message = controller.taskNotifications?.errorMessage {
                InlineNotice(message: message).padding(12)
            }
            GeometryReader { viewport in
                destination(environment)
                    .environment(\.worklogContentAutofocus, !sidebarFocused)
                    .buttonStyle(.bordered)
                    .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
            }
        }
        .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(selectedRoute.title)
        .toolbar {
            ToolbarItem(placement: .status) {
                if let audio = controller.meetings?.audio, audio.isCapturing {
                    HStack {
                        Label("\(audio.meetingTitle) · \(Int(audio.elapsed) / 60):\(String(format: "%02d", Int(audio.elapsed) % 60))", systemImage: "record.circle")
                            .lineLimit(1).foregroundStyle(.red)
                        Button("녹음 중지", systemImage: "stop.fill") { audio.stop() }
                            .disabled(audio.phase == .stopping)
                    }
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("빠른 입력", systemImage: "square.and.pencil") { controller.showCapture() }
                    .worklogHelp("빠른 입력", keys: controller.hotkeyDisplay(.capture))
                Button("검색", systemImage: "magnifyingglass") { controller.showSearch() }
                    .worklogHelp("검색 패널 열기", keys: "⌘F")
            }
            ToolbarItemGroup {
                Button("새로고침", systemImage: "arrow.clockwise") { controller.refresh() }
                    .worklogHelp("새로고침")
                Button("키보드 단축키", systemImage: "keyboard") {
                    KeyboardHelpFocusRestoration.shared.open(using: openWindow)
                }
                .worklogHelp("키보드 단축키", keys: "⌘⌥K")
            }
        }
    }

    private var taskNames: [String: String] {
        Dictionary(uniqueKeysWithValues: (controller.taskList?.rows ?? []).map { ($0.id, $0.title) })
    }

    private func refreshAfterDetailDismissal() {
        controller.refresh()
        // DayViewModel.load() is synchronous; restore only after refreshed rows are available.
        detailDismissalRevision += 1
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section("기록") {
                ForEach(SidebarRoute.primary) { navigationRow($0) }
            }
            Section("도구") {
                ForEach(SidebarRoute.secondary) { navigationRow($0) }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("WorkLog")
        .focused($sidebarFocused)
        .accessibilityLabel("사이드바")
    }

    private func navigationRow(_ route: SidebarRoute) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(route.title)
                if let purpose = route.purpose {
                    Text(purpose).font(.caption).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: route.symbol)
        }
        .tag(route)
        .accessibilityLabel(Text(route.purpose.map { "\(route.title), \($0)" } ?? route.title))
        .worklogHelp(route.purpose.map { "\(route.title) · \($0)" } ?? route.title, keys: route.shortcut)
    }

    private func focusSidebar() {
        controller.sidebarExpanded = true
        // The sidebar must be visible before its native list receives focus.
        DispatchQueue.main.async { sidebarFocused = true }
    }

    @ViewBuilder private func destination(_ environment: AppEnvironment) -> some View {
        switch selectedRoute {
        case .day:
            if let day = controller.day {
                DayScreen(model: day, calendar: environment.calendar,
                    onCapture: { controller.showCapture() }, onMemo: { controller.openMemo($0) }, onTask: { id in
                        let asOf: WorkDate? = day.box?.isPast == true ? day.selectedDate : nil
                        controller.openTask(id, asOf: asOf)
                    }, projectNames: Dictionary(uniqueKeysWithValues: (controller.projects?.projects ?? []).map { ($0.id, $0.name) }),
                    detailDismissalRevision: detailDismissalRevision)
            }
        case .tasks:
            if let tasks = controller.taskList {
                TaskListScreen(model: tasks, onOpen: { controller.openTask($0) }, onCapture: { controller.showTaskCapture() },
                    detailDismissalRevision: detailDismissalRevision)
            }
        case .projects:
            if let projects = controller.projects {
                ProjectsScreen(model: projects, calendar: environment.calendar,
                    onOpen: { controller.openTask($0) }, onCapture: { controller.showTaskCapture() },
                    onProjectCreated: { controller.refresh() },
                    relatedMeetings: controller.meetings?.rows ?? [],
                    onOpenMeetings: { controller.openProjectMeetings($0) },
                    detailDismissalRevision: detailDismissalRevision)
            }
        case .meetings:
            if let meetings = controller.meetings {
                MeetingsScreen(model: meetings).onAppear {
                    meetings.onOpenTask = { controller.openTask($0) }
                }
            }
        case .search:
            if let search = controller.search, let surface = controller.searchSurface {
                SearchScreen(model: search, surface: surface, environment: environment, secrets: controller.secrets,
                    onOpenSecrets: { controller.route = .secrets }, onOpenMeeting: { controller.openMeeting($0) })
            }
        case .graph:
            if let graph = controller.graph { GraphScreen(model: graph, onOpen: { controller.openGraphNode($0) }) }
        case .weekly:
            if let reports = controller.reportModel, let plan = controller.plan, let quiz = controller.quiz {
                WeeklyReportScreen(model: reports, plan: plan, quiz: quiz, calendar: environment.calendar,
                    onManageTemplates: { controller.route = .settings })
            }
        case .performance:
            if let reports = controller.performanceReports {
                PerformanceReportScreen(model: reports, calendar: environment.calendar,
                    onManageTemplates: { controller.route = .settings })
            }
        case .reportLibrary:
            if let library = controller.reportLibrary {
                ReportLibraryScreen(model: library,
                    onOpen: { controller.openLibraryReport($0) },
                    onCreate: { controller.openReportCreation(family: $0, periodType: library.periodType) })
            }
        case .secrets:
            if let secrets = controller.secrets { SecretsScreen(model: secrets, calendar: environment.calendar) }
        case .trash:
            if let secrets = controller.secrets { TrashScreen(model: secrets) }
        case .settings:
            if let settings = controller.settingsModel, let prompts = controller.prompts {
                SettingsScreen(chatGPTLogin: controller.chatGPTLogin, model: settings, prompts: prompts, onSave: { controller.saveSettings() },
                    onBeginHotkeyRecording: { controller.beginHotkeyRecording() },
                    onEndHotkeyRecording: { controller.endHotkeyRecording() },
                    backups: controller.backups, onOpenBackups: { controller.route = .backups },
                    activityIntegrations: controller.activityIntegrations, onImported: { controller.refresh() })
            }
        case .backups:
            if let backups = controller.backups {
                BackupScreen(model: backups, calendar: environment.calendar, onRestore: { backup, include in
                    Task { await controller.restoreBackup(backup, includeVault: include) }
                })
            }
        }
    }
}

/// Identifies main windows without changing SwiftUI's scene/restoration identifier.
@MainActor private struct MainWindowIdentity: NSViewRepresentable {
    func makeNSView(context: Context) -> IdentityView { IdentityView() }
    func updateNSView(_ view: IdentityView, context: Context) {}
    final class IdentityView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.setAccessibilityIdentifier(AppController.mainWindowAccessibilityIdentifier)
        }
    }
}

struct WorkDatePicker: View {
    let title: String
    @Binding var value: WorkDate
    let calendar: WorkCalendar
    var showsTitle = true

    var body: some View {
        Group {
            if showsTitle { datePicker }
            else { datePicker.labelsHidden() }
        }
        .environment(\.calendar, calendar.calendar)
        .environment(\.timeZone, calendar.timeZone)
        .environment(\.locale, Locale(identifier: "ko_KR"))
    }

    private var datePicker: some View {
        DatePicker(title, selection: Binding(
            get: { calendar.startOfDay(value) },
            set: { value = calendar.workDate(of: $0) }
        ), displayedComponents: .date)
        .datePickerStyle(.compact)
        .accessibilityLabel(title)
        .help("업무일 선택")
    }
}

struct InlineNotice: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "info.circle.fill")
            .font(.callout).foregroundStyle(WorkLogTheme.text)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(WorkLogTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct EmptyMessage: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "tray")
                .font(.title2).foregroundStyle(WorkLogTheme.accent)
                .frame(width: 40, height: 40)
                .background(WorkLogTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(WorkLogTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 12)
    }
}
#endif
