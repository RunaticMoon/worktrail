#if os(macOS)
import SwiftUI
import WorkLogCore

@MainActor struct TaskListScreen: View {
    @Bindable var model: TaskListModel
    let onOpen: (String) -> Void
    let onCapture: () -> Void
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: "업무", purpose: "업무의 현재 상태와 진행 기록") {
                Button(action: onCapture) { ShortcutLabel(title: "업무 기록 추가", keys: "⌘N") }
            }
            TextField("업무 이름으로 찾기", text: $model.query)
                .textFieldStyle(.roundedBorder).accessibilityLabel("업무 이름 검색")
            if let error = model.errorMessage {
                RecoveryNotice(failed: error, preserved: "저장된 업무와 검색어는 그대로입니다.", retry: { model.load() })
            } else if model.rows.isEmpty {
                StateView(kind: .empty, title: "첫 업무를 기록하세요", detail: "빠른 입력의 Task 유형에서 업무를 등록할 수 있습니다.",
                    actionTitle: "업무 기록 추가 ⌘N", action: onCapture)
            } else if model.filteredRows.isEmpty {
                StateView(kind: .noResults, title: "일치하는 업무가 없습니다", detail: "업무 이름을 확인하거나 검색어를 지우세요.",
                    actionTitle: "검색어 지우기", action: { model.query = "" })
            } else {
                ScrollViewReader { proxy in
                    List(selection: $selection) {
                        ForEach(model.filteredRows) { row in
                            taskRow(row)
                                .tag(row.id).id(row.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { selection = row.id; onOpen(row.id) }
                        }
                    }
                    .listStyle(.inset)
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        guard press.modifiers.isEmpty else { return .ignored }
                        guard let selection else { return .ignored }
                        onOpen(selection)
                        return .handled
                    }
                    .onAppear { if let selection { proxy.scrollTo(selection) } }
                }
                Button("선택한 업무 상세 열기") { if let selection { onOpen(selection) } }
                    .disabled(selection == nil).worklogHelp("선택한 업무 상세 열기", keys: "Return")
                Text("↑↓ 선택 · Return 또는 더블클릭으로 상세 열기")
                    .font(.callout).foregroundStyle(WorkLogTheme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(WorkLogTheme.contentInset)
        .onAppear { model.load() }
        .onChange(of: model.filteredRows.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
    }

    private func taskRow(_ row: TaskListRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { badges(row) }
                VStack(alignment: .leading, spacing: 8) { badges(row) }
            }
            if !row.projectNames.isEmpty {
                Text(projectLabel(row.projectNames)).font(.callout).foregroundStyle(WorkLogTheme.muted)
                    .help(row.projectNames.joined(separator: " · "))
                    .accessibilityLabel(Text("프로젝트: " + row.projectNames.joined(separator: ", ")))
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Return으로 업무 상세 열기")
    }

    @ViewBuilder private func badges(_ row: TaskListRow) -> some View {
        if let status = row.status { TaskStatusBadge(status: status) }
        else { StatusBadge(label: "상태 없음", systemImage: "questionmark.circle", tone: .neutral) }
        if let due = row.dueLabel {
            StatusBadge(label: due, systemImage: row.isOverdue ? "exclamationmark.triangle" : "calendar",
                        tone: row.isOverdue ? .warning : .neutral)
        }
        if row.isInThisWeekPlan { ChipView(label: "이번 주", systemImage: "calendar.badge.clock") }
    }

    private func projectLabel(_ names: [String]) -> String {
        var label = names.prefix(2).joined(separator: " · ")
        if names.count > 2 { label += " 외 \(names.count - 2)" }
        return label
    }
}
#endif
