#if os(macOS)
import SwiftUI
import WorkLogCore

struct MeetingManualSummaryView: View {
    @Bindable var model: MeetingsModel
    var body: some View {
        GroupBox("직접 작성하는 회의록") {
            VStack(alignment: .leading, spacing: 12) {
                Text("AI 설정 없이 작성할 수 있습니다. 각 줄은 하나의 항목으로 저장되고 이전 버전은 보존됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.selected?.isSummaryStale == true { Text("원문 변경 · 작성한 내용을 다시 검토해 주세요.").foregroundStyle(.orange) }
                section("요약", text: $model.manualSummary)
                section("결정사항", text: $model.manualDecisions)
                section("할 일", text: $model.manualActions)
                section("확인사항", text: $model.manualQuestions)
                if let conflict = model.conflictingSummary {
                    GroupBox("다른 곳에서 저장한 최신 회의록") {
                        VStack(alignment: .leading) {
                            Text(conflict.content).textSelection(.enabled)
                            Text("입력 중인 초안은 위에 유지됩니다. 확인 후 새 버전으로 저장하면 최신 버전도 이력에 남습니다.").font(.caption)
                            Button("비교 완료 · 내 초안을 새 버전으로 저장") { model.retrySummaryAfterReview() }
                                .disabled(model.hasEdits || model.hasMetadataEdits)
                        }
                    }
                }
                Button("직접 작성한 회의록 저장") { _ = model.save() }.disabled(!model.hasSummaryEdits)
                if let summary = model.selected?.summary, summary.isManual {
                    ForEach(Array(summary.structuredOutput.actionItems.enumerated()), id: \.offset) { index, item in
                        HStack {
                            Text(item.text).textSelection(.enabled)
                            Spacer()
                            Button("업무 연결 검토…") {
                                model.reviewTask(text: item.text, key: "manual-action:\(item.text)")
                            }
                        }
                    }
                }
                if !model.taskLinks.isEmpty {
                    DisclosureGroup("연결한 업무") {
                        ForEach(model.taskLinks) { link in
                            VStack(alignment: .leading) {
                                Button(model.availableTasks.first { $0.id == link.taskID }?.title ?? "연결된 업무") { model.onOpenTask?(link.taskID) }
                                Text(link.localOnly ? "로컬 보호 · 외부 AI 및 보고서 제외" : "회의 근거 연결").font(.caption)
                                if link.meetingRevision != model.selected?.revision { Text("연결 후 원문 변경 · 당시 근거 보존됨").font(.caption).foregroundStyle(.orange) }
                                Text(link.quote).font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                }
                DisclosureGroup("회의록 버전 이력 (\(model.summaryHistory.count))") {
                    ForEach(model.summaryHistory) { summary in
                        DisclosureGroup("v\(summary.version) · \(summary.isManual ? "직접 작성" : summary.isUserEdited ? "AI 생성 후 수정됨" : "AI 생성")") {
                            Text(summary.content).textSelection(.enabled)
                        }
                    }
                }
            }.padding(6)
        }.disabled(model.isSummarizing)
    }
    private func section(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            TextEditor(text: text).frame(minHeight: 64, maxHeight: 120).accessibilityLabel("직접 작성 \(title)")
        }
    }
}

struct MeetingMetadataView: View {
    @Bindable var model: MeetingsModel
    var body: some View {
        DisclosureGroup("프로젝트·태그·참석자·안건") {
            VStack(alignment: .leading, spacing: 10) {
                Text("업무일은 회의 목록의 날짜입니다. 실제 회의 시각은 선택 사항입니다.").font(.caption).foregroundStyle(.secondary)
                Toggle("실제 회의 시각 입력", isOn: Binding(get: { model.metadataDraft.occurredAt != nil }, set: {
                    model.metadataDraft.occurredAt = $0 ? model.selected?.createdAt : nil
                }))
                if model.metadataDraft.occurredAt != nil {
                    DatePicker("실제 회의 시각", selection: Binding(get: { model.metadataDraft.occurredAt ?? model.selected!.createdAt }, set: { model.metadataDraft.occurredAt = $0 }))
                }
                TextField("참석자 (쉼표로 구분, 미지정 가능)", text: Binding(get: { model.metadataDraft.participants.joined(separator: ", ") }, set: {
                    model.metadataDraft.participants = $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                }))
                TextField("안건 (선택)", text: $model.metadataDraft.agenda, axis: .vertical)
                DisclosureGroup("프로젝트") {
                    ForEach(model.projects) { project in
                        Toggle(project.name + (project.archivedAt == nil ? "" : " · 보관됨"), isOn: selected(project.id, projects: true))
                    }
                    ForEach(model.metadataDraft.projectIDs.filter { id in !model.projects.contains { $0.id == id } }, id: \.self) { id in
                        Toggle("사용할 수 없는 프로젝트 (\(id))", isOn: selected(id, projects: true))
                    }
                }
                DisclosureGroup("태그") { ForEach(model.tags) { tag in Toggle(tag.name, isOn: selected(tag.id, projects: false)) } }
            }.padding(6)
        }
    }
    private func selected(_ id: String, projects: Bool) -> Binding<Bool> {
        Binding(get: { (projects ? model.metadataDraft.projectIDs : model.metadataDraft.tagIDs).contains(id) }, set: { enabled in
            var values = projects ? model.metadataDraft.projectIDs : model.metadataDraft.tagIDs
            values.removeAll { $0 == id }; if enabled { values.append(id) }
            if projects { model.metadataDraft.projectIDs = values } else { model.metadataDraft.tagIDs = values }
        })
    }
}

struct MeetingTaskReviewSheet: View {
    @Bindable var model: MeetingsModel
    let review: MeetingTaskReview
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var owner = ""
    @State private var quote: String
    @State private var dueOn: WorkDate?
    @State private var projectIDs: Set<String> = []
    @State private var existingID = ""
    init(model: MeetingsModel, review: MeetingTaskReview) {
        self.model = model; self.review = review; _title = State(initialValue: review.text); _quote = State(initialValue: review.text)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("회의 근거에서 업무 연결 검토").font(.headline)
            DisclosureGroup("선택한 원문") { Text(review.text).textSelection(.enabled) }
            Text("근거로 남길 문장 (선택한 원문의 일부)").font(.caption)
            TextEditor(text: $quote).frame(minHeight: 64, maxHeight: 120).accessibilityLabel("업무 근거 문장")
            Picker("연결 방식", selection: $existingID) {
                Text("새 업무 만들기").tag("")
                ForEach(model.availableTasks) { Text($0.title).tag($0.id) }
            }
            if existingID.isEmpty {
                TextField("업무 제목", text: $title)
                TextField("담당자 (미지정 가능)", text: $owner)
                Toggle("기한 지정", isOn: Binding(get: { dueOn != nil }, set: { dueOn = $0 ? model.workDate : nil }))
                if let due = dueOn { WorkDatePicker(title: "기한", value: Binding(get: { dueOn ?? due }, set: { dueOn = $0 }), calendar: model.calendar) }
                DisclosureGroup("프로젝트") {
                    ForEach(model.projects.filter { $0.archivedAt == nil }) { project in
                        Toggle(project.name, isOn: Binding(get: { projectIDs.contains(project.id) }, set: { if $0 { projectIDs.insert(project.id) } else { projectIDs.remove(project.id) } }))
                    }
                }
            }
            Text("확정 전에는 업무가 바뀌지 않습니다. 기존 업무 연결은 상태·기한을 변경하지 않습니다. 로컬 회의에서 파생한 업무는 외부 AI·제출용 및 성과 리포트에서 제외됩니다.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = model.message { Text(message).foregroundStyle(.orange) }
            HStack {
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("검토한 내용으로 확정") {
                    let source = MeetingTaskReview(meetingID: review.meetingID, revision: review.revision,
                        key: review.key + ":" + quote, text: quote, runID: review.runID, segmentID: review.segmentID)
                    if model.confirmTask(source, title: title, owner: owner, dueOn: dueOn,
                        projectIDs: Array(projectIDs), existingTaskID: existingID.isEmpty ? nil : existingID) { dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(quote.isEmpty || !review.text.contains(quote) || (existingID.isEmpty && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }.padding(20).frame(minWidth: 460, idealWidth: 560)
    }
}
#endif
