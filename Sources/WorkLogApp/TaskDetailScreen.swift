#if os(macOS)
import SwiftUI
import WorkLogCore

struct TaskDetailScreen: View {
    @Bindable var model: TaskDetailModel
    let onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.detail?.task.title ?? "업무 상세").font(.title2)
                Spacer()
                Button("닫기", action: onClose).keyboardShortcut(.cancelAction)
            }
            if let error = model.errorMessage { InlineNotice(message: error) }
            if let detail = model.detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("상태: \(detail.status?.koreanLabel ?? "상태 없음")")
                        Text("시작일: \(detail.firstStartedOn?.iso ?? "기록 없음")")
                        if let due = detail.task.dueOn { Text("마감일: \(due.iso)") }
                        ForEach(Array(detail.completionDates.enumerated()), id: \.offset) { _, date in
                            Text("완료 이력: \(date.iso)")
                        }
                        if let date = model.asOf {
                            Text("\(date.iso) 종료 상태 · 읽기 전용").foregroundStyle(.secondary)
                        } else {
                            HStack {
                                if detail.status == .planned { Button("시작") { model.changeStatus(.started) } }
                                if detail.status == .inProgress { Button("보류") { model.changeStatus(.paused) } }
                                if detail.status == .onHold { Button("재개") { model.changeStatus(.resumed) } }
                                if detail.status == .completed { Button("재개") { model.changeStatus(.reopened) } }
                                if detail.status == .cancelled { Button("예정으로") { model.changeStatus(.replanned) } }
                                if detail.status != .completed { Button("전체 완료") { model.complete() } }
                                if detail.status != .cancelled { Button("취소") { model.changeStatus(.cancelled) } }
                            }
                        }
                        if !detail.projects.isEmpty {
                            Text("프로젝트 적용").font(.headline)
                            ForEach(detail.projects, id: \.link.id) { project in
                                HStack {
                                    Text(project.project.name)
                                    Spacer()
                                    Text(project.status?.koreanLabel ?? "공통 연결").foregroundStyle(.secondary)
                                    if project.link.trackingEnabled && model.asOf == nil {
                                        Menu("적용 상태 변경") {
                                            if project.status == .planned {
                                                Button("시작") { model.changeProjectStatus(projectId: project.project.id, kind: .started) }
                                            }
                                            if project.status == .inProgress {
                                                Button("보류") { model.changeProjectStatus(projectId: project.project.id, kind: .paused) }
                                            }
                                            if project.status == .onHold {
                                                Button("재개") { model.changeProjectStatus(projectId: project.project.id, kind: .resumed) }
                                            }
                                            if project.status == .completed {
                                                Button("재개") { model.changeProjectStatus(projectId: project.project.id, kind: .reopened) }
                                            }
                                            if project.status == .cancelled {
                                                Button("예정으로") { model.changeProjectStatus(projectId: project.project.id, kind: .replanned) }
                                            }
                                            if project.status != .completed {
                                                Button("적용 완료") { model.changeProjectStatus(projectId: project.project.id, kind: .completed) }
                                            }
                                            if project.status != .cancelled {
                                                Button("적용 취소") { model.changeProjectStatus(projectId: project.project.id, kind: .cancelled) }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if !detail.checklist.isEmpty {
                            Text("체크리스트").font(.headline)
                            ForEach(detail.checklist, id: \.item.id) { entry in
                                Toggle(entry.item.text, isOn: Binding(get: { entry.done }, set: {
                                    model.setChecklist(itemId: entry.item.id, done: $0)
                                })).disabled(model.asOf != nil)
                            }
                        }
                        if model.asOf == nil {
                            HStack {
                                TextField("새 체크리스트 항목", text: $model.checklistText)
                                Button("항목 추가") { model.addChecklistItem() }
                            }
                            Text("진행 기록 추가").font(.headline)
                            TextEditor(text: $model.activityText).frame(minHeight: 90).accessibilityLabel("진행 내용")
                            Button("진행 기록 저장") { model.addActivity() }
                            Text("오늘의 업무일로 저장됩니다. 다른 날짜는 빠른 입력을 사용하세요.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("진행 기록").font(.headline)
                        if detail.activities.isEmpty { Text("진행 기록 없음").foregroundStyle(.secondary) }
                        ForEach(detail.activities) { activity in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(activity.workDate.iso).font(.caption).foregroundStyle(.secondary)
                                Text(activity.body).textSelection(.enabled)
                            }
                        }
                        if !detail.links.isEmpty {
                            Text("근거 링크").font(.headline)
                            ForEach(detail.links) { link in
                                if let url = URL(string: link.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                                    Link(link.url, destination: url)
                                } else { Text(link.url).textSelection(.enabled) }
                            }
                        }
                        if !detail.violations.isEmpty {
                            InlineNotice(message: "상태 이력에 확인이 필요한 항목이 있습니다.")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else { EmptyMessage(title: "업무를 선택하세요", detail: "업무 목록에서 상세 내용을 열 수 있습니다.") }
        }.padding(WorkLogTheme.contentInset)
            .alert("남은 범위를 확인하세요", isPresented: Binding(get: { model.completionCheck != nil },
                set: { if !$0 { model.cancelCompletion() } })) {
                Button("돌아가기", role: .cancel) { model.cancelCompletion() }
                Button("남은 범위를 유지하고 전체 완료") { model.complete(confirmRemaining: true) }
            } message: {
                Text(completionMessage)
            }
    }
    private var completionMessage: String {
        guard let check = model.completionCheck else { return "" }
        let items = check.remainingChecklist.map(\.text)
        let projects = check.unfinishedProjects.map { item in
            model.detail?.projects.first { $0.project.id == item.projectId }?.project.name ?? "프로젝트"
        }
        return (items + projects).joined(separator: "\n") + "\n이 항목들은 자동 완료되지 않습니다."
    }
}
#endif
