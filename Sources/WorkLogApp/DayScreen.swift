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
    /// Measure the destination area, excluding the sidebar, for the 980pt breakpoint.
    var contentWidth: CGFloat? = nil
    var detailDismissalRevision: Int = 0
    @SceneStorage("worklog.day.region") private var selectedRegion = "timeline"
    @State private var lastOpened: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: "오늘", purpose: "선택한 날짜의 기록과 업무 상태") {
                Button(action: onCapture) { ShortcutLabel(title: "기록 추가", keys: "⌘N") }
            }
            dateControls
            if let error = model.errorMessage {
                RecoveryNotice(failed: error, preserved: "기존 기록과 선택한 날짜는 그대로입니다.",
                    retry: { model.load() })
            }
            if model.isLoading { ProgressView("기록 불러오는 중…") }
            if let box = model.box {
                if box.isPast {
                    AsOfDateBadge(dateLabel: KoreanDateLabel.monthDayWeekday(box.date, calendar: calendar))
                    Text("이 화면의 업무 상태는 그날 종료 시점 기준입니다. 현재 상태는 업무 화면에서 관리합니다.")
                        .font(.callout).foregroundStyle(WorkLogTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if box.timeline.isEmpty && box.tasks.isEmpty && box.memos.isEmpty && model.aiSummary == nil {
                    StateView(kind: .empty, title: "이 날짜의 기록이 없습니다", detail: "빠른 입력에서 선택한 날짜의 기록을 추가하세요.",
                        actionTitle: "기록 추가 ⌘N", action: onCapture)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GeometryReader { geometry in
                        if (contentWidth ?? geometry.size.width) >= 980 {
                            HStack(alignment: .top, spacing: 12) {
                                timeline(box).frame(maxWidth: .infinity)
                                taskColumn(box).frame(maxWidth: .infinity)
                                memos(box).frame(maxWidth: .infinity)
                            }
                        } else {
                            VStack(spacing: 12) {
                                Picker("표시 영역", selection: $selectedRegion) {
                                    Text("타임라인 \(box.timeline.count)").tag("timeline")
                                    Text("업무 \(box.tasks.count)").tag("tasks")
                                    Text("메모 \(box.memos.count)").tag("memos")
                                }.pickerStyle(.segmented)
                                switch selectedRegion {
                                case "tasks": taskColumn(box)
                                case "memos": memos(box)
                                default: timeline(box)
                                }
                            }
                        }
                    }
                }
            } else if model.errorMessage == nil {
                StateView(kind: .empty, title: "날짜를 선택하세요", detail: "기록을 불러오면 타임라인·업무·메모를 보여드립니다.")
            }
            Spacer(minLength: 0)
        }
        .padding(WorkLogTheme.contentInset)
        .background(WorkLogTheme.canvas)
        .onAppear { model.load() }
        .onChange(of: model.selectedDate) { _, _ in lastOpened = [:]; model.load() }
        .onChange(of: model.includeHeldAndCancelled) { _, _ in model.load() }
    }

    private var dateControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { dateNavigation; Spacer(minLength: 12); heldToggle }
            VStack(alignment: .leading, spacing: 8) { dateNavigation; heldToggle }
        }
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

    private func panelHeader(_ title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).accessibilityHidden(true)
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Text("\(count)개").font(.callout).foregroundStyle(WorkLogTheme.muted)
        }.padding(12)
    }

    private func timeline(_ box: DayBox) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader("타임라인", icon: "clock", count: box.timeline.count)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if box.timeline.isEmpty {
                            StateView(kind: .empty, title: "타임라인 기록이 없습니다", detail: "메모와 업무의 변화를 기록하면 여기에 표시됩니다.",
                                      actionTitle: "기록 추가 ⌘N", action: onCapture)
                        }
                        ForEach(box.timeline) { entry in
                            timelineRow(entry).id(entry.id)
                        }
                    }.padding(12)
                }
                .onAppear { if let id = lastOpened["timeline"] { proxy.scrollTo(id) } }
                .onChange(of: detailDismissalRevision) { _, _ in
                    if let id = lastOpened["timeline"] { proxy.scrollTo(id) }
                }
            }
        }.worklogCard(padding: 0)
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
                    } label: { Text(entry.title).font(.headline).multilineTextAlignment(.leading) }
                    .accessibilityHint("업무 상세 열기")
                } else if entry.kind == .memo, entry.id.hasPrefix("memo:") {
                    Button {
                        lastOpened["timeline"] = entry.id
                        onMemo(String(entry.id.dropFirst(5)))
                    } label: { Text(entry.title).font(.headline).multilineTextAlignment(.leading) }
                    .accessibilityHint("메모 상세 열기")
                } else { Text(entry.title).font(.headline) }
                if let detail = entry.detail, detail != entry.title, !detail.isEmpty {
                    Text(detail).font(.body).foregroundStyle(WorkLogTheme.muted).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func taskColumn(_ box: DayBox) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader("업무", icon: "checkmark.circle", count: box.tasks.count)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if box.tasks.isEmpty {
                            StateView(kind: .empty, title: "표시할 업무가 없습니다", detail: "예정·진행 중인 업무와 이날 활동한 업무를 모아 보여드립니다.",
                                      actionTitle: "기록 추가 ⌘N", action: onCapture)
                        }
                        ForEach(box.tasks) { row in
                            Button {
                                lastOpened["tasks"] = row.id
                                onTask(row.taskId)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(row.title).font(.headline).foregroundStyle(WorkLogTheme.text)
                                    TaskStatusBadge(status: row.status)
                                    if !row.projectIds.isEmpty {
                                        Text(row.projectIds.map { projectNames[$0] ?? "프로젝트" }.joined(separator: " · "))
                                            .font(.callout).foregroundStyle(WorkLogTheme.muted)
                                    }
                                    if row.startedOnDay { Label("이날 시작", systemImage: "play.circle").font(.callout) }
                                    if row.completedOnDay { Label("이날 완료", systemImage: "checkmark.circle").font(.callout) }
                                    if let due = row.dueOn {
                                        Label("마감 \(KoreanDateLabel.monthDayWeekday(due, calendar: calendar))", systemImage: "calendar")
                                            .font(.callout).foregroundStyle(WorkLogTheme.muted)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading).padding(12)
                                .background(WorkLogTheme.elevated, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(WorkLogButtonStyle()).id(row.id).accessibilityHint("업무 상세 열기")
                        }
                    }.padding(12)
                }
                .onAppear { if let id = lastOpened["tasks"] { proxy.scrollTo(id) } }
                .onChange(of: detailDismissalRevision) { _, _ in
                    if let id = lastOpened["tasks"] { proxy.scrollTo(id) }
                }
            }
        }.worklogCard(padding: 0)
    }

    private func memos(_ box: DayBox) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader("메모 정리", icon: "text.alignleft", count: box.memos.count)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if box.memos.isEmpty {
                            StateView(kind: .empty, title: "메모가 없습니다", detail: "확인한 내용이나 떠오른 생각을 남겨보세요.",
                                      actionTitle: "기록 추가 ⌘N", action: onCapture)
                        }
                        ForEach(box.memos) { memo in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(memo.body).font(.body).textSelection(.enabled)
                                Button {
                                    lastOpened["memos"] = memo.id
                                    onMemo(memo.id)
                                } label: { Label("메모 상세·업무 연결", systemImage: "link") }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(WorkLogTheme.elevated, in: RoundedRectangle(cornerRadius: 8)).id(memo.id)
                        }
                        if let summary = model.aiSummary {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("하루 AI 정리").font(.headline)
                                StatusBadge(label: summary.state == .confirmed ? "확정" : "초안", systemImage: "doc.text", tone: .neutral)
                                HStack {
                                    Text(summary.createdAt, style: .date)
                                    Text(summary.createdAt, style: .time)
                                }.font(.callout).foregroundStyle(WorkLogTheme.muted).environment(\.timeZone, calendar.timeZone)
                                Text(summary.content).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading).worklogCard()
                        } else {
                            Label("생성된 AI 정리 없음", systemImage: "sparkles").font(.callout).foregroundStyle(WorkLogTheme.muted)
                        }
                    }.padding(12)
                }
                .onAppear { if let id = lastOpened["memos"] { proxy.scrollTo(id) } }
                .onChange(of: detailDismissalRevision) { _, _ in
                    if let id = lastOpened["memos"] { proxy.scrollTo(id) }
                }
            }
        }.worklogCard(padding: 0)
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
