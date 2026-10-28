#if os(macOS)
import SwiftUI
import WorkLogCore

@MainActor struct MemoDetailScreen: View {
    @Bindable var model: MemoDetailModel
    let onClose: () -> Void
    var onSaved: (() -> Void)? = nil
    var initiallyEditing = false
    @State private var isEditing = false
    @State private var draft = ""
    @State private var originalBody = ""
    @State private var draftDate = WorkDate(year: 1970, month: 1, day: 1)
    @State private var draftProjects: Set<String> = []
    @State private var draftTags = ""
    @State private var originalTags = ""
    @State private var editingRevision = 0
    @State private var taskQuery = ""
    @State private var pendingTask: WorkTask?
    @State private var saveError: String?
    @State private var showsUnsavedChanges = false
    @FocusState private var editorFocused: Bool
    @FocusState private var editButtonFocused: Bool

    private var hasChanges: Bool { isEditing && (draft != originalBody || draftDate != model.memo?.workDate
        || draftProjects != Set(model.memo?.projectIds ?? []) || draftTags != originalTags) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isEditing ? "\(model.recordLabel) 편집" :
                    (model.importedActivity == nil ? "메모와 업무 연결" : "\(model.recordLabel) · 업무 연결")).font(.title2)
                Spacer()
                if onSaved != nil, model.memo != nil {
                    if isEditing {
                        Button("저장 ⌘S") { save() }
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !hasChanges)
                            .focusable()
                    } else {
                        Button("편집 ⌘E") { beginEditing() }
                            .focusable().focused($editButtonFocused)
                    }
                }
                Button("닫기") { requestClose() }.keyboardShortcut(.cancelAction).focusable()
            }
            if let saveError { InlineNotice(message: saveError) }
            if isEditing {
                DatePicker("실제 업무일", selection: Binding(get: { model.workCalendar.startOfDay(draftDate) },
                    set: { draftDate = model.workCalendar.workDate(of: $0) }), displayedComponents: .date)
                    .environment(\.calendar, model.workCalendar.calendar)
                    .environment(\.timeZone, model.workCalendar.timeZone)
                DisclosureGroup("프로젝트 다중 선택 · \(draftProjects.count)개") {
                    ScrollView {
                        ForEach(model.projects) { project in
                            Toggle(project.name, isOn: Binding(get: { draftProjects.contains(project.id) },
                                set: { if $0 { draftProjects.insert(project.id) } else { draftProjects.remove(project.id) } }))
                        }
                    }.frame(maxHeight: 120)
                }
                TextField("태그 (쉼표로 구분)", text: $draftTags)
                TextEditor(text: $draft)
                    .font(.body).focused($editorFocused)
                    .accessibilityLabel("\(model.recordLabel) 본문 편집")
                    .frame(minHeight: 240)
                    .padding(8)
                    .worklogCard(padding: 0)
                Text("Return 줄바꿈 · ⌘S 또는 ⌘Return 저장 · Esc 닫기")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let memo = model.memo {
                        Text(memo.workDate.iso).font(.caption).foregroundStyle(.secondary)
                        Text(memo.body).textSelection(.enabled)
                        Text("원래 기록: \(timestamp(memo.recordedAt)) · revision \(memo.revision)")
                            .font(.caption).foregroundStyle(.secondary)
                        if let updatedAt = model.updatedAt {
                            Text("마지막 수정: \(timestamp(updatedAt))").font(.caption)
                        }
                        Text("프로젝트: " + model.projects.filter { memo.projectIds.contains($0.id) }.map(\.name).joined(separator: ", "))
                        Text("태그: " + model.tags.filter { memo.tagIds.contains($0.id) }.map(\.name).joined(separator: ", "))
                        DisclosureGroup("변경 이력 · \(model.history.count)개") {
                            ForEach(model.history) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("revision \(entry.memo.revision) · 업무일 \(entry.memo.workDate.iso)").font(.headline)
                                    Text(entry.memo.body).textSelection(.enabled)
                                    if let supersededAt = entry.supersededAt {
                                        Text("수정 시각: \(timestamp(supersededAt))").font(.caption)
                                    }
                                    if entry.classificationRecorded {
                                        Text("프로젝트: " + entry.memo.projectIds.map { id in model.projects.first { $0.id == id }?.name ?? "삭제된 프로젝트" }.joined(separator: ", "))
                                        Text("태그: " + entry.memo.tagIds.map { id in model.tags.first { $0.id == id }?.name ?? "삭제된 태그" }.joined(separator: ", "))
                                    } else { Text("이전 버전에서 분류 이력을 기록하지 않았습니다.").foregroundStyle(.secondary) }
                                }
                                Divider()
                            }
                        }
                    }
                    Text("일반 관련 기록 \(model.relatedLinkCount)개 · 아래 업무 연결은 보고서 근거 승인입니다.")
                        .font(.callout).foregroundStyle(.secondary)
                    TextField("근거로 연결할 기존 업무 검색", text: $taskQuery)
                    if !taskQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ForEach(model.tasks.filter { $0.title.localizedCaseInsensitiveContains(taskQuery) }) { task in
                            Button("보고서 근거 연결: \(task.title)") { pendingTask = task }
                        }
                    }
                    Text("제안은 승인 후 연결됩니다. 원문과 업무 상태는 유지됩니다.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("AI 업무 연결 제안") { Task { await model.suggest() } }
                        .disabled(!model.isAIAvailable || model.isSuggesting)
                    if !model.isAIAvailable {
                        StateView(kind: .aiUnavailable, title: "AI 업무 연결 제안은 연결 후 사용할 수 있습니다",
                                  detail: "원문과 기존 업무 연결은 계속 확인할 수 있습니다.")
                    }
                    if model.isSuggesting { ProgressView("연결 후보 찾는 중…") }
                    if let message = model.message { InlineNotice(message: message) }
                    if model.links.isEmpty {
                        StateView(kind: .empty, title: "연결 제안 없음",
                                  detail: "원문과 업무 상태는 유지됩니다. AI가 연결되어 있으면 제안을 요청할 수 있습니다.")
                    }
                    ForEach(model.links) { link in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.tasks.first { $0.id == link.taskId }?.title ?? "찾을 수 없는 업무").font(.headline)
                            Text(link.reason)
                            Text(label(link.status)).font(.callout)
                            if link.sourceRevision != model.memo?.revision {
                                Text("연결 당시 revision \(link.sourceRevision) · 현재 revision \(model.memo?.revision ?? 0). 최신 원문을 확인하고 다시 승인하세요.")
                                    .foregroundStyle(.orange)
                            }
                            DisclosureGroup(link.status == .accepted || link.status == .rejected ? "근거 연결 다시 검토 / 해제" : "연결 결정") {
                                HStack {
                                    Button("현재 원문 승인") { model.decide(linkId: link.id, status: .accepted) }
                                    Button(link.status == .accepted ? "근거 연결 해제" : "거절") { model.decide(linkId: link.id, status: .rejected) }
                                    Button("나중에") { model.decide(linkId: link.id, status: .deferred) }
                                }
                            }
                        }
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            }
        }.padding(WorkLogTheme.contentInset).frame(minWidth: 540, minHeight: 440)
        .interactiveDismissDisabled(hasChanges)
        .background(WorkLogKeyHandler { event in
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard modifiers == .command else { return false }
            if event.keyCode == 13 {
                if !event.isARepeat { requestClose() }
                return true
            }
            if event.keyCode == 14, onSaved != nil {
                if !event.isARepeat { beginEditing() }
                return true
            }
            if isEditing, event.keyCode == 1 || event.keyCode == 36 || event.keyCode == 76 {
                if !event.isARepeat { save() }
                return true
            }
            return false
        })
        .onAppear {
            if initiallyEditing { beginEditing() }
            else if onSaved != nil { editButtonFocused = true }
        }
        .confirmationDialog("선택한 업무의 보고서 근거로 연결할까요?", isPresented: Binding(
            get: { pendingTask != nil }, set: { if !$0 { pendingTask = nil } })) {
            Button("근거 연결 승인") {
                if let task = pendingTask { model.connect(taskId: task.id) }
                pendingTask = nil; taskQuery = ""
            }
            Button("취소", role: .cancel) { pendingTask = nil }
        } message: { Text(pendingTask?.title ?? "") }
        .alert("\(model.recordLabel) 수정을 저장할까요?", isPresented: $showsUnsavedChanges) {
            Button("저장하고 닫기") { if save() { onClose() } }.keyboardShortcut(.defaultAction)
            Button("수정 버리고 닫기", role: .destructive) { onClose() }
                .keyboardShortcut("d", modifiers: .command)
            Button("계속 편집", role: .cancel) { editorFocused = true }
        } message: {
            Text("저장하지 않은 수정이 있습니다. 기존 원문은 저장하기 전까지 유지됩니다.")
        }
    }

    private func beginEditing() {
        guard !worklogHasMarkedText, onSaved != nil, let memo = model.memo else { return }
        if !isEditing {
            draft = memo.body; originalBody = memo.body; draftDate = memo.workDate
            draftProjects = Set(memo.projectIds)
            draftTags = model.tags.filter { memo.tagIds.contains($0.id) }.map(\.name).joined(separator: ", ")
            originalTags = draftTags; editingRevision = memo.revision; saveError = nil
        }
        isEditing = true
        editorFocused = true
    }

    @discardableResult private func save() -> Bool {
        guard !worklogHasMarkedText, let onSaved, isEditing else { return false }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            saveError = "메모 내용을 입력하세요."; editorFocused = true; return false
        }
        do {
            if hasChanges {
                try model.save(body: draft, workDate: draftDate, projectIds: Array(draftProjects),
                    tagNames: draftTags.components(separatedBy: ","), expectedRevision: editingRevision)
                onSaved()
            }
            isEditing = false; saveError = nil
            editButtonFocused = true
            return true
        } catch {
            saveError = "메모를 저장하지 못했습니다. 수정 내용은 유지됩니다. 다시 저장하세요."
            editorFocused = true
            return false
        }
    }

    private func requestClose() {
        guard !worklogHasMarkedText else { return }
        if hasChanges { showsUnsavedChanges = true }
        else { onClose() }
    }
    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.calendar = model.workCalendar.calendar
        formatter.timeZone = model.workCalendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm z"
        return formatter.string(from: date)
    }
    private func label(_ status: MemoTaskLinkStatus) -> String {
        switch status { case .proposed: return "검토 대기"; case .accepted: return "연결 승인"; case .rejected: return "연결 거절"; case .deferred: return "나중에 검토" }
    }
}
#endif
