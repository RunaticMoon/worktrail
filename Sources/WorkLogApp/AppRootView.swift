#if os(macOS)
import SwiftUI
import WorkLogCore

/// Main-window destinations, shared with the app controller.
enum SidebarRoute: String, CaseIterable, Identifiable {
    case day, tasks, search, graph, reports, plans, secrets, settings, backups
    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: return "하루 기록"
        case .tasks: return "업무"
        case .search: return "검색"
        case .graph: return "그래프"
        case .reports: return "리포트"
        case .plans: return "계획"
        case .secrets: return "시크릿"
        case .settings: return "설정"
        case .backups: return "백업"
        }
    }
    var symbol: String {
        switch self {
        case .day: return "calendar"
        case .tasks: return "checklist"
        case .search: return "magnifyingglass"
        case .graph: return "point.3.connected.trianglepath.dotted"
        case .reports: return "doc.text"
        case .plans: return "list.bullet.rectangle"
        case .secrets: return "lock"
        case .settings: return "gearshape"
        case .backups: return "externaldrive"
        }
    }
}

struct AppRootView: View {
    @Bindable var controller: AppController
    @Environment(\.openWindow) private var openWindow
    @State private var sidebarVisible = true
    @State private var taskQuery = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedRoute: SidebarRoute { controller.route ?? .day }

    var body: some View {
        Group {
            if let error = controller.startupError {
                VStack(spacing: 20) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 32)).foregroundStyle(WorkLogTheme.accent)
                    InlineNotice(message: error)
                    Button("다시 시도") { Task { await controller.retryStart() } }
                        .buttonStyle(WorkLogButtonStyle(prominent: true))
                }.frame(maxWidth: 420).worklogCard(padding: 28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let environment = controller.environment {
                HStack(spacing: 0) {
                    if sidebarVisible {
                        sidebar.frame(width: 216)
                        Rectangle().fill(WorkLogTheme.border).frame(width: 1)
                    }
                    VStack(spacing: 0) {
                        workspaceHeader
                        Rectangle().fill(WorkLogTheme.border.opacity(0.6)).frame(height: 1)
                        if let notice = controller.notice {
                            HStack(alignment: .top, spacing: 10) {
                                InlineNotice(message: notice)
                                Button { controller.dismissNotice() } label: { Image(systemName: "xmark") }
                                    .accessibilityLabel("안내 닫기").help("안내 닫기")
                            }.padding(16)
                        }
                        destination(environment)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .sheet(isPresented: Binding(get: { controller.selectedTaskId != nil },
                    set: { if !$0 { controller.selectedTaskId = nil } })) {
                    if let detail = controller.taskDetail {
                        TaskDetailScreen(model: detail, onClose: { controller.selectedTaskId = nil; controller.refresh() })
                            .frame(minWidth: 560, minHeight: 480)
                    }
                }
                .sheet(isPresented: Binding(get: { controller.selectedMemoId != nil },
                    set: { if !$0 { controller.selectedMemoId = nil } })) {
                    if let memo = controller.memoDetail {
                        MemoDetailScreen(model: memo, onClose: { controller.selectedMemoId = nil })
                    }
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 32)).foregroundStyle(WorkLogTheme.accent)
                    ProgressView("나의 기록을 여는 중…")
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(WorkLogTheme.canvas)
        .tint(WorkLogTheme.accent)
        .buttonStyle(WorkLogButtonStyle())
        .groupBoxStyle(WorkLogGroupBoxStyle())
        .scrollContentBackground(.hidden)
        .onAppear {
            let action = openWindow
            controller.openMainWindow = { action(id: "main") }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(WorkLogTheme.accent)
                    .frame(width: 36, height: 36)
                    .background(WorkLogTheme.accentSoft, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text("WorkLog").font(.system(size: 17, weight: .bold, design: .rounded))
                    Text("일의 흐름을 기록하세요").font(.system(size: 10)).foregroundStyle(WorkLogTheme.muted)
                }
            }.padding(.horizontal, 8).padding(.top, 12)

            Button { controller.showCapture() } label: {
                HStack {
                    Image(systemName: "plus")
                    Text("빠른 입력")
                    Spacer()
                    Text("⌘ N").font(.system(size: 10, design: .monospaced)).opacity(0.8)
                }.padding(.vertical, 2)
            }.buttonStyle(WorkLogButtonStyle(prominent: true))

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    navigationGroup("워크스페이스", routes: [.day, .tasks, .search, .graph])
                    navigationGroup("정리와 보관", routes: [.reports, .plans, .secrets])
                    navigationGroup("관리", routes: [.settings, .backups])
                }
            }.scrollIndicators(.hidden)
            HStack(spacing: 8) {
                Image(systemName: "keyboard").foregroundStyle(WorkLogTheme.accent)
                Text("기록은 가볍게, 흐름은 선명하게")
                    .font(.system(size: 10)).foregroundStyle(WorkLogTheme.muted)
            }.padding(.horizontal, 6)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(WorkLogTheme.surface)
    }

    private func navigationGroup(_ title: String, routes: [SidebarRoute]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(WorkLogTheme.muted).padding(.leading, 12).padding(.bottom, 5)
            ForEach(routes) { route in
                Button { controller.route = route } label: {
                    HStack(spacing: 11) {
                        Image(systemName: route.symbol).font(.system(size: 14, weight: .medium)).frame(width: 20)
                        Text(route.title).font(.system(size: 12, weight: selectedRoute == route ? .semibold : .medium))
                        Spacer(minLength: 4)
                        if route == .tasks, !controller.tasks.isEmpty {
                            Text("\(controller.tasks.count)").font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(WorkLogTheme.muted)
                        }
                        if selectedRoute == route {
                            RoundedRectangle(cornerRadius: 2).fill(WorkLogTheme.accent).frame(width: 3, height: 14)
                        }
                    }
                    .foregroundStyle(selectedRoute == route ? WorkLogTheme.accent : WorkLogTheme.text)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(selectedRoute == route ? WorkLogTheme.accentSoft : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedRoute == route ? .isSelected : [])
            }
        }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 14) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { sidebarVisible.toggle() }
            } label: { Image(systemName: "sidebar.left") }
                .help(sidebarVisible ? "사이드바 숨기기" : "사이드바 보기")
                .accessibilityLabel(sidebarVisible ? "사이드바 숨기기" : "사이드바 보기")
            HStack(spacing: 8) {
                Text("워크스페이스").foregroundStyle(WorkLogTheme.muted)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(WorkLogTheme.muted)
                Text(selectedRoute.title).fontWeight(.semibold)
            }.font(.system(size: 12))
            Spacer(minLength: 8)
            Button { controller.showSearch() } label: {
                HStack(spacing: 8) { Image(systemName: "magnifyingglass"); Text("검색"); Keycap("⌘ F") }
            }.help("검색 패널 열기")
            Button { controller.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("새로고침").accessibilityLabel("새로고침")
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .background(WorkLogTheme.canvas)
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("지금 하고 있는 일").font(.system(size: 25, weight: .bold))
                    Text("업무의 현재 상태와 진행 내용을 한곳에서 확인하세요.")
                        .font(.callout).foregroundStyle(WorkLogTheme.muted)
                }
                Spacer()
                Text("\(controller.tasks.count)건").font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(WorkLogTheme.accent).padding(10)
                    .background(WorkLogTheme.accentSoft, in: Capsule())
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(WorkLogTheme.muted)
                TextField("업무 이름으로 찾기", text: $taskQuery).textFieldStyle(.plain)
                    .accessibilityLabel("업무 이름으로 찾기")
                if !taskQuery.isEmpty {
                    Button { taskQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("업무 검색어 지우기")
                }
            }.worklogCard(padding: 14)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if controller.tasks.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            EmptyMessage(title: "첫 업무를 기록해 보세요", detail: "빠른 입력의 업무 탭에서 할 일과 진행 내용을 남길 수 있어요.")
                            Button("빠른 입력") { controller.showCapture() }
                                .buttonStyle(WorkLogButtonStyle(prominent: true))
                        }.frame(maxWidth: .infinity, alignment: .leading).worklogCard(padding: 24)
                    } else if filteredTasks.isEmpty {
                        EmptyMessage(title: "일치하는 업무가 없습니다", detail: "다른 검색어로 다시 찾아보세요.")
                            .frame(maxWidth: .infinity, alignment: .leading).worklogCard()
                    }
                    ForEach(filteredTasks) { task in
                        Button { controller.openTask(task.id) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: task.cachedStatus == .completed ? "checkmark.circle.fill" : "circle.dashed")
                                    .font(.system(size: 20)).foregroundStyle(WorkLogTheme.accent)
                                Text(task.title).font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(WorkLogTheme.text).multilineTextAlignment(.leading)
                                Spacer()
                                Text(task.cachedStatus?.koreanLabel ?? "상태 없음")
                                    .font(.system(size: 11, weight: .medium)).foregroundStyle(WorkLogTheme.accent)
                                    .padding(.horizontal, 9).padding(.vertical, 5)
                                    .background(WorkLogTheme.accentSoft, in: Capsule())
                                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(WorkLogTheme.muted)
                            }.frame(maxWidth: .infinity, alignment: .leading).worklogCard(padding: 18)
                                .contentShape(RoundedRectangle(cornerRadius: WorkLogTheme.cornerRadius))
                        }.buttonStyle(.plain).accessibilityHint("업무 상세 열기")
                    }
                }
            }
        }.padding(24)
    }

    private var filteredTasks: [WorkTask] {
        let query = taskQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? controller.tasks : controller.tasks.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    @ViewBuilder private func destination(_ environment: AppEnvironment) -> some View {
        switch controller.route ?? .day {
        case .day:
            if let day = controller.day {
                DayScreen(model: day, calendar: environment.calendar,
                    onCapture: { controller.showCapture() }, onMemo: { controller.openMemo($0) }, onTask: { id in
                        controller.openTask(id, asOf: day.box?.isPast == true ? day.selectedDate : nil)
                    })
            }
        case .tasks:
            taskList
        case .search:
            if let search = controller.search { SearchScreen(model: search, environment: environment) }
        case .graph:
            if let graph = controller.graph { GraphScreen(model: graph, onOpen: { controller.openGraphNode($0) }) }
        case .reports:
            if let reports = controller.reports, let plan = controller.plan, let quiz = controller.quiz {
                ReportsScreen(model: reports, plan: plan, quiz: quiz, calendar: environment.calendar)
            }
        case .plans:
            if let plan = controller.plan { PlanScreen(model: plan, calendar: environment.calendar) }
        case .secrets:
            if let secrets = controller.secrets { SecretsScreen(model: secrets, calendar: environment.calendar) }
        case .settings:
            if let settings = controller.settingsModel, let prompts = controller.prompts {
                SettingsScreen(model: settings, prompts: prompts, onSave: { controller.saveSettings() },
                    onBeginHotkeyRecording: { controller.beginHotkeyRecording() },
                    onEndHotkeyRecording: { controller.endHotkeyRecording() })
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
    var body: some View {
        DatePicker(title, selection: Binding(get: { calendar.startOfDay(value) },
            set: { value = calendar.workDate(of: $0) }), displayedComponents: .date)
            .environment(\.timeZone, calendar.timeZone)
            .environment(\.calendar, calendar.calendar)
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
                .font(.system(size: 20, weight: .light)).foregroundStyle(WorkLogTheme.accent)
                .frame(width: 40, height: 40)
                .background(WorkLogTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.callout).foregroundStyle(WorkLogTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 12)
    }
}
#endif
