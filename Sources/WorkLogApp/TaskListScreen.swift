#if os(macOS)
import AppKit
import SwiftUI
import WorkLogCore

@MainActor struct TaskListScreen: View {
    @Bindable var model: TaskListModel
    let onOpen: (String) -> Void
    let onCapture: () -> Void
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: "업무", purpose: "") {
                Button(action: onCapture) { ShortcutLabel(title: "업무 기록 추가", keys: "⌘N") }
            }
            HStack(spacing: 12) {
                TextField("업무 이름으로 찾기", text: $model.query)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("업무 이름 검색")
                Text("\(model.filteredRows.count)개").font(.callout).foregroundStyle(WorkLogTheme.muted)
                    .monospacedDigit().fixedSize()
            }
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
                        guard press.modifiers.isEmpty,
                              (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return .ignored }
                        guard let selection else { return .ignored }
                        onOpen(selection)
                        return .handled
                    }
                    .onAppear { if let selection { proxy.scrollTo(selection) } }
                }
                HStack(spacing: 12) {
                    Button("선택한 업무 열기") { if let selection { onOpen(selection) } }
                        .disabled(selection == nil).worklogHelp("선택한 업무 상세 열기", keys: "Return")
                    Text("↑↓ 선택 · Return 열기")
                        .font(.callout).foregroundStyle(WorkLogTheme.muted)
                }
            }
        }
        .padding(WorkLogTheme.contentInset)
        .onAppear { model.load() }
        .onChange(of: model.filteredRows.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
    }

    private func taskRow(_ row: TaskListRow) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(row.title).font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                if !row.projectNames.isEmpty || row.dueLabel != nil || row.isInThisWeekPlan {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { metadata(row) }
                        VStack(alignment: .leading, spacing: 4) { metadata(row) }
                    }
                    .font(.callout).foregroundStyle(WorkLogTheme.muted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(row.status?.koreanLabel ?? "상태 없음")
                .font(.callout.weight(.medium))
                .foregroundStyle(row.status == .inProgress ? WorkLogTheme.accent : WorkLogTheme.muted)
                .frame(width: 56, alignment: .trailing)
                .accessibilityLabel("Task 전체 상태: \(row.status?.koreanLabel ?? "상태 없음")")
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Return으로 업무 상세 열기")
    }

    @ViewBuilder private func metadata(_ row: TaskListRow) -> some View {
        if !row.projectNames.isEmpty {
            Text(projectLabel(row.projectNames))
                .lineLimit(1)
                .help(row.projectNames.joined(separator: " · "))
                .accessibilityLabel(Text("프로젝트: " + row.projectNames.joined(separator: ", ")))
        }
        if let due = row.dueLabel {
            Label(due, systemImage: row.isOverdue ? "exclamationmark.triangle" : "calendar")
                .foregroundStyle(row.isOverdue ? WorkLogTheme.text : WorkLogTheme.muted)
                .fixedSize()
        }
        if row.isInThisWeekPlan {
            Label("이번 주 계획", systemImage: "calendar.badge.clock").fixedSize()
        }
    }

    private func projectLabel(_ names: [String]) -> String {
        var label = names.prefix(2).joined(separator: " · ")
        if names.count > 2 { label += " 외 \(names.count - 2)" }
        return label
    }
}
#endif
