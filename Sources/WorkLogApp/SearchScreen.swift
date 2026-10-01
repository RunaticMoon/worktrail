#if os(macOS)
import SwiftUI
import WorkLogCore

struct SearchScreen: View {
    @Bindable var model: SearchModel
    let environment: AppEnvironment
    @FocusState private var focused: Bool
    @State private var source: SearchHit?
    @State private var sourceBody: String?
    @State private var sourceError: String?
    @State private var projects: [Project] = []
    @State private var tags: [Tag] = []
    @State private var filterStart: WorkDate?
    @State private var filterEnd: WorkDate?
    @State private var useDates = false
    @State private var filterError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("원문 검색 또는 AI 질문", text: $model.text)
                .textFieldStyle(.roundedBorder).focused($focused).accessibilityLabel("원문 검색 또는 AI 질문")
                .onSubmit { model.search() }
            DisclosureGroup("검색 필터") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Picker("유형", selection: Binding(get: { model.types?.first?.rawValue ?? "all" }, set: {
                            model.types = SearchSourceType(rawValue: $0).map { Set([$0]) }; model.search()
                        })) {
                            Text("전체").tag("all")
                            ForEach(SearchSourceType.allCases, id: \.self) { Text(sourceLabel($0)).tag($0.rawValue) }
                        }
                        Picker("프로젝트", selection: Binding(get: { model.projectIds.first ?? "" }, set: {
                            model.projectIds = $0.isEmpty ? [] : [$0]; model.search()
                        })) {
                            Text("전체").tag("")
                            ForEach(projects) { Text($0.name).tag($0.id) }
                        }
                        Picker("태그", selection: Binding(get: { model.tagIds.first ?? "" }, set: {
                            model.tagIds = $0.isEmpty ? [] : [$0]; model.search()
                        })) {
                            Text("전체").tag("")
                            ForEach(tags) { Text($0.name).tag($0.id) }
                        }
                    }
                    Toggle("기간 지정", isOn: $useDates).onChange(of: useDates) { _, _ in applyDates() }
                    if useDates, let start = filterStart, let end = filterEnd {
                        HStack {
                            WorkDatePicker(title: "시작일", value: Binding(get: { filterStart ?? start }, set: {
                                filterStart = $0; applyDates()
                            }), calendar: environment.calendar)
                            WorkDatePicker(title: "종료일 포함", value: Binding(get: { filterEnd ?? end }, set: {
                                filterEnd = $0; applyDates()
                            }), calendar: environment.calendar)
                        }
                    }
                    if let filterError { InlineNotice(message: filterError) }
                }.padding(.top, 8)
            }
            HStack {
                Text("원문 \(model.hits.count)건").font(.headline)
                Spacer()
                if model.isAskingAI { ProgressView().controlSize(.small) }
                Button("기록 기반 AI 답변") { Task { await model.askAI() } }
                    .disabled(!model.isAIAvailable || model.isAskingAI || !model.tagIds.isEmpty || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = model.errorMessage { InlineNotice(message: error) }
            if let message = model.aiMessage { InlineNotice(message: message) }
            if !model.tagIds.isEmpty { Text("태그 필터는 원문 검색에만 적용됩니다.").font(.caption).foregroundStyle(.secondary) }
            if model.isSearching { ProgressView("원문 검색 중…") }
            ScrollView { LazyVStack(alignment: .leading, spacing: 16) {
                if model.hits.isEmpty {
                    EmptyMessage(title: "검색 결과 없음", detail: "검색어를 바꾸거나 필터를 해제해 보세요.")
                }
                ForEach(model.hits, id: \.self) { hit in
                    Button { openSource(hit) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(sourceLabel(hit.sourceType)) · \(hit.workDate?.iso ?? "날짜 없음")")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(hit.snippet).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).accessibilityHint("저장된 원문 열기")
                    Divider()
                }
                if let answer = model.answer {
                    Text("기록 기반 답변").font(.headline)
                    Text(answer.question).font(.callout).foregroundStyle(.secondary)
                    ForEach(Array(answer.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph.text).textSelection(.enabled)
                        ForEach(paragraph.evidence, id: \.id) { evidence in
                            Button("근거: \(evidence.snippet)") {
                                openSource(SearchHit(sourceType: evidence.sourceType, sourceId: evidence.sourceId,
                                    taskId: nil, workDate: evidence.workDate, snippet: evidence.snippet))
                            }.multilineTextAlignment(.leading)
                        }
                    }
                    ForEach(Array(answer.missingEvidence.enumerated()), id: \.offset) { _, message in InlineNotice(message: message) }
                    ForEach(Array(answer.warnings.enumerated()), id: \.offset) { _, message in InlineNotice(message: message) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(16).navigationTitle("검색")
            .onAppear {
                focused = true
                let today = environment.calendar.workDate(of: environment.options.clock.now())
                filterStart = model.range?.start ?? today
                filterEnd = model.range.map { environment.calendar.adding(days: -1, to: $0.endExclusive) } ?? today
                useDates = model.range != nil
                do { projects = try environment.repo.projects(); tags = try environment.repo.tags() }
                catch { filterError = "필터 후보를 불러오지 못했습니다." }
                model.search()
            }
            .task(id: model.text) {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                guard !Task.isCancelled else { return }; model.search()
            }
            .sheet(isPresented: Binding(get: { source != nil }, set: { if !$0 { source = nil } })) {
                SourceRecordSheet(bodyText: sourceBody, error: sourceError, snippet: source?.snippet ?? "",
                    onClose: { source = nil })
            }
    }
    private func applyDates() {
        filterError = nil
        if !useDates { model.range = nil; model.search(); return }
        guard let start = filterStart, let end = filterEnd, start <= end else {
            filterError = "종료일은 시작일보다 빠를 수 없습니다."; return
        }
        model.range = DateRange(start: start, endExclusive: environment.calendar.adding(days: 1, to: end)); model.search()
    }
    private func openSource(_ hit: SearchHit) {
        source = hit; sourceBody = nil; sourceError = nil
        do {
            switch hit.sourceType {
            case .memo: sourceBody = try environment.repo.memo(id: hit.sourceId)?.body
            case .activity: sourceBody = try environment.repo.activity(id: hit.sourceId)?.body
            case .task:
                let detail = try environment.tasks.detail(taskId: hit.sourceId)
                sourceBody = ([detail.task.title, "상태: \(detail.status?.koreanLabel ?? "상태 없음")"]
                    + detail.checklist.map { $0.item.text } + detail.activities.map { $0.body }).joined(separator: "\n\n")
            case .report: sourceBody = try environment.repo.reportVersion(id: hit.sourceId)?.content
            }
            if sourceBody == nil { sourceError = "원문이 없거나 삭제되었습니다. 검색을 새로고침하세요." }
        } catch { sourceError = "원문을 불러오지 못했습니다. 다시 시도하세요." }
    }
    private func sourceLabel(_ type: SearchSourceType) -> String {
        switch type { case .memo: return "메모"; case .task: return "업무"; case .activity: return "진행 기록"; case .report: return "리포트" }
    }
}

private struct SourceRecordSheet: View {
    let bodyText: String?
    let error: String?
    let snippet: String
    let onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("저장된 원문").font(.title2); Spacer(); Button("닫기", action: onClose).keyboardShortcut(.cancelAction) }
            if let error { InlineNotice(message: error) }
            if let bodyText {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if !snippet.isEmpty, let range = bodyText.range(of: snippet) {
                                Text(String(bodyText[..<range.lowerBound]))
                                Text(String(bodyText[range])).padding(4).background(Color(nsColor: .selectedTextBackgroundColor)).id("match")
                                Text(String(bodyText[range.upperBound...]))
                            } else { Text(bodyText).id("match") }
                        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }.onAppear { proxy.scrollTo("match", anchor: .top) }
                }
            }
        }.padding(20).frame(minWidth: 540, minHeight: 400)
    }
}
#endif
