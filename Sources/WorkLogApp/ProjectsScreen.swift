#if os(macOS)
import AppKit
import SwiftUI
import WorkLogCore

@MainActor struct ProjectsScreen: View {
    @Environment(\.worklogContentAutofocus) private var contentAutofocus
    @Bindable var model: ProjectsModel
    let calendar: WorkCalendar
    let onOpen: (String) -> Void
    let onCapture: () -> Void
    let onProjectCreated: () -> Void
    var detailDismissalRevision: Int = 0
    @State private var taskSelection: String?
    @State private var showsProjectTasks = false
    @State private var showsProjectCreator = false
    @FocusState private var projectsFocused: Bool
    @FocusState private var tasksFocused: Bool
    @FocusState private var fallbackFocused: Bool

    private var needsFallbackFocus: Bool { model.errorMessage != nil || model.projects.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: "프로젝트", purpose: "프로젝트에 연결된 업무와 진행 상태를 확인합니다") {
                Button(action: onCreateProject) { ShortcutLabel(title: "프로젝트 추가", keys: "⌘N") }
                    .worklogKeyboardActivation(onCreateProject)
                    .worklogHelp("새 프로젝트 만들기", keys: "⌘N")
            }
            if let error = model.errorMessage {
                RecoveryNotice(failed: error, preserved: "저장된 프로젝트와 업무는 그대로입니다.", retry: { model.load() })
                    .focusable().focused($fallbackFocused)
            } else if model.projects.isEmpty {
                StateView(kind: .empty, title: "아직 프로젝트가 없습니다", detail: "프로젝트를 먼저 만든 뒤 메모와 업무를 연결하세요.",
                    actionTitle: "프로젝트 추가 ⌘N", action: onCreateProject)
                    .focusable().focused($fallbackFocused)
                    .onKeyPress(keys: [.return, .space], phases: .down) { press in
                        guard fallbackFocused, press.modifiers.isEmpty, !hasMarkedText else { return .ignored }
                        onCreateProject()
                        return .handled
                    }
                    .accessibilityHint("Return 또는 Space로 프로젝트 추가")
            } else {
                GeometryReader { geometry in
                    Group {
                        if geometry.size.width >= 800 {
                            HStack(spacing: 16) {
                                projectList.frame(width: 240)
                                Divider()
                                projectTasks
                            }
                        } else if showsProjectTasks, model.selectedProjectId != nil {
                            VStack(alignment: .leading, spacing: 12) {
                                Button("프로젝트 목록", systemImage: "chevron.left") { focusProjectList() }
                                    .keyboardShortcut(.leftArrow, modifiers: .command)
                                projectTasks
                            }
                        } else { projectList }
                    }
                    .onChange(of: showsProjectTasks) { _, showingTasks in
                        guard geometry.size.width < 800 else { return }
                        // Apply focus after the destination list enters the view hierarchy.
                        DispatchQueue.main.async {
                            guard geometry.size.width < 800, showsProjectTasks == showingTasks else { return }
                            if showingTasks {
                                guard model.selectedProjectId != nil else { return }
                                projectsFocused = false
                                tasksFocused = true
                            } else {
                                tasksFocused = false
                                projectsFocused = true
                            }
                        }
                    }
                }
                Text(tasksFocused ? "↑↓ 업무 선택 · Return 상세 열기 · ← 프로젝트" : "↑↓ 프로젝트 선택 · → 또는 Return 업무 목록")
                    .font(.callout).foregroundStyle(WorkLogTheme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(WorkLogTheme.contentInset)
        .focusedSceneValue(\.worklogCreateProject, onCreateProject)
        .sheet(isPresented: $showsProjectCreator, onDismiss: { focusProjectList() }) {
            ProjectCreationSheet(model: model) {
                onProjectCreated()
                showsProjectCreator = false
            }
        }
        .worklogFocusContent {
            if showsProjectTasks { focusProjectTasks() }
            else { focusProjectList() }
        }
        .onAppear {
            model.load()
            DispatchQueue.main.async {
                if contentAutofocus { focusProjectList() }
            }
        }
        .onChange(of: detailDismissalRevision) { _, _ in focusProjectTasks() }
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
                        .accessibilityHint("↑↓로 선택, → 또는 Return으로 프로젝트 업무 보기")
                        .worklogHelp("프로젝트 업무 보기", keys: "→ / Return")
                        .id(project.id)
                    }
                }
                .padding(2)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($projectsFocused)
            .accessibilityLabel("프로젝트 목록")
            .onKeyPress(keys: [.upArrow, .downArrow, .rightArrow, .return], phases: [.down, .repeat]) { press in
                guard press.modifiers.isEmpty, !hasMarkedText else { return .ignored }
                if press.key == .return || press.key == .rightArrow {
                    if press.phase == .down { focusProjectTasks() }
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

    private var hasMarkedText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }

    private func onCreateProject() {
        guard !hasMarkedText else { return }
        showsProjectCreator = true
    }

    private func focusProjectList() {
        showsProjectTasks = false
        tasksFocused = false
        if needsFallbackFocus {
            projectsFocused = false
            DispatchQueue.main.async { fallbackFocused = true }
            return
        }
        fallbackFocused = false
        if model.selectedProjectId == nil { model.select(model.projects.first?.id) }
        DispatchQueue.main.async { projectsFocused = true }
    }

    private func focusProjectTasks() {
        guard !needsFallbackFocus else { focusProjectList(); return }
        fallbackFocused = false
        guard model.selectedProjectId != nil else { focusProjectList(); return }
        showsProjectTasks = true
        projectsFocused = false
        if !model.tasks.contains(where: { $0.id == taskSelection }) {
            taskSelection = model.tasks.first?.id
        }
        DispatchQueue.main.async { tasksFocused = true }
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
                        actionTitle: "업무 기록 추가", action: onCapture)
                        .focusable()
                        .focusEffectDisabled()
                        .focused($tasksFocused)
                        .onKeyPress(keys: [.leftArrow], phases: [.down]) { press in
                            guard press.modifiers.isEmpty, !hasMarkedText else { return .ignored }
                            focusProjectList()
                            return .handled
                        }
                } else {
                    GeometryReader { geometry in
                        // Decide once for the whole list, regardless of individual title lengths.
                        projectTaskList(compact: geometry.size.width < TaskColumns.tableMinimumWidth)
                    }
                    Button("선택한 업무 상세 열기") { if let taskSelection { onOpen(taskSelection) } }
                        .disabled(taskSelection == nil).worklogHelp("업무 상세 열기", keys: "Return")
                        .accessibilityIdentifier("project-open-selected-task")
                }
            }
        } else {
            StateView(kind: .empty, title: "프로젝트를 선택하세요", detail: "연결된 업무와 프로젝트 기준 상태를 보여드립니다.")
        }
    }

    private enum TaskColumns {
        static let tableMinimumWidth: CGFloat = 680
        static let spacing: CGFloat = 12
        static let overallStatus: CGFloat = 88
        static let projectStatus: CGFloat = 124
        static let dueDate: CGFloat = 112
    }

    private func projectTaskList(compact: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    if !compact { taskTableHeader }
                    ForEach(model.tasks) { row in
                        VStack(spacing: 4) {
                            Button { taskSelection = row.id; tasksFocused = true } label: {
                                projectTaskRow(row, compact: compact)
                            }
                                .buttonStyle(WorkLogSourceRowStyle(isSelected: taskSelection == row.id,
                                    isFocused: tasksFocused && taskSelection == row.id))
                                .focusable(false)
                                .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen(row.id) })
                                .accessibilityElement(children: .ignore)
                                .accessibilityIdentifier("project-task-row-\(row.id)")
                                .accessibilityAddTraits(taskSelection == row.id ? .isSelected : [])
                                .accessibilityLabel(Text(taskRowLabel(row)))
                                .accessibilityHint("Return 또는 더블클릭으로 업무 상세 열기")
                                .accessibilityAction(named: Text("업무 상세 열기")) {
                                    taskSelection = row.id
                                    onOpen(row.id)
                                }
                            if row.id != model.tasks.last?.id {
                                Divider().padding(.horizontal, WorkLogTheme.cardInset)
                            }
                        }
                        .id(row.id)
                    }
                }
                .padding(2)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($tasksFocused)
            .accessibilityLabel("프로젝트 업무 목록")
            .accessibilityIdentifier("project-task-list")
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .return], phases: [.down, .repeat]) { press in
                guard press.modifiers.isEmpty, !hasMarkedText else { return .ignored }
                if press.key == .leftArrow {
                    if press.phase == .down { focusProjectList() }
                } else if press.key == .return {
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
            .onChange(of: detailDismissalRevision) { _, _ in
                if let taskSelection { proxy.scrollTo(taskSelection) }
            }
        }
    }

    private var taskTableHeader: some View {
        HStack(spacing: TaskColumns.spacing) {
            Text("업무명").frame(maxWidth: .infinity, alignment: .leading)
            Text("전체 상태").frame(width: TaskColumns.overallStatus, alignment: .leading)
            Text("이 프로젝트 기준").frame(width: TaskColumns.projectStatus, alignment: .leading)
            Text("마감").frame(width: TaskColumns.dueDate, alignment: .leading)
        }
        .font(.caption).foregroundStyle(WorkLogTheme.muted)
        .padding(.horizontal, WorkLogTheme.cardInset).padding(.vertical, 4)
        .accessibilityAddTraits(.isHeader)
    }

    private func projectTaskRow(_ row: ProjectTaskRow, compact: Bool) -> some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 12) {
                    projectTaskTitle(row).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(alignment: .top, spacing: TaskColumns.spacing) {
                        taskField("전체 상태") { overallStatus(row) }
                        taskField("이 프로젝트 기준") { projectStatus(row) }
                        taskField("마감") { dueDate(row) }
                    }
                }
            } else {
                HStack(spacing: TaskColumns.spacing) {
                    projectTaskTitle(row).frame(maxWidth: .infinity, alignment: .leading)
                    overallStatus(row).frame(width: TaskColumns.overallStatus, alignment: .leading)
                    projectStatus(row).frame(width: TaskColumns.projectStatus, alignment: .leading)
                    dueDate(row).frame(width: TaskColumns.dueDate, alignment: .leading)
                }
            }
        }
        .padding(WorkLogTheme.cardInset)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }

    private func taskField<Value: View>(_ title: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(WorkLogTheme.muted)
            value()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func projectTaskTitle(_ row: ProjectTaskRow) -> some View {
        Text(row.title).font(.body.weight(taskSelection == row.id ? .semibold : .regular))
            .lineLimit(2, reservesSpace: true).truncationMode(.tail).help(row.title)
    }

    @ViewBuilder private func overallStatus(_ row: ProjectTaskRow) -> some View {
        if let status = row.overallStatus { TaskStatusBadge(status: status) }
        else { StatusBadge(label: "상태 없음", systemImage: "questionmark.circle", tone: .neutral) }
    }

    @ViewBuilder private func projectStatus(_ row: ProjectTaskRow) -> some View {
        if row.tracksProjectStatus {
            if let status = row.projectStatus { TaskStatusBadge(status: status) }
            else { StatusBadge(label: "상태 없음", systemImage: "questionmark.circle", tone: .neutral) }
        } else {
            Label("전체 상태 따름", systemImage: "equal")
                .font(.callout).foregroundStyle(WorkLogTheme.muted)
                .help("프로젝트별 상태를 따로 관리하지 않고 전체 업무 상태를 따릅니다.")
        }
    }

    private func dueDate(_ row: ProjectTaskRow) -> some View {
        Text(row.dueOn.map { KoreanDateLabel.monthDayWeekday($0, calendar: calendar) } ?? "마감 없음")
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
