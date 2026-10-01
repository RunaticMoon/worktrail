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
        VStack(spacing: 12) {
            HStack {
                Button("이전 날", systemImage: "chevron.left") { model.move(days: -1) }.labelStyle(.iconOnly)
                WorkDatePicker(title: "업무일", value: $model.selectedDate, calendar: calendar)
                    .frame(maxWidth: 260)
                Button("다음 날", systemImage: "chevron.right") { model.move(days: 1) }.labelStyle(.iconOnly)
                Button("오늘") { model.showToday() }
                Spacer()
                Toggle("보류·취소 포함", isOn: $model.includeHeldAndCancelled)
            }.padding(.horizontal, 16)
            if let error = model.errorMessage {
                InlineNotice(message: error).padding(.horizontal)
                Button("다시 불러오기") { model.load() }
            }
            if model.isLoading { ProgressView("기록 불러오는 중…") }
            if let box = model.box {
                Text(box.isPast ? "이 날짜 종료 시점의 상태입니다. 보충 기록은 빠른 입력에서 업무일을 지정하세요." : "선택한 업무일의 기록과 상태입니다.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        timeline(box).frame(minWidth: 240, maxWidth: .infinity)
                        Divider()
                        taskColumn(box).frame(minWidth: 220, maxWidth: .infinity)
                        Divider()
                        memos(box).frame(minWidth: 240, maxWidth: .infinity)
                    }
                    ScrollView { VStack(spacing: 16) {
                        timeline(box).frame(height: 320)
                        taskColumn(box).frame(height: 320)
                        memos(box).frame(height: 400)
                    } }
                }
            } else if model.errorMessage == nil {
                EmptyMessage(title: "하루 기록", detail: "날짜를 선택하면 기록을 불러옵니다.")
            }
            Spacer(minLength: 0)
        }.padding(.top, 16)
            .navigationTitle("하루")
            .onAppear { model.load() }
            .onChange(of: model.selectedDate) { _, _ in model.load() }
            .onChange(of: model.includeHeldAndCancelled) { _, _ in model.load() }
    }
    private func timeline(_ box: DayBox) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("타임라인").font(.headline).padding(.horizontal, 16)
            ScrollView { LazyVStack(alignment: .leading, spacing: 16) {
                if box.timeline.isEmpty { EmptyMessage(title: "이날 기록 없음", detail: "기록을 남기면 이곳에 표시됩니다.") }
                ForEach(box.timeline) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(label(entry)).font(.caption).foregroundStyle(.secondary)
                            if let time = entry.effectiveTime {
                                Text(time, style: .time).font(.caption).environment(\.timeZone, calendar.timeZone)
                            }
                        }
                        if let id = entry.taskId { Button(entry.title) { onTask(id) } }
                        else { Text(entry.title).font(.body) }
                        if let detail = entry.detail { Text(detail).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }
            }.padding(16) }
        }
    }
    private func taskColumn(_ box: DayBox) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("업무").font(.headline).padding(.horizontal, 16)
            ScrollView { LazyVStack(alignment: .leading, spacing: 16) {
                if box.tasks.isEmpty { EmptyMessage(title: "표시할 업무 없음", detail: "예정·진행 업무와 이날 활동한 업무가 표시됩니다.") }
                ForEach(box.tasks) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Button(row.title) { onTask(row.taskId) }
                        Text(row.status.koreanLabel).font(.callout)
                        if row.startedOnDay { Text("이날 시작").font(.caption).foregroundStyle(.secondary) }
                        if row.completedOnDay { Text("이날 완료").font(.caption).foregroundStyle(.secondary) }
                        if let due = row.dueOn { Text("마감 \(due.iso)").font(.caption).foregroundStyle(.secondary) }
                    }
                    Divider()
                }
            }.padding(16) }
        }
    }
    private func memos(_ box: DayBox) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("메모 원문").font(.headline).padding(.horizontal, 16)
            ScrollView { LazyVStack(alignment: .leading, spacing: 16) {
                if box.memos.isEmpty {
                    EmptyMessage(title: "아직 메모가 없습니다", detail: "빠른 입력에서 생각과 확인한 내용을 남기세요.")
                    Button("빠른 입력", action: onCapture)
                }
                ForEach(box.memos) { memo in
                    Text(memo.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button("업무 연결 검토") { onMemo(memo.id) }
                    Divider()
                }
                if let summary = model.aiSummary {
                    Text("하루 AI 정리 · \(summary.state == .confirmed ? "확정" : "초안")").font(.headline)
                    Text(summary.createdAt, style: .date).font(.caption).environment(\.timeZone, calendar.timeZone)
                    Text(summary.createdAt, style: .time).font(.caption).environment(\.timeZone, calendar.timeZone)
                    Text(summary.content).textSelection(.enabled)
                } else { Text("생성된 AI 정리 없음").font(.caption).foregroundStyle(.secondary) }
            }.padding(16) }
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
