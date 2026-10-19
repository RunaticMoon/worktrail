#if os(macOS)
import SwiftUI
import AppKit
import WorkLogCore

@MainActor struct SearchScreen: View {
    @Environment(\.worklogContentAutofocus) private var contentAutofocus
    @Environment(\.colorSchemeContrast) private var contrast
    @Bindable var model: SearchModel
    @Bindable var surface: SearchSurfaceState
    let environment: AppEnvironment
    var secrets: SecretsModel? = nil
    var onOpenSecrets: (() -> Void)? = nil
    var isPanel: Bool = false
    @State private var secretQuery = ""
    @State private var completedQuery = ""
    @State private var secretTitles: [SecretMetadata] = []
    @State private var secretSearchError: String?
    @State private var selectedSecretId: String?
    @State private var openingId: String?
    @State private var isActive = false
    @State private var isWindowActive = false
    @State private var hasAppeared = false
    @State private var hasInitialized = false
    @State private var secretNotice: String?
    @State private var secretSelection = SearchSecretSelection()
    @FocusState private var focusedResult: SearchResultSelection?
    @State private var focused = false
    @State private var source: SearchHit?
    @State private var sourceBody: String?
    @State private var sourceError: String?
    @State private var sourceMemoDetail: MemoDetailModel?
    @State private var sourceTaskDetail: TaskDetailModel?
    @State private var projects: [Project] = []
    @State private var tags: [Tag] = []
    @State private var filtersExpanded = false
    @State private var aiExpanded = false
    @State private var sourceOpenedFromQuery = false
    @State private var showsScopeShortcuts = false

    // Secret-only input and selection never enter the controller-owned surface or SearchModel.
    private var query: String {
        get { surface.scope == .secret ? secretQuery : surface.recordQuery }
        nonmutating set {
            if surface.scope == .secret { secretQuery = newValue }
            else { surface.recordQuery = newValue }
        }
    }

    private var selectedResult: SearchResultSelection? {
        get {
            if let selectedSecretId { return .secret(selectedSecretId) }
            return surface.selectedKey.map { .record($0) }
        }
        nonmutating set {
            switch newValue {
            case .record(let key): surface.selectedKey = key; selectedSecretId = nil
            case .secret(let id): surface.selectedKey = nil; selectedSecretId = id
            case nil: surface.selectedKey = nil; selectedSecretId = nil
            }
        }
    }

    var body: some View {
        searchLifecycle
            .sheet(isPresented: sourcePresented, onDismiss: sourceDidDismiss) { sourceSheet }
    }

    private var searchContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            scopePicker
            queryField
            searchResults
            keyboardHints
        }
        .padding(16)
        .background(WorkLogTheme.canvas)
        .tint(WorkLogTheme.accent)
        .navigationTitle("검색")
        .background(SearchKeyboardBridge(handle: handleKey))
        .background(SearchWindowActivityObserver(onChange: windowActivityDidChange))
        .background {
            if hasAppeared {
                SearchScopeShortcutMonitor(modifier: isPanel ? .command : .control) {
                    showsScopeShortcuts = $0
                }
            }
        }
        .worklogFocusContent { returnToResults() }
    }

    private var scopePicker: some View {
        Picker("검색 범위", selection: $surface.scope) {
            ForEach(SearchScope.allCases, id: \.self) { scope in
                Text(scope.title)
                    .accessibilityLabel("\(scope.title), 단축키 \(scopeModifier)\(scope.shortcutNumber)")
                    .tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .overlay(alignment: .top) {
            // Overlay the control, not its native segment labels: badges never resize tabs.
            if showsScopeShortcuts {
                HStack(spacing: 0) {
                    ForEach(SearchScope.allCases, id: \.self) { scope in
                        Keycap("\(scopeModifier)\(scope.shortcutNumber)")
                            .background(WorkLogTheme.surface, in: RoundedRectangle(cornerRadius: 4))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.trailing, 4)
                    }
                }
                .offset(y: -8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: 600)
        .accessibilityIdentifier("search.scope")
        .worklogHelp("검색 범위 · \(scopeModifier)1 전체 · \(scopeModifier)2 기록 · \(scopeModifier)3 업무 · \(scopeModifier)4 Secret · \(scopeModifier)5 리포트 · ⌃Tab 다음 범위")
    }

    @ViewBuilder private var searchResults: some View {
        if showsSecretKeys, let secrets {
            SearchSecretScope(model: secrets, selection: $secretSelection,
                onBack: returnToResults, onOpenSecrets: onOpenSecrets)
        } else {
            unifiedResults
        }
    }

    private var searchWithSecretObservers: some View {
        searchContent
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
    }

    private var searchWithQueryObservers: some View {
        searchWithSecretObservers
        .onChange(of: surface.scope) { previous, current in scopeDidChange(from: previous, to: current) }
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
        .onChange(of: filtersExpanded) { _, expanded in
            if !expanded { focusQuery() }
        }
        .onChange(of: model.hits) { _, _ in refreshRecordResults() }
        .onChange(of: model.errorMessage) { _, _ in refreshRecordResults() }
    }

    private var searchLifecycle: some View {
        searchWithQueryObservers
        .onAppear { initializeSearch() }
        .onDisappear {
            hasAppeared = false; isActive = false; isWindowActive = false
            showsScopeShortcuts = false
            cancelSecretOpening()
            secretQuery = ""; completedQuery = ""
            selectedSecretId = nil; secretTitles = []
            secretSelection = SearchSecretSelection()
        }
        .task(id: openingId) { await openSecretSelection() }
    }

    private var sourcePresented: Binding<Bool> {
        Binding<Bool>(get: { source != nil }, set: { if !$0 { closeSource() } })
    }

    private func sourceDidDismiss() {
        updateSearch()
        validateSelection()
        if sourceOpenedFromQuery || selectedResult == nil { focusQuery() }
        else { focusResults() }
    }

    private func scopeDidChange(from _: SearchScope, to _: SearchScope) {
        cancelSecretOpening()
        secretSelection.openedId = nil
        secretSelection.selectedRowId = nil
        // The query accessor keeps Secret-only input separate from the retained record query.
        // A manual type from another scope must never hide this scope's results.
        surface.typeFilter = nil
        // Relationship filters stay local, and are suspended only while searching reports.
        updateSearch()
        validateSelection()
        focusQuery()
    }

    private var scopeModifier: String { isPanel ? "⌘" : "⌃" }

    private var includesSecrets: Bool { surface.scope == .all || surface.scope == .secret }

    private var availableTypes: [SearchSourceType] {
        surface.scope == .records ? [.memo, .activity] : SearchSourceType.allCases
    }

    private var scopedTypes: Set<SearchSourceType>? {
        switch surface.scope {
        case .all: return surface.typeFilter.map { Set([$0]) }
        case .records: return surface.typeFilter.map { Set([$0]) } ?? Set([.memo, .activity])
        case .tasks: return [.task]
        case .reports: return [.report]
        case .secret: return nil
        }
    }

    /// The scope itself is navigation, not a user-applied filter.
    private var activeFilterCount: Int {
        (surface.typeFilter == nil ? 0 : 1) + (surface.scope == .reports ? 0 : surface.projectFilterIds.count + surface.tagFilterIds.count)
            + (surface.filterRange == nil ? 0 : 1)
    }

    private var keyboardHints: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(scopeModifier)1–5 범위 · ⌃Tab 다음 범위 · ⌃⇧Tab 이전 범위 · ⌘F 검색어")
            if !showsSecretKeys {
                Text("↑↓ 선택 · Tab 결과로 · ⇧Tab 검색어로 · Return 원문 · ⌘E 메모·업무 편집 · ⌘⌥F 필터")
            }
        }
        .font(.caption).foregroundStyle(WorkLogTheme.muted)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var unifiedResults: some View {
        VStack(alignment: .leading, spacing: 12) {
            filterControls
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if surface.scope != .secret {
                            if surface.recordSearchError != nil {
                                RecoveryNotice(failed: "검색하지 못했습니다", preserved: "입력과 필터는 그대로입니다",
                                    retryTitle: "다시 검색", retry: { updateSearch() })
                            }
                            if isActive, aiExpanded, model.isAIAvailable, let message = model.aiMessage {
                                Label(message, systemImage: "info.circle")
                                    .font(.callout).foregroundStyle(WorkLogTheme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if surface.scope == .all, activeFilterCount > 0 {
                                Text("필터는 일반 검색 결과에만 적용됩니다. Secret은 제목·그룹명으로 검색합니다.")
                                    .font(.caption).foregroundStyle(WorkLogTheme.muted)
                            }
                            if isActive, model.isSearching { ProgressView("원문 검색 중…") }
                            if !recordHits.isEmpty {
                                if surface.scope == .all && !secretTitles.isEmpty {
                                    Text("기록").font(.caption.weight(.semibold)).foregroundStyle(WorkLogTheme.muted)
                                        .padding(.vertical, 8).accessibilityAddTraits(.isHeader)
                                }
                                ForEach(recordHits, id: \.key) { hit in
                                    resultRow(hit).id(SearchResultSelection.record(hit.key))
                                }
                            }
                        }
                        if includesSecrets, let secrets {
                            if !secretTitles.isEmpty {
                                if surface.scope == .all {
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
                        } else if includesSecrets, secrets == nil {
                            InlineNotice(message: "Secret 검색을 연결하지 못했습니다. 기록 검색은 사용할 수 있습니다.")
                        }
                        if resultIDs.isEmpty && (surface.scope == .secret || !isActive || !model.isSearching)
                            && (surface.scope == .secret || surface.recordSearchError == nil)
                            && !(surface.scope == .secret && (secrets == nil || secretSearchError != nil)) { emptyResults }
                        if isActive, surface.scope != .secret, !secretSelected, aiExpanded {
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
            if surface.scope != .secret, surface.previewVisible, let hit = selectedRecordHit {
                ScrollView { preview(hit) }.frame(maxHeight: 160)
            }
        }
    }

    private func initializeSearch() {
        hasAppeared = true
        isActive = isWindowActive
        focused = contentAutofocus
        guard !hasInitialized else { updateSearch(); validateSelection(); return }
        hasInitialized = true
        if !surface.hasInitialized {
            surface.hasInitialized = true
            surface.recordQuery = model.text
            let today = environment.calendar.workDate(of: environment.options.clock.now())
            surface.filterStart = today
            surface.filterEnd = today
        }
        do { projects = try environment.repo.projects(); tags = try environment.repo.tags() }
        catch { surface.filterError = "필터 후보를 불러오지 못했습니다." }
        updateSearch()
    }

    private func windowActivityDidChange(_ active: Bool) {
        isWindowActive = active
        isActive = active && hasAppeared
        guard isActive, hasInitialized else { return }
        // Switching key windows must reapply this surface before using the shared model.
        updateSearch()
        validateSelection()
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

    private var selectedRecordHit: SearchHit? {
        guard case .record(let key) = selectedResult else { return nil }
        return recordHits.first { $0.key == key }
    }

    private var recordHits: [SearchHit] {
        guard surface.scope != .secret else { return [] }
        guard let scopedTypes else { return surface.recordResults }
        return surface.recordResults.filter { scopedTypes.contains($0.sourceType) }
    }

    private var secretSelected: Bool {
        if case .secret = selectedResult { return true }
        return showsSecretKeys
    }

    private var resultIDs: [SearchResultSelection] {
        var ids: [SearchResultSelection] = []
        if surface.scope != .secret { ids += recordHits.map { SearchResultSelection.record($0.key) } }
        if includesSecrets, secrets != nil { ids += secretTitles.map { SearchResultSelection.secret($0.id) } }
        return ids
    }

    private func updateSearch() {
        guard isActive, hasInitialized else { return }
        // Only the user-authored query is copied. Never assign a Secret title/key/value to SearchModel.
        if surface.scope != .secret {
            if model.text != query { model.text = query }
            if model.types != scopedTypes { model.types = scopedTypes }
            let projectIds = surface.scope == .reports ? [] : surface.projectFilterIds
            let tagIds = surface.scope == .reports ? [] : surface.tagFilterIds
            if model.projectIds != projectIds { model.projectIds = projectIds }
            if model.tagIds != tagIds { model.tagIds = tagIds }
            if model.range != surface.filterRange { model.range = surface.filterRange }
            model.search()
            surface.recordResults = model.hits
            surface.recordSearchError = model.errorMessage
            if let hit = selectedRecordHit { model.select(hit) }
            model.isPreviewVisible = surface.previewVisible
        }
        refreshSecretTitles()
        completedQuery = query
    }

    private func refreshRecordResults() {
        // AppController can refresh the shared model after a source edit.
        guard isActive, surface.scope != .secret, model.text == query, model.types == scopedTypes,
              model.projectIds == (surface.scope == .reports ? [] : surface.projectFilterIds),
              model.tagIds == (surface.scope == .reports ? [] : surface.tagFilterIds), model.range == surface.filterRange else { return }
        surface.recordResults = model.hits
        surface.recordSearchError = model.errorMessage
    }

    private func refreshSecretTitles() {
        guard hasAppeared else { return }
        guard includesSecrets else { secretTitles = []; secretSearchError = nil; return }
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
            if isActive, let hit = recordHits.first(where: { $0.key == recordKey }) { model.select(hit) }
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
        focusQuery()
    }

    private func focusQuery() {
        focusedResult = nil
        focused = true
    }

    private func focusResults() {
        guard let key = selectedResult ?? resultIDs.first else { focusQuery(); return }
        selectResult(key)
        focused = false
        focusedResult = key
    }

    private func changeScope(to next: SearchScope) {
        if surface.scope == next { returnToResults() }
        else { surface.scope = next }
    }

    private func cycleScope(backwards: Bool) {
        let scopes = SearchScope.allCases
        guard let current = scopes.firstIndex(of: surface.scope) else { return }
        changeScope(to: scopes[(current + (backwards ? scopes.count - 1 : 1)) % scopes.count])
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
        // Device authentication can temporarily take key focus; the original screen must remain visible.
        guard !Task.isCancelled, hasAppeared, openingId == id, requestWindow?.isVisible == true,
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
            if !isPanel { NSApp.activate(ignoringOtherApps: true) }
            requestWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private func askAI() {
        guard isActive, surface.scope != .secret, !secretSelected else { return }
        // Explicit invocation passes only the typed question. GroundedAnswerService uses ordinary records.
        updateSearch()
        guard model.canAskAI else { return }
        aiExpanded = true
        Task {
            guard isActive, surface.scope != .secret, !secretSelected else { return }
            updateSearch()
            await model.askAI()
        }
    }

    private func handleKey(_ event: NSEvent, editingText: Bool) -> Bool {
        guard isActive, source == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command, event.keyCode == 3 {
            filtersExpanded = false
            returnToResults(); return true
        }
        if filtersExpanded {
            if modifiers.isEmpty, event.keyCode == 53 { filtersExpanded = false; return true }
            return false
        }
        if modifiers == .control || (isPanel && modifiers == .command) {
            let scopeKeyCodes: [UInt16] = [18, 19, 20, 21, 23] // 1, 2, 3, 4, 5
            if let index = scopeKeyCodes.firstIndex(of: event.keyCode) {
                changeScope(to: SearchScope.allCases[index]); return true
            }
        }
        if event.keyCode == 48, modifiers == .control || modifiers == [.control, .shift] {
            cycleScope(backwards: modifiers.contains(.shift)); return true
        }
        if modifiers == [.command, .option], event.keyCode == 3, surface.scope != .secret, !showsSecretKeys {
            focused = false; focusedResult = nil
            filtersExpanded = true
            return true
        }
        if modifiers == .command, event.keyCode == 36 || event.keyCode == 76 {
            guard surface.scope != .secret, !secretSelected else { return false }
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
            if modifiers == .command, event.keyCode == 14, let onOpenSecrets {
                if !event.isARepeat { onOpenSecrets() }
                return true
            }
            return false
        }
        let navigatingResults = focused || focusedResult != nil
        if navigatingResults, completedQuery != query,
           [UInt16(48), 125, 126, 36, 76].contains(event.keyCode)
            || (modifiers == .command && event.keyCode == 14) {
            // Return immediately after typing must not open an old debounced result.
            updateSearch()
            validateSelection()
        }
        if event.keyCode == 48 {
            if focused, modifiers.isEmpty, !resultIDs.isEmpty { focusResults(); return true }
            if focusedResult != nil, modifiers == .shift { focusQuery(); return true }
        }
        if navigatingResults, modifiers == .command, event.keyCode == 14,
           case .record(let key) = selectedResult ?? resultIDs.first,
           let hit = recordHits.first(where: { $0.key == key }), hit.sourceType != .report {
            if !event.isARepeat { selectResult(.record(key)); openSource(hit, editing: true) }
            return true
        }
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
            togglePreview(); return true
        }
        if navigatingResults, modifiers.isEmpty, event.keyCode == 36 || event.keyCode == 76 {
            if !event.isARepeat, let selectedResult = selectedResult ?? resultIDs.first {
                selectResult(selectedResult)
                switch selectedResult {
                case .record(let key):
                    if let hit = recordHits.first(where: { $0.key == key }) { openSource(hit) }
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
        .buttonStyle(.plain).focusable().focused($focusedResult, equals: key)
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
            SearchQueryField(text: Binding(get: { query }, set: { query = $0 }), isFocused: $focused, allowsAIQuestion: surface.scope != .secret)
                .frame(minHeight: 22)
                .accessibilityLabel(queryLabel)
                .accessibilityHint(includesSecrets
                    ? "↑↓로 결과 선택, Tab으로 결과 이동, Return 열기. Secret은 AI로 보내지 않습니다"
                    : "↑↓로 결과 선택, Tab으로 결과 이동, Return 원문 열기")
                .worklogHelp(queryLabel, keys: "↑↓ 선택 · Tab 결과로 · ⌥Space 미리보기 · Return 원문")
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
                .strokeBorder(focused ? WorkLogTheme.focusColor(for: contrast) : WorkLogTheme.outlineColor(for: contrast),
                              lineWidth: focused ? (contrast == .increased ? 3 : 2) : WorkLogTheme.outlineWidth(for: contrast))
                .allowsHitTesting(false)
        }
    }

    private var queryLabel: String {
        switch surface.scope {
        case .all: return "원문·Secret 제목 검색"
        case .records: return "메모·진행 기록 검색"
        case .tasks: return "업무 검색"
        case .reports: return "리포트 검색"
        case .secret: return "Secret 제목 검색"
        }
    }

    private var filterControls: some View {
        HStack(spacing: 12) {
            Text("결과 \(resultIDs.count)건").font(.callout).foregroundStyle(WorkLogTheme.muted)
            if surface.scope != .secret {
            Button { filtersExpanded.toggle() } label: {
                Label(activeFilterCount == 0 ? "필터" : "필터 \(activeFilterCount)",
                      systemImage: "line.3.horizontal.decrease")
            }
            .popover(isPresented: $filtersExpanded, arrowEdge: .bottom) { filterPopover }
            .accessibilityValue("\(activeFilterCount)개 적용 중")
            .worklogHelp("유형 · 프로젝트 · 태그 · 기간 필터", keys: "⌘⌥F")
            if activeFilterCount > 0 {
                Button("초기화", action: resetFilters).font(.caption)
            }
            }
            Spacer(minLength: 0)
            if surface.scope != .secret, selectedRecordHit != nil {
                Button(action: togglePreview) {
                    Label(surface.previewVisible ? "미리보기 닫기" : "미리보기", systemImage: "doc.text.viewfinder")
                }
                .worklogHelp("미리보기", keys: "⌥Space · 결과 행 Space")
            }
            if surface.scope != .secret, !secretSelected, model.isAIAvailable {
                Button(action: askAI) { Label("AI 질문", systemImage: "sparkles") }
                    .disabled(!model.canAskAI)
                    .worklogHelp(surface.scope == .reports || surface.tagFilterIds.isEmpty ? "입력한 질문에 기록을 근거로 답변" : "AI 질문은 태그 필터를 해제한 뒤 실행", keys: "⌘Return")
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
                Button("완료") { filtersExpanded = false }.keyboardShortcut(.cancelAction)
            }
            if surface.scope == .all || surface.scope == .records {
                Picker("유형", selection: Binding(get: { surface.typeFilter?.rawValue ?? "all" }, set: {
                    surface.typeFilter = SearchSourceType(rawValue: $0)
                    updateSearch()
                })) {
                    Text("전체").tag("all")
                    ForEach(availableTypes, id: \.self) { Text(sourceLabel($0)).tag($0.rawValue) }
                }
            }
            Picker("프로젝트", selection: Binding(get: { surface.projectFilterIds.first ?? "" }, set: {
                surface.projectFilterIds = $0.isEmpty ? [] : [$0]
                updateSearch()
            })) {
                Text("전체").tag("")
                ForEach(projects) { Text($0.name).tag($0.id) }
            }
            .disabled(surface.scope == .reports)
            Picker("태그", selection: Binding(get: { surface.tagFilterIds.first ?? "" }, set: {
                surface.tagFilterIds = $0.isEmpty ? [] : [$0]
                updateSearch()
            })) {
                Text("전체").tag("")
                ForEach(tags) { Text($0.name).tag($0.id) }
            }
            .disabled(surface.scope == .reports)
            if surface.scope == .reports {
                Text("리포트에는 프로젝트·태그 필터가 적용되지 않습니다. 다른 범위로 돌아가면 기존 필터를 복원합니다.")
                    .font(.caption).foregroundStyle(WorkLogTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("기간 지정", isOn: $surface.useDates)
                .onChange(of: surface.useDates) { _, _ in applyDates() }
            if surface.useDates, let start = surface.filterStart, let end = surface.filterEnd {
                dateFilters(start: start, end: end)
            }
            if let filterError = surface.filterError { InlineNotice(message: filterError) }
            if surface.scope != .reports, !surface.tagFilterIds.isEmpty {
                Text("태그 필터는 로컬 원문 검색에 적용됩니다.").font(.caption).foregroundStyle(WorkLogTheme.muted)
            }
            if activeFilterCount > 0 { Button("필터 초기화", action: resetFilters) }
        }
        .controlSize(.small)
        .padding(16).frame(width: 360)
    }

    @ViewBuilder private func dateFilters(start: WorkDate, end: WorkDate) -> some View {
        WorkDatePicker(title: "시작일", value: Binding(get: { surface.filterStart ?? start }, set: {
            surface.filterStart = $0; applyDates()
        }), calendar: environment.calendar)
        WorkDatePicker(title: "종료일 포함", value: Binding(get: { surface.filterEnd ?? end }, set: {
            surface.filterEnd = $0; applyDates()
        }), calendar: environment.calendar)
    }

    private var emptyResults: some View {
        let action: (() -> Void)?
        let actionTitle: String?
        if surface.scope != .secret && activeFilterCount > 0 {
            action = { resetFilters() }
            actionTitle = "필터 초기화"
        } else {
            action = nil
            actionTitle = nil
        }
        return StateView(kind: query.isEmpty ? StateView.Kind.empty : StateView.Kind.noResults,
            title: emptyTitle, detail: emptyDetail,
            actionTitle: actionTitle, action: action)
    }

    private var emptyTitle: String {
        switch surface.scope {
        case .all: return query.isEmpty ? "찾을 기록이나 Secret 제목을 입력하세요" : "일치하는 검색 결과가 없습니다"
        case .records: return query.isEmpty ? "찾을 메모나 진행 기록을 입력하세요" : "일치하는 기록이 없습니다"
        case .tasks: return query.isEmpty ? "찾을 업무를 입력하세요" : "일치하는 업무가 없습니다"
        case .reports: return query.isEmpty ? "찾을 리포트를 입력하세요" : "일치하는 리포트가 없습니다"
        case .secret: return query.isEmpty ? "찾을 Secret 제목을 입력하세요" : "일치하는 Secret 제목이 없습니다"
        }
    }

    private var emptyDetail: String {
        switch surface.scope {
        case .all: return "철자를 확인하거나 검색 범위·필터를 넓혀보세요. Secret은 잠금 중에도 제목을 검색합니다."
        case .records: return "메모와 진행 기록에서 검색합니다. 철자를 확인하거나 필터를 넓혀보세요."
        case .tasks: return "업무에서 검색합니다. 철자를 확인하거나 필터를 넓혀보세요."
        case .reports: return "리포트 본문에서 검색합니다. 철자를 확인하거나 기간 필터를 넓혀보세요."
        case .secret: return "Secret 제목·그룹명에서 검색합니다. 잠금 중에도 제목을 검색할 수 있습니다."
        }
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
        .focusable()
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
        surface.useDates = false
        surface.filterError = nil
        surface.typeFilter = nil
        if surface.scope != .reports { surface.projectFilterIds = []; surface.tagFilterIds = [] }
        surface.filterRange = nil
        updateSearch()
    }

    private func applyDates() {
        surface.filterError = nil
        if !surface.useDates { surface.filterRange = nil; updateSearch(); return }
        guard let start = surface.filterStart, let end = surface.filterEnd, start <= end else {
            surface.filterError = "종료일은 시작일보다 빠를 수 없습니다."; return
        }
        surface.filterRange = DateRange(start: start, endExclusive: environment.calendar.adding(days: 1, to: end))
        updateSearch()
    }

    private func togglePreview() {
        guard isActive, selectedRecordHit != nil else { return }
        surface.previewVisible.toggle()
        model.isPreviewVisible = surface.previewVisible
    }

    @ViewBuilder private var sourceSheet: some View {
        if let detail = sourceMemoDetail {
            memoSourceSheet(detail)
        } else if let detail = sourceTaskDetail {
            taskSourceSheet(detail)
        } else {
            readOnlySourceSheet
        }
    }

    private func memoSourceSheet(_ detail: MemoDetailModel) -> MemoDetailScreen {
        let saveBody: (String) throws -> Void = { body in
            try saveSourceMemo(body: body, detail: detail)
        }
        return MemoDetailScreen(model: detail, onClose: closeSource,
            onSaveBody: saveBody, initiallyEditing: true)
    }

    private func saveSourceMemo(body: String, detail: MemoDetailModel) throws {
        guard let memo = detail.memo else { throw WorkLogError.notFound("memo") }
        _ = try environment.repo.updateMemoBody(id: memo.id, body: body, workDate: memo.workDate)
        detail.load(id: memo.id)
        updateSearch()
    }

    private func taskSourceSheet(_ detail: TaskDetailModel) -> some View {
        TaskDetailScreen(model: detail, onClose: closeSource)
            .buttonStyle(.bordered)
            .frame(minWidth: 560, minHeight: 480)
    }

    private var readOnlySourceSheet: SourceRecordSheet {
        let editAction: (() -> Void)?
        if let source, source.sourceType != .report, sourceBody != nil {
            editAction = { editSource() }
        } else {
            editAction = nil
        }
        let title: String = source.map { sourceLabel($0.sourceType) } ?? "기록"
        return SourceRecordSheet(bodyText: sourceBody, error: sourceError,
            snippet: source?.snippet ?? "", sourceTitle: title,
            workDate: source?.workDate, onClose: closeSource, onEdit: editAction)
    }

    private func closeSource() { source = nil }

    private func editSource() {
        guard let hit = source else { return }
        switch hit.sourceType {
        case .memo:
            let detail = MemoDetailModel(environment: environment)
            detail.load(id: hit.sourceId)
            sourceMemoDetail = detail
        case .task, .activity:
            do {
                let taskId: String?
                if hit.sourceType == .task { taskId = hit.sourceId }
                else { taskId = try hit.taskId ?? environment.repo.activity(id: hit.sourceId)?.taskId }
                guard let taskId else { sourceError = "업무가 없거나 삭제되었습니다."; return }
                let detail = TaskDetailModel(environment: environment)
                detail.load(taskId: taskId)
                sourceTaskDetail = detail
            } catch { sourceError = "업무를 불러오지 못했습니다. 다시 시도하세요." }
        case .report: break
        }
    }

    private func openSource(_ hit: SearchHit, editing: Bool = false) {
        sourceOpenedFromQuery = focused
        source = hit; sourceBody = nil; sourceError = nil
        sourceMemoDetail = nil; sourceTaskDetail = nil
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
        if editing, sourceBody != nil { editSource() }
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

/// Observe modifiers without consuming events or involving the query field/IME.
@MainActor private struct SearchScopeShortcutMonitor: NSViewRepresentable {
    let modifier: NSEvent.ModifierFlags
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.modifier = modifier
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.modifier = modifier
        view.onChange = onChange
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stopMonitoring() }

    final class MonitorView: NSView {
        var modifier: NSEvent.ModifierFlags = .control
        var onChange: ((Bool) -> Void)?
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        private var isShowing = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                MainActor.assumeIsolated { self?.refresh(flags: event.modifierFlags) }
                return event
            }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publish(false) }
            })
            observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification,
                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publish(false) }
            })
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification,
                object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(flags: NSEvent.modifierFlags) }
            })
            // A panel may appear while its opening shortcut is still held down.
            DispatchQueue.main.async { [weak self] in self?.refresh(flags: NSEvent.modifierFlags) }
        }

        private func refresh(flags: NSEvent.ModifierFlags) {
            // Check the key window rather than NSApp.isActive for the non-activating panel.
            let eligible = window?.isKeyWindow == true && window?.isVisible == true
                && window?.attachedSheet == nil && !isHiddenOrHasHiddenAncestor
            publish(eligible && flags.contains(modifier))
        }

        private func publish(_ value: Bool) {
            guard isShowing != value else { return }
            isShowing = value
            onChange?(value)
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
        }
    }
}

/// Observe the hosting window rather than app activation: the hotkey panel is non-activating.
@MainActor private struct SearchWindowActivityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: WindowView, context: Context) { view.onChange = onChange }
    static func dismantleNSView(_ view: WindowView, coordinator: ()) { view.stopObserving() }

    final class WindowView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification,
                object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.publishActivity(keyWindow: notification.object as? NSWindow)
                }
            })
            observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification,
                object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, self.ownsKeyWindow(notification.object as? NSWindow) else { return }
                    self.onChange?(false)
                }
            })
            // Attachment can happen during a SwiftUI update, before onAppear.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.publishActivity(keyWindow: NSApp.keyWindow)
            }
        }

        private func publishActivity(keyWindow: NSWindow?) {
            onChange?(window?.isVisible == true && !isHiddenOrHasHiddenAncestor && ownsKeyWindow(keyWindow))
        }

        private func ownsKeyWindow(_ candidate: NSWindow?) -> Bool {
            guard let window else { return false }
            var current = candidate
            while let keyWindow = current {
                if keyWindow === window { return true }
                // Keep this screen's filters and source sheet associated with their owner.
                current = keyWindow.sheetParent ?? keyWindow.parent
            }
            return false
        }

        func stopObserving() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
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
    var onEdit: (() -> Void)? = nil

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
                if let onEdit {
                    Button(sourceTitle == "메모" ? "본문 편집" : "업무 관리", action: onEdit)
                        .buttonStyle(.bordered)
                        .keyboardShortcut("e", modifiers: .command)
                        .worklogHelp(sourceTitle == "메모" ? "저장된 메모 편집" : "업무 상태·진행 기록 관리", keys: "⌘E")
                }
                Button("닫기", action: onClose)
                    .buttonStyle(.bordered)
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
