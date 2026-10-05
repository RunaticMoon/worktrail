#if os(macOS)
import SwiftUI
import AppKit
import WorkLogCore

// Kept outside SearchModel: titles, queries and key selection never enter the
// ordinary search state, AI input, or an ordinary-storage snapshot.
enum SearchScope: Hashable { case records, secret }

struct SearchSecretSelection {
    var selectedTitleId: String?
    var openedId: String?
    var selectedRowId: String?
}

@MainActor struct SearchSecretScope: View {
    @Bindable var model: SecretsModel
    @Binding var selection: SearchSecretSelection
    var onOpenSecrets: (() -> Void)?
    @State private var openingId: String?
    @State private var isActive = false
    @FocusState private var queryFocused: Bool
    @FocusState private var titleFocus: String?
    @FocusState private var rowFocus: String?

    private var showsKeys: Bool {
        selection.openedId != nil && selection.openedId == model.selectedId && !model.isLocked && !model.hasUnsavedDraft
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Secret 제목 검색", text: $model.query)
                .font(.body).textFieldStyle(.roundedBorder).focused($queryFocused)
                .accessibilityLabel("Secret 제목 검색")
                .accessibilityHint("로컬 제목 검색. AI로 보내지 않습니다")

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.isLocked {
                            Label("Secret 잠김 · 제목을 열면 기기 인증 후 key를 표시합니다", systemImage: "lock.fill")
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                        if model.isUnlocking || openingId != nil { ProgressView("Secret을 여는 중…") }
                        if model.hasUnsavedDraft || model.hasRecoverableDraft {
                            draftNotice
                        }
                        if let message = model.message {
                            Label(message, systemImage: "info.circle")
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                        if showsKeys {
                            keyResults
                        } else {
                            titleResults
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(1)
                }
                .onChange(of: selection.selectedTitleId) { _, id in
                    if let id { proxy.scrollTo("title-" + id) }
                }
                .onChange(of: selection.selectedRowId) { _, id in
                    if let id { proxy.scrollTo("key-" + id) }
                }
                .onAppear {
                    if showsKeys, let id = selection.selectedRowId { proxy.scrollTo("key-" + id) }
                    else if let id = selection.selectedTitleId { proxy.scrollTo("title-" + id) }
                }
            }
        }
        .background(SearchKeyboardBridge(handle: handleKey))
        .onAppear { isActive = true; queryFocused = true; model.searchTitles() }
        .onDisappear { isActive = false }
        .onChange(of: model.query) { _, _ in selection.openedId = nil; selection.selectedRowId = nil }
        .onChange(of: model.isLocked) { _, locked in if locked { selection.openedId = nil; selection.selectedRowId = nil } }
        .onChange(of: model.titles) { _, titles in
            if let id = selection.selectedTitleId, !titles.contains(where: { $0.id == id }) { selection.selectedTitleId = nil }
        }
        .onChange(of: titleFocus) { _, id in if let id { selection.selectedTitleId = id } }
        .onChange(of: rowFocus) { _, id in if let id { selection.selectedRowId = id } }
        .task(id: openingId) {
            guard let id = openingId, let item = model.titles.first(where: { $0.id == id }) else { return }
            defer { openingId = nil }
            guard !model.hasUnsavedDraft, !model.hasRecoverableDraft else { return }
            let requestWindow = NSApp.keyWindow
            if model.isLocked { await model.unlock() }
            // Authentication can suspend while the user changes scopes or resumes editing.
            guard !Task.isCancelled, isActive, requestWindow?.isVisible == true, !model.isLocked,
                  !model.hasUnsavedDraft, !model.hasRecoverableDraft,
                  selection.selectedTitleId == id, model.titles.contains(where: { $0.id == id }) else { return }
            model.open(item)
            if model.selectedId == id {
                selection.openedId = id; selection.selectedRowId = nil; queryFocused = false
            }
        }
    }

    private var draftNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Secret 화면에서 편집 중인 초안이 있습니다", systemImage: "pencil")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            if let onOpenSecrets { Button("Secret 화면 열기", action: onOpenSecrets) }
            else { Text("Secret 화면에서 초안을 저장하거나 정리한 뒤 다시 여세요.").font(.callout) }
        }.worklogCard()
    }

    @ViewBuilder private var titleResults: some View {
        if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("제목을 입력하거나 아래 목록에서 항목을 고르세요.")
                .font(.callout).foregroundStyle(WorkLogTheme.muted)
        }
        if model.titles.isEmpty {
            StateView(kind: .noResults, title: "일치하는 Secret 제목이 없습니다",
                detail: "다른 제목으로 검색하세요. 잠금 중에도 제목 검색은 사용할 수 있습니다.")
        }
        ForEach(model.titles) { item in
            Button { selection.selectedTitleId = item.id; requestOpen(item.id) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label(item.title, systemImage: "lock.doc").font(.body)
                    if let group = item.groupName, !group.isEmpty { Text(group).font(.caption) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .foregroundStyle(selection.selectedTitleId == item.id ? Color(nsColor: .alternateSelectedControlTextColor)
                    : WorkLogTheme.text)
                .background(selection.selectedTitleId == item.id ? Color(nsColor: .selectedContentBackgroundColor)
                    : WorkLogTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selection.selectedTitleId == item.id ? Color(nsColor: .selectedContentBackgroundColor)
                            : WorkLogTheme.border, lineWidth: selection.selectedTitleId == item.id ? 2 : 1)
                }
            }
            .buttonStyle(.plain).focused($titleFocus, equals: item.id)
            .accessibilityLabel(Text([item.title, item.groupName].compactMap { $0 }.joined(separator: ", ")))
            .accessibilityValue(selection.selectedTitleId == item.id ? "선택됨" : "")
            .worklogHelp("Secret key 목록 열기", keys: "Return")
            .id("title-" + item.id)
        }
    }

    private var keyResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.title).font(.headline)
                Spacer()
                Button("제목 목록") { selection.openedId = nil; selection.selectedRowId = nil; queryFocused = true }
            }
            Text("↑↓는 선택 이동 · Return 또는 클릭으로 값 복사. 값 보기는 Secret 화면에서 가능합니다.")
                .font(.callout).foregroundStyle(WorkLogTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if model.rows.isEmpty {
                StateView(kind: .empty, title: "저장된 key가 없습니다", detail: "Secret 화면에서 항목을 편집할 수 있습니다.")
            }
            ForEach(model.rows) { row in
                Button { selection.selectedRowId = row.id; copySelectedRow() } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.key).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                        MaskedValueText()
                        Image(systemName: "doc.on.doc").accessibilityHidden(true)
                    }
                    .padding(10)
                    .foregroundStyle(WorkLogTheme.text)
                    .background(selection.selectedRowId == row.id ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.16)
                        : WorkLogTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(selection.selectedRowId == row.id ? Color(nsColor: .selectedContentBackgroundColor)
                                : WorkLogTheme.border, lineWidth: selection.selectedRowId == row.id ? 2 : 1)
                    }
                }
                .buttonStyle(.plain).focused($rowFocus, equals: row.id)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(row.key), 가려진 값, 값 복사"))
                .accessibilityValue(selection.selectedRowId == row.id ? "선택됨" : "")
                .worklogHelp("값 복사", keys: "Return")
                .id("key-" + row.id)
            }
            if let onOpenSecrets { Button("Secret 화면 열기", action: onOpenSecrets) }
        }
    }

    private func requestOpen(_ id: String) {
        guard !model.isUnlocking, openingId == nil, !model.hasUnsavedDraft, !model.hasRecoverableDraft else { return }
        openingId = id
    }

    private func copySelectedRow() {
        guard showsKeys, let row = model.rows.first(where: { $0.id == selection.selectedRowId }) else { return }
        model.copyRow(row)
    }

    private func activateSelection() {
        if showsKeys { copySelectedRow() }
        else if let id = selection.selectedTitleId { requestOpen(id) }
    }

    private func handleKey(_ event: NSEvent, editingText: Bool) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // Consume the AI chord in this scope without any SearchModel access.
        if modifiers == .command, event.keyCode == 36 || event.keyCode == 76 { return true }
        guard modifiers.isEmpty else { return false }
        if event.keyCode == 125 || event.keyCode == 126 {
            let ids = showsKeys ? model.rows.map(\.id) : model.titles.map(\.id)
            let current = showsKeys ? selection.selectedRowId : selection.selectedTitleId
            guard !ids.isEmpty else { return true }
            let delta = event.keyCode == 125 ? 1 : -1
            let next = current.flatMap { ids.firstIndex(of: $0) }.map { min(max($0 + delta, 0), ids.count - 1) }
                ?? (delta > 0 ? 0 : ids.count - 1)
            if showsKeys { selection.selectedRowId = ids[next]; if !editingText { rowFocus = ids[next] } }
            else { selection.selectedTitleId = ids[next]; if !editingText { titleFocus = ids[next] } }
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if !event.isARepeat { activateSelection() }
            return true
        }
        return false
    }
}
#endif
