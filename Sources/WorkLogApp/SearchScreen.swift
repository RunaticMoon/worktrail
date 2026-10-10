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
    @State private var scope: SearchScope = .all
    @State private var query = ""
    @State private var recordQuery = ""
    @State private var secretQuery = ""
    @State private var secretTitles: [SecretMetadata] = []
    @State private var secretSearchError: String?
    @State private var selectedResult: SearchResultSelection?
    @State private var openingId: String?
    @State private var isActive = false
    @State private var hasInitialized = false
    @State private var secretNotice: String?
    @State private var secretSelection = SearchSecretSelection()
    @FocusState private var focusedResult: SearchResultSelection?
    @State private var focused = false
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
                Text(isPanel ? "전체 (⌘1)" : "전체").tag(SearchScope.all)
                Text(isPanel ? "기록 (⌘2)" : "기록").tag(SearchScope.records)
                Text(isPanel ? "Secret (⌘3)" : "Secret").tag(SearchScope.secret)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .worklogHelp(isPanel ? "검색 범위 · ⌘1 전체 · ⌘2 기록 · ⌘3 Secret" : "검색 범위 · Tab으로 포커스한 뒤 화살표로 전환")
            queryField
            if showsSecretKeys, let secrets {
                SearchSecretScope(model: secrets, selection: $secretSelection,
                    onBack: returnToResults, onOpenSecrets: onOpenSecrets)
            } else {
                unifiedResults
            }
        }
        .padding(16)
        .background(WorkLogTheme.canvas)
        .tint(WorkLogTheme.accent)
        .navigationTitle("검색")
        .background(SearchKeyboardBridge(handle: handleKey))
        .onChange(of: scope) { previous, current in
            cancelSecretOpening()
            secretSelection.openedId = nil
            secretSelection.selectedRowId = nil
            // Secret-only input must never become an ordinary AI question on a scope change.
            if previous == .secret {
                secretQuery = query
                query = recordQuery
            } else if current == .secret {
                recordQuery = query
                query = secretQuery
            }
            updateSearch()
            validateSelection()
            focused = true
        }
        .onChange(of: secrets?.isLocked) { _, locked in
            if locked == true { returnToResults() }
        }
        .onChange(of: secrets?.titles) { _, _ in
            refreshSecretTitles()
            validateSelection()
        }
        .onChange(of: secrets?.selectedId) { _, id in
            if let opened = secretSelection.openedId, id != opened { returnToResults() }
        }
        .onChange(of: secrets?.hasUnsavedDraft) { _, changed in
            if changed == true { returnToResults() }
        }
        .onChange(of: secrets?.isEditing) { _, editing in
            if editing == true { returnToResults() }
        }
        .onChange(of: secrets?.hasRecoverableDraft) { _, hasDraft in
            if hasDraft == true { returnToResults() }
        }
        .onAppear { initializeSearch() }
        .onChange(of: query) { _, _ in
            cancelSecretOpening()
            secretSelection.openedId = nil
            secretSelection.selectedRowId = nil
        }
        .task(id: query) {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard !Task.isCancelled else { return }
            updateSearch()
            validateSelection()
        }
        .onChange(of: focusedResult) { _, key in if let key { selectResult(key) } }
        .onDisappear { isActive = false; cancelSecretOpening() }
        .task(id: openingId) { await openSecretSelection() }
        .sheet(isPresented: Binding(get: { source != nil }, set: { if !$0 { source = nil } }), onDismiss: {
            if sourceOpenedFromQuery { focused = true }
            else { focusedResult = selectedResult }
        }) {
            SourceRecordSheet(bodyText: sourceBody, error: sourceError, snippet: source?.snippet ?? "",
                sourceTitle: source.map { sourceLabel($0.sourceType) } ?? "기록",
                workDate: source?.workDate, onClose: { source = nil })
        }
    }

    private var unifiedResults: some View {
        VStack(alignment: .leading, spacing: 12) {
            filterControls
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if scope != .secret {
                            if model.errorMessage != nil {
                                RecoveryNotice(failed: "검색하지 못했습니다", preserved: "입력과 필터는 그대로입니다",
                                    retryTitle: "다시 검색", retry: { model.search() })
                            }
                            if aiExpanded, model.isAIAvailable, let message = model.aiMessage {
                                Label(message, systemImage: "info.circle")
                                    .font(.callout).foregroundStyle(WorkLogTheme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if model.activeFilterCount > 0 {
                                Text("필터는 기록에만 적용됩니다. Secret은 제목·그룹명으로 검색합니다.")
                                    .font(.caption).foregroundStyle(WorkLogTheme.muted)
                            }
                            if model.isSearching { ProgressView("원문 검색 중…") }
                            if !model.hits.isEmpty {
                                if scope == .all && !secretTitles.isEmpty {
                                    Text("기록").font(.caption.weight(.semibold)).foregroundStyle(WorkLogTheme.muted)
                                        .padding(.vertical, 8).accessibilityAddTraits(.isHeader)
                                }
                                ForEach(model.hits, id: \.key) { hit in
                                    resultRow(hit).id(SearchResultSelection.record(hit.key))
                                }
                            }
                        }
                        if scope != .records, let secrets {
                            if !secretTitles.isEmpty {
                                if scope == .all {
                                    Label("Secret", systemImage: "lock.fill").font(.caption.weight(.semibold))
                                        .foregroundStyle(WorkLogTheme.muted).padding(.vertical, 8)
                                        .accessibilityAddTraits(.isHeader)
                                }
                                ForEach(secretTitles) { item in secretTitleRow(item, model: secrets) }
                            }
                            if let secretNotice { InlineNotice(message: secretNotice) }
                            if let secretSearchError { InlineNotice(message: secretSearchError) }
                            if secrets.isUnlocking || openingId != nil { ProgressView("Secret을 여는 중…") }
                            if !showsSecretKeys, let message = secrets.message {
                                Label(message, systemImage: "info.circle")
                                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                            }
                        } else if scope != .records, secrets == nil {
                            InlineNotice(message: "Secret 검색을 연결하지 못했습니다. 기록 검색은 사용할 수 있습니다.")
                        }
                        if resultIDs.isEmpty && (scope == .secret || !model.isSearching)
                            && (scope == .secret || model.errorMessage == nil)
                            && !(scope == .secret && (secrets == nil || secretSearchError != nil)) { emptyResults }
                        if scope != .secret, !secretSelected, aiExpanded {
                            if model.isAskingAI { ProgressView("답변 생성 중…").controlSize(.small) }
                            if let answer = model.answer { answerView(answer) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(1)
                }
                .onChange(of: selectedResult) { _, key in if let key { proxy.scrollTo(key) } }
                .onChange(of: resultIDs) { _, _ in
                    validateSelection()
                    if let key = selectedResult { proxy.scrollTo(key) }
                }
                .onAppear { if let key = selectedResult { proxy.scrollTo(key) } }
            }
            if scope != .secret, isRecordSelected, model.isPreviewVisible, let hit = model.selectedHit {
                ScrollView { preview(hit) }.frame(maxHeight: 160)
            }
        }
    }

    private func initializeSearch() {
        isActive = true
        focused = true
        guard !hasInitialized else { updateSearch(); validateSelection(); return }
        hasInitialized = true
        query = model.text
        recordQuery = query
        if let key = model.selectedKey { selectedResult = .record(key) }
        let today = environment.calendar.workDate(of: environment.options.clock.now())
        filterStart = model.range?.start ?? today
        filterEnd = model.range.map { environment.calendar.adding(days: -1, to: $0.endExclusive) } ?? today
        useDates = model.range != nil
        do { projects = try environment.repo.projects(); tags = try environment.repo.tags() }
        catch { filterError = "필터 후보를 불러오지 못했습니다." }
        updateSearch()
    }

    private var showsSecretKeys: Bool {
        guard let secrets else { return false }
        return secretSelection.openedId != nil && secretSelection.openedId == secrets.selectedId
            && !secrets.isLocked && !secrets.isEditing && !secrets.hasUnsavedDraft && !secrets.hasRecoverableDraft
    }

    private var isRecordSelected: Bool {
        if case .record = selectedResult { return true }
        return false
    }

    private var secretSelected: Bool {
        if case .secret = selectedResult { return true }
        return showsSecretKeys
    }

    private var resultIDs: [SearchResultSelection] {
        var ids: [SearchResultSelection] = []
        if scope != .secret { ids += model.hits.map { SearchResultSelection.record($0.key) } }
        if scope != .records, secrets != nil { ids += secretTitles.map { SearchResultSelection.secret($0.id) } }
        return ids
    }

    private func updateSearch() {
        // Only the user-authored query is copied. Never assign a Secret title/key/value to SearchModel.
        if scope != .secret {
            if model.text != query { model.text = query }
            model.search()
        }
        refreshSecretTitles()
    }

    private func refreshSecretTitles() {
        guard isActive, scope != .records else { return }
        guard secrets != nil else { secretTitles = []; secretSearchError = nil; return }
        // App-owned metadata results: leave the shared Secret screen's query and titles untouched.
        do {
            secretTitles = try environment.vaultSession.searchTitles(query)
            secretSearchError = nil
        } catch {
            secretTitles = []
            secretSearchError = "Secret 제목을 검색하지 못했습니다. 검색어를 다시 입력하세요."
        }
    }

    private func selectResult(_ key: SearchResultSelection) {
        selectedResult = key
        switch key {
        case .record(let recordKey):
            if let hit = model.hits.first(where: { $0.key == recordKey }) { model.select(hit) }
        case .secret(let id): secretSelection.selectedTitleId = id
        }
    }

    private func validateSelection() {
        if let selectedResult, !resultIDs.contains(selectedResult) {
            self.selectedResult = nil; focusedResult = nil
        }
    }

    private func returnToResults() {
        cancelSecretOpening()
        secretSelection.openedId = nil; secretSelection.selectedRowId = nil
        focused = true
    }

    private func cancelSecretOpening() { openingId = nil; secretNotice = nil }

    private func requestSecret(_ id: String) {
        guard let secrets, openingId == nil, !secrets.isUnlocking else { return }
        selectResult(.secret(id))
        guard !secrets.hasUnsavedDraft, !secrets.hasRecoverableDraft, (secrets.editorOwner == nil || !secrets.isEditing) else {
            secretNotice = "Secret 화면 또는 빠른 입력에서 편집 중인 초안을 저장하거나 정리한 뒤 다시 여세요."
            return
        }
        openingId = id
    }

    private func openSecretSelection() async {
        guard let id = openingId, let secrets else { openingId = nil; return }
        defer { if openingId == id { openingId = nil } }
        guard secretTitles.contains(where: { $0.id == id }) else {
            returnToResults()
            secretNotice = "Secret을 찾지 못했습니다."
            return
        }
        let requestWindow = NSApp.keyWindow
        if secrets.isLocked { await secrets.unlock() }
        guard !Task.isCancelled, isActive, openingId == id, requestWindow?.isVisible == true,
              !secrets.isLocked, !secrets.hasUnsavedDraft, !secrets.hasRecoverableDraft,
              (secrets.editorOwner == nil || !secrets.isEditing), selectedResult == .secret(id) else {
            if secrets.hasRecoverableDraft { secretNotice = "Secret 화면에서 보존된 초안을 확인한 뒤 다시 여세요." }
            return
        }
        refreshSecretTitles()
        guard let item = secretTitles.first(where: { $0.id == id }) else {
            returnToResults()
            secretNotice = "Secret을 찾지 못했습니다."
            return
        }
        secrets.open(item)
        if secrets.selectedId == id {
            secretSelection.openedId = id
            secretSelection.selectedRowId = secrets.rows.first?.id
            focused = false
            NSApp.activate(ignoringOtherApps: true)
            requestWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private func askAI() {
        guard scope != .secret, !secretSelected else { return }
        // Explicit invocation passes only the typed question. GroundedAnswerService uses ordinary records.
        if model.text != query { model.text = query }
        guard model.canAskAI else { return }
        aiExpanded = true
        Task {
            guard scope != .secret, !secretSelected else { return }
            await model.askAI()
        }
    }

    private func handleKey(_ event: NSEvent, editingText: Bool) -> Bool {
        guard source == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command, event.keyCode == 3 { focused = true; return true }
        if isPanel, modifiers == .command {
            switch event.keyCode {
            case 18: scope = .all; return true
            case 19: scope = .records; return true
            case 20: scope = .secret; return true
            default: break
            }
        }
        if modifiers == .command, event.keyCode == 36 || event.keyCode == 76 {
            guard scope != .secret, !secretSelected else { return false }
            if !event.isARepeat { askAI() }
            return true
        }
        if showsSecretKeys, let secrets {
            if (modifiers.isEmpty && event.keyCode == 53) || (modifiers == .command && event.keyCode == 123) {
                returnToResults(); return true
            }
            if modifiers.isEmpty, event.keyCode == 125 || event.keyCode == 126 {
                let ids = secrets.rows.map(\.id)
                guard !ids.isEmpty else { return true }
                let delta = event.keyCode == 125 ? 1 : -1
                let index = secretSelection.selectedRowId.flatMap { ids.firstIndex(of: $0) }
                let next = index.map { min(max($0 + delta, 0), ids.count - 1) } ?? (delta > 0 ? 0 : ids.count - 1)
                secretSelection.selectedRowId = ids[next]
                return true
            }
            if modifiers.isEmpty, event.keyCode == 36 || event.keyCode == 76 {
                if !event.isARepeat,
                   let row = secrets.rows.first(where: { $0.id == secretSelection.selectedRowId }) { secrets.copyRow(row) }
                return true
            }
            return false
        }
        let navigatingResults = focused || focusedResult != nil
        if navigatingResults, modifiers.isEmpty, event.keyCode == 125 || event.keyCode == 126 {
            let ids = resultIDs
            guard !ids.isEmpty else { return true }
            let delta = event.keyCode == 125 ? 1 : -1
            let index = selectedResult.flatMap { ids.firstIndex(of: $0) }
            let next = index.map { min(max($0 + delta, 0), ids.count - 1) } ?? (delta > 0 ? 0 : ids.count - 1)
            selectResult(ids[next])
            if !editingText { focusedResult = ids[next] }
            return true
        }
        if isRecordSelected, event.keyCode == 49,
           (navigatingResults && modifiers == .option && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || modifiers.isEmpty && !editingText && focusedResult != nil) {
            model.togglePreview(); return true
        }
        if navigatingResults, modifiers.isEmpty, event.keyCode == 36 || event.keyCode == 76 {
            if !event.isARepeat, let selectedResult {
                switch selectedResult {
                case .record(let key):
                    if let hit = model.hits.first(where: { $0.key == key }) { openSource(hit) }
                case .secret(let id): requestSecret(id)
                }
            }
            return true
        }
        return false
    }

    private func secretTitleRow(_ item: SecretMetadata, model secrets: SecretsModel) -> some View {
        let key = SearchResultSelection.secret(item.id)
        let selected = selectedResult == key
        return Button { requestSecret(item.id) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.fill").accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.body)
                    if let group = item.groupName, !group.isEmpty { Text(group).font(.caption) }
                    if secrets.isLocked { Text("잠김 · Return으로 잠금 해제").font(.caption) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10).padding(.vertical, 12)
            .foregroundStyle(WorkLogTheme.text)
            .background(selected ? WorkLogTheme.accentSoft : .clear)
            .overlay(alignment: .bottom) { Rectangle().fill(WorkLogTheme.border).frame(height: 1) }
            .overlay(alignment: .leading) {
                if selected { Rectangle().fill(WorkLogTheme.accent).frame(width: 3) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focused($focusedResult, equals: key)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(["Secret", item.title, item.groupName].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityValue(selected ? "선택됨" : "")
        .accessibilityHint(secrets.isLocked ? "Return으로 잠금 해제 후 key 목록 열기" : "Return으로 key 목록 열기")
        .worklogHelp("Secret key 목록 열기", keys: "Return")
        .id(key)
    }

    private var queryField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(focused ? WorkLogTheme.accent : WorkLogTheme.muted)
            SearchQueryField(text: $query, isFocused: $focused, allowsAIQuestion: scope != .secret)
                .frame(minHeight: 22)
                .accessibilityLabel(scope == .secret ? "Secret 제목 검색" : "원문 검색")
                .accessibilityHint("↑↓로 기록과 Secret 선택, Return 열기. Secret은 AI로 보내지 않습니다")
                .worklogHelp("원문 검색", keys: "↑↓ 선택 · ⌥Space 미리보기 · Return 원문")
            if !query.isEmpty {
                Button {
                    query = ""
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
            Text("결과 \(resultIDs.count)건").font(.callout).foregroundStyle(WorkLogTheme.muted)
            if scope != .secret {
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
            }
            Spacer(minLength: 0)
            if scope != .secret, isRecordSelected, model.selectedHit != nil {
                Button { model.togglePreview() } label: {
                    Label(model.isPreviewVisible ? "미리보기 닫기" : "미리보기", systemImage: "doc.text.viewfinder")
                }
                .worklogHelp("미리보기", keys: "⌥Space · 결과 행 Space")
            }
            if scope != .secret, !secretSelected, model.isAIAvailable {
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

    @ViewBuilder private func dateFilters(start: WorkDate, end: WorkDate) -> some View {
        WorkDatePicker(title: "시작일", value: Binding(get: { filterStart ?? start }, set: {
            filterStart = $0; applyDates()
        }), calendar: environment.calendar)
        WorkDatePicker(title: "종료일 포함", value: Binding(get: { filterEnd ?? end }, set: {
            filterEnd = $0; applyDates()
        }), calendar: environment.calendar)
    }

    private var emptyResults: some View {
        let action: (() -> Void)?
        let actionTitle: String?
        if scope != .secret && model.activeFilterCount > 0 {
            action = { resetFilters() }
            actionTitle = "필터 초기화"
        } else {
            action = nil
            actionTitle = nil
        }
        return StateView(kind: query.isEmpty ? StateView.Kind.empty : StateView.Kind.noResults,
            title: query.isEmpty ? "찾을 기록이나 Secret 제목을 입력하세요" : "일치하는 검색 결과가 없습니다",
            detail: "철자를 확인하거나 검색 범위·기록 필터를 넓혀보세요. Secret은 잠금 중에도 제목을 검색합니다.",
            actionTitle: actionTitle, action: action)
    }

    private func resultRow(_ hit: SearchHit) -> some View {
        let selected = selectedResult == .record(hit.key)
        return Button { selectResult(.record(hit.key)); openSource(hit) } label: {
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
        .focused($focusedResult, equals: SearchResultSelection.record(hit.key))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
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
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty, let range = text.range(of: needle, options: [.caseInsensitive]) {
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
        }.frame(maxWidth: .infinity, alignment: .leading).worklogCard()
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
        .worklogCard(padding: 18)
        .padding(.top, 6)
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
                        .font(.body)
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
