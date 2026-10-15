#if os(macOS)
import SwiftUI
import WorkLogCore

@MainActor
struct PlanScreen: View {
    @Bindable var model: PlanModel
    let calendar: WorkCalendar
    var embedded = false
    @State private var taskId = ""
    @State private var editingIds: Set<String> = []
    @State private var candidatesExpanded = true

    var body: some View {
        Group {
            if embedded { content }
            else {
                ScrollView {
                    content.frame(maxWidth: 840, alignment: .leading)
                        .padding(WorkLogTheme.contentInset).frame(maxWidth: .infinity, alignment: .leading)
                }.navigationTitle("이번 주 계획")
            }
        }.onAppear { model.load() }
            .onChange(of: model.weekStart) { _, _ in editingIds = [] }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !embedded {
                Text("이번 주 계획").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                WorkDatePicker(title: "계획 주의 날짜", value: Binding(get: { model.weekStart }, set: { model.selectWeek($0) }), calendar: calendar)
                    .frame(maxWidth: 400)
            }
            ReportRangeLabel(title: "계획 기간", range: model.range)
            Text("확정한 범위만 보고서의 예정에 포함됩니다. 업무 상태는 바뀌지 않습니다.")
                .font(.callout).foregroundStyle(WorkLogTheme.muted).fixedSize(horizontal: false, vertical: true)
            if let error = model.errorMessage {
                RecoveryNotice(failed: error, preserved: "저장한 계획과 실제 업무 상태는 유지됩니다.",
                               retryTitle: "계획 다시 불러오기", retry: { model.load() })
            }
            if model.isLoading {
                StateView(kind: .loading, title: "계획 불러오는 중…", detail: "저장한 계획을 확인합니다.")
            }
            planSection("확정 계획", items: model.confirmed)
            Divider()
            DisclosureGroup(isExpanded: $candidatesExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { candidateActions; confirmAction }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) { candidateActions }
                            confirmAction
                        }
                    }
                    planSection("계획 후보", items: model.candidates, showsHeading: false)
                }.padding(.top, 8)
            } label: {
                Text("계획 후보 \(model.candidates.count)개").font(.body.weight(.medium))
            }
            DisclosureGroup("업무 직접 추가") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("보류·취소 업무도 직접 선택할 수 있습니다. 후보 추가만으로 확정되거나 재개되지 않습니다.")
                        .font(.callout).foregroundStyle(WorkLogTheme.muted)
                    Picker("업무", selection: $taskId) {
                        Text("업무 선택").tag("")
                        ForEach(model.tasks) { task in Text(task.title).tag(task.id) }
                    }
                    Button("후보에 추가") { model.addTask(taskId); taskId = "" }.disabled(taskId.isEmpty || model.isLoading)
                        .worklogHelp("선택한 업무 전체를 계획 후보에 추가")
                }.padding(.top, 8)
            }
            if !model.excluded.isEmpty {
                DisclosureGroup("제외한 항목 \(model.excluded.count)개") {
                    ForEach(model.excluded) { item in
                        Label("\(model.title(for: item)) · \(item.label ?? scopeTitle(item))", systemImage: "minus.circle")
                            .foregroundStyle(WorkLogTheme.muted).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    }
                }
            }
        }
    }
    @ViewBuilder private var candidateActions: some View {
        Button("후보 생성") { model.generateCandidates() }.disabled(model.isLoading)
            .worklogHelp("지난주 미완료·이번 주 마감 업무에서 후보 생성")
        Button("다시 불러오기") { model.load() }.disabled(model.isLoading)
            .worklogHelp("저장한 계획과 후보 다시 불러오기")
    }
    private var confirmAction: some View {
        Button("선택한 \(model.checkedIds.count)개 계획 확정") { model.confirmChecked() }
            .buttonStyle(.borderedProminent).disabled(model.checkedIds.isEmpty || model.isLoading)
            .worklogHelp("선택한 후보만 이번 주 계획으로 확정 · 업무 상태는 유지")
    }
    private func planSection(_ title: String, items: [WeekPlanItem], showsHeading: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeading {
                Text("\(title) \(items.count)개").font(.body.weight(.medium)).padding(.bottom, 8)
            }
            if items.isEmpty {
                Text(title == "계획 후보" ? "후보가 없습니다. 후보를 생성하거나 업무를 직접 추가하세요." : "확정 계획이 없습니다. 아래 후보에서 이번 주 범위를 선택하세요.")
                    .font(.callout).foregroundStyle(WorkLogTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            if item.state == .candidate {
                                Toggle(model.title(for: item), isOn: Binding(get: { model.checkedIds.contains(item.id) },
                                    set: { model.check(item.id, selected: $0) }))
                                    .toggleStyle(.checkbox)
                                    .accessibilityHint("후보를 선택한 뒤 계획 확정 버튼을 누르면 보고서의 예정에 포함됩니다.")
                            } else {
                                Label(model.title(for: item), systemImage: "checkmark")
                                    .font(.body.weight(.medium))
                            }
                            if let label = item.label, !label.isEmpty, !editingIds.contains(item.id) {
                                Text(label).font(.body).textSelection(.enabled)
                            }
                            Text(scopeTitle(item) + (item.candidateReason.map { " · \($0)" } ?? ""))
                                .font(.caption).foregroundStyle(WorkLogTheme.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button(editingIds.contains(item.id) ? "편집 접기" : "문구·포함 수정") {
                            if editingIds.contains(item.id) { editingIds.remove(item.id) }
                            else { editingIds.insert(item.id) }
                        }.controlSize(.small)
                            .accessibilityLabel("\(model.title(for: item)) 계획 문구와 포함 여부 수정")
                    }
                    if editingIds.contains(item.id) {
                        TextField("계획 문구 (선택)", text: Binding(get: { model.labels[item.id] ?? "" }, set: { model.labels[item.id] = $0 }), axis: .vertical)
                            .lineLimit(1...4).textFieldStyle(.roundedBorder).accessibilityLabel("\(model.title(for: item)) 계획 문구")
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { itemActions(item) }
                            VStack(alignment: .leading, spacing: 8) { itemActions(item) }
                        }
                    }
                }.padding(.vertical, 8)
                Divider()
            }
        }
    }
    @ViewBuilder private func itemActions(_ item: WeekPlanItem) -> some View {
        Button("문구 저장") { model.saveLabel(item.id) }
            .disabled((model.labels[item.id] ?? "") == (item.label ?? "") || model.isLoading)
            .worklogHelp("이 계획 항목의 문구 저장")
        if item.state == .confirmed {
            Button("확정 해제") { model.unconfirm(item.id) }.worklogHelp("후보로 되돌리기 · 업무 상태는 유지")
        }
        Button("계획에서 제외") { model.exclude(item.id) }.worklogHelp("계획에서만 제외 · 업무는 유지")
    }
    private func scopeTitle(_ item: WeekPlanItem) -> String {
        switch item.scopeType {
        case .wholeTask: return "업무 전체"
        case .taskProject: return "프로젝트 적용 범위"
        case .checklistItem: return "체크리스트 항목"
        }
    }
}
#endif
