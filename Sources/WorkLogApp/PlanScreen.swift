#if os(macOS)
import SwiftUI
import WorkLogCore

struct PlanScreen: View {
    @Bindable var model: PlanModel
    let calendar: WorkCalendar
    var embedded = false
    @State private var taskId = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !embedded {
                    WorkDatePicker(title: "계획 주의 날짜", value: Binding(get: { model.weekStart }, set: { model.selectWeek($0) }), calendar: calendar)
                        .frame(maxWidth: 320)
                }
                ReportRangeLabel(title: "계획 기간", range: model.range)
                Text("계획 확정은 착수·완료가 아님. 확인한 범위만 제출용 보고의 예정에 포함됩니다.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = model.errorMessage { InlineNotice(message: error) }
                if model.isLoading { ProgressView("계획 불러오는 중…") }
                HStack {
                    Button("후보 생성") { model.generateCandidates() }
                    Button("다시 불러오기") { model.load() }
                }
                planSection("후보 확인", items: model.candidates)
                Button("확인한 항목 \(model.checkedIds.count)개 확정") { model.confirmChecked() }
                    .buttonStyle(.borderedProminent).disabled(model.checkedIds.isEmpty)
                planSection("확정 계획", items: model.confirmed)
                DisclosureGroup("업무 직접 추가") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("보류·취소 업무도 직접 선택할 수 있습니다. 추가만으로 확정되거나 재개되지 않습니다.").font(.callout).foregroundStyle(.secondary)
                        Picker("업무", selection: $taskId) {
                            Text("업무 선택").tag("")
                            ForEach(model.tasks) { task in Text(task.title).tag(task.id) }
                        }
                        Button("후보에 추가") { model.addTask(taskId); taskId = "" }.disabled(taskId.isEmpty)
                    }.padding(.top, 8)
                }
                if !model.excluded.isEmpty {
                    DisclosureGroup("제외한 항목 \(model.excluded.count)개") {
                        ForEach(model.excluded) { item in
                            Text("\(model.title(for: item)) — \(item.label ?? scopeTitle(item))").foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                        }
                    }
                }
            }.frame(maxWidth: 840, alignment: .leading).padding(embedded ? 8 : WorkLogTheme.contentInset)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.navigationTitle(embedded ? "리포트" : "계획").onAppear { model.load() }
    }
    private func planSection(_ title: String, items: [WeekPlanItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if items.isEmpty {
                Text(title == "후보 확인" ? "후보가 없습니다. 후보를 생성하거나 업무를 직접 추가하세요." : "확정 계획이 없습니다. 후보를 확인한 뒤 확정하세요.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    if item.state == .candidate {
                        Toggle(model.title(for: item), isOn: Binding(get: { model.checkedIds.contains(item.id) },
                            set: { model.check(item.id, selected: $0) }))
                            .toggleStyle(.checkbox)
                            .accessibilityHint("계획 범위를 확인합니다. 확정 버튼을 누르면 보고의 예정에 포함됩니다.")
                    } else { Label(model.title(for: item), systemImage: "checkmark.circle").font(.body.weight(.medium)) }
                    Text(scopeTitle(item) + (item.candidateReason.map { " · \($0)" } ?? ""))
                        .font(.callout).foregroundStyle(.secondary)
                    TextField("계획 문구", text: Binding(get: { model.labels[item.id] ?? "" }, set: { model.labels[item.id] = $0 }))
                        .textFieldStyle(.roundedBorder).accessibilityLabel("\(model.title(for: item)) 계획 문구")
                    HStack {
                        Button("문구 저장") { model.saveLabel(item.id) }
                            .disabled((model.labels[item.id] ?? "") == (item.label ?? ""))
                        if item.state == .confirmed { Button("확정 해제") { model.unconfirm(item.id) } }
                        Button("계획에서 제외") { model.exclude(item.id) }
                    }
                    Divider()
                }.padding(.vertical, 4)
            }
        }
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
