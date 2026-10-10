#if os(macOS)
import SwiftUI
import WorkLogCore

@MainActor struct DayScreen: View {
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
                    Picker("표시 영역", selection: $selectedRegion) {
                        Text("활동 기록 \(box.timeline.count)").tag("timeline")
                        Text("업무 상태 \(box.tasks.count)").tag("tasks")
                        Text("메모 \(box.memos.count)").tag("memos")
                    }.pickerStyle(.segmented).frame(maxWidth: 480)
                    switch selectedRegion {
                    case "tasks": taskColumn(box)
                    case "memos": memos(box)
                    default: timeline(box)
                    }
            } else if model.errorMessage == nil {
                StateView(kind: .empty, title: "날짜를 선택하세요", detail: "기록을 불러오면 타임라인·업무·메모를 보여드립니다.")
            }
        }
        .padding(WorkLogTheme.contentInset)
        .background(WorkLogTheme.canvas)
        .onAppear { model.load() }
        .onChange(of: model.selectedDate) { _, _ in
            lastOpened = [:]; timelineScrollID = nil; taskScrollID = nil; memoScrollID = nil
            model.load()
        }
        .onChange(of: model.includeHeldAndCancelled) { _, _ in model.load() }
    }

    private var dateControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { dateNavigation; Spacer(minLength: 12); captureButton }
            VStack(alignment: .leading, spacing: 8) { dateNavigation; captureButton }
        }
    }

    private var captureButton: some View {
        Button(action: onCapture) { Label("기록 추가", systemImage: "square.and.pencil") }
            .buttonStyle(WorkLogButtonStyle(prominent: true))
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
                            timelineRow(entry).padding(.vertical, 12).id(entry.id)
                            Divider()
                        }
                    }.scrollTargetLayout().frame(maxWidth: 1120, alignment: .leading).padding(.trailing, 8)
                }
                .scrollPosition(id: $timelineScrollID)
                .onAppear { if let id = lastOpened["timeline"] { proxy.scrollTo(id) } }
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
                        lastOpened["timeline"] = entry.id
                        onTask(id)
                    } label: { Text(entry.title).font(.body.weight(.medium)).multilineTextAlignment(.leading) }
                    .buttonStyle(.plain).accessibilityHint("업무 상세 열기")
                } else if entry.kind == .memo, entry.id.hasPrefix("memo:") {
                    Button {
                        lastOpened["timeline"] = entry.id
                        onMemo(String(entry.id.dropFirst(5)))
                    } label: { Text(entry.title).font(.body.weight(.medium)).multilineTextAlignment(.leading) }
                    .buttonStyle(.plain).accessibilityHint("메모 상세 열기")
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
                                    Label(row.status.koreanLabel, systemImage: row.status.badgeSymbol)
                                        .font(.callout).foregroundStyle(row.status.badgeTone.color).fixedSize()
                                }
                                .multilineTextAlignment(.leading).padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(row.id).accessibilityHint("업무 상세 열기")
                            Divider()
                        }
                    }.scrollTargetLayout().frame(maxWidth: 1120, alignment: .leading).padding(.trailing, 8)
                }
                .scrollPosition(id: $taskScrollID)
                .onAppear { if let id = lastOpened["tasks"] { proxy.scrollTo(id) } }
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
                                    lastOpened["memos"] = memo.id
                                    onMemo(memo.id)
                                } label: { Label("원문 열기 · 업무 연결", systemImage: "arrow.up.right") }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12).id(memo.id)
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
                .scrollPosition(id: $memoScrollID)
                .onAppear { if let id = lastOpened["memos"] { proxy.scrollTo(id) } }
                .onChange(of: detailDismissalRevision) { _, _ in
                    if let id = lastOpened["memos"] { proxy.scrollTo(id) }
                }
            }
        }
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
