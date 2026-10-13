#if os(macOS)
import AppKit
import SwiftUI
import WorkLogCore

@MainActor struct TaskListScreen: View {
    @Bindable var model: TaskListModel
    let onOpen: (String) -> Void
    let onCapture: () -> Void
    var detailDismissalRevision: Int = 0
    @State private var selection: String?
    @FocusState private var listFocused: Bool
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: "업무", purpose: "") {
                Button(action: onCapture) { ShortcutLabel(title: "새 업무", keys: "⌘N") }
            }
            HStack(spacing: 12) {
                TextField("업무 이름으로 찾기", text: $model.query)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("업무 이름 검색")
                    .focused($queryFocused)
                    .worklogHelp("업무 이름으로 찾기 · ↓ 목록으로 이동 · Return 열기", keys: "⌘⌥F")
                Text("\(model.filteredRows.count)개").font(.callout).foregroundStyle(WorkLogTheme.muted)
                    .monospacedDigit().fixedSize()
            }
            if let error = model.errorMessage {
                RecoveryNotice(failed: error, preserved: "저장된 업무와 검색어는 그대로입니다.", retry: { model.load() })
            } else if model.rows.isEmpty {
                StateView(kind: .empty, title: "첫 업무를 기록하세요", detail: "빠른 입력의 Task 유형에서 업무를 등록할 수 있습니다.",
                    actionTitle: "새 업무 ⌘N", action: onCapture)
            } else if model.filteredRows.isEmpty {
                StateView(kind: .noResults, title: "일치하는 업무가 없습니다", detail: "업무 이름을 확인하거나 검색어를 지우세요.",
                    actionTitle: "검색어 지우기", action: { model.query = "" })
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if !model.openRows.isEmpty {
                                groupHeading("현재 업무", count: model.openRows.count)
                                ForEach(model.openRows) { row in taskButton(row) }
                            } else if !model.isSearching {
                                Text("현재 진행할 업무가 없습니다.")
                                    .font(.callout).foregroundStyle(WorkLogTheme.muted)
                                    .padding(.horizontal, 8).padding(.vertical, 16)
                            }
                            if !model.closedRows.isEmpty {
                                closedHeading
                                    .padding(.top, model.openRows.isEmpty ? 0 : 16)
                                if model.showsClosedRows {
                                    ForEach(model.closedRows) { row in taskButton(row) }
                                }
                            }
                        }
                        .padding(2)
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($listFocused)
                    .accessibilityLabel("업무 목록")
                    .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return], phases: [.down, .repeat]) { press in
                        guard listFocused, press.modifiers.isEmpty,
                              (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return .ignored }
                        if press.key == .leftArrow || press.key == .rightArrow {
                            guard !model.isSearching, !model.closedRows.isEmpty else { return .ignored }
                            model.isClosedExpanded = press.key == .rightArrow
                        } else if press.key == .return {
                            if press.phase == .down, let selection { onOpen(selection) }
                        } else { moveSelection(press.key == .upArrow ? -1 : 1) }
                        return .handled
                    }
                    .onChange(of: listFocused) { _, focused in
                        if focused && selection == nil { selection = model.visibleRows.first?.id }
                    }
                    .onChange(of: selection) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                    .onAppear { if let selection { proxy.scrollTo(selection) } }
                    .onChange(of: detailDismissalRevision) { _, _ in
                        focusList()
                        if let selection { proxy.scrollTo(selection) }
                    }
                }
                HStack(spacing: 12) {
                    Button("선택한 업무 열기") { if let selection { onOpen(selection) } }
                        .disabled(selection == nil).worklogHelp("선택한 업무 상세 열기", keys: "Return")
                    Text("⌘⌥F 찾기 · ↑↓ 선택 · Return 열기")
                        .font(.callout).foregroundStyle(WorkLogTheme.muted)
                }
            }
        }
        .padding(WorkLogTheme.contentInset)
        .background(WorkLogKeyHandler(handle: handleKey))
        .worklogFocusContent { focusContent() }
        .onAppear {
            model.load()
            DispatchQueue.main.async { focusContent() }
        }
        .onChange(of: model.visibleRows.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = listFocused ? ids.first : nil }
            else if selection == nil && listFocused { selection = ids.first }
        }
    }

    private func focusContent() {
        if model.visibleRows.isEmpty {
            listFocused = false
            queryFocused = true
        } else { focusList() }
    }

    private func focusList() {
        guard !model.visibleRows.isEmpty else { return }
        if !model.visibleRows.contains(where: { $0.id == selection }) {
            selection = model.visibleRows.first?.id
        }
        queryFocused = false
        listFocused = true
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == [.command, .option], event.keyCode == 3 {
            listFocused = false
            queryFocused = true
            return true
        }
        guard queryFocused, modifiers.isEmpty, !model.filteredRows.isEmpty else { return false }
        switch event.keyCode {
        case 125: // Down leaves the single-line search field and enters the results.
            if model.visibleRows.isEmpty { model.isClosedExpanded = true }
            focusList()
            return true
        case 36, 76:
            guard !event.isARepeat else { return true }
            if model.visibleRows.isEmpty { model.isClosedExpanded = true }
            focusList()
            if let selection { onOpen(selection) }
            return true
        default: return false
        }
    }

    private func groupHeading(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.callout.weight(.semibold))
            Text("\(count)").font(.caption).monospacedDigit()
        }
        .foregroundStyle(WorkLogTheme.muted)
        .padding(.horizontal, 8).padding(.vertical, 9)
    }

    @ViewBuilder private var closedHeading: some View {
        if model.isSearching {
            groupHeading("완료·취소", count: model.closedRows.count)
        } else {
            Button {
                model.isClosedExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.isClosedExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).frame(width: 12)
                    Text("완료·취소").font(.callout.weight(.semibold))
                    Text("\(model.closedRows.count)").font(.caption).monospacedDigit()
                    Spacer()
                }
                .foregroundStyle(WorkLogTheme.muted)
                .padding(.horizontal, 8).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("완료·취소 업무 \(model.closedRows.count)개")
            .accessibilityValue(model.isClosedExpanded ? "펼쳐짐" : "접힘")
            .help("완료·취소한 업무 기록 보기 · 목록에서 ← 접기 / → 펼치기")
        }
    }

    private func taskButton(_ row: TaskListRow) -> some View {
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
        let ids = model.visibleRows.map(\.id)
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
