#if os(macOS)
import AppKit
import SwiftUI
import WorkLogCore

@MainActor struct TaskDetailScreen: View {
    @Bindable var model: TaskDetailModel
    let onClose: () -> Void
    var confirmsTaskNavigation: Binding<Bool> = .constant(false)
    var onCancelTaskNavigation: () -> Void = {}
    var onDiscardInputAndNavigate: () -> Void = {}
    var onEditorPresentationChanged: (Bool) -> Void = { _ in }
    var taskNames: [String: String] = [:]
    var onOpenTask: ((String) -> Void)? = nil
    var meetingRepository: WorkRepository? = nil
    var onOpenMeeting: ((MeetingLocalSearchHit) -> Void)? = nil
    @State private var editingProperties = false
    @State private var editingChecklist: ChecklistItem?
    @State private var correctingEvent: DomainEvent?
    @State private var projectsExpanded = false
    @State private var checklistExpanded = false
    @State private var evidenceExpanded = false
    @State private var activitiesExpanded = true
    @State private var initializedTaskID: String?
    @State private var confirmsDiscardInput = false
    @State private var resumeChecklistAfterClose = false
    @FocusState private var activityFocused: Bool
    @FocusState private var checklistFocused: Bool
    @FocusState private var actionsFocused: Bool

    private var hasUnsavedInput: Bool {
        model.hasUnsavedInput
    }
    private var hasPresentedEditor: Bool {
        editingProperties || editingChecklist != nil || correctingEvent != nil
            || model.completionCheck != nil || confirmsDiscardInput
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.detail?.task.title ?? "업무 상세").font(.title2.weight(.semibold))
                        .lineLimit(3).help(model.detail?.task.title ?? "업무 상세")
                        .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 0)
                Button(model.completionCheck == nil ? "닫기" : "완료 취소", action: requestClose)
                    .keyboardShortcut(.cancelAction)
                    .focusable()
                    .worklogKeyboardActivation(requestClose)
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
                if let notice = model.noticeMessage { Text(notice).font(.callout).foregroundStyle(.secondary) }
                if let detail = model.detail {
                    if let meetingRepository, let onOpenMeeting {
                        TaskMeetingEvidenceView(repo: meetingRepository, taskID: detail.task.id, onOpen: onOpenMeeting)
                            .disabled(hasUnsavedInput)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { taskStatus(detail) }
                        VStack(alignment: .leading, spacing: 8) { taskStatus(detail) }
                    }
                    if model.asOf == nil {
                        WorkDatePicker(title: "실제 업무일", value: $model.workDate, calendar: model.workCalendar)
                            .accessibilityIdentifier("task-detail-work-date")
                        TextField("보류·취소 등 상태 변경 사유 (선택)", text: $model.statusNote)
                            .accessibilityLabel("상태 변경 사유")
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { primaryActions(detail); statusActions(detail) }
                            VStack(alignment: .leading, spacing: 8) { primaryActions(detail); statusActions(detail) }
                        }
                        Text("⌘E 진행 기록 · ⌘L 업무 동작 · ⌘⇧J 체크리스트 · Tab / ⇧Tab 이동")
                            .font(.caption).foregroundStyle(WorkLogTheme.muted)
                    }
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if model.asOf == nil {
                                    Button("업무 정보 편집") { editingProperties = true }
                                        .accessibilityIdentifier("task-detail-edit-properties")
                                    GroupBox("마감·알림") {
                                        TaskDueFields(
                                            dueOn: Binding(get: { model.detail?.task.dueOn }, set: { model.setDueDate($0) }),
                                            daysBefore: Binding(get: { model.detail?.task.dueReminderDaysBefore },
                                                                set: { model.setDueReminderDaysBefore($0) }),
                                            calendar: model.workCalendar, defaultDate: model.today)
                                            .padding(4)
                                    }
                                    activityComposer.id("activities")
                                }
                                SectionDisclosure(title: "프로젝트별 적용 상태", summary: projectSummary(detail),
                                                  isExpanded: $projectsExpanded) { projectStatuses(detail) }
                                Divider()
                                SectionDisclosure(title: "체크리스트", summary: model.checklistSummary ?? "항목 없음",
                                                  isExpanded: $checklistExpanded,
                                                  actionTitle: model.asOf == nil ? "항목 추가" : nil,
                                                  action: focusChecklistInput) { checklist(detail) }
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
                        .onChange(of: checklistFocused) { _, focused in
                            if focused { proxy.scrollTo("checklist-input", anchor: .center) }
                        }
                    }
                } else {
                    StateView(kind: model.errorMessage == nil ? .empty : .failure, title: "업무를 불러올 수 없습니다",
                              detail: "목록으로 돌아가 업무를 다시 선택하세요.", actionTitle: "목록으로", action: requestClose)
                }
            }
        }
        .padding(WorkLogTheme.contentInset)
        .onChange(of: model.detail?.task.id, initial: true) { _, _ in
            initializeSectionExpansion()
        }
        .onChange(of: hasPresentedEditor) { _, presented in onEditorPresentationChanged(presented) }
        .onDisappear { onEditorPresentationChanged(false) }
        .sheet(isPresented: $editingProperties) {
            if let draft = model.propertiesDraft { TaskPropertiesEditor(model: model, initial: draft) }
        }
        .sheet(item: $editingChecklist) { ChecklistItemEditor(model: model, item: $0) }
        .sheet(item: $correctingEvent) { StatusCorrectionEditor(model: model, event: $0) }
        .interactiveDismissDisabled(hasUnsavedInput)
        .background(WorkLogKeyHandler(handle: handleKey))
        .background {
            Color.clear.alert("다른 업무로 이동할까요?", isPresented: confirmsTaskNavigation) {
                Button("계속 편집", role: .cancel) { onCancelTaskNavigation(); resumeEditing() }
                    .keyboardShortcut(.cancelAction)
                Button("입력 버리고 이동", role: .destructive) { onDiscardInputAndNavigate() }
            } message: {
                Text("저장하지 않은 진행 기록·체크리스트·상태 변경 사유가 있습니다. 계속 편집하여 저장하거나 입력을 버린 뒤 이동하세요.")
            }
        }
        .alert("업무 입력을 버리고 닫을까요?", isPresented: $confirmsDiscardInput) {
            Button("계속 편집", role: .cancel, action: resumeEditing)
                .keyboardShortcut(.cancelAction)
            Button("입력 버리고 닫기", role: .destructive, action: discardInputAndClose)
                .keyboardShortcut("d", modifiers: .command)
        } message: {
            Text("저장하지 않은 진행 기록·체크리스트·상태 변경 사유가 있습니다. 계속 편집하여 저장하거나 입력을 버린 뒤 닫으세요.")
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard !confirmsTaskNavigation.wrappedValue else { return false }
        guard !editingProperties, editingChecklist == nil, correctingEvent == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command, event.keyCode == 13 {
            if !event.isARepeat { requestClose() }
            return true
        }
        guard model.asOf == nil, model.completionCheck == nil, !editingProperties, editingChecklist == nil, correctingEvent == nil else { return false }
        if modifiers == .command, event.keyCode == 14 {
            if !event.isARepeat { activityFocused = true }
            return true
        }
        if modifiers == .command, event.keyCode == 37 {
            if !event.isARepeat { activityFocused = false; actionsFocused = true }
            return true
        }
        if activityFocused, event.keyCode == 48, modifiers.isEmpty || modifiers == .shift {
            // Leave the multiline editor without inserting an invisible tab.
            activityFocused = false
            actionsFocused = true
            return true
        }
        if modifiers == [.command, .shift], event.keyCode == 38 {
            if !event.isARepeat { focusChecklistInput() }
            return true
        }
        return false
    }

    private func initializeSectionExpansion() {
        guard let detail = model.detail, initializedTaskID != detail.task.id else { return }
        initializedTaskID = detail.task.id
        // Apply defaults once per task, preserving the user's choices after saves.
        projectsExpanded = detail.projects.count <= 3
        checklistExpanded = detail.checklist.count <= 3 || !model.checklistText.isEmpty
        evidenceExpanded = false
        activitiesExpanded = true
    }

    private func focusChecklistInput() {
        guard model.asOf == nil, model.completionCheck == nil, !hasMarkedText else { return }
        checklistExpanded = true
        activityFocused = false
        actionsFocused = false
        checklistFocused = false
        DispatchQueue.main.async { checklistFocused = true }
    }

    private func requestClose() {
        guard !hasMarkedText, !confirmsTaskNavigation.wrappedValue else { return }
        if model.completionCheck != nil {
            model.cancelCompletion()
        } else if hasUnsavedInput {
            resumeChecklistAfterClose = checklistFocused || (model.activityText.isEmpty && !model.checklistText.isEmpty)
            confirmsDiscardInput = true
        } else {
            onClose()
        }
    }

    private func resumeEditing() {
        guard model.asOf == nil, model.detail != nil else { return }
        if resumeChecklistAfterClose { checklistExpanded = true }
        DispatchQueue.main.async {
            if resumeChecklistAfterClose { checklistFocused = true }
            else { activityFocused = true }
        }
    }

    private func discardInputAndClose() {
        guard !hasMarkedText else { return }
        model.discardInput()
        onClose()
    }

    private var completionConfirmation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("남은 범위를 확인하세요").font(.headline)
            Text("실제 업무일: \(model.workDate.iso)").font(.callout)
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
            .focusable()
            .worklogKeyboardActivation { model.cancelCompletion() }
            .worklogHelp("전체 완료를 취소하고 작성 중인 내용으로 돌아가기", keys: "Esc")
        Button("남겨두고 Task 전체 완료") { model.complete(confirmRemaining: true) }
            .buttonStyle(.borderedProminent)
            .focusable()
            .worklogKeyboardActivation { model.complete(confirmRemaining: true) }
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
            .focusable().focused($actionsFocused)
            .worklogKeyboardActivation { activityFocused = true }
        Button("Task 전체 완료") { model.complete() }
            .focusable()
            .worklogKeyboardActivation { model.complete() }
            .disabled(detail.status == .completed)
            .worklogHelp("Task 전체 완료. 체크리스트·프로젝트 상태는 별도입니다")
    }

    private var hasMarkedText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }

    private func statusActions(_ detail: TaskDetail) -> some View {
        HStack(spacing: 8) {
            if detail.status == .planned {
                Button("시작") { model.changeStatus(.started) }.focusable()
                    .worklogKeyboardActivation { model.changeStatus(.started) }
            }
            if detail.status == .inProgress {
                Button("보류") { model.changeStatus(.paused) }.focusable()
                    .worklogKeyboardActivation { model.changeStatus(.paused) }
            }
            if detail.status == .onHold {
                Button("재개") { model.changeStatus(.resumed) }.focusable()
                    .worklogKeyboardActivation { model.changeStatus(.resumed) }
            }
            if detail.status == .completed {
                Button("재개") { model.changeStatus(.reopened) }.focusable()
                    .worklogKeyboardActivation { model.changeStatus(.reopened) }
            }
            if detail.status == .cancelled {
                Button("예정으로") { model.changeStatus(.replanned) }.focusable()
                    .worklogKeyboardActivation { model.changeStatus(.replanned) }
            }
            if detail.status != .cancelled {
                Button("Task 취소") { model.changeStatus(.cancelled) }.focusable()
                    .worklogKeyboardActivation { model.changeStatus(.cancelled) }
            }
        }
    }

    private func projectSummary(_ detail: TaskDetail) -> String {
        guard !detail.projects.isEmpty else { return "연결된 프로젝트 없음" }
        let tracked = detail.projects.filter { $0.link.trackingEnabled }
        guard !tracked.isEmpty else { return "\(detail.projects.count)개 · 업무 전체 상태로 관리" }
        let completed = tracked.filter { $0.status == .completed }.count
        return "\(detail.projects.count)개 · 개별 적용 완료 \(completed)/\(tracked.count)"
    }

    private func projectStatuses(_ detail: TaskDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if detail.projects.isEmpty { Text("연결된 프로젝트가 없습니다.").foregroundStyle(WorkLogTheme.muted) }
            if detail.projects.contains(where: { $0.link.trackingEnabled }) {
                Text("각 프로젝트에서 이 업무가 어디까지 진행됐는지 기록합니다. 프로젝트를 완료해도 업무 전체나 다른 프로젝트의 상태는 바뀌지 않습니다.")
                    .font(.callout).foregroundStyle(WorkLogTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(detail.projects, id: \.link.id) { project in
                VStack(alignment: .leading, spacing: 8) {
                    Text(project.project.name).font(.headline)
                    if project.link.trackingEnabled {
                        if let status = project.status { TaskStatusBadge(status: status) }
                        if model.asOf == nil {
                            Button("\(project.project.name)에 적용 완료") {
                                model.changeProjectStatus(projectId: project.project.id, kind: .completed)
                            }
                            .focusable()
                            .worklogKeyboardActivation {
                                model.changeProjectStatus(projectId: project.project.id, kind: .completed)
                            }
                            .disabled(project.status == .completed)
                            .accessibilityIdentifier("task-detail-project-\(project.project.id)-complete")
                            Menu("다른 적용 상태") {
                                if project.status == .planned { Button("시작") { model.changeProjectStatus(projectId: project.project.id, kind: .started) } }
                                if project.status == .inProgress { Button("보류") { model.changeProjectStatus(projectId: project.project.id, kind: .paused) } }
                                if project.status == .onHold { Button("재개") { model.changeProjectStatus(projectId: project.project.id, kind: .resumed) } }
                                if project.status == .completed { Button("재개") { model.changeProjectStatus(projectId: project.project.id, kind: .reopened) } }
                                if project.status == .cancelled { Button("예정으로") { model.changeProjectStatus(projectId: project.project.id, kind: .replanned) } }
                                if project.status != .cancelled { Button("적용 취소") { model.changeProjectStatus(projectId: project.project.id, kind: .cancelled) } }
                            }.focusable()
                                .accessibilityLabel("\(project.project.name) 적용 상태 변경")
                                .accessibilityIdentifier("task-detail-project-\(project.project.id)-status")
                        }
                    } else {
                        Text("업무 전체 상태로 관리 · \(detail.status?.koreanLabel ?? "상태 없음")")
                            .font(.callout).foregroundStyle(WorkLogTheme.muted)
                    }
                }.padding(.top, 8)
            }
        }
    }

    private func checklist(_ detail: TaskDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if detail.checklist.isEmpty { Text("체크리스트 항목이 없습니다.").foregroundStyle(WorkLogTheme.muted) }
            ForEach(detail.checklist, id: \.item.id) { entry in
                checklistRow(entry.item, done: entry.done, detail: detail)
            }
            if model.asOf == nil {
                if !detail.checklist.isEmpty {
                    Text("여기에 놓으면 맨 아래로 이동").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .dropDestination(for: String.self) { ids, _ in
                            guard let id = ids.first, let index = detail.checklist.firstIndex(where: { $0.item.id == id }) else { return false }
                            model.moveChecklist(itemId: id, offset: detail.checklist.count - 1 - index); return true
                        }
                }
                if model.checklistUndoCount > 0 {
                    Button("체크리스트 편집 실행 취소") { model.undoChecklistEdit() }
                        .accessibilityIdentifier("checklist-undo")
                }
                HStack {
                    TextField("새 체크리스트 항목", text: $model.checklistText).accessibilityLabel("새 체크리스트 항목")
                        .focused($checklistFocused)
                        .id("checklist-input")
                        .accessibilityIdentifier("task-detail-checklist-input")
                        .onSubmit {
                            guard !hasMarkedText, !model.checklistText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            model.addChecklistItem()
                            checklistFocused = true
                        }
                    Button("항목 추가") { model.addChecklistItem() }
                        .focusable()
                        .worklogKeyboardActivation { model.addChecklistItem() }
                        .disabled(model.checklistText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("task-detail-checklist-add")
                }
                Text("체크리스트를 모두 체크해도 Task 전체 상태는 바뀌지 않습니다.")
                    .font(.callout).foregroundStyle(WorkLogTheme.muted)
            }
        }.padding(.top, 8)
    }

    private func checklistRow(_ item: ChecklistItem, done: Bool, detail: TaskDetail) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(item.text, isOn: Binding(get: { done }, set: { model.setChecklist(itemId: item.id, done: $0) }))
                    .focusable().disabled(model.asOf != nil)
                    .accessibilityIdentifier("task-detail-checklist-\(item.id)")
                Text(model.checklistScopeLabel(item)).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if model.asOf == nil {
                Button("편집") { editingChecklist = item }.accessibilityLabel("\(item.text) 편집")
                Menu("이동·삭제") {
                    Button("위로 이동") { model.moveChecklist(itemId: item.id, offset: -1) }
                        .disabled(detail.checklist.first?.item.id == item.id)
                    Button("아래로 이동") { model.moveChecklist(itemId: item.id, offset: 1) }
                        .disabled(detail.checklist.last?.item.id == item.id)
                    Button("삭제", role: .destructive) { model.deleteChecklist(itemId: item.id) }
                }.accessibilityLabel("\(item.text) 이동 또는 삭제")
            }
        }
        .draggable(item.id)
        .dropDestination(for: String.self) { ids, _ in
            guard model.asOf == nil, let id = ids.first,
                  detail.checklist.contains(where: { $0.item.id == id }) else { return false }
            model.moveChecklist(itemId: id, before: item.id); return true
        }
    }

    private var activityComposer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.asOf == nil {
                HStack(spacing: 12) {
                    Button("진행 기록 추가 ⌘E") { activityFocused = true }
                        .buttonStyle(.plain).font(.headline).focusable()
                        .worklogKeyboardActivation { activityFocused = true }
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
                    Text("\(model.workDate.iso) 업무일로 저장").font(.callout).foregroundStyle(WorkLogTheme.muted)
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

    private func recordedTimeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = model.workCalendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss z"
        return formatter.string(from: date)
    }

    private func evidence(_ detail: TaskDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("시작일: \(detail.firstStartedOn?.iso ?? "기록 없음")")
            if detail.completionDates.isEmpty { Text("완료 이력 없음").foregroundStyle(WorkLogTheme.muted) }
            ForEach(Array(detail.completionDates.enumerated()), id: \.offset) { _, date in Text("완료 이력: \(date.iso)") }
            ForEach(model.statusEvents) { event in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(event.effectiveDate.iso) · \(model.eventScopeLabel(event)) · \(event.kind.editingLabel)")
                        Spacer()
                        if model.asOf == nil, event.kind.isStatusEvent, !model.isSuperseded(event) {
                            Button("정정") { correctingEvent = event }
                                .accessibilityLabel("\(event.effectiveDate.iso) \(event.kind.editingLabel) 이력 정정")
                                .accessibilityIdentifier("status-correct-\(event.id)")
                        }
                    }
                    if model.isSuperseded(event) { Text("정정 전 원래 기록 · 보존됨").font(.caption).foregroundStyle(.secondary) }
                    if event.supersedesEventId != nil { Text(event.kind == .voided ? "원래 사건을 무효화한 정정 이력" : "정정된 대체 사건").font(.caption).foregroundStyle(.secondary) }
                    Text("기록 시각: " + recordedTimeLabel(event.recordedAt))
                        .font(.caption).foregroundStyle(.secondary)
                    if let note = event.note, !note.isEmpty { Text(note).font(.callout) }
                }
            }
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
