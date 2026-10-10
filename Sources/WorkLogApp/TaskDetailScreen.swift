#if os(macOS)
import AppKit
import SwiftUI
import WorkLogCore

@MainActor struct TaskDetailScreen: View {
    @Bindable var model: TaskDetailModel
    let onClose: () -> Void
    var taskNames: [String: String] = [:]
    var onOpenTask: ((String) -> Void)? = nil
    @State private var projectsExpanded = false
    @State private var checklistExpanded = false
    @State private var evidenceExpanded = false
    @State private var activitiesExpanded = true
    @FocusState private var activityFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.detail?.task.title ?? "업무 상세").font(.title2.weight(.semibold))
                        .lineLimit(3).help(model.detail?.task.title ?? "업무 상세")
                        .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 0)
                Button(model.completionCheck == nil ? "닫기" : "완료 취소") {
                    guard !hasMarkedText else { return }
                    if model.completionCheck != nil { model.cancelCompletion() }
                    else { onClose() }
                }.keyboardShortcut(.cancelAction)
            }
            if model.completionCheck != nil {
                completionConfirmation
            } else {
                if let date = model.asOf {
                    AsOfDateBadge(dateLabel: date.iso)
                    Text("읽기 전용입니다. 현재 상태는 업무 화면에서 관리합니다.")
                        .font(.callout).foregroundStyle(WorkLogTheme.muted)
                }
                if let error = model.errorMessage { InlineNotice(message: error) }
                if let detail = model.detail {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { taskStatus(detail) }
                        VStack(alignment: .leading, spacing: 8) { taskStatus(detail) }
                    }
                    if model.asOf == nil {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { primaryActions(detail); statusActions(detail) }
                            VStack(alignment: .leading, spacing: 8) { primaryActions(detail); statusActions(detail) }
                        }
                    }
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if model.asOf == nil { activityComposer.id("activities") }
                                SectionDisclosure(title: "프로젝트별 적용 상태", summary: projectSummary(detail),
                                                  isExpanded: $projectsExpanded) { projectStatuses(detail) }
                                Divider()
                                SectionDisclosure(title: "체크리스트", summary: model.checklistSummary ?? "항목 없음",
                                                  isExpanded: $checklistExpanded) { checklist(detail) }
                                Divider()
                                SectionDisclosure(title: "근거·이력", summary: "완료 이력 \(detail.completionDates.count)개 · 관계 \(detail.relations.count)개 · 링크 \(detail.links.count)개",
                                                  isExpanded: $evidenceExpanded) { evidence(detail) }
                                Divider()
                                SectionDisclosure(title: "진행 기록", summary: "\(detail.activities.count)개 기록",
                                                  isExpanded: $activitiesExpanded) { activityHistory(detail) }
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
        }
        .padding(WorkLogTheme.contentInset)
    }

    private var completionConfirmation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("남은 범위를 확인하세요").font(.headline)
            if let error = model.errorMessage { InlineNotice(message: error) }
            Text("체크리스트와 프로젝트별 적용 상태는 그대로 남습니다.")
                .font(.callout).foregroundStyle(WorkLogTheme.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let check = model.completionCheck {
                        if !check.remainingChecklist.isEmpty {
                            Text("남은 체크리스트 · \(check.remainingChecklist.count)개").font(.headline)
                            ForEach(check.remainingChecklist) { item in
                                Label(item.text, systemImage: "square")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if !check.unfinishedProjects.isEmpty {
                            Text("프로젝트별 미완료 적용 · \(check.unfinishedProjects.count)개").font(.headline)
                            ForEach(check.unfinishedProjects.indices, id: \.self) { index in
                                let project = check.unfinishedProjects[index]
                                let name = model.detail?.projects.first { $0.project.id == project.projectId }?.project.name ?? "프로젝트"
                                Text("\(name) · \(project.status.koreanLabel)")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { completionActions }
                VStack(alignment: .leading, spacing: 8) { completionActions }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var completionActions: some View {
        Button("계속 작업") { model.cancelCompletion() }
            .worklogHelp("전체 완료를 취소하고 작성 중인 내용으로 돌아가기", keys: "Esc")
        Button("남겨두고 Task 전체 완료") { model.complete(confirmRemaining: true) }
            .buttonStyle(.borderedProminent)
    }

    @ViewBuilder private func taskStatus(_ detail: TaskDetail) -> some View {
        HStack(spacing: 8) {
            Text("Task 전체 상태").font(.callout).foregroundStyle(WorkLogTheme.muted)
            if let status = detail.status { TaskStatusBadge(status: status) }
            else { Text("상태 없음").font(.callout) }
        }
        if let due = detail.task.dueOn {
            Label("마감 \(due.iso)", systemImage: "calendar").font(.callout).foregroundStyle(WorkLogTheme.muted)
        }
        if model.isInThisWeekPlan {
            Label("이번 주 계획 포함", systemImage: "calendar.badge.clock")
                .font(.callout).foregroundStyle(WorkLogTheme.muted)
                .help("계획 포함 여부는 실제 착수·완료 상태와 별개입니다")
        }
    }

    @ViewBuilder private func primaryActions(_ detail: TaskDetail) -> some View {
        Button("진행 기록 추가") { activityFocused = true }
            .buttonStyle(.borderedProminent)
        Button("Task 전체 완료") { model.complete() }
            .disabled(detail.status == .completed)
            .worklogHelp("Task 전체 완료. 체크리스트·프로젝트 상태는 별도입니다")
    }

    private var hasMarkedText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
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

    private func projectSummary(_ detail: TaskDetail) -> String {
        guard !detail.projects.isEmpty else { return "연결된 프로젝트 없음" }
        let names = detail.projects.prefix(2).map { project in
            project.project.name + (project.link.trackingEnabled ? " · " + (project.status?.koreanLabel ?? "상태 없음") : "")
        }.joined(separator: " / ")
        return names + (detail.projects.count > 2 ? " 외 \(detail.projects.count - 2)개" : "")
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

    private var activityComposer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.asOf == nil {
                HStack(spacing: 12) {
                    Text("진행 기록 추가").font(.headline)
                    Spacer(minLength: 8)
                    Picker("범위", selection: $model.activityProjectId) {
                        ForEach(model.activityScopeOptions, id: \.id) { option in
                            Text(option.label).tag(option.id)
                        }
                    }.frame(maxWidth: 260).lineLimit(1).accessibilityLabel("진행 기록 범위")
                }
                TextEditor(text: $model.activityText)
                    .font(.body)
                    .frame(height: activityEditorHeight)
                    .padding(6)
                    .background(WorkLogTheme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(WorkLogTheme.muted.opacity(0.35)))
                    .focused($activityFocused).accessibilityLabel("진행 기록 내용")
                HStack(spacing: 12) {
                    Text("오늘 업무일로 저장").font(.callout).foregroundStyle(WorkLogTheme.muted)
                        .help("다른 업무일은 빠른 입력에서 선택할 수 있습니다")
                    Spacer(minLength: 8)
                    Button("진행 기록 저장") {
                        guard !hasMarkedText else { return }
                        model.addActivity()
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.activityText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .worklogHelp("진행 기록 저장", keys: "⌘Return")
                }
            }
        }
    }

    private func activityHistory(_ detail: TaskDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if detail.activities.isEmpty {
                Text("진행 기록이 없습니다.").foregroundStyle(WorkLogTheme.muted)
            }
            ForEach(detail.activities) { activity in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Text(activity.workDate.iso)
                        Text(model.activityScopeLabel(activity))
                    }.font(.callout).foregroundStyle(WorkLogTheme.muted)
                    Text(activity.body).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
        }
    }

    private var activityEditorHeight: CGFloat {
        let lines = model.activityText.split(separator: "\n", omittingEmptySubsequences: false).count
        return CGFloat(min(160, max(72, max(lines, model.activityText.count / 65 + 1) * 19 + 16)))
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
