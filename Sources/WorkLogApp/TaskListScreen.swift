#if os(macOS)
import AppKit
import SwiftUI
import WorkLogCore

@MainActor struct TaskListScreen: View {
    @Environment(\.worklogContentAutofocus) private var contentAutofocus
    @Bindable var model: TaskListModel
    let onOpen: (String) -> Void
    let onCapture: () -> Void
    var detailDismissalRevision: Int = 0
    @State private var selection: String?
    @State private var projectFilter: TaskProjectFilter = .all
    @State private var sortOrder: TaskListSort = .defaultOrder
    @State private var usesHorizontalSearchControls = false
    @FocusState private var listFocused: Bool
    @FocusState private var queryFocused: Bool

    private var results: TaskListResults {
        TaskListResults(rows: model.filteredRows, projectFilter: projectFilter, sortOrder: sortOrder)
    }
    private var projectNames: [String] {
        Set(model.rows.flatMap(\.projectNames)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var isFiltering: Bool { model.isSearching || projectFilter != .all }
    private var visibleRows: [TaskListRow] {
        results.visibleRows(showsClosedRows: isFiltering || model.isClosedExpanded)
    }
    private var searchLayout: AnyLayout {
        usesHorizontalSearchControls
            ? AnyLayout(HStackLayout(spacing: 12))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: "업무", purpose: "") {
                Button(action: onCapture) { ShortcutLabel(title: "새 업무", keys: "⌘N") }
                    .worklogKeyboardActivation(onCapture)
                    .worklogHelp("새 업무 기록하기", keys: "⌘N")
                    .accessibilityIdentifier("task-list-new-task")
            }
            // Keep one search field and focus binding as the window changes size.
            searchLayout {
                queryField.frame(minWidth: 220)
                filterControls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: Bool.self) { $0.size.width >= 700 } action: { usesHorizontalSearchControls = $0 }
            if let error = model.errorMessage {
                RecoveryNotice(failed: error, preserved: "저장된 업무와 검색어는 그대로입니다.", retry: { model.load() })
            } else if model.rows.isEmpty {
                StateView(kind: .empty, title: "첫 업무를 기록하세요", detail: "빠른 입력의 Task 유형에서 업무를 등록할 수 있습니다.",
                    actionTitle: "새 업무 ⌘N", action: onCapture)
            } else if results.rows.isEmpty {
                StateView(kind: .noResults, title: "일치하는 업무가 없습니다", detail: "검색어 또는 프로젝트 필터를 확인하세요.",
                    actionTitle: "검색·필터 초기화", action: clearFilters)
            } else {
                ScrollViewReader { proxy in
                    List(selection: $selection) {
                        if !results.openRows.isEmpty {
                            Section("현재 업무 \(results.openRows.count)개") {
                                ForEach(results.openRows) { row in selectableTaskRow(row) }
                            }
                        } else if !isFiltering {
                            Text("현재 진행할 업무가 없습니다.")
                                .foregroundStyle(.secondary)
                        }
                        if !results.closedRows.isEmpty {
                            if isFiltering {
                                Section("완료·취소 \(results.closedRows.count)개") {
                                    ForEach(results.closedRows) { row in selectableTaskRow(row) }
                                }
                            } else {
                                DisclosureGroup(isExpanded: $model.isClosedExpanded) {
                                    ForEach(results.closedRows) { row in selectableTaskRow(row) }
                                } label: {
                                    Text("완료·취소 \(results.closedRows.count)개")
                                }
                                .help("완료·취소한 업무 기록 보기 · 목록에서 ← 접기 / → 펼치기")
                            }
                        }
                    }
                    .listStyle(.inset)
                    .focused($listFocused)
                    .accessibilityLabel("업무 목록")
                    .onKeyPress(keys: [.leftArrow, .rightArrow, .return], phases: [.down, .repeat]) { press in
                        guard listFocused, press.modifiers.isEmpty,
                              (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return .ignored }
                        if press.key == .leftArrow || press.key == .rightArrow {
                            guard !isFiltering, !results.closedRows.isEmpty else { return .ignored }
                            model.isClosedExpanded = press.key == .rightArrow
                        } else if press.key == .return {
                            if press.phase == .down, let selection { onOpen(selection) }
                        }
                        return .handled
                    }
                    .onChange(of: listFocused) { _, focused in
                        if focused && selection == nil { selection = visibleRows.first?.id }
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
            DispatchQueue.main.async {
                if contentAutofocus { focusContent() }
            }
        }
        .onChange(of: visibleRows.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = listFocused ? ids.first : nil }
            else if selection == nil && listFocused { selection = ids.first }
        }
    }

    private var queryField: some View {
        TextField("업무 이름으로 찾기", text: $model.query)
            .textFieldStyle(.roundedBorder).accessibilityLabel("업무 이름 검색")
            .accessibilityIdentifier("task-list-query")
            .focused($queryFocused)
            .worklogHelp("업무 이름으로 찾기 · ↓ 목록으로 이동 · Return 열기", keys: "⌘⌥F")
    }

    private var filterControls: some View {
        HStack(spacing: 12) {
            Picker("프로젝트", selection: $projectFilter) {
                Text("전체").tag(TaskProjectFilter.all)
                Text("프로젝트 없음").tag(TaskProjectFilter.unassigned)
                ForEach(projectNames, id: \.self) { name in
                    Text(name).tag(TaskProjectFilter.project(name))
                }
            }
            .pickerStyle(.menu)
            .lineLimit(1)
            .frame(minWidth: 140, maxWidth: 220)
            .accessibilityLabel("프로젝트 필터")
            .accessibilityIdentifier("task-list-project-filter")
            .help("선택한 프로젝트에 연결된 업무만 표시합니다")

            Picker("정렬", selection: $sortOrder) {
                ForEach(TaskListSort.allCases, id: \.self) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 140, maxWidth: 180)
            .accessibilityLabel("업무 정렬")
            .accessibilityIdentifier("task-list-sort")
            .help("현재 업무와 완료·취소 그룹 안에서 정렬합니다")

            Text("\(results.rows.count)개").font(.callout).foregroundStyle(WorkLogTheme.muted)
                .monospacedDigit().fixedSize()
                .accessibilityLabel("조건에 맞는 업무 \(results.rows.count)개")
                .accessibilityIdentifier("task-list-result-count")
        }
    }

    private func clearFilters() {
        model.query = ""
        projectFilter = .all
        listFocused = false
        queryFocused = true
    }

    private func focusContent() {
        if visibleRows.isEmpty {
            listFocused = false
            queryFocused = true
        } else { focusList() }
    }

    private func focusList() {
        guard !visibleRows.isEmpty else { return }
        if !visibleRows.contains(where: { $0.id == selection }) {
            selection = visibleRows.first?.id
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
        guard queryFocused, modifiers.isEmpty, !results.rows.isEmpty,
              (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return false }
        switch event.keyCode {
        case 125: // Down leaves the single-line search field and enters the results.
            if visibleRows.isEmpty { model.isClosedExpanded = true }
            focusList()
            return true
        case 36, 76:
            guard !event.isARepeat else { return true }
            if visibleRows.isEmpty { model.isClosedExpanded = true }
            focusList()
            if let selection { onOpen(selection) }
            return true
        default: return false
        }
    }

    private func selectableTaskRow(_ row: TaskListRow) -> some View {
        taskRow(row)
            .tag(row.id)
            .id(row.id)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen(row.id) })
            .accessibilityLabel(Text(rowLabel(row)))
            .accessibilityHint("Return 또는 더블클릭으로 업무 상세 열기")
            .accessibilityAction(named: Text("업무 상세 열기")) { onOpen(row.id) }
    }

    private func taskRow(_ row: TaskListRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            statusBadge(row.status)
                .frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                Text(row.title).font(.body.weight(selection == row.id ? .semibold : .medium))
                    .fixedSize(horizontal: false, vertical: true).help(row.title)
                if !row.projectNames.isEmpty || row.dueLabel != nil || row.isInThisWeekPlan {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { metadata(row) }
                        VStack(alignment: .leading, spacing: 4) { metadata(row) }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(minHeight: WorkLogTheme.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Return으로 업무 상세 열기")
    }

    private func statusBadge(_ status: TaskStatus?) -> some View {
        Group {
            if let status { TaskStatusBadge(status: status) }
            else { StatusBadge(label: "상태 없음", systemImage: "questionmark.circle", tone: .neutral) }
        }
        // Keep the shared badge's semantic colors legible on the blue List selection.
        .background(WorkLogTheme.surface, in: Capsule())
        .accessibilityHidden(true) // The combined row label includes the status once.
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
                .foregroundStyle(row.isOverdue ? .primary : .secondary)
                .fixedSize()
                .help(row.isOverdue ? "마감이 지난 업무 · \(due)" : "마감 · \(due)")
        }
        if row.isInThisWeekPlan {
            Label("이번 주 계획", systemImage: "calendar.badge.clock").fixedSize()
        }
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

private enum TaskProjectFilter: Hashable {
    case all, unassigned, project(String)

    func includes(_ row: TaskListRow) -> Bool {
        switch self {
        case .all: return true
        case .unassigned: return row.projectNames.isEmpty
        case .project(let name): return row.projectNames.contains(name)
        }
    }
}

private enum TaskListSort: String, CaseIterable {
    case defaultOrder = "기본 순서"
    case dueDate = "마감일 빠른 순"
    case title = "이름순"
    case status = "상태순"

    func sortedRows(_ rows: [TaskListRow]) -> [TaskListRow] {
        guard self != .defaultOrder else { return rows }
        return rows.enumerated().sorted { lhs, rhs in
            let a = lhs.element, b = rhs.element
            switch self {
            case .defaultOrder: break
            case .dueDate:
                switch (a.dueOn, b.dueOn) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            case .title:
                let comparison = a.title.localizedStandardCompare(b.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case .status:
                let aRank = Self.statusRank(a.status), bRank = Self.statusRank(b.status)
                if aRank != bRank { return aRank < bRank }
            }
            // Equal keys retain the model's deterministic default order.
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func statusRank(_ status: TaskStatus?) -> Int {
        switch status {
        case .inProgress: return 0
        case .planned: return 1
        case .onHold: return 2
        case nil: return 3
        case .completed: return 4
        case .cancelled: return 5
        }
    }
}

private struct TaskListResults {
    let rows: [TaskListRow]

    init(rows: [TaskListRow], projectFilter: TaskProjectFilter, sortOrder: TaskListSort) {
        self.rows = sortOrder.sortedRows(rows.filter { projectFilter.includes($0) })
    }

    var openRows: [TaskListRow] { rows.filter { !Self.isClosed($0.status) } }
    var closedRows: [TaskListRow] { rows.filter { Self.isClosed($0.status) } }

    func visibleRows(showsClosedRows: Bool) -> [TaskListRow] {
        openRows + (showsClosedRows ? closedRows : [])
    }

    private static func isClosed(_ status: TaskStatus?) -> Bool {
        status == .completed || status == .cancelled
    }
}
#endif
