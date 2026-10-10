#if os(macOS)
import SwiftUI
import AppKit
import WorkLogCore

@MainActor struct SearchScreen: View {
    @Bindable var model: SearchModel
    let environment: AppEnvironment
    var secrets: SecretsModel? = nil
    var onOpenSecrets: (() -> Void)? = nil
    var isPanel: Bool = false
    @State private var scope: SearchScope = .records
    @State private var secretSelection = SearchSecretSelection()
    @FocusState private var focusedResult: SearchHitKey?
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
    @State private var aiExpanded = false
    @State private var sourceOpenedFromQuery = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("검색 범위", selection: $scope) {
                Text(isPanel ? "기록 (⌘1)" : "기록").tag(SearchScope.records)
                Text(isPanel ? "Secret (⌘2)" : "Secret").tag(SearchScope.secret)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .worklogHelp(isPanel ? "검색 범위 · ⌘1 기록 · ⌘2 Secret" : "검색 범위 · Tab으로 포커스한 뒤 화살표로 전환")
            if scope == .records {
                recordSearch
            } else if let secrets {
                SearchSecretScope(model: secrets, selection: $secretSelection, onOpenSecrets: onOpenSecrets)
            } else {
                StateView(kind: .empty, title: "Secret 검색을 연결하지 못했습니다",
                    detail: "검색 패널 또는 Secret 화면에서 제목을 검색하세요.")
            }
        }
        .padding(16)
        .background(WorkLogTheme.canvas)
        .tint(WorkLogTheme.accent)
        .navigationTitle("검색")
        .background(SearchKeyboardBridge(handle: handleKey))
        .onChange(of: scope) { _, _ in focused = scope == .records }
        .sheet(isPresented: Binding(get: { source != nil }, set: { if !$0 { source = nil } }), onDismiss: {
            if sourceOpenedFromQuery { focused = true }
            else { focusedResult = model.selectedKey }
        }) {
            SourceRecordSheet(bodyText: sourceBody, error: sourceError, snippet: source?.snippet ?? "",
                sourceTitle: source.map { sourceLabel($0.sourceType) } ?? "기록",
                workDate: source?.workDate, onClose: { source = nil })
        }
    }

    private var recordSearch: some View {
        VStack(alignment: .leading, spacing: 12) {
            queryField
            filterControls
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if model.errorMessage != nil {
                            RecoveryNotice(failed: "검색하지 못했습니다", preserved: "입력과 필터는 그대로입니다",
                                retryTitle: "다시 검색", retry: { model.search() })
                        }
                        if aiExpanded || model.answer != nil {
                            DisclosureGroup("기록 기반 AI 답변", isExpanded: $aiExpanded) {
                                VStack(alignment: .leading, spacing: 12) {
                                    if model.isAskingAI { ProgressView("답변 생성 중…").controlSize(.small) }
                                    if let message = model.aiMessage {
                                        Text(message).font(.callout).foregroundStyle(WorkLogTheme.muted)
                                    }
                                    if let answer = model.answer { answerView(answer) }
                                }.padding(.vertical, 12)
                            }
                            .padding(.bottom, 12)
                        }
                        if model.isSearching { ProgressView("원문 검색 중…") }
                        if model.hits.isEmpty && !model.isSearching && model.errorMessage == nil {
                            emptyResults
                        }
                        ForEach(model.hits, id: \.key) { hit in resultRow(hit).id(hit.key) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(1)
                }
                .onChange(of: model.selectedKey) { _, key in
                    if let key { proxy.scrollTo(key) }
                }
                .onChange(of: model.hits) { _, _ in
                    if let key = model.selectedKey { proxy.scrollTo(key) }
                }
                .onAppear { if let key = model.selectedKey { proxy.scrollTo(key) } }
            }
            if model.isPreviewVisible, let hit = model.selectedHit {
                Divider()
                ScrollView { preview(hit) }.frame(maxHeight: 140)
            }
        }
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
            guard !Task.isCancelled else { return }
            model.search()
        }
        .onChange(of: focusedResult) { _, key in
            if let hit = model.hits.first(where: { $0.key == key }) { model.select(hit) }
        }
    }

    // Space stays an ordinary space while editing. Option-Space previews from the
    // query; bare Space previews only a focused result. Both leave selection intact.
    private func handleKey(_ event: NSEvent, editingText: Bool) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if isPanel, modifiers == .command, event.keyCode == 18 { scope = .records; return true }
        if isPanel, modifiers == .command, event.keyCode == 19 { scope = .secret; return true }
        guard scope == .records, source == nil else { return false }
        if modifiers == .command, event.keyCode == 3 { focused = true; return true }
        let navigatingResults = focused || focusedResult != nil
        if navigatingResults, modifiers.isEmpty, event.keyCode == 125 || event.keyCode == 126 {
            model.moveSelection(by: event.keyCode == 125 ? 1 : -1)
            if !editingText { focusedResult = model.selectedKey }
            return true
        }
        if event.keyCode == 49,
           (navigatingResults && modifiers == .option && !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || modifiers.isEmpty && !editingText && focusedResult != nil) {
            guard model.selectedHit != nil else { return false }
            model.togglePreview(); return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if modifiers == .command {
                askAI()
                return true
            }
            if navigatingResults, modifiers.isEmpty, let hit = model.selectedHit { openSource(hit); return true }
        }
        return false
    }

    private var queryField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(focused ? WorkLogTheme.accent : WorkLogTheme.muted)
            TextField("메모, 업무, 진행 기록 검색", text: $model.text)
                .font(.body)
                .textFieldStyle(.plain)
                .focused($focused)
                .accessibilityLabel("원문 검색")
                .accessibilityHint("↑↓로 결과 선택, ⌥Space 미리보기, Return 원문 열기")
                .worklogHelp("원문 검색", keys: "↑↓ 선택 · ⌥Space 미리보기 · Return 원문")
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
                .worklogHelp("검색어 지우기")
            }
            Keycap("↵")
                .accessibilityHidden(true)
        }
        .padding(12)
        .background(WorkLogTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(focused ? WorkLogTheme.accent.opacity(0.6) : WorkLogTheme.border, lineWidth: 1)
        }
    }

    private var filterControls: some View {
        HStack(spacing: 12) {
            Text("결과 \(model.hits.count)건").font(.callout).foregroundStyle(WorkLogTheme.muted)
            Button { filtersExpanded.toggle() } label: {
                Label(model.activeFilterCount == 0 ? "필터" : "필터 \(model.activeFilterCount)",
                      systemImage: "line.3.horizontal.decrease")
            }
            .popover(isPresented: $filtersExpanded, arrowEdge: .bottom) { filterPopover }
            .accessibilityValue("\(model.activeFilterCount)개 적용 중")
            .worklogHelp("유형 · 프로젝트 · 태그 · 기간 필터")
            if model.activeFilterCount > 0 {
                Button("초기화", action: resetFilters).font(.caption)
            }
            Spacer(minLength: 0)
            if model.selectedHit != nil {
                Button { model.togglePreview() } label: {
                    Label(model.isPreviewVisible ? "미리보기 닫기" : "미리보기", systemImage: "doc.text.viewfinder")
                }
                .worklogHelp("미리보기", keys: "⌥Space · 결과 행 Space")
            }
            if model.isAIAvailable {
                Button(action: askAI) { Label("AI 질문", systemImage: "sparkles") }
                    .disabled(!model.canAskAI)
                    .worklogHelp(model.tagIds.isEmpty ? "입력한 질문에 기록을 근거로 답변" : "AI 질문은 태그 필터를 해제한 뒤 실행", keys: "⌘Return")
            }
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
    }

    private var filterPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("검색 필터").font(.headline)
                Spacer()
                Button("완료") { filtersExpanded = false }
            }
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
            Toggle("기간 지정", isOn: $useDates)
                .onChange(of: useDates) { _, _ in applyDates() }
            if useDates, let start = filterStart, let end = filterEnd {
                dateFilters(start: start, end: end)
            }
            if let filterError { InlineNotice(message: filterError) }
            if !model.tagIds.isEmpty {
                Text("태그 필터는 로컬 원문 검색에 적용됩니다.").font(.caption).foregroundStyle(WorkLogTheme.muted)
            }
            if model.activeFilterCount > 0 { Button("필터 초기화", action: resetFilters) }
        }
        .controlSize(.small)
        .padding(16).frame(width: 360)
    }

    private func askAI() {
        guard model.canAskAI else { return }
        aiExpanded = true
        Task { await model.askAI() }
    }

    @ViewBuilder private func dateFilters(start: WorkDate, end: WorkDate) -> some View {
        WorkDatePicker(title: "시작일", value: Binding(get: { filterStart ?? start }, set: {
            filterStart = $0; applyDates()
        }), calendar: environment.calendar)
        WorkDatePicker(title: "종료일 포함", value: Binding(get: { filterEnd ?? end }, set: {
            filterEnd = $0; applyDates()
        }), calendar: environment.calendar)
    }

    private var emptyResults: some View {
        let kind: StateView.Kind = model.emptyMessage == nil ? .empty : .noResults
        let action: (() -> Void)? = model.activeFilterCount > 0 ? { resetFilters() } : nil
        return StateView(kind: kind,
            title: model.emptyMessage ?? "찾을 기록을 입력하세요",
            detail: model.emptyMessage == nil ? "메모·업무·진행 기록·리포트를 검색합니다. ↑↓로 선택하고 Return으로 원문을 여세요."
                : "철자를 확인하거나 필터를 넓혀보세요.",
            actionTitle: model.activeFilterCount > 0 ? "필터 초기화" : nil,
            action: action)
    }

    private func resultRow(_ hit: SearchHit) -> some View {
        let selected = model.selectedKey == hit.key
        return Button { model.select(hit); openSource(hit) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: sourceIcon(hit.sourceType)).accessibilityHidden(true)
                    .foregroundStyle(WorkLogTheme.muted).frame(width: 18).padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    Text(highlightedSnippet(hit.snippet)).font(.body).lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    hitMetadata(hit).foregroundStyle(WorkLogTheme.muted)
                }
                Image(systemName: "chevron.right").font(.caption).accessibilityHidden(true)
                    .foregroundStyle(WorkLogTheme.muted).padding(.top, 2)
            }
            .padding(.horizontal, 10).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(WorkLogTheme.text)
            .background(selected ? WorkLogTheme.accentSoft : .clear)
            .overlay(alignment: .bottom) {
                Rectangle().fill(WorkLogTheme.border).frame(height: 1)
            }
            .overlay(alignment: .leading) {
                if selected { Rectangle().fill(WorkLogTheme.accent).frame(width: 3) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedResult, equals: hit.key)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(([sourceLabel(hit.sourceType)] + [hit.workDate?.iso].compactMap { $0 }
            + hit.projectNames + [hit.snippet]).joined(separator: ", ")))
        .accessibilityValue(selected ? "선택됨" : "")
        .accessibilityHint("Return 원문 열기, Space 미리보기")
        .worklogHelp("원문 열기", keys: "Return")
    }

    private func hitMetadata(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(sourceLabel(hit.sourceType)).fontWeight(.semibold)
                if let date = hit.workDate { Text(date.iso).monospacedDigit() }
            }
            if !hit.projectNames.isEmpty {
                Text(hit.projectNames.prefix(2).joined(separator: ", ")
                    + (hit.projectNames.count > 2 ? " 외 \(hit.projectNames.count - 2)개" : ""))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.font(.caption)
    }

    private func highlightedSnippet(_ snippet: String) -> AttributedString {
        var text = AttributedString(snippet)
        let query = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty, let range = text.range(of: query, options: [.caseInsensitive]) {
            text[range].font = .body.bold()
        }
        return text
    }

    private func preview(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("미리보기", systemImage: sourceIcon(hit.sourceType)).font(.headline)
            hitMetadata(hit)
            Text(hit.snippet).font(.body).textSelection(.enabled)
            Button("원문 열기") { openSource(hit) }.worklogHelp("원문 열기", keys: "Return")
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
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
                        .font(.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                    ForEach(paragraph.evidence, id: \.id) { evidence in
                        Button {
                            openSource(SearchHit(sourceType: evidence.sourceType, sourceId: evidence.sourceId,
                                taskId: nil, workDate: evidence.workDate, snippet: evidence.snippet))
                        } label: {
                            ChipView(label: "근거: \(evidence.snippet)", systemImage: "link")
                        }
                        .buttonStyle(.plain)
                        .worklogHelp("근거 원문 열기")
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
        .padding(.vertical, 8)
    }

    private func resetFilters() {
        useDates = false
        filterError = nil
        model.clearFilters()
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
        sourceOpenedFromQuery = focused
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

@MainActor private struct SourceRecordSheet: View {
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
                    .font(.title3)
                    .foregroundStyle(WorkLogTheme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("저장된 원문").font(.title3).fontWeight(.semibold)
                    Text("\(sourceTitle) · \(workDate?.iso ?? "날짜 없음")")
                        .font(.caption).foregroundStyle(WorkLogTheme.muted)
                }
                Spacer()
                Button("검색으로 돌아가기", action: onClose)
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
                        .font(.body)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                    }
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
