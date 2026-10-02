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
    @State private var filtersExpanded = false
    @State private var hoveredResult: SearchHit?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            queryField
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        filterControls
                        resultsHeader
                        if let error = model.errorMessage { InlineNotice(message: error) }
                        if let message = model.aiMessage {
                            Label(message, systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(WorkLogTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !model.tagIds.isEmpty {
                            Text("태그 필터는 원문 검색에만 적용됩니다.")
                                .font(.caption).foregroundStyle(WorkLogTheme.muted)
                        }
                        if model.isSearching { ProgressView("원문 검색 중…") }
                        if model.hits.isEmpty && !model.isSearching {
                            emptyResults
                        }
                        ForEach(model.hits, id: \.self) { hit in
                            resultRow(hit)
                        }
                        if let answer = model.answer {
                            answerView(answer).id("ai-answer")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(1)
                }
                .onChange(of: model.isAskingAI) { _, isAsking in
                    if !isAsking, model.answer != nil {
                        proxy.scrollTo("ai-answer", anchor: .top)
                    }
                }
            }
        }
        .padding(WorkLogTheme.contentInset)
        .background(WorkLogTheme.canvas)
        .tint(WorkLogTheme.accent)
        .navigationTitle("검색")
        .onAppear {
            focused = true
            let today = environment.calendar.workDate(of: environment.options.clock.now())
            filterStart = model.range?.start ?? today
            filterEnd = model.range.map { environment.calendar.adding(days: -1, to: $0.endExclusive) } ?? today
            useDates = model.range != nil
            filtersExpanded = activeFilterCount > 0
            do { projects = try environment.repo.projects(); tags = try environment.repo.tags() }
            catch { filterError = "필터 후보를 불러오지 못했습니다." }
            model.search()
        }
        .task(id: model.text) {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard !Task.isCancelled else { return }
            model.search()
        }
        .sheet(isPresented: Binding(get: { source != nil }, set: { if !$0 { source = nil } })) {
            SourceRecordSheet(bodyText: sourceBody, error: sourceError, snippet: source?.snippet ?? "",
                sourceTitle: source.map { sourceLabel($0.sourceType) } ?? "기록",
                workDate: source?.workDate, onClose: { source = nil })
        }
    }

    private var queryField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(focused ? WorkLogTheme.accent : WorkLogTheme.muted)
            TextField("기록을 찾거나, 업무에 대해 질문하세요", text: $model.text)
                .font(.system(size: 15))
                .textFieldStyle(.plain)
                .focused($focused)
                .accessibilityLabel("원문 검색 또는 AI 질문")
                .onSubmit { model.search() }
            if !model.text.isEmpty {
                Button {
                    model.text = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(WorkLogTheme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("검색어 지우기")
                .help("검색어 지우기")
            }
            Keycap("↵")
                .accessibilityHidden(true)
        }
        .padding(12)
        .background(WorkLogTheme.surface, in: RoundedRectangle(cornerRadius: WorkLogTheme.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: WorkLogTheme.cornerRadius)
                .strokeBorder(focused ? WorkLogTheme.accent.opacity(0.6) : WorkLogTheme.border, lineWidth: 1)
        }
    }

    private var filterControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button { filtersExpanded.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "slider.horizontal.3")
                        Text("검색 필터")
                        if activeFilterCount > 0 {
                            Text(activeFilterCount.formatted())
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(WorkLogTheme.accentSoft, in: Capsule())
                        }
                        Image(systemName: filtersExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.caption)
                    .foregroundStyle(activeFilterCount > 0 ? WorkLogTheme.accent : WorkLogTheme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityValue(filtersExpanded ? "펼쳐짐" : "접힘")
                if activeFilterCount > 0 {
                    Button("초기화", action: resetFilters)
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(WorkLogTheme.muted)
                }
                Spacer(minLength: 0)
                Label("원문 검색", systemImage: "doc.text.magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(WorkLogTheme.muted)
            }
            if filtersExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Picker("유형", selection: Binding(get: { model.types?.first?.rawValue ?? "all" }, set: {
                            model.types = SearchSourceType(rawValue: $0).map { Set([$0]) }
                            model.search()
                        })) {
                            Text("전체").tag("all")
                            ForEach(SearchSourceType.allCases, id: \.self) { Text(sourceLabel($0)).tag($0.rawValue) }
                        }
                        Picker("프로젝트", selection: Binding(get: { model.projectIds.first ?? "" }, set: {
                            model.projectIds = $0.isEmpty ? [] : [$0]
                            model.search()
                        })) {
                            Text("전체").tag("")
                            ForEach(projects) { Text($0.name).tag($0.id) }
                        }
                        Picker("태그", selection: Binding(get: { model.tagIds.first ?? "" }, set: {
                            model.tagIds = $0.isEmpty ? [] : [$0]
                            model.search()
                        })) {
                            Text("전체").tag("")
                            ForEach(tags) { Text($0.name).tag($0.id) }
                        }
                    }
                    .controlSize(.small)
                    Toggle("기간 지정", isOn: $useDates)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.caption)
                        .onChange(of: useDates) { _, _ in applyDates() }
                    if useDates, let start = filterStart, let end = filterEnd {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                dateFilters(start: start, end: end)
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                dateFilters(start: start, end: end)
                            }
                        }
                    }
                    if let filterError { InlineNotice(message: filterError) }
                }
                .worklogCard(padding: 14)
            } else if let filterError {
                InlineNotice(message: filterError)
            }
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder private func dateFilters(start: WorkDate, end: WorkDate) -> some View {
        WorkDatePicker(title: "시작일", value: Binding(get: { filterStart ?? start }, set: {
            filterStart = $0; applyDates()
        }), calendar: environment.calendar)
        WorkDatePicker(title: "종료일 포함", value: Binding(get: { filterEnd ?? end }, set: {
            filterEnd = $0; applyDates()
        }), calendar: environment.calendar)
    }

    private var resultsHeader: some View {
        HStack(spacing: 8) {
            Text("검색 결과")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(WorkLogTheme.text)
            Text("\(model.hits.count)건")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(WorkLogTheme.muted)
            Spacer(minLength: 8)
            if model.isAskingAI { ProgressView().controlSize(.small) }
            Button { Task { await model.askAI() } } label: {
                Label("기록 기반 AI 답변", systemImage: "sparkles")
            }
            .buttonStyle(WorkLogButtonStyle())
            .disabled(!model.isAIAvailable || model.isAskingAI || !model.tagIds.isEmpty
                      || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var emptyResults: some View {
        VStack(spacing: 6) {
            Image(systemName: model.text.isEmpty ? "text.magnifyingglass" : "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(WorkLogTheme.accent)
                .frame(width: 64, height: 64)
                .background(WorkLogTheme.accentSoft, in: RoundedRectangle(cornerRadius: 20))
            Text(model.text.isEmpty ? "기록에서 다시 발견하세요" : "일치하는 기록이 없어요")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(WorkLogTheme.text)
                .padding(.top, 10)
            Text(model.text.isEmpty ? "메모, 업무, 진행 기록, 리포트를 한곳에서 찾아보세요."
                 : "다른 검색어로 시도하거나 검색 필터를 넓혀보세요.")
                .font(.callout)
                .foregroundStyle(WorkLogTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
                .padding(.bottom, 10)
            if activeFilterCount > 0 {
                Button("필터 초기화", action: resetFilters)
                    .buttonStyle(WorkLogButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func resultRow(_ hit: SearchHit) -> some View {
        Button { openSource(hit) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: sourceIcon(hit.sourceType))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(WorkLogTheme.accent)
                    .frame(width: 36, height: 36)
                    .background(WorkLogTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Text(sourceLabel(hit.sourceType)).fontWeight(.medium)
                        Text("·")
                        Text(hit.workDate?.iso ?? "날짜 없음").monospacedDigit()
                    }
                    .font(.caption2)
                    .foregroundStyle(WorkLogTheme.muted)
                    Text(hit.snippet)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .foregroundStyle(WorkLogTheme.text)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(WorkLogTheme.muted)
                    .padding(.top, 3)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hoveredResult == hit ? WorkLogTheme.accentSoft : WorkLogTheme.surface,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(hoveredResult == hit ? WorkLogTheme.accent.opacity(0.25) : WorkLogTheme.border, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hoveredResult = $0 ? hit : (hoveredResult == hit ? nil : hoveredResult) }
        .accessibilityHint("저장된 원문 열기")
    }

    private func answerView(_ answer: GroundedAnswer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(WorkLogTheme.accent)
                Text("기록 기반 답변").font(.headline)
            }
            Text(answer.question).font(.callout).foregroundStyle(WorkLogTheme.muted)
            ForEach(Array(answer.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                VStack(alignment: .leading, spacing: 10) {
                    Text(paragraph.text)
                        .font(.system(size: 13))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                    ForEach(paragraph.evidence, id: \.id) { evidence in
                        Button {
                            openSource(SearchHit(sourceType: evidence.sourceType, sourceId: evidence.sourceId,
                                taskId: nil, workDate: evidence.workDate, snippet: evidence.snippet))
                        } label: {
                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: "link")
                                Text("근거: \(evidence.snippet)")
                                    .multilineTextAlignment(.leading)
                            }
                            .font(.caption)
                            .foregroundStyle(WorkLogTheme.accent)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(WorkLogTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            ForEach(Array(answer.missingEvidence.enumerated()), id: \.offset) { _, message in
                InlineNotice(message: message)
            }
            ForEach(Array(answer.warnings.enumerated()), id: \.offset) { _, message in
                InlineNotice(message: message)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .worklogCard(padding: 18)
        .padding(.top, 6)
    }

    private var activeFilterCount: Int {
        (model.types == nil ? 0 : 1) + (model.projectIds.isEmpty ? 0 : 1)
        + (model.tagIds.isEmpty ? 0 : 1) + (model.range == nil ? 0 : 1)
    }

    private func resetFilters() {
        model.types = nil
        model.projectIds = []
        model.tagIds = []
        model.range = nil
        useDates = false
        filterError = nil
        model.search()
    }

    private func applyDates() {
        filterError = nil
        if !useDates { model.range = nil; model.search(); return }
        guard let start = filterStart, let end = filterEnd, start <= end else {
            filterError = "종료일은 시작일보다 빠를 수 없습니다."; return
        }
        model.range = DateRange(start: start, endExclusive: environment.calendar.adding(days: 1, to: end))
        model.search()
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

    private func sourceIcon(_ type: SearchSourceType) -> String {
        switch type {
        case .memo: return "text.alignleft"
        case .task: return "checkmark.circle"
        case .activity: return "bolt"
        case .report: return "doc.text"
        }
    }
}

private struct SourceRecordSheet: View {
    let bodyText: String?
    let error: String?
    let snippet: String
    let sourceTitle: String
    let workDate: WorkDate?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(WorkLogTheme.accent)
                    .frame(width: 44, height: 44)
                    .background(WorkLogTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text("저장된 원문").font(.title3).fontWeight(.semibold)
                    Text("\(sourceTitle) · \(workDate?.iso ?? "날짜 없음")")
                        .font(.caption).foregroundStyle(WorkLogTheme.muted)
                }
                Spacer()
                Button("닫기", action: onClose)
                    .buttonStyle(WorkLogButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            if let error { InlineNotice(message: error) }
            if let bodyText {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if !snippet.isEmpty, let range = bodyText.range(of: snippet) {
                                Text(String(bodyText[..<range.lowerBound]))
                                Text(String(bodyText[range]))
                                    .padding(4)
                                    .background(WorkLogTheme.accentSoft, in: RoundedRectangle(cornerRadius: 4))
                                    .id("match")
                                Text(String(bodyText[range.upperBound...]))
                            } else {
                                Text(bodyText).id("match")
                            }
                        }
                        .font(.system(size: 14))
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                    }
                    .worklogCard(padding: 0)
                    .onAppear { proxy.scrollTo("match", anchor: .top) }
                }
            }
        }
        .padding(WorkLogTheme.contentInset)
        .frame(minWidth: 540, minHeight: 400)
        .background(WorkLogTheme.canvas)
    }
}
#endif
