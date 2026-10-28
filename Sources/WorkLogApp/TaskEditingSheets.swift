#if os(macOS)
import AppKit
import SwiftUI
import WorkLogCore

@MainActor struct TaskPropertiesEditor: View {
    @Bindable var model: TaskDetailModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TaskPropertiesDraft
    @State private var tags: String
    @FocusState private var titleFocused: Bool

    init(model: TaskDetailModel, initial: TaskPropertiesDraft) {
        self.model = model; _draft = State(initialValue: initial)
        _tags = State(initialValue: initial.tagNames.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("업무 정보 편집").font(.title2)
            Form {
                TextField("업무명", text: $draft.title).focused($titleFocused)
                    .accessibilityIdentifier("task-properties-title")
                TaskDueFields(dueOn: $draft.dueOn, daysBefore: $draft.dueReminderDaysBefore,
                              calendar: model.workCalendar, defaultDate: model.today)
                Section("연결할 프로젝트") {
                    if model.availableProjects.isEmpty { Text("프로젝트 화면에서 프로젝트를 먼저 만드세요.").foregroundStyle(.secondary) }
                    ForEach(model.availableProjects) { project in
                        Toggle(project.name, isOn: Binding(get: { draft.projectIds.contains(project.id) }, set: {
                            if $0 { draft.projectIds.insert(project.id) } else { draft.projectIds.remove(project.id) }
                        }))
                    }
                }
                TextField("태그 (쉼표로 구분)", text: $tags).accessibilityIdentifier("task-properties-tags")
            }.formStyle(.grouped)
            if let error = model.errorMessage { InlineNotice(message: error) }
            HStack {
                Button("취소") { if !taskEditorHasMarkedText { dismiss() } }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("업무 정보 저장") {
                    guard !taskEditorHasMarkedText else { return }
                    draft.tagNames = tags.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    if model.saveProperties(draft) { dismiss() }
                }.keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent)
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("task-properties-save")
            }
        }.padding(20).frame(minWidth: 480, idealWidth: 560, minHeight: 460)
            .interactiveDismissDisabled()
            .onAppear { titleFocused = true }
    }
}

@MainActor struct ChecklistItemEditor: View {
    @Bindable var model: TaskDetailModel
    let item: ChecklistItem
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var projectIds: Set<String>
    @FocusState private var textFocused: Bool

    init(model: TaskDetailModel, item: ChecklistItem) {
        self.model = model; self.item = item
        _text = State(initialValue: item.text)
        let allowed = Set(model.detail?.projects.map { $0.project.id } ?? [])
        _projectIds = State(initialValue: Set(item.projectIds).intersection(allowed))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("체크리스트 편집").font(.title2)
            TextField("내용", text: $text, axis: .vertical).lineLimit(1...5)
                .focused($textFocused).accessibilityIdentifier("checklist-edit-text")
            Text(projectIds.isEmpty ? "공통 항목" : "선택한 프로젝트에 해당하는 항목").foregroundStyle(.secondary)
            ForEach(model.detail?.projects.map(\.project) ?? []) { project in
                Toggle(project.name, isOn: Binding(get: { projectIds.contains(project.id) }, set: {
                    if $0 { projectIds.insert(project.id) } else { projectIds.remove(project.id) }
                }))
            }
            if !projectIds.isEmpty { Button("공통으로 변경") { projectIds = [] } }
            if let error = model.errorMessage { InlineNotice(message: error) }
            HStack {
                Button("취소") { if !taskEditorHasMarkedText { dismiss() } }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("체크리스트 저장") {
                    guard !taskEditorHasMarkedText else { return }
                    if model.editChecklist(itemId: item.id, text: text, projectIds: Array(projectIds)) { dismiss() }
                }.keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(minWidth: 440, idealWidth: 520)
            .interactiveDismissDisabled().onAppear { textFocused = true }
    }
}

@MainActor struct StatusCorrectionEditor: View {
    @Bindable var model: TaskDetailModel
    let event: DomainEvent
    @Environment(\.dismiss) private var dismiss
    @State private var date: WorkDate
    @State private var kind: DomainEventKind
    @State private var createdStatus: TaskStatus
    @State private var note = ""

    init(model: TaskDetailModel, event: DomainEvent) {
        self.model = model; self.event = event
        _date = State(initialValue: event.effectiveDate); _kind = State(initialValue: event.kind)
        _createdStatus = State(initialValue: event.toStatus ?? .planned)
    }

    private var kinds: [DomainEventKind] {
        if event.kind == .created { return [.created] }
        if event.scopeType == .checklistItem { return [.completed, .reopened] }
        return [.started, .paused, .resumed, .completed, .reopened, .cancelled, .replanned]
    }
    private var conflicts: [String] {
        model.correctionConflicts(event: event, date: date, kind: kind, createdStatus: createdStatus, note: note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("상태 이력 정정").font(.title2)
            Text("원래 기록: \(event.effectiveDate.iso) · \(model.eventScopeLabel(event)) · \(event.kind.editingLabel)")
            WorkDatePicker(title: "실제 업무일", value: $date, calendar: model.workCalendar)
                .accessibilityIdentifier("status-correction-date")
            Picker("정정할 상태 변경", selection: $kind) {
                ForEach(kinds, id: \.self) { Text($0.editingLabel).tag($0) }
            }
            if kind == .created {
                Picker("생성 상태", selection: $createdStatus) {
                    ForEach(TaskStatus.allCases, id: \.self) { Text($0.koreanLabel).tag($0) }
                }
            }
            TextField("정정 사유 (선택)", text: $note, axis: .vertical).lineLimit(1...3)
            Text("원래 사건과 정정 이력을 함께 보존합니다. 영향받는 보고서 초안은 다시 생성해 확인하세요. 확정 리포트와 당시 근거는 유지됩니다.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if conflicts.isEmpty { Label("후속 이력과 충돌 없음", systemImage: "checkmark.circle") }
            else {
                ScrollView {
                    VStack(alignment: .leading) {
                        Text("후속 상태 변경과 충돌하여 저장할 수 없습니다.").font(.headline)
                        ForEach(Array(conflicts.enumerated()), id: \.offset) { _, conflict in Text(conflict) }
                    }
                }.frame(maxHeight: 160).accessibilityIdentifier("status-correction-conflicts")
            }
            if let error = model.errorMessage { InlineNotice(message: error) }
            HStack {
                Button("취소") { if !taskEditorHasMarkedText { dismiss() } }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("이력 정정 저장") {
                    guard !taskEditorHasMarkedText else { return }
                    if model.correctEvent(event, date: date, kind: kind, createdStatus: createdStatus, note: note) { dismiss() }
                }.keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent)
                    .disabled(!conflicts.isEmpty).accessibilityIdentifier("status-correction-save")
            }
        }.padding(20).frame(minWidth: 500, idealWidth: 580).interactiveDismissDisabled()
    }
}

extension DomainEventKind {
    var editingLabel: String {
        switch self {
        case .created: return "생성"
        case .started: return "시작"
        case .paused: return "보류"
        case .resumed: return "재개"
        case .completed: return "완료"
        case .reopened: return "완료 후 다시 열기"
        case .cancelled: return "취소"
        case .replanned: return "예정으로"
        case .voided: return "정정으로 무효화"
        default: return rawValue
        }
    }
}

@MainActor private var taskEditorHasMarkedText: Bool {
    (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
}
#endif
