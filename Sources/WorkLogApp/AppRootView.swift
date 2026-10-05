#if os(macOS)
import SwiftUI
import WorkLogCore

/// Destinations and their menu order are shared by the sidebar and View menu.
enum SidebarRoute: String, CaseIterable, Identifiable {
    case day, tasks, projects, weekly, performance, secrets
    case search, graph, trash, backups, settings
    static let primary: [SidebarRoute] = [.day, .tasks, .projects, .weekly, .performance, .secrets]
    static let secondary: [SidebarRoute] = [.search, .graph, .trash, .backups, .settings]
    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: return "오늘"
        case .tasks: return "업무"
        case .projects: return "프로젝트"
        case .weekly: return "주간보고"
        case .performance: return "성과자료"
        case .secrets: return "Secret"
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
        case .secrets: return "lock"
        case .search: return "magnifyingglass"
        case .graph: return "point.3.connected.trianglepath.dotted"
        case .trash: return "trash"
        case .backups: return "externaldrive"
        case .settings: return "gearshape"
        }
    }
    var shortcut: String? {
        guard let index = Self.primary.firstIndex(of: self) else { return nil }
        return "⌘\(index + 1)"
    }
}

struct AppRootView: View {
    @Bindable var controller: AppController
    @Environment(\.openWindow) private var openWindow
    @State private var detailDismissalRevision = 0
    @FocusState private var sidebarFocus: SidebarRoute?
    private var selectedRoute: SidebarRoute { controller.route ?? .day }

    var body: some View {
        GeometryReader { _ in
            Group {
                if let error = controller.startupError {
                    RecoveryNotice(failed: error,
                        preserved: "기존 기록은 삭제하지 않았습니다. 저장소 권한과 설정 파일을 확인하세요.",
                        retry: { Task { await controller.retryStart() } })
                        .frame(maxWidth: 540)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let environment = controller.environment {
                    HStack(spacing: 0) {
                        sidebar.frame(width: controller.sidebarExpanded ? 216 : 60)
                        Divider()
                        VStack(spacing: 0) {
                            workspaceHeader
                            Divider()
                            if let notice = controller.notice {
                                HStack(alignment: .top, spacing: 8) {
                                    InlineNotice(message: notice)
                                    Button { controller.dismissNotice() } label: { Image(systemName: "xmark") }
                                        .accessibilityLabel("안내 닫기").worklogHelp("안내 닫기")
                                }.padding(12)
                            }
                            GeometryReader { contentGeometry in
                                destination(environment, contentWidth: contentGeometry.size.width)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            }
                        }
                        .buttonStyle(WorkLogButtonStyle())
                    }
                    .worklogAnimation(.easeInOut(duration: 0.18), value: controller.sidebarExpanded)
                    .sheet(isPresented: Binding(get: { controller.selectedTaskId != nil },
                        set: { if !$0 { controller.selectedTaskId = nil } }), onDismiss: { refreshAfterDetailDismissal() }) {
                        if let detail = controller.taskDetail {
                            TaskDetailScreen(model: detail, onClose: { controller.selectedTaskId = nil },
                                taskNames: taskNames, onOpenTask: { controller.openTask($0, asOf: detail.asOf) })
                                .buttonStyle(WorkLogButtonStyle())
                                .frame(minWidth: 560, minHeight: 480)
                        }
                    }
                    .sheet(isPresented: Binding(get: { controller.selectedMemoId != nil },
                        set: { if !$0 { controller.selectedMemoId = nil } }), onDismiss: { refreshAfterDetailDismissal() }) {
                        if let memo = controller.memoDetail {
                            MemoDetailScreen(model: memo, onClose: { controller.selectedMemoId = nil })
                                .buttonStyle(WorkLogButtonStyle())
                        }
                    }
                } else {
                    StateView(kind: .loading, title: "나의 기록을 여는 중…", detail: "로컬 저장소를 준비하고 있습니다.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(WorkLogTheme.canvas)
        .tint(WorkLogTheme.accent)
        .groupBoxStyle(WorkLogGroupBoxStyle())
        .scrollContentBackground(.hidden)
        .onAppear {
            let action = openWindow
            controller.openMainWindow = { action(id: "main") }
        }
        .onChange(of: selectedRoute) { _, route in
            if sidebarFocus != nil { sidebarFocus = route }
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                WorkLogAppIcon().frame(width: 28, height: 28).accessibilityHidden(true)
                if controller.sidebarExpanded { Text("WorkLog").font(.headline) }
            }.padding(.vertical, 4)
            Button { controller.showCapture() } label: {
                if controller.sidebarExpanded { ShortcutLabel(title: "빠른 입력", keys: "⌘N") }
                else { Image(systemName: "plus").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .accessibilityLabel("빠른 입력").worklogHelp("빠른 입력", keys: "⌘N")
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(SidebarRoute.primary) { navigationButton($0) }
                            Spacer(minLength: 16)
                            Divider().padding(.vertical, 6)
                            ForEach(SidebarRoute.secondary) { navigationButton($0) }
                        }
                        .frame(minHeight: geometry.size.height, alignment: .top)
                    }
                    .onChange(of: sidebarFocus) { _, route in
                        if let route { proxy.scrollTo(route) }
                    }
                    .onKeyPress(keys: [.upArrow, .downArrow, .return], phases: [.down, .repeat]) { press in
                        guard press.modifiers.isEmpty, let sidebarFocus else { return .ignored }
                        if press.key == .return {
                            guard press.phase == .down else { return .handled }
                            controller.route = sidebarFocus
                        } else {
                            let routes = SidebarRoute.primary + SidebarRoute.secondary
                            guard let index = routes.firstIndex(of: sidebarFocus) else { return .ignored }
                            let offset = press.key == .upArrow ? -1 : 1
                            self.sidebarFocus = routes[min(max(index + offset, 0), routes.count - 1)]
                        }
                        return .handled
                    }
                }
            }
        }
        .padding(controller.sidebarExpanded ? 12 : 8)
        .background(WorkLogTheme.surface)
        .buttonStyle(.plain)
        .accessibilityLabel("사이드바")
    }

    private func navigationButton(_ route: SidebarRoute) -> some View {
        Button { controller.route = route; sidebarFocus = route } label: {
            HStack(spacing: 8) {
                Image(systemName: route.symbol).frame(width: 20).accessibilityHidden(true)
                if controller.sidebarExpanded {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(route.title).fontWeight(selectedRoute == route ? .semibold : .regular)
                        if let purpose = route.purpose {
                            Text(purpose).font(.caption).foregroundStyle(WorkLogTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .font(.body)
            .foregroundStyle(WorkLogTheme.text)
            .padding(.horizontal, controller.sidebarExpanded ? 8 : 0)
            .padding(.vertical, 5)
            .frame(minHeight: controller.sidebarExpanded && route.purpose != nil ? 42 : WorkLogTheme.rowHeight)
            .frame(maxWidth: .infinity, alignment: controller.sidebarExpanded ? .leading : .center)
        }
        .buttonStyle(WorkLogSourceRowStyle(isSelected: selectedRoute == route, isFocused: sidebarFocus == route))
        .focusEffectDisabled()
        .focused($sidebarFocus, equals: route)
        .id(route)
        .accessibilityLabel(Text(route.purpose.map { "\(route.title), \($0)" } ?? route.title))
        .accessibilityAddTraits(selectedRoute == route ? .isSelected : [])
        .accessibilityHint("위아래 방향키로 이동하고 Return으로 엽니다.")
        .worklogHelp(route.purpose.map { "\(route.title) · \($0)" } ?? route.title, keys: route.shortcut)
    }

    private var workspaceHeader: some View {
        HStack(spacing: 12) {
            Button { controller.sidebarExpanded.toggle() } label: { Image(systemName: "sidebar.left") }
                .accessibilityLabel(controller.sidebarExpanded ? "사이드바 접기" : "사이드바 펼치기")
                .worklogHelp(controller.sidebarExpanded ? "사이드바 접기" : "사이드바 펼치기", keys: "⌃⌘S")
            Text(selectedRoute.title).font(.headline)
            Spacer(minLength: 8)
            Button { controller.showSearch() } label: { ShortcutLabel(title: "검색", keys: "⌘F") }
                .worklogHelp("검색 패널 열기", keys: "⌘F")
            Button { controller.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .worklogHelp("새로고침").accessibilityLabel("새로고침")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    @ViewBuilder private func destination(_ environment: AppEnvironment, contentWidth: CGFloat) -> some View {
        switch selectedRoute {
        case .day:
            if let day = controller.day {
                DayScreen(model: day, calendar: environment.calendar,
                    onCapture: { controller.showCapture() }, onMemo: { controller.openMemo($0) }, onTask: { id in
                        let asOf: WorkDate? = day.box?.isPast == true ? day.selectedDate : nil
                        controller.openTask(id, asOf: asOf)
                    }, projectNames: Dictionary(uniqueKeysWithValues: (controller.projects?.projects ?? []).map { ($0.id, $0.name) }),
                    contentWidth: contentWidth, detailDismissalRevision: detailDismissalRevision)
            }
        case .tasks:
            if let tasks = controller.taskList {
                TaskListScreen(model: tasks, onOpen: { controller.openTask($0) }, onCapture: { controller.showCapture() })
            }
        case .projects:
            if let projects = controller.projects {
                ProjectsScreen(model: projects, calendar: environment.calendar,
                    onOpen: { controller.openTask($0) }, onCapture: { controller.showCapture() })
            }
        case .search:
            if let search = controller.search {
                SearchScreen(model: search, environment: environment, secrets: controller.secrets,
                    onOpenSecrets: { controller.route = .secrets })
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
        case .secrets:
            if let secrets = controller.secrets { SecretsScreen(model: secrets, calendar: environment.calendar) }
        case .trash:
            if let secrets = controller.secrets { TrashScreen(model: secrets) }
        case .settings:
            if let settings = controller.settingsModel, let prompts = controller.prompts {
                SettingsScreen(model: settings, prompts: prompts, onSave: { controller.saveSettings() },
                    onBeginHotkeyRecording: { controller.beginHotkeyRecording() },
                    onEndHotkeyRecording: { controller.endHotkeyRecording() },
                    backups: controller.backups, onOpenBackups: { controller.route = .backups })
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

struct WorkDatePicker: View {
    let title: String
    @Binding var value: WorkDate
    let calendar: WorkCalendar
    var showsTitle = true
    @State private var isCalendarPresented = false

    var body: some View {
        HStack(spacing: 8) {
            if showsTitle {
                Text(title).font(.caption).foregroundStyle(WorkLogTheme.muted)
            }
            Button { isCalendarPresented.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "calendar").foregroundStyle(WorkLogTheme.accent)
                    Text("\(value.year.formatted(.number.grouping(.never))). \(value.month). \(value.day).")
                        .monospacedDigit()
                    Text(weekday).foregroundStyle(WorkLogTheme.muted)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(WorkLogTheme.muted)
                }
            }
            .buttonStyle(WorkLogButtonStyle())
            .accessibilityLabel(title)
            .accessibilityValue("\(value.year)년 \(value.month)월 \(value.day)일 \(weekday)요일")
            .help("달력에서 날짜 선택")
            .popover(isPresented: $isCalendarPresented, arrowEdge: .bottom) {
                WorkDateCalendar(value: value, calendar: calendar) { date in
                    value = date
                    isCalendarPresented = false
                } onDismiss: {
                    isCalendarPresented = false
                }
            }
        }
    }

    private var weekday: String {
        ["월", "화", "수", "목", "금", "토", "일"][calendar.isoWeekday(value) - 1]
    }
}

private struct WorkDateCalendar: View {
    let value: WorkDate
    let calendar: WorkCalendar
    let onSelect: (WorkDate) -> Void
    let onDismiss: () -> Void
    @State private var cursor: WorkDate
    @FocusState private var isFocused: Bool

    init(value: WorkDate, calendar: WorkCalendar, onSelect: @escaping (WorkDate) -> Void,
         onDismiss: @escaping () -> Void) {
        self.value = value
        self.calendar = calendar
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        _cursor = State(initialValue: value)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                monthButton("이전 달", symbol: "chevron.left", offset: -1)
                Spacer(minLength: 0)
                Text("\(cursor.year.formatted(.number.grouping(.never)))년 \(cursor.month)월")
                    .font(.headline)
                    .monospacedDigit()
                Spacer(minLength: 0)
                monthButton("다음 달", symbol: "chevron.right", offset: 1)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 3), count: 7), spacing: 3) {
                ForEach(["월", "화", "수", "목", "금", "토", "일"], id: \.self) { weekday in
                    Text(weekday)
                        .font(.caption)
                        .foregroundStyle(WorkLogTheme.muted)
                        .frame(width: 28, height: 22)
                }
                ForEach(visibleDays, id: \.self) { date in
                    Button { onSelect(date) } label: {
                        Text(date.day.formatted())
                            .font(.body.weight(date == value ? .semibold : .regular))
                            .monospacedDigit()
                            .frame(width: 28, height: 28)
                            .foregroundStyle(date == value ? WorkLogTheme.surface : WorkLogTheme.text)
                            .background(date == value ? WorkLogTheme.accent : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(date == cursor ? WorkLogTheme.accent : Color.clear, lineWidth: 1)
                            }
                            .opacity(date.month == cursor.month ? 1 : 0.35)
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(date.year)년 \(date.month)월 \(date.day)일")
                    .accessibilityValue(date == value ? "선택됨" : "")
                }
            }
        }
        .frame(width: 214)
        .padding(12)
        .background(WorkLogTheme.surface)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .escape],
                    phases: [.down, .repeat]) { press in
            switch press.key {
            case .leftArrow: cursor = calendar.adding(days: -1, to: cursor)
            case .rightArrow: cursor = calendar.adding(days: 1, to: cursor)
            case .upArrow: cursor = calendar.adding(days: -7, to: cursor)
            case .downArrow: cursor = calendar.adding(days: 7, to: cursor)
            case .return: onSelect(cursor)
            case .escape: onDismiss()
            default: return .ignored
            }
            return .handled
        }
        .accessibilityHint("방향키로 날짜를 이동하고 Return으로 선택합니다.")
    }

    private var visibleDays: [WorkDate] {
        let first = WorkDate(year: cursor.year, month: cursor.month, day: 1)
        let leading = calendar.isoWeekday(first) - 1
        let nextMonth = calendar.adding(months: 1, to: first)
        let count = calendar.daysBetween(first, nextMonth)
        let cellCount = ((leading + count + 6) / 7) * 7
        return (0..<cellCount).map { calendar.adding(days: $0 - leading, to: first) }
    }

    private func monthButton(_ title: String, symbol: String, offset: Int) -> some View {
        Button {
            cursor = calendar.adding(months: offset, to: cursor)
            isFocused = true
        } label: {
            Image(systemName: symbol)
                .font(.callout)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(WorkLogTheme.muted)
        .accessibilityLabel(title)
        .help(title)
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
