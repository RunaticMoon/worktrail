#if os(macOS)
import AppKit
import SwiftUI
import WorkLogCore

@MainActor struct DayScreen: View {
    @Environment(\.worklogContentAutofocus) private var contentAutofocus
    @Bindable var model: DayViewModel
    let calendar: WorkCalendar
    let onCapture: () -> Void
    let onMemo: (String) -> Void
    let onTask: (String) -> Void
    var projectNames: [String: String] = [:]
    var detailDismissalRevision: Int = 0
    @SceneStorage("worklog.day.region") private var selectedRegion = "timeline"
    @State private var lastOpened: [String: String] = [:]
    @State private var showsSummary = false
    @State private var timelineScrollID: String?
    @State private var taskScrollID: String?
    @State private var memoScrollID: String?
    @State private var selectedRows: [String: String] = [:]
    @FocusState private var focusedRegion: String?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            dateControls
            if let error = model.errorMessage {
                RecoveryNotice(failed: error, preserved: "기존 기록과 선택한 날짜는 그대로입니다.",
                    retry: { model.load() })
            }
            if model.isLoading { ProgressView("기록 불러오는 중…") }
            if let box = model.box {
                if box.isPast {
                    Label("당시 상태 · \(KoreanDateLabel.monthDayWeekday(box.date, calendar: calendar)) 종료 기준", systemImage: "clock.arrow.circlepath")
                        .font(.callout).foregroundStyle(WorkLogTheme.muted)
                }
                    SegmentedFilterBar(title: "표시 영역", selection: $selectedRegion, items: [
                        SegmentedFilterItem(value: "timeline", label: "활동 기록", systemImage: "bolt",
                                            count: box.timeline.count,
                                            accessibilityIdentifier: "day.region.timeline", shortcutHint: "⌘⌥1"),
                        SegmentedFilterItem(value: "tasks", label: "업무 상태", systemImage: "checklist",
                                            count: box.tasks.count,
                                            accessibilityIdentifier: "day.region.tasks", shortcutHint: "⌘⌥2"),
                        SegmentedFilterItem(value: "memos", label: "메모", systemImage: "text.alignleft",
                                            count: box.memos.count,
                                            accessibilityIdentifier: "day.region.memos", shortcutHint: "⌘⌥3")
                    ], reservesShortcutHintSpace: false)
                    .accessibilityIdentifier("day.region.filter")
                    .worklogHelp("활동 기록 ⌘⌥1 · 업무 상태 ⌘⌥2 · 메모 ⌘⌥3 · 다음 영역 ⌃Tab")
                    switch selectedRegion {
                    case "tasks": taskColumn(box)
                    case "memos": memos(box)
                    default: timeline(box)
                    }
                    Text("⌃Tab 영역 전환 · ↑↓ 선택 · Return 열기")
                        .font(.callout).foregroundStyle(WorkLogTheme.muted)
            } else if model.errorMessage == nil {
                StateView(kind: .empty, title: "날짜를 선택하세요", detail: "기록을 불러오면 타임라인·업무·메모를 보여드립니다.")
            }
        }
        .padding(WorkLogTheme.contentInset)
        .background(WorkLogTheme.canvas)
        .background(WorkLogKeyHandler(handle: handleKey))
        .worklogFocusContent { focusSelectedRegion() }
        .onAppear {
            model.load()
            DispatchQueue.main.async {
                if contentAutofocus { focusSelectedRegion() }
            }
        }
        .onChange(of: selectedRegion) { _, _ in
            focusedRegion = nil
            DispatchQueue.main.async { focusSelectedRegion() }
        }
        .onChange(of: model.selectedDate) { _, _ in
            lastOpened = [:]; selectedRows = [:]
            timelineScrollID = nil; taskScrollID = nil; memoScrollID = nil
            model.load()
            ensureSelection(in: selectedRegion)
        }
        .onChange(of: model.includeHeldAndCancelled) { _, _ in model.load() }
        .onChange(of: model.box) { _, _ in
            for region in ["timeline", "tasks", "memos"] { ensureSelection(in: region) }
        }
        .onChange(of: focusedRegion) { _, region in
            if let region { ensureSelection(in: region) }
        }
        .onChange(of: detailDismissalRevision) { _, _ in
            if let id = lastOpened[selectedRegion], rowIDs(in: selectedRegion).contains(id) {
                selectedRows[selectedRegion] = id
            }
            DispatchQueue.main.async { focusSelectedRegion() }
        }
    }

    private var dateControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { dateNavigation; Spacer(minLength: 12); captureButton }
            VStack(alignment: .leading, spacing: 8) { dateNavigation; captureButton }
        }
    }

    private var captureButton: some View {
        Button(action: onCapture) { Label("기록 추가", systemImage: "square.and.pencil") }
            .buttonStyle(.borderedProminent)
            .worklogHelp("기록 추가", keys: "⌘N")
    }

    private var heldToggle: some View {
        Toggle("보류·취소 포함", isOn: $model.includeHeldAndCancelled)
            .toggleStyle(.switch).controlSize(.small).font(.callout)
    }

    private var dateNavigation: some View {
        HStack(spacing: 8) {
            Button("이전 날", systemImage: "chevron.left") { model.move(days: -1) }
                .labelStyle(.iconOnly).accessibilityLabel("이전 날").worklogHelp("이전 날")
            WorkDatePicker(title: "업무일", value: $model.selectedDate, calendar: calendar, showsTitle: false)
            Button("다음 날", systemImage: "chevron.right") { model.move(days: 1) }
                .labelStyle(.iconOnly).accessibilityLabel("다음 날").worklogHelp("다음 날")
            Button("오늘로") { model.showToday() }
        }
    }

    private func timeline(_ box: DayBox) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if box.timeline.isEmpty {
                            StateView(kind: .empty, title: "타임라인 기록이 없습니다", detail: "메모와 업무의 변화를 기록하면 여기에 표시됩니다.",
                                      actionTitle: "기록 추가 ⌘N", action: onCapture)
                        }
                        ForEach(box.timeline) { entry in
                            timelineRow(entry).padding(.vertical, 12).padding(.horizontal, 8)
                                .background(rowBackground(entry.id, region: "timeline"))
                                .overlay(rowOutline(entry.id, region: "timeline"))
                                .contentShape(Rectangle())
                                .onTapGesture { selectRow(entry.id, region: "timeline") }
                                .accessibilityAddTraits(selectedRows["timeline"] == entry.id ? .isSelected : [])
                                .id(entry.id)
                            Divider()
                        }
                    }.scrollTargetLayout().frame(maxWidth: 1120, alignment: .leading).padding(.trailing, 8)
                }
                .focusable().focusEffectDisabled().focused($focusedRegion, equals: "timeline")
                .accessibilityLabel("활동 기록 목록")
                .onKeyPress(keys: [.upArrow, .downArrow, .return], phases: [.down, .repeat]) { press in
                    handleListKey(press, region: "timeline")
                }
                .scrollPosition(id: $timelineScrollID)
                .onChange(of: selectedRows["timeline"]) { _, id in if let id { proxy.scrollTo(id) } }
                .onChange(of: detailDismissalRevision) { _, _ in
                    if let id = lastOpened["timeline"] { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func timelineRow(_ entry: TimelineEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: timelineIcon(entry.kind)).foregroundStyle(WorkLogTheme.muted).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(label(entry))
                    Spacer(minLength: 0)
                    if let time = entry.effectiveTime {
                        Text(time, style: .time).monospacedDigit().environment(\.timeZone, calendar.timeZone)
                    }
                }.font(.callout).foregroundStyle(WorkLogTheme.muted)
                if let id = entry.taskId {
                    Button {
                        selectRow(entry.id, region: "timeline")
                        lastOpened["timeline"] = entry.id
                        onTask(id)
                    } label: { Text(entry.title).font(.body.weight(.medium)).multilineTextAlignment(.leading) }
                    .buttonStyle(.plain).focusable(false).accessibilityHint("업무 상세 열기")
                } else if entry.kind == .memo, entry.id.hasPrefix("memo:") {
                    Button {
                        selectRow(entry.id, region: "timeline")
                        lastOpened["timeline"] = entry.id
                        onMemo(String(entry.id.dropFirst(5)))
                    } label: { Text(entry.title).font(.body.weight(.medium)).multilineTextAlignment(.leading) }
                    .buttonStyle(.plain).focusable(false).accessibilityHint("메모 상세 열기")
                } else { Text(entry.title).font(.body.weight(.medium)) }
                if let detail = entry.detail, detail != entry.title, !detail.isEmpty {
                    Text(detail).font(.body).foregroundStyle(WorkLogTheme.muted).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func taskColumn(_ box: DayBox) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("선택한 날짜의 업무 상태").font(.callout).foregroundStyle(WorkLogTheme.muted); Spacer(); heldToggle }.padding(.bottom, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if box.tasks.isEmpty {
                            StateView(kind: .empty, title: "표시할 업무가 없습니다", detail: "예정·진행 중인 업무와 이날 활동한 업무를 모아 보여드립니다.",
                                      actionTitle: "기록 추가 ⌘N", action: onCapture)
                        }
                        ForEach(box.tasks) { row in
                            Button {
                                selectRow(row.id, region: "tasks")
                                lastOpened["tasks"] = row.id
                                onTask(row.taskId)
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(row.title).font(.body.weight(.medium)).foregroundStyle(WorkLogTheme.text)
                                        if !row.projectIds.isEmpty {
                                            Text(projectSummary(row.projectIds))
                                                .font(.callout).foregroundStyle(WorkLogTheme.muted)
                                                .help(row.projectIds.map { projectNames[$0] ?? "프로젝트" }.joined(separator: " · "))
                                        }
                                        HStack(spacing: 12) {
                                            if row.startedOnDay { Text("이날 시작") }
                                            if row.completedOnDay { Text("이날 완료") }
                                            if let due = row.dueOn { Text("마감 \(KoreanDateLabel.monthDayWeekday(due, calendar: calendar))") }
                                        }.font(.callout).foregroundStyle(WorkLogTheme.muted)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Label {
                                        Text(row.status.koreanLabel).foregroundStyle(WorkLogTheme.text)
                                    } icon: {
                                        Image(systemName: row.status.badgeSymbol)
                                            .foregroundStyle(contrast == .increased ? WorkLogTheme.text : row.status.badgeTone.color)
                                            .accessibilityHidden(true)
                                    }
                                    .font(.callout).fixedSize()
                                }
                                .multilineTextAlignment(.leading).padding(.vertical, 12).padding(.horizontal, 8)
                                .contentShape(Rectangle())
                            }.buttonStyle(WorkLogSourceRowStyle(isSelected: selectedRows["tasks"] == row.id,
                                isFocused: focusedRegion == "tasks" && selectedRows["tasks"] == row.id))
                                .focusable(false).id(row.id).accessibilityHint("Return으로 업무 상세 열기")
                                .accessibilityAddTraits(selectedRows["tasks"] == row.id ? .isSelected : [])
                            Divider()
                        }
                    }.scrollTargetLayout().frame(maxWidth: 1120, alignment: .leading).padding(.trailing, 8)
                }
                .focusable().focusEffectDisabled().focused($focusedRegion, equals: "tasks")
                .accessibilityLabel("하루 업무 목록")
                .onKeyPress(keys: [.upArrow, .downArrow, .return], phases: [.down, .repeat]) { press in
                    handleListKey(press, region: "tasks")
                }
                .scrollPosition(id: $taskScrollID)
                .onChange(of: selectedRows["tasks"]) { _, id in if let id { proxy.scrollTo(id) } }
                .onChange(of: detailDismissalRevision) { _, _ in
                    if let id = lastOpened["tasks"] { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func memos(_ box: DayBox) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if box.memos.isEmpty {
                            StateView(kind: .empty, title: "메모가 없습니다", detail: "확인한 내용이나 떠오른 생각을 남겨보세요.",
                                      actionTitle: "기록 추가 ⌘N", action: onCapture)
                        }
                        ForEach(box.memos) { memo in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(memo.body).font(.body).lineLimit(8).textSelection(.enabled)
                                Button {
                                    selectRow(memo.id, region: "memos")
                                    lastOpened["memos"] = memo.id
                                    onMemo(memo.id)
                                } label: { Label("원문 열기 · 업무 연결", systemImage: "arrow.up.right") }
                                    .focusable(false)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12).padding(.horizontal, 8)
                            .background(rowBackground(memo.id, region: "memos"))
                            .overlay(rowOutline(memo.id, region: "memos"))
                            .contentShape(Rectangle())
                            .onTapGesture { selectRow(memo.id, region: "memos") }
                            .accessibilityAddTraits(selectedRows["memos"] == memo.id ? .isSelected : [])
                            .id(memo.id)
                            Divider()
                        }
                        if let summary = model.aiSummary {
                            DisclosureGroup("하루 AI 정리", isExpanded: $showsSummary) {
                                VStack(alignment: .leading, spacing: 8) {
                                StatusBadge(label: summary.state == .confirmed ? "확정" : "초안", systemImage: "doc.text", tone: .neutral)
                                HStack {
                                    Text(summary.createdAt, style: .date)
                                    Text(summary.createdAt, style: .time)
                                }.font(.callout).foregroundStyle(WorkLogTheme.muted).environment(\.timeZone, calendar.timeZone)
                                Text(summary.content).textSelection(.enabled)
                                }.padding(.top, 8)
                            }.padding(.vertical, 12)
                        }
                    }.scrollTargetLayout().frame(maxWidth: 1120, alignment: .leading).padding(.trailing, 8)
                }
                .focusable().focusEffectDisabled().focused($focusedRegion, equals: "memos")
                .accessibilityLabel("하루 메모 목록")
                .onKeyPress(keys: [.upArrow, .downArrow, .return], phases: [.down, .repeat]) { press in
                    handleListKey(press, region: "memos")
                }
                .scrollPosition(id: $memoScrollID)
                .onChange(of: selectedRows["memos"]) { _, id in if let id { proxy.scrollTo(id) } }
                .onChange(of: detailDismissalRevision) { _, _ in
                    if let id = lastOpened["memos"] { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func rowIDs(in region: String) -> [String] {
        guard let box = model.box else { return [] }
        switch region {
        case "tasks": return box.tasks.map(\.id)
        case "memos": return box.memos.map(\.id)
        default: return box.timeline.map(\.id)
        }
    }

    private func ensureSelection(in region: String) {
        let ids = rowIDs(in: region)
        if let id = selectedRows[region], ids.contains(id) { return }
        selectedRows[region] = ids.first
    }

    private func selectRow(_ id: String, region: String) {
        selectedRows[region] = id
        focusedRegion = region
    }

    private func focusSelectedRegion() {
        ensureSelection(in: selectedRegion)
        focusedRegion = selectedRegion
    }

    private func rowBackground(_ id: String, region: String) -> some View {
        RoundedRectangle(cornerRadius: WorkLogTheme.rowCornerRadius)
            .fill(selectedRows[region] == id ? WorkLogTheme.accentSoft : Color.clear)
    }

    private func rowOutline(_ id: String, region: String) -> some View {
        RoundedRectangle(cornerRadius: WorkLogTheme.rowCornerRadius)
            .strokeBorder(selectedRows[region] == id && (focusedRegion == region || contrast == .increased)
                          ? (contrast == .increased ? WorkLogTheme.text : WorkLogTheme.accent) : Color.clear,
                          lineWidth: 2)
            .allowsHitTesting(false)
    }

    private func handleListKey(_ press: KeyPress, region: String) -> KeyPress.Result {
        guard focusedRegion == region, press.modifiers.isEmpty,
              !(NSApp.keyWindow?.firstResponder is NSTextView),
              (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return .ignored }
        let ids = rowIDs(in: region)
        guard !ids.isEmpty else { return .ignored }
        if press.key == .return {
            if press.phase == .down { openSelectedRow(in: region) }
        } else {
            let offset = press.key == .upArrow ? -1 : 1
            if let id = selectedRows[region], let index = ids.firstIndex(of: id) {
                selectedRows[region] = ids[min(max(index + offset, 0), ids.count - 1)]
            } else { selectedRows[region] = offset < 0 ? ids.last : ids.first }
        }
        return .handled
    }

    private func openSelectedRow(in region: String) {
        guard let id = selectedRows[region], let box = model.box else { return }
        switch region {
        case "tasks":
            guard let row = box.tasks.first(where: { $0.id == id }) else { return }
            lastOpened[region] = id
            onTask(row.taskId)
        case "memos":
            lastOpened[region] = id
            onMemo(id)
        default:
            guard let entry = box.timeline.first(where: { $0.id == id }) else { return }
            if let taskId = entry.taskId {
                lastOpened[region] = id
                onTask(taskId)
            } else if entry.kind == .memo, entry.id.hasPrefix("memo:") {
                lastOpened[region] = id
                onMemo(String(entry.id.dropFirst(5)))
            }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let regions = ["timeline", "tasks", "memos"]
        if modifiers == [.command, .option],
           let index = [UInt16(18), 19, 20].firstIndex(of: event.keyCode) {
            selectedRegion = regions[index]
            focusSelectedRegion()
            return true
        }
        if event.keyCode == 48, modifiers == [.control] || modifiers == [.control, .shift] {
            let index = regions.firstIndex(of: selectedRegion) ?? 0
            let offset = modifiers.contains(.shift) ? -1 : 1
            selectedRegion = regions[(index + offset + regions.count) % regions.count]
            return true
        }
        return false
    }

    private func projectSummary(_ ids: [String]) -> String {
        let names = ids.prefix(2).map { projectNames[$0] ?? "프로젝트" }.joined(separator: " · ")
        return ids.count > 2 ? "\(names) 외 \(ids.count - 2)개" : names
    }

    private func timelineIcon(_ kind: TimelineEntryKind) -> String {
        switch kind {
        case .memo: return "text.alignleft"
        case .activity: return "bolt"
        case .taskCreated: return "plus"
        case .taskStatus: return "arrow.triangle.2.circlepath"
        case .projectStatus: return "folder"
        case .checklistStatus: return "checkmark"
        }
    }

    private func label(_ entry: TimelineEntry) -> String {
        let scope: String
        switch entry.kind {
        case .memo: scope = "메모"
        case .activity: scope = "진행 기록"
        case .taskCreated: scope = "업무 등록"
        case .taskStatus: scope = "업무 상태"
        case .projectStatus: scope = "프로젝트 적용"
        case .checklistStatus: scope = "체크리스트"
        }
        return entry.toStatus.map { "\(scope) · \($0.koreanLabel)" } ?? scope
    }
}
#endif
