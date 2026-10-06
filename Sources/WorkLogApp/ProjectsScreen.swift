#if os(macOS)
import SwiftUI
import WorkLogCore

@MainActor struct ProjectsScreen: View {
    @Bindable var model: ProjectsModel
    let calendar: WorkCalendar
    let onOpen: (String) -> Void
    let onCapture: () -> Void
    @State private var taskSelection: String?
    @State private var showsProjectTasks = false
    @FocusState private var projectsFocused: Bool
    @FocusState private var tasksFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: "프로젝트", purpose: "전체 업무 상태와 프로젝트별 적용 상태를 구분합니다")
            if let error = model.errorMessage {
                RecoveryNotice(failed: error, preserved: "저장된 프로젝트와 업무는 그대로입니다.", retry: { model.load() })
            } else if model.projects.isEmpty {
                StateView(kind: .empty, title: "아직 프로젝트가 없습니다", detail: "빠른 입력에서 프로젝트를 만들고 업무에 연결하세요.",
                    actionTitle: "기록 추가 ⌘N", action: onCapture)
            } else {
                GeometryReader { geometry in
                    if geometry.size.width >= 800 {
                        HStack(spacing: 16) {
                            projectList.frame(width: 240)
                            Divider()
                            projectTasks
                        }
                    } else if showsProjectTasks, model.selectedProjectId != nil {
                        VStack(alignment: .leading, spacing: 12) {
                            Button("프로젝트 목록", systemImage: "chevron.left") { showsProjectTasks = false }
                            projectTasks
                        }
                    } else { projectList }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(WorkLogTheme.contentInset)
        .onAppear { model.load() }
        .onChange(of: model.selectedProjectId) { _, _ in
            taskSelection = tasksFocused ? model.tasks.first?.id : nil
        }
        .onChange(of: model.tasks.map(\.id)) { _, ids in
            if let taskSelection, !ids.contains(taskSelection) { self.taskSelection = tasksFocused ? ids.first : nil }
        }
        .worklogAnimation(.easeInOut(duration: 0.16), value: showsProjectTasks)
    }

    private var projectList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.projects) { project in
                        Button {
                            model.select(project.id)
                            projectsFocused = true
                            showsProjectTasks = true
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.name)
                                    .font(.body.weight(model.selectedProjectId == project.id ? .semibold : .regular))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("진행 중 \(project.openTaskCount) · 전체 \(project.totalTaskCount)")
                                    .font(.callout).foregroundStyle(WorkLogTheme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, minHeight: WorkLogTheme.rowHeight, alignment: .leading)
                        }
                        .buttonStyle(WorkLogSourceRowStyle(isSelected: model.selectedProjectId == project.id,
                            isFocused: projectsFocused && model.selectedProjectId == project.id))
                        .focusable(false)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("\(project.name), 진행 중 업무 \(project.openTaskCount)개, 전체 업무 \(project.totalTaskCount)개"))
                        .accessibilityAddTraits(model.selectedProjectId == project.id ? .isSelected : [])
                        .accessibilityHint("↑↓로 선택, Return으로 프로젝트 업무 보기")
                        .worklogHelp("프로젝트 업무 보기", keys: "Return")
                        .id(project.id)
                    }
                }
                .padding(2)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($projectsFocused)
            .accessibilityLabel("프로젝트 목록")
            .onKeyPress(keys: [.upArrow, .downArrow, .return], phases: [.down, .repeat]) { press in
                guard press.modifiers.isEmpty else { return .ignored }
                if press.key == .return {
                    if press.phase == .down, model.selectedProjectId != nil { showsProjectTasks = true }
                } else { moveProjectSelection(press.key == .upArrow ? -1 : 1) }
                return .handled
            }
            .onChange(of: projectsFocused) { _, focused in
                if focused && model.selectedProjectId == nil { model.select(model.projects.first?.id) }
            }
            .onChange(of: model.selectedProjectId) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .onAppear { if let id = model.selectedProjectId { proxy.scrollTo(id) } }
        }
    }

    private func moveProjectSelection(_ offset: Int) {
        let ids = model.projects.map(\.id)
        guard !ids.isEmpty else { return }
        if let selected = model.selectedProjectId, let index = ids.firstIndex(of: selected) {
            model.select(ids[min(max(index + offset, 0), ids.count - 1)])
        } else {
            model.select(offset < 0 ? ids.last : ids.first)
        }
    }

    @ViewBuilder private var projectTasks: some View {
        if let project = model.projects.first(where: { $0.id == model.selectedProjectId }) {
            VStack(alignment: .leading, spacing: 12) {
                Text(project.name).font(.headline).accessibilityAddTraits(.isHeader)
                if model.tasks.isEmpty {
                    StateView(kind: .empty, title: "연결된 업무가 없습니다", detail: "빠른 입력에서 이 프로젝트를 업무에 연결하세요.",
                        actionTitle: "업무 기록 추가 ⌘N", action: onCapture)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                taskTableHeader
                                ForEach(model.tasks) { row in
                                    Button { taskSelection = row.id; tasksFocused = true } label: { projectTaskRow(row) }
                                        .buttonStyle(WorkLogSourceRowStyle(isSelected: taskSelection == row.id,
                                            isFocused: tasksFocused && taskSelection == row.id))
                                        .focusable(false)
                                        .id(row.id)
                                        .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen(row.id) })
                                        .accessibilityAddTraits(taskSelection == row.id ? .isSelected : [])
                                        .accessibilityLabel(Text(taskRowLabel(row)))
                                        .accessibilityHint("Return 또는 더블클릭으로 업무 상세 열기")
                                }
                            }
                            .padding(2)
                        }
                        .focusable()
                        .focusEffectDisabled()
                        .focused($tasksFocused)
                        .accessibilityLabel("프로젝트 업무 목록")
                        .onKeyPress(keys: [.upArrow, .downArrow, .return], phases: [.down, .repeat]) { press in
                            guard press.modifiers.isEmpty else { return .ignored }
                            if press.key == .return {
                                if press.phase == .down, let taskSelection { onOpen(taskSelection) }
                            } else { moveTaskSelection(press.key == .upArrow ? -1 : 1) }
                            return .handled
                        }
                        .onChange(of: tasksFocused) { _, focused in
                            if focused && taskSelection == nil { taskSelection = model.tasks.first?.id }
                        }
                        .onChange(of: taskSelection) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                        .onAppear { if let taskSelection { proxy.scrollTo(taskSelection) } }
                    }
                    Button("선택한 업무 상세 열기") { if let taskSelection { onOpen(taskSelection) } }
                        .disabled(taskSelection == nil).worklogHelp("업무 상세 열기", keys: "Return")
                }
            }
        } else {
            StateView(kind: .empty, title: "프로젝트를 선택하세요", detail: "연결된 업무와 프로젝트 기준 상태를 보여드립니다.")
        }
    }

    private var taskTableHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text("업무명").frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
                Text("전체 상태").frame(width: 100, alignment: .leading)
                Text("이 프로젝트 기준").frame(width: 130, alignment: .leading)
                Text("마감").frame(width: 110, alignment: .leading)
            }
            Text("업무 · 전체 상태 · 이 프로젝트 기준 · 마감")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption).foregroundStyle(WorkLogTheme.muted)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .accessibilityAddTraits(.isHeader)
    }

    private func projectTaskRow(_ row: ProjectTaskRow) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                projectTaskTitle(row).frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
                overallStatus(row).frame(width: 100, alignment: .leading)
                projectStatus(row).frame(width: 130, alignment: .leading)
                dueDate(row).frame(width: 110, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 4) {
                projectTaskTitle(row).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Text("전체 상태").font(.caption).foregroundStyle(WorkLogTheme.muted)
                    overallStatus(row)
                }
                HStack(spacing: 8) {
                    Text("이 프로젝트 기준").font(.caption).foregroundStyle(WorkLogTheme.muted)
                    projectStatus(row)
                }
                Label(row.dueOn.map { KoreanDateLabel.monthDayWeekday($0, calendar: calendar) } ?? "마감 없음",
                      systemImage: "calendar").font(.callout).foregroundStyle(WorkLogTheme.muted)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(minHeight: WorkLogTheme.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(taskRowLabel(row)))
        .accessibilityHint("Return 또는 더블클릭으로 업무 상세 열기")
    }

    private func projectTaskTitle(_ row: ProjectTaskRow) -> some View {
        Text(row.title).font(.body.weight(taskSelection == row.id ? .semibold : .regular))
            .lineLimit(1).truncationMode(.tail).help(row.title)
    }

    @ViewBuilder private func overallStatus(_ row: ProjectTaskRow) -> some View {
        if let status = row.overallStatus { TaskStatusBadge(status: status) }
        else { StatusBadge(label: "상태 없음", systemImage: "questionmark.circle", tone: .neutral) }
    }

    @ViewBuilder private func projectStatus(_ row: ProjectTaskRow) -> some View {
        if row.tracksProjectStatus {
            if let status = row.projectStatus { TaskStatusBadge(status: status) }
            else { StatusBadge(label: "상태 없음", systemImage: "questionmark.circle", tone: .neutral) }
        } else { Text("전체 상태 따름").font(.callout).foregroundStyle(WorkLogTheme.muted) }
    }

    private func dueDate(_ row: ProjectTaskRow) -> some View {
        Text(row.dueOn.map { KoreanDateLabel.monthDayWeekday($0, calendar: calendar) } ?? "—")
            .font(.callout).foregroundStyle(WorkLogTheme.muted)
    }

    private func moveTaskSelection(_ offset: Int) {
        let ids = model.tasks.map(\.id)
        guard !ids.isEmpty else { return }
        if let taskSelection, let index = ids.firstIndex(of: taskSelection) {
            self.taskSelection = ids[min(max(index + offset, 0), ids.count - 1)]
        } else { taskSelection = offset < 0 ? ids.last : ids.first }
    }

    private func taskRowLabel(_ row: ProjectTaskRow) -> String {
        "\(row.title), 전체 상태 \(row.overallStatus?.koreanLabel ?? "상태 없음"), 이 프로젝트 기준 \(row.tracksProjectStatus ? (row.projectStatus?.koreanLabel ?? "상태 없음") : "전체 상태 따름"), 마감 \(row.dueOn?.iso ?? "없음")"
    }
}
#endif
