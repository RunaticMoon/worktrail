#if os(macOS)
import AppKit
import SwiftUI
import WorkLogCore

@MainActor struct TaskListScreen: View {
    @Bindable var model: TaskListModel
    let onOpen: (String) -> Void
    let onCapture: () -> Void
    @State private var selection: String?
    @FocusState private var listFocused: Bool

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
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(model.filteredRows) { row in
                                Button { selection = row.id; listFocused = true } label: { taskRow(row) }
                                    .buttonStyle(WorkLogSourceRowStyle(isSelected: selection == row.id,
                                        isFocused: listFocused && selection == row.id))
                                    .focusable(false)
                                    .id(row.id)
                                    .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen(row.id) })
                                    .accessibilityAddTraits(selection == row.id ? .isSelected : [])
                                    .accessibilityLabel(Text(rowLabel(row)))
                                    .accessibilityHint("Return 또는 더블클릭으로 업무 상세 열기")
                            }
                        }
                        .padding(2)
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($listFocused)
                    .accessibilityLabel("업무 목록")
                    .onKeyPress(keys: [.upArrow, .downArrow, .return], phases: [.down, .repeat]) { press in
                        guard press.modifiers.isEmpty,
                              (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return .ignored }
                        if press.key == .return {
                            if press.phase == .down, let selection { onOpen(selection) }
                        } else { moveSelection(press.key == .upArrow ? -1 : 1) }
                        return .handled
                    }
                    .onChange(of: listFocused) { _, focused in
                        if focused && selection == nil { selection = model.filteredRows.first?.id }
                    }
                    .onChange(of: selection) { _, id in
                        if let id { proxy.scrollTo(id) }
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
            if let selection, !ids.contains(selection) { self.selection = listFocused ? ids.first : nil }
        }
    }

    private func taskRow(_ row: TaskListRow) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(row.title).font(.body.weight(selection == row.id ? .semibold : .medium))
                    .fixedSize(horizontal: false, vertical: true).help(row.title)
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
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(minHeight: WorkLogTheme.rowHeight)
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
                .help(row.isOverdue ? "마감이 지난 업무 · \(due)" : "마감 · \(due)")
        }
        if row.isInThisWeekPlan {
            Label("이번 주 계획", systemImage: "calendar.badge.clock").fixedSize()
        }
    }

    private func moveSelection(_ offset: Int) {
        let ids = model.filteredRows.map(\.id)
        guard !ids.isEmpty else { return }
        if let selection, let index = ids.firstIndex(of: selection) {
            self.selection = ids[min(max(index + offset, 0), ids.count - 1)]
        } else { selection = offset < 0 ? ids.last : ids.first }
    }

    private func rowLabel(_ row: TaskListRow) -> String {
        var parts = [row.title, "전체 상태 \(row.status?.koreanLabel ?? "상태 없음")"]
        if !row.projectNames.isEmpty { parts.append("프로젝트 \(row.projectNames.joined(separator: ", "))") }
        if let due = row.dueLabel { parts.append("\(row.isOverdue ? "마감 지남" : "마감") \(due)") }
        if row.isInThisWeekPlan { parts.append("이번 주 계획") }
        return parts.joined(separator: ", ")
    }

    private func projectLabel(_ names: [String]) -> String {
        var label = names.prefix(2).joined(separator: " · ")
        if names.count > 2 { label += " 외 \(names.count - 2)" }
        return label
    }
}
#endif
