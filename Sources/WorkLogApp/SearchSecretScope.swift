#if os(macOS)
import SwiftUI
import AppKit
import WorkLogCore

// App-only identities: Secret metadata and rows never enter SearchModel or its snapshot.
enum SearchScope: Hashable { case all, records, secret }
enum SearchResultSelection: Hashable {
    case record(SearchHitKey)
    case secret(String)
}

struct SearchSecretSelection {
    var selectedTitleId: String?
    var openedId: String?
    var selectedRowId: String?
}

/// The detail step shows keys and masks only. SearchScreen owns the single query and navigation.
@MainActor struct SearchSecretScope: View {
    @Bindable var model: SecretsModel
    @Binding var selection: SearchSecretSelection
    let onBack: () -> Void
    var onOpenSecrets: (() -> Void)?
    @FocusState private var rowFocus: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(model.title).font(.headline)
                        Spacer()
                        Button("검색 결과로 돌아가기", action: onBack)
                            .worklogHelp("검색 결과로 돌아가기", keys: "Esc · ⌘←")
                    }
                    Label("Secret은 AI로 보내지 않습니다", systemImage: "lock.fill")
                        .font(.callout).foregroundStyle(WorkLogTheme.muted)
                    Text("↑↓ 선택 · Return 값 복사 · Esc 또는 ⌘← 검색 결과로 돌아가기")
                        .font(.callout).foregroundStyle(WorkLogTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.rows.isEmpty {
                        StateView(kind: .empty, title: "저장된 key가 없습니다", detail: "Secret 화면에서 항목을 편집할 수 있습니다.")
                    }
                    ForEach(model.rows) { row in
                        Button {
                            selection.selectedRowId = row.id
                            copySelection()
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(row.key).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                                MaskedValueText()
                                Image(systemName: "doc.on.doc").accessibilityHidden(true)
                            }
                            .padding(10)
                            .foregroundStyle(WorkLogTheme.text)
                            .background(selection.selectedRowId == row.id ? WorkLogTheme.accentSoft : WorkLogTheme.surface,
                                in: RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(selection.selectedRowId == row.id ? WorkLogTheme.accent : WorkLogTheme.border,
                                        lineWidth: selection.selectedRowId == row.id ? 2 : 1)
                            }
                        }
                        .buttonStyle(.plain).focused($rowFocus, equals: row.id)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("\(row.key), 가려진 값, 값 복사"))
                        .accessibilityValue(selection.selectedRowId == row.id ? "선택됨" : "")
                        .worklogHelp("값 복사", keys: "Return")
                        .id(row.id)
                    }
                    // SecretsModel uses fixed feedback; never interpolate a value here.
                    if let message = model.message {
                        Label(message, systemImage: "info.circle")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    if let onOpenSecrets { Button("Secret 화면 열기", action: onOpenSecrets) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(1)
            }
            .onChange(of: selection.selectedRowId) { _, id in
                rowFocus = id
                if let id { proxy.scrollTo(id) }
            }
            .onAppear {
                rowFocus = selection.selectedRowId
                if let id = selection.selectedRowId { proxy.scrollTo(id) }
            }
        }
        .onChange(of: rowFocus) { _, id in if let id { selection.selectedRowId = id } }
    }

    private func copySelection() {
        guard !model.isLocked, !model.isEditing, !model.hasUnsavedDraft, !model.hasRecoverableDraft,
              model.selectedId == selection.openedId,
              let row = model.rows.first(where: { $0.id == selection.selectedRowId }) else { return }
        model.copyRow(row)
    }
}
#endif
