#if os(macOS)
import SwiftUI
import WorkLogCore

struct DayScreen: View {
    @Bindable var model: DayViewModel
    let calendar: WorkCalendar
    let onCapture: () -> Void
    let onMemo: (String) -> Void
    let onTask: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            dateControls
            if let error = model.errorMessage {
                HStack {
                    InlineNotice(message: error)
                    Button("다시 불러오기") { model.load() }
                        .buttonStyle(WorkLogButtonStyle())
                }
            }
            if model.isLoading { ProgressView("기록 불러오는 중…") }
            if let box = model.box {
                HStack(spacing: 7) {
                    Image(systemName: box.isPast ? "clock.arrow.circlepath" : "calendar")
                    Text(box.isPast
                         ? "이 날짜 종료 시점의 상태입니다. 보충 기록은 빠른 입력에서 업무일을 지정하세요."
                         : "선택한 업무일의 기록과 상태입니다.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(WorkLogTheme.muted)
                GeometryReader { geometry in
                    if geometry.size.width >= 850 {
                        HStack(alignment: .top, spacing: 12) {
                            timeline(box).frame(maxWidth: .infinity)
                            taskColumn(box).frame(maxWidth: .infinity)
                            memos(box).frame(maxWidth: .infinity)
                        }
                    } else {
                        ScrollView {
                            VStack(spacing: 12) {
                                timeline(box).frame(height: 350)
                                taskColumn(box).frame(height: 350)
                                memos(box).frame(height: 420)
                            }
                        }
                    }
                }
            } else if model.errorMessage == nil {
                EmptyMessage(title: "하루 기록", detail: "날짜를 선택하면 기록을 불러옵니다.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .worklogCard()
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(WorkLogTheme.canvas)
        .navigationTitle("하루")
        .onAppear { model.load() }
        .onChange(of: model.selectedDate) { _, _ in model.load() }
        .onChange(of: model.includeHeldAndCancelled) { _, _ in model.load() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("하루의 흐름")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(WorkLogTheme.text)
                Text("작은 기록이 모여, 선명한 하루가 됩니다.")
                    .font(.caption)
                    .foregroundStyle(WorkLogTheme.muted)
            }
            Spacer(minLength: 12)
            Button(action: onCapture) {
                Label("기록 남기기", systemImage: "plus")
            }
            .buttonStyle(WorkLogButtonStyle(prominent: true))
        }
    }

    private var dateControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                dateNavigation
                Spacer(minLength: 12)
                Toggle("보류·취소 포함", isOn: $model.includeHeldAndCancelled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.caption)
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                dateNavigation
                Toggle("보류·취소 포함", isOn: $model.includeHeldAndCancelled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.caption)
            }
        }
        .tint(WorkLogTheme.accent)
        .padding(.vertical, 2)
    }

    private var dateNavigation: some View {
        HStack(spacing: 4) {
            Button("이전 날", systemImage: "chevron.left") { model.move(days: -1) }
                .labelStyle(.iconOnly)
                .buttonStyle(WorkLogButtonStyle())
                .help("이전 날")
            WorkDatePicker(title: "업무일", value: $model.selectedDate, calendar: calendar, showsTitle: false)
                .fixedSize()
            Button("다음 날", systemImage: "chevron.right") { model.move(days: 1) }
                .labelStyle(.iconOnly)
                .buttonStyle(WorkLogButtonStyle())
                .help("다음 날")
            Button("오늘") { model.showToday() }
                .buttonStyle(WorkLogButtonStyle())
        }
    }

    private func panelHeader(_ title: String, subtitle: String, icon: String, count: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(WorkLogTheme.accent)
                .frame(width: 20, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(WorkLogTheme.text)
                Text(subtitle).font(.caption).foregroundStyle(WorkLogTheme.muted)
            }
            Spacer(minLength: 4)
            Text(count.formatted())
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(WorkLogTheme.muted)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(WorkLogTheme.elevated, in: Capsule())
                .accessibilityLabel("\(count)개")
        }
        .padding(12)
    }

    private func timeline(_ box: DayBox) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader("타임라인", subtitle: "기록이 쌓인 순서", icon: "clock", count: box.timeline.count)
            Rectangle().fill(WorkLogTheme.border).frame(height: 0.5)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if box.timeline.isEmpty {
                        EmptyMessage(title: "아직 조용한 하루", detail: "메모와 업무의 변화를 남기면 하루의 흐름이 이곳에 쌓입니다.")
                    }
                    ForEach(box.timeline) { entry in
                        timelineRow(entry, isLast: entry.id == box.timeline.last?.id)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: .infinity)
        }
        .worklogCard(padding: 0)
    }

    private func timelineRow(_ entry: TimelineEntry, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 4) {
                Image(systemName: timelineIcon(entry.kind))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WorkLogTheme.accent)
                    .frame(width: 22, height: 22)
                    .background(WorkLogTheme.accentSoft, in: Circle())
                if !isLast {
                    Rectangle().fill(WorkLogTheme.border).frame(width: 1)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(label(entry)).lineLimit(2)
                    Spacer(minLength: 0)
                    if let time = entry.effectiveTime {
                        Text(time, style: .time)
                            .monospacedDigit()
                            .environment(\.timeZone, calendar.timeZone)
                    }
                }
                .font(.caption2)
                .foregroundStyle(WorkLogTheme.muted)
                if let id = entry.taskId {
                    Button { onTask(id) } label: {
                        Text(entry.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(WorkLogTheme.text)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("업무 상세 열기")
                } else {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WorkLogTheme.text)
                }
                if let detail = entry.detail, detail != entry.title, !detail.isEmpty {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(WorkLogTheme.muted)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
            .padding(.bottom, isLast ? 0 : 16)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func taskColumn(_ box: DayBox) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader("업무", subtitle: "선택한 날짜의 상태", icon: "checkmark.circle", count: box.tasks.count)
            Rectangle().fill(WorkLogTheme.border).frame(height: 0.5)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if box.tasks.isEmpty {
                        EmptyMessage(title: "표시할 업무가 없어요", detail: "예정·진행 중인 업무와 이날 활동한 업무를 모아 보여드립니다.")
                    }
                    ForEach(box.tasks) { row in
                        Button { onTask(row.taskId) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .top, spacing: 8) {
                                    Text(row.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(WorkLogTheme.text)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(WorkLogTheme.muted)
                                }
                                HStack(spacing: 5) {
                                    Image(systemName: statusIcon(row.status))
                                    Text(row.status.koreanLabel)
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(row.status == .inProgress ? WorkLogTheme.accent : WorkLogTheme.muted)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(row.status == .inProgress ? WorkLogTheme.accentSoft : WorkLogTheme.surface, in: Capsule())
                                if row.startedOnDay || row.completedOnDay || row.dueOn != nil {
                                    VStack(alignment: .leading, spacing: 5) {
                                        if row.startedOnDay { Label("이날 시작", systemImage: "play.circle") }
                                        if row.completedOnDay { Label("이날 완료", systemImage: "checkmark.circle") }
                                        if let due = row.dueOn { Label("마감 \(due.iso)", systemImage: "calendar") }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(WorkLogTheme.muted)
                                }
                            }
                            .multilineTextAlignment(.leading)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(WorkLogTheme.elevated, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("업무 상세 열기")
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: .infinity)
        }
        .worklogCard(padding: 0)
    }

    private func memos(_ box: DayBox) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader("메모 원문", subtitle: "가공하지 않은 생각과 기록", icon: "text.alignleft", count: box.memos.count)
            Rectangle().fill(WorkLogTheme.border).frame(height: 0.5)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if box.memos.isEmpty {
                        EmptyMessage(title: "생각을 가볍게 남겨보세요", detail: "확인한 내용, 떠오른 생각, 작은 진척까지. 짧은 문장이면 충분합니다.")
                        Button(action: onCapture) { Label("첫 메모 남기기", systemImage: "plus") }
                            .buttonStyle(WorkLogButtonStyle())
                    }
                    ForEach(box.memos) { memo in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(memo.body)
                                .font(.system(size: 13))
                                .lineSpacing(3)
                                .foregroundStyle(WorkLogTheme.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button { onMemo(memo.id) } label: {
                                Label("업무 연결 검토", systemImage: "link")
                                    .font(.caption)
                            }
                            .buttonStyle(WorkLogButtonStyle())
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(WorkLogTheme.elevated, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if let summary = model.aiSummary {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles").foregroundStyle(WorkLogTheme.accent)
                                Text("하루 AI 정리").fontWeight(.semibold)
                                Spacer(minLength: 2)
                                Text(summary.state == .confirmed ? "확정" : "초안")
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(WorkLogTheme.accentSoft, in: Capsule())
                            }
                            .font(.callout)
                            HStack(spacing: 5) {
                                Text(summary.createdAt, style: .date)
                                Text(summary.createdAt, style: .time)
                            }
                            .font(.caption2)
                            .foregroundStyle(WorkLogTheme.muted)
                            .environment(\.timeZone, calendar.timeZone)
                            Text(summary.content)
                                .font(.callout)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(WorkLogTheme.accentSoft.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    } else {
                        Label("생성된 AI 정리 없음", systemImage: "sparkles")
                            .font(.caption2)
                            .foregroundStyle(WorkLogTheme.muted)
                            .padding(.vertical, 4)
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: .infinity)
        }
        .worklogCard(padding: 0)
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

    private func statusIcon(_ status: TaskStatus) -> String {
        switch status {
        case .planned: return "circle.dashed"
        case .inProgress: return "circle.lefthalf.filled"
        case .onHold: return "pause.circle"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
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
