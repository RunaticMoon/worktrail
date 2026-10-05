#if os(macOS)
import SwiftUI
import WorkLogCore

@MainActor struct TaskDetailScreen: View {
    @Bindable var model: TaskDetailModel
    let onClose: () -> Void
    var taskNames: [String: String] = [:]
    var onOpenTask: ((String) -> Void)? = nil
    @State private var projectsExpanded = false
    @State private var checklistExpanded = false
    @State private var activitiesExpanded = true
    @State private var evidenceExpanded = false
    @FocusState private var activityFocused: Bool
    @State private var activityFocusRequested = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.detail?.task.title ?? "업무 상세").font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                    if let status = model.detail?.status { TaskStatusBadge(status: status) }
                    else if model.detail != nil { StatusBadge(label: "상태 없음", systemImage: "questionmark.circle", tone: .neutral) }
                    if model.isInThisWeekPlan { ChipView(label: "이번 주 계획", systemImage: "calendar.badge.clock") }
                }
                Spacer(minLength: 0)
                Button("닫기", action: onClose).keyboardShortcut(.cancelAction)
            }
            if let date = model.asOf {
                AsOfDateBadge(dateLabel: date.iso)
                Text("읽기 전용입니다. 현재 상태는 업무 화면에서 관리합니다.")
                    .font(.callout).foregroundStyle(WorkLogTheme.muted)
            }
            if let error = model.errorMessage { InlineNotice(message: error) }
            if let detail = model.detail {
                if model.asOf == nil {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { primaryActions(detail) }
                        VStack(alignment: .leading, spacing: 8) { primaryActions(detail) }
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if let due = detail.task.dueOn { Label("마감 \(due.iso)", systemImage: "calendar").font(.callout) }
                            if model.asOf == nil { statusActions(detail) }
                            SectionDisclosure(title: "프로젝트별 적용 상태", summary: model.projectStatusSummary ?? "추적하는 프로젝트 없음",
                                              isExpanded: $projectsExpanded) { projectStatuses(detail) }
                            Divider()
                            SectionDisclosure(title: "체크리스트", summary: model.checklistSummary ?? "항목 없음",
                                              isExpanded: $checklistExpanded) { checklist(detail) }
                            Divider()
                            SectionDisclosure(title: "진행 기록", summary: "\(detail.activities.count)개 기록",
                                              isExpanded: $activitiesExpanded) { activities(detail) }.id("activities")
                            Divider()
                            SectionDisclosure(title: "근거·이력", summary: "완료 이력 \(detail.completionDates.count)개 · 관계 \(detail.relations.count)개 · 링크 \(detail.links.count)개",
                                              isExpanded: $evidenceExpanded) { evidence(detail) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: activityFocused) { _, focused in
                        if focused { proxy.scrollTo("activities", anchor: .top) }
                    }
                }
            } else {
                StateView(kind: model.errorMessage == nil ? .empty : .failure, title: "업무를 불러올 수 없습니다",
                          detail: "목록으로 돌아가 업무를 다시 선택하세요.", actionTitle: "목록으로", action: onClose)
            }
        }
        .padding(WorkLogTheme.contentInset)
        .sheet(isPresented: Binding(get: { model.completionCheck != nil },
            set: { if !$0 { model.cancelCompletion() } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("남은 범위를 확인하세요").font(.title2).accessibilityAddTraits(.isHeader)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(model.completionScopeLines.enumerated()), id: \.offset) { _, line in
                            Text(line).fixedSize(horizontal: false, vertical: true)
                        }
                        Text("남은 항목과 프로젝트 상태는 자동으로 완료되지 않습니다.")
                            .foregroundStyle(WorkLogTheme.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { completionActions }
                    VStack(alignment: .leading, spacing: 8) { completionActions }
                }
            }.padding(24).frame(minWidth: 500, minHeight: 300)
        }
    }

    @ViewBuilder private func primaryActions(_ detail: TaskDetail) -> some View {
        Button("진행 기록 추가") {
            if activitiesExpanded { activityFocused = true }
            else { activityFocusRequested = true; activitiesExpanded = true }
        }
        Button("Task 전체 완료") { model.complete() }
            .disabled(detail.status == .completed)
            .worklogHelp("Task 전체 완료. 체크리스트·프로젝트 상태는 별도입니다")
    }

    @ViewBuilder private var completionActions: some View {
        Button("취소", role: .cancel) { model.cancelCompletion() }.keyboardShortcut(.cancelAction)
        Button("남겨두고 Task 전체 완료") { model.complete(confirmRemaining: true) }
            .buttonStyle(.borderedProminent)
    }

    private func statusActions(_ detail: TaskDetail) -> some View {
        HStack(spacing: 8) {
            if detail.status == .planned { Button("시작") { model.changeStatus(.started) } }
            if detail.status == .inProgress { Button("보류") { model.changeStatus(.paused) } }
            if detail.status == .onHold { Button("재개") { model.changeStatus(.resumed) } }
            if detail.status == .completed { Button("재개") { model.changeStatus(.reopened) } }
            if detail.status == .cancelled { Button("예정으로") { model.changeStatus(.replanned) } }
            if detail.status != .cancelled { Button("Task 취소") { model.changeStatus(.cancelled) } }
        }
    }

    private func projectStatuses(_ detail: TaskDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if detail.projects.isEmpty { Text("연결된 프로젝트가 없습니다.").foregroundStyle(WorkLogTheme.muted) }
            ForEach(detail.projects, id: \.link.id) { project in
                VStack(alignment: .leading, spacing: 8) {
                    Text(project.project.name).font(.headline)
                    if project.link.trackingEnabled {
                        if let status = project.status { TaskStatusBadge(status: status) }
                        if model.asOf == nil {
                            Button("\(project.project.name)에 적용 완료") {
                                model.changeProjectStatus(projectId: project.project.id, kind: .completed)
                            }.disabled(project.status == .completed)
                            Menu("다른 적용 상태") {
                                if project.status == .planned { Button("시작") { model.changeProjectStatus(projectId: project.project.id, kind: .started) } }
                                if project.status == .inProgress { Button("보류") { model.changeProjectStatus(projectId: project.project.id, kind: .paused) } }
                                if project.status == .onHold { Button("재개") { model.changeProjectStatus(projectId: project.project.id, kind: .resumed) } }
                                if project.status == .completed { Button("재개") { model.changeProjectStatus(projectId: project.project.id, kind: .reopened) } }
                                if project.status == .cancelled { Button("예정으로") { model.changeProjectStatus(projectId: project.project.id, kind: .replanned) } }
                                if project.status != .cancelled { Button("적용 취소") { model.changeProjectStatus(projectId: project.project.id, kind: .cancelled) } }
                            }
                        }
                    } else { Text("전체 상태 따름").font(.callout).foregroundStyle(WorkLogTheme.muted) }
                }.padding(.top, 8)
            }
        }
    }

    private func checklist(_ detail: TaskDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if detail.checklist.isEmpty { Text("체크리스트 항목이 없습니다.").foregroundStyle(WorkLogTheme.muted) }
            ForEach(detail.checklist, id: \.item.id) { entry in
                Toggle(entry.item.text, isOn: Binding(get: { entry.done }, set: { model.setChecklist(itemId: entry.item.id, done: $0) }))
                    .disabled(model.asOf != nil)
            }
            if model.asOf == nil {
                HStack {
                    TextField("새 체크리스트 항목", text: $model.checklistText).accessibilityLabel("새 체크리스트 항목")
                    Button("항목 추가") { model.addChecklistItem() }
                        .disabled(model.checklistText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("체크리스트를 모두 체크해도 Task 전체 상태는 바뀌지 않습니다.")
                    .font(.callout).foregroundStyle(WorkLogTheme.muted)
            }
        }.padding(.top, 8)
    }

    private func activities(_ detail: TaskDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.asOf == nil {
                Picker("기록 범위", selection: $model.activityProjectId) {
                    ForEach(model.activityScopeOptions, id: \.id) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                TextEditor(text: $model.activityText).frame(minHeight: 100)
                    .focused($activityFocused).accessibilityLabel("진행 기록 내용")
                    .onAppear {
                        if activityFocusRequested { activityFocused = true; activityFocusRequested = false }
                    }
                Button("진행 기록 저장") { model.addActivity() }
                    .disabled(model.activityText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("오늘의 업무일로 저장됩니다. 다른 날짜는 빠른 입력을 사용하세요.")
                    .font(.callout).foregroundStyle(WorkLogTheme.muted)
            }
            if detail.activities.isEmpty { Text("진행 기록이 없습니다.").foregroundStyle(WorkLogTheme.muted) }
            ForEach(detail.activities) { activity in
                VStack(alignment: .leading, spacing: 8) {
                    Text(activity.workDate.iso).font(.callout).foregroundStyle(WorkLogTheme.muted)
                    ChipView(label: model.activityScopeLabel(activity), systemImage: "folder")
                    Text(activity.body).textSelection(.enabled)
                }
                Divider()
            }
        }.padding(.top, 8)
    }

    private func evidence(_ detail: TaskDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("시작일: \(detail.firstStartedOn?.iso ?? "기록 없음")")
            if detail.completionDates.isEmpty { Text("완료 이력 없음").foregroundStyle(WorkLogTheme.muted) }
            ForEach(Array(detail.completionDates.enumerated()), id: \.offset) { _, date in Text("완료 이력: \(date.iso)") }
            ForEach(detail.relations) { relation in
                let id = relation.fromTaskId == detail.task.id ? relation.toTaskId : relation.fromTaskId
                let title = taskNames[id] ?? "연결된 업무"
                if let onOpenTask {
                    Button { onOpenTask(id) } label: { Label(title, systemImage: "link") }
                } else { Label(title, systemImage: "link") }
                Text(relation.type == .followUp ? "후속 업무" : "관련 업무").font(.callout).foregroundStyle(WorkLogTheme.muted)
            }
            ForEach(detail.links) { link in
                if let url = URL(string: link.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    Link(link.url, destination: url)
                } else { Text(link.url).textSelection(.enabled) }
            }
            if !detail.violations.isEmpty { InlineNotice(message: "상태 이력에 확인이 필요한 항목이 있습니다.") }
        }.padding(.top, 8)
    }
}
#endif
