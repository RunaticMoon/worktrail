#if os(macOS)
import SwiftUI
import WorkLogCore

/// AE/AF: add destinations here, then implement the route switch in AppRootView.destination.
enum SidebarRoute: String, CaseIterable, Identifiable {
    case day, tasks, search, reports, plans, secrets, settings, backups
    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: return "오늘 / 하루"
        case .tasks: return "업무"
        case .search: return "검색"
        case .reports: return "리포트"
        case .plans: return "계획"
        case .secrets: return "Secret"
        case .settings: return "설정"
        case .backups: return "백업"
        }
    }
    var symbol: String {
        switch self {
        case .day: return "calendar"
        case .tasks: return "checklist"
        case .search: return "magnifyingglass"
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
    var body: some View {
        Group {
            if let error = controller.startupError {
                VStack(spacing: 16) {
                    InlineNotice(message: error)
                    Button("다시 시도") { Task { await controller.retryStart() } }
                }.padding()
            } else if let environment = controller.environment {
                NavigationSplitView {
                    List(selection: $controller.route) {
                        Section("기록") {
                            ForEach([SidebarRoute.day, .tasks, .search]) { route in
                                Label(route.title, systemImage: route.symbol).tag(route)
                            }
                        }
                        Section("도구") {
                            ForEach([SidebarRoute.reports, .plans, .secrets, .settings, .backups]) { route in
                                Label(route.title, systemImage: route.symbol).tag(route)
                            }
                        }
                    }.navigationTitle("WorkLog")
                } detail: {
                    VStack(spacing: 0) {
                        if let notice = controller.notice {
                            HStack(alignment: .top) {
                                InlineNotice(message: notice)
                                Button { controller.dismissNotice() } label: { Image(systemName: "xmark") }
                                    .accessibilityLabel("안내 닫기").help("안내 닫기")
                            }.padding(12)
                        }
                        destination(environment)
                    }
                    .toolbar {
                        Button("빠른 입력", systemImage: "square.and.pencil") { controller.showCapture() }
                        Button("새로고침", systemImage: "arrow.clockwise") { controller.refresh() }
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
            } else { ProgressView("WorkLog 여는 중…") }
        }.onAppear {
            let action = openWindow
            controller.openMainWindow = { action(id: "main") }
        }
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
            List {
                if controller.tasks.isEmpty { EmptyMessage(title: "아직 업무가 없습니다", detail: "빠른 입력에서 업무를 등록하세요.") }
                ForEach(controller.tasks) { task in
                    Button { controller.openTask(task.id) } label: {
                        HStack { Text(task.title); Spacer(); Text(task.cachedStatus?.koreanLabel ?? "상태 없음").foregroundStyle(.secondary) }
                    }.buttonStyle(.plain).padding(.vertical, 4)
                }
            }.navigationTitle("현재 업무")
        case .search:
            if let search = controller.search { SearchScreen(model: search, environment: environment) }
        case .reports:
            if let reports = controller.reports, let plan = controller.plan, let quiz = controller.quiz {
                ReportsScreen(model: reports, plan: plan, quiz: quiz, calendar: environment.calendar)
            }
        case .plans:
            if let plan = controller.plan { PlanScreen(model: plan, calendar: environment.calendar) }
        case .secrets:
            if let secrets = controller.secrets { SecretsScreen(model: secrets, calendar: environment.calendar) }
        case .settings:
            if let settings = controller.settingsModel { SettingsScreen(model: settings, onSave: { controller.saveSettings() }) }
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
        Label(message, systemImage: "exclamationmark.circle")
            .font(.callout).fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyMessage: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16)
    }
}
#endif
