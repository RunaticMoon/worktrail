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
        .onChange(of: model.selectedProjectId) { _, _ in taskSelection = nil }
        .onChange(of: model.tasks.map(\.id)) { _, ids in
            if let taskSelection, !ids.contains(taskSelection) { self.taskSelection = nil }
        }
        .worklogAnimation(.easeInOut(duration: 0.16), value: showsProjectTasks)
    }

    private var projectList: some View {
        List(selection: Binding(get: { model.selectedProjectId }, set: { id in
            model.select(id)
            if id != nil { showsProjectTasks = true }
        })) {
            ForEach(model.projects) { project in
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name).font(.headline)
                    Text("진행 중 \(project.openTaskCount) · 전체 \(project.totalTaskCount)")
                        .font(.callout).foregroundStyle(WorkLogTheme.muted)
                }
                .padding(.vertical, 8).tag(project.id)
                .accessibilityElement(children: .combine)
            }
        }
        .listStyle(.inset).accessibilityLabel("프로젝트 목록")
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
                        List(selection: $taskSelection) {
                            HStack(alignment: .top, spacing: 8) {
                                Text("업무명").frame(maxWidth: .infinity, alignment: .leading)
                                Text("전체 상태").frame(width: 100, alignment: .leading)
                                Text("이 프로젝트 기준").frame(width: 130, alignment: .leading)
                                Text("마감").frame(width: 110, alignment: .leading)
                            }.font(.callout).foregroundStyle(WorkLogTheme.muted).accessibilityAddTraits(.isHeader)
                            ForEach(model.tasks) { row in
                                projectTaskRow(row).tag(row.id).id(row.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { taskSelection = row.id; onOpen(row.id) }
                            }
                        }
                        .listStyle(.inset)
                        .onKeyPress(keys: [.return], phases: .down) { press in
                            guard press.modifiers.isEmpty else { return .ignored }
                            guard let taskSelection else { return .ignored }
                            onOpen(taskSelection)
                            return .handled
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

    private func projectTaskRow(_ row: ProjectTaskRow) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(row.title).font(.body).frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading) {
                if let status = row.overallStatus { TaskStatusBadge(status: status) }
                else { Text("상태 없음") }
            }.frame(width: 100, alignment: .leading)
            VStack(alignment: .leading) {
                if row.tracksProjectStatus {
                    if let status = row.projectStatus { TaskStatusBadge(status: status) }
                    else { Text("상태 없음") }
                } else { Text("전체 상태 따름").font(.callout).foregroundStyle(WorkLogTheme.muted) }
            }.frame(width: 130, alignment: .leading)
            Text(row.dueOn.map { KoreanDateLabel.monthDayWeekday($0, calendar: calendar) } ?? "—")
                .font(.callout).frame(width: 110, alignment: .leading)
        }
        .padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(row.title), 전체 상태 \(row.overallStatus?.koreanLabel ?? "상태 없음"), 이 프로젝트 기준 \(row.tracksProjectStatus ? (row.projectStatus?.koreanLabel ?? "상태 없음") : "전체 상태 따름"), 마감 \(row.dueOn?.iso ?? "없음")"))
        .accessibilityHint("Return 또는 더블클릭으로 업무 상세 열기")
    }
}
#endif
