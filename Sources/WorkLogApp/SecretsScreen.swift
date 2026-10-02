#if os(macOS)
import SwiftUI
import AppKit
import WorkLogCore

struct SecretsScreen: View {
    @Bindable var model: SecretsModel
    let calendar: WorkCalendar
    @State private var showsTrash = false
    @State private var purgeId: String?
    @State private var confirmsVersion = false
    @State private var confirmsTrash = false
    @State private var pendingItem: SecretMetadata?
    @State private var pendingNew = false
    @State private var confirmsLeaving = false
    @FocusState private var titleFocused: Bool
    private enum CellFocus: Hashable { case key(String), value(String) }
    @FocusState private var cellFocused: CellFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.isLocked ? "잠긴 보관함" : "보관함 열림", systemImage: model.isLocked ? "lock.fill" : "lock.open")
                Spacer()
                if model.isUnlocking { ProgressView().controlSize(.small) }
                Button(model.isLocked ? "기기 인증으로 열기" : "지금 잠금") {
                    if model.isLocked { Task { await model.unlock() } } else { model.lock() }
                }.disabled(model.isUnlocking)
            }
            if let message = model.message { InlineNotice(message: message) }
            if model.hasRecoverableDraft && !model.isLocked {
                VStack(alignment: .leading, spacing: 8) {
                    Text("저장하지 않은 암호화 초안이 있습니다. 제목·그룹·편집한 행을 복구할 수 있습니다.")
                    HStack {
                        Button("초안 복구") { model.recoverDraft() }
                        Button("초안 버리기", role: .destructive) { confirmsDiscardDraft = true }
                    }
                }
            }
            GeometryReader { geometry in
                if geometry.size.width < 740 {
                    VStack(spacing: 12) {
                        titleList.frame(height: 190)
                        editor
                    }
                } else {
                    HSplitView {
                        titleList.frame(minWidth: 190, idealWidth: 240, maxWidth: 300)
                        editor.frame(minWidth: 400)
                    }
                }
            }
        }.padding(16).navigationTitle("Secret")
        .onAppear { model.tick(); model.searchTitles(); handleNewEntryRequest() }
        .onChange(of: model.requestsNewEntry) { _, _ in handleNewEntryRequest() }
        .onChange(of: model.isLocked) { _, _ in handleNewEntryRequest() }
        .onChange(of: model.hasRecoverableDraft) { _, _ in handleNewEntryRequest() }
        .onDisappear { model.showsValues = false }
        .alert("현재 보관함에서 영구 삭제할까요?", isPresented: Binding(
            get: { purgeId != nil }, set: { if !$0 { purgeId = nil } })) {
            Button("취소", role: .cancel) { purgeId = nil }
            Button("영구 삭제", role: .destructive) { if let id = purgeId { model.purge(id) }; purgeId = nil }
        } message: { Text("현재 항목과 모든 버전을 삭제합니다. 과거 백업에는 남을 수 있습니다.") }
        .alert("선택한 버전을 복원할까요?", isPresented: $confirmsVersion) {
            Button("취소", role: .cancel) {}
            Button("버전 복원") { model.restoreSelectedRevision() }
        } message: { Text("선택한 내용을 새 버전으로 저장합니다. 현재 편집 중인 변경은 버립니다.") }
        .alert("휴지통으로 옮길까요?", isPresented: $confirmsTrash) {
            Button("취소", role: .cancel) {}
            Button("휴지통으로 이동", role: .destructive) { model.moveToTrash() }
        } message: { Text("항목 전체와 이전 버전을 함께 이동합니다. 휴지통에서 복원할 수 있습니다.") }
        .alert("편집한 행을 저장할까요?", isPresented: $confirmsLeaving) {
            Button("계속 편집", role: .cancel) { pendingItem = nil; pendingNew = false }
            Button("저장하고 이동") { if model.save() { finishNavigation() } }
            Button("변경 버리고 이동", role: .destructive) { model.discardDraft(); finishNavigation() }
        } message: { Text("현재 표의 변경을 저장하거나 버린 후 다른 항목을 여세요.") }
        .alert("암호화 초안을 버릴까요?", isPresented: $confirmsDiscardDraft) {
            Button("취소", role: .cancel) {}
            Button("초안 버리기", role: .destructive) { model.discardDraft() }
        } message: { Text("저장하지 않은 행을 복구할 수 없게 됩니다.") }
    }
    @State private var confirmsDiscardDraft = false
    private var titleList: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("제목 검색", text: $model.query).textFieldStyle(.roundedBorder)
                .accessibilityHint("잠금 중에도 제목만 검색합니다")
            if !model.isLocked {
                HStack {
                    Button("새 항목", systemImage: "plus") { navigate(to: nil) }
                        .disabled(model.hasRecoverableDraft)
                    Toggle("휴지통", isOn: $showsTrash).toggleStyle(.button)
                }
            }
            List {
                if showsTrash && !model.isLocked {
                    if model.trashItems.isEmpty { Text("휴지통이 비어 있습니다.").foregroundStyle(.secondary) }
                    ForEach(model.trashItems) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title)
                            HStack {
                                Button("복원") { model.restoreTrash(item.id) }
                                Button("영구 삭제…", role: .destructive) { purgeId = item.id }
                            }
                        }.padding(.vertical, 4)
                    }
                } else {
                    if model.titles.isEmpty {
                        Text(model.query.isEmpty ? "아직 보관 항목이 없습니다." : "일치하는 제목이 없습니다.").foregroundStyle(.secondary)
                    }
                    ForEach(model.titles) { item in
                        Button {
                            if model.isLocked {
                                Task { await model.unlock(); if !model.isLocked && !model.hasRecoverableDraft { model.open(item) } }
                            } else { navigate(to: item) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).fontWeight(model.selectedId == item.id ? .semibold : .regular)
                                if let group = item.groupName { Text(group).font(.caption).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).padding(.vertical, 4)
                            .disabled(model.isUnlocking || model.hasRecoverableDraft)
                    }
                }
            }
        }
    }
    @ViewBuilder private var editor: some View {
        if model.isLocked {
            EmptyMessage(title: "값은 잠겨 있습니다", detail: "제목을 선택하거나 ‘기기 인증으로 열기’를 누르세요. 값 열람·복사·편집은 인증 후 사용할 수 있습니다.")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("제목 (비우면 임시 제목)", text: $model.title).focused($titleFocused)
                    TextField("그룹 (선택 사항)", text: $model.groupName)
                    HStack {
                        Text("key / value").font(.headline)
                        Spacer()
                        Toggle("값 표시", isOn: $model.showsValues).toggleStyle(.checkbox)
                    }
                    Text("Tab 셀 이동 · ⌘Return 저장. 행의 복사 버튼으로 값을 복사하세요. key·값의 앞뒤 공백은 저장 시 제거합니다.")
                        .font(.callout).foregroundStyle(.secondary)
                    if model.rows.isEmpty { Text("‘행 추가’ 또는 붙여넣기로 값을 입력하세요.").foregroundStyle(.secondary) }
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach($model.rows) { $row in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .top, spacing: 8) {
                                    TextField("key", text: $row.key).frame(minWidth: 90, idealWidth: 140, maxWidth: 180)
                                        .accessibilityLabel("행 \(row.order + 1) key")
                                        .focused($cellFocused, equals: .key(row.id))
                                        .onKeyPress(.tab, phases: .down) { moveCell(from: .key(row.id), backwards: $0.modifiers.contains(.shift)) }
                                    if model.showsValues {
                                        TextField("값", text: $row.value, axis: .vertical).lineLimit(1...6)
                                            .accessibilityLabel("행 \(row.order + 1) 값")
                                            .focused($cellFocused, equals: .value(row.id))
                                            .onKeyPress(.tab, phases: .down) { moveCell(from: .value(row.id), backwards: $0.modifiers.contains(.shift)) }
                                    } else {
                                        SecureField("값", text: $row.value).accessibilityLabel("행 \(row.order + 1) 가려진 값")
                                            .focused($cellFocused, equals: .value(row.id))
                                            .onKeyPress(.tab, phases: .down) { moveCell(from: .value(row.id), backwards: $0.modifiers.contains(.shift)) }
                                    }
                                    Button("복사") { model.copyRow(row) }
                                    Button { model.removeRow(row.id) } label: { Image(systemName: "minus.circle") }
                                        .accessibilityLabel("행 \(row.order + 1) 삭제")
                                }
                                if model.duplicateRowIds.contains(row.id) {
                                    Label("중복 key · 수정 후 저장하세요", systemImage: "exclamationmark.circle")
                                        .font(.caption).foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    Button("행 추가", systemImage: "plus") { model.addRow() }
                    Divider()
                    DisclosureGroup("여러 줄 붙여넣기") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("A=B 또는 A : B 형식의 텍스트를 붙여 넣으세요. 첫 구분자 뒤는 값 전체로 보존합니다.").foregroundStyle(.secondary)
                            if model.showsValues {
                                TextEditor(text: $model.pasteText).frame(height: 90).accessibilityLabel("붙여넣을 텍스트")
                            } else {
                                SecureField("여러 줄 텍스트 붙여넣기", text: $model.pasteText)
                            }
                            HStack {
                                Button("클립보드에서 분리 미리보기") {
                                    // Explicit native paste input; retain every newline without a single-line field conversion.
                                    guard !model.isLocked, let text = NSPasteboard.general.string(forType: .string) else { return }
                                    model.acceptPaste(text)
                                }
                                Button("입력 분리 미리보기") { model.makePastePreview() }.disabled(model.pasteText.isEmpty)
                            }
                            ForEach(model.preview.indices, id: \.self) { index in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        TextField("자동 key", text: $model.preview[index].input.key).frame(maxWidth: 180)
                                        if model.showsValues {
                                            TextField("값", text: $model.preview[index].input.value, axis: .vertical)
                                        } else { SecureField("가려진 값", text: $model.preview[index].input.value) }
                                    }
                                    if model.preview[index].ambiguous {
                                        Label("구분이 모호해 원문 전체를 값으로 보존했습니다. 확인하세요.", systemImage: "exclamationmark.circle")
                                            .font(.caption)
                                    }
                                }
                            }
                            if !model.preview.isEmpty {
                                HStack {
                                    Button("표에 행 추가") { model.appendPreview() }
                                    Button("붙여넣기 취소") { model.cancelPreview() }
                                }
                            }
                        }.padding(.top, 8)
                    }
                    HStack {
                        Button("저장") { model.save() }.keyboardShortcut(.return, modifiers: .command)
                        if model.selectedId != nil {
                            Button("휴지통으로 이동…", role: .destructive) { confirmsTrash = true }
                        }
                    }
                    if !model.revisions.isEmpty {
                        Divider()
                        DisclosureGroup("이전 버전 (\(model.revisions.count))") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(model.revisions, id: \.id) { revision in
                                    Button("버전 \(revision.version) · \(revision.createdAt.formatted(Date.FormatStyle(date: .numeric, time: .shortened, timeZone: calendar.timeZone)))") {
                                        model.selectRevision(revision)
                                    }
                                }
                                if model.selectedRevisionId != nil {
                                    ForEach(model.revisionRows) { row in
                                        HStack(alignment: .top) {
                                            Text(row.key)
                                            Spacer()
                                            Text(model.showsValues ? row.value : "•••")
                                        }
                                    }
                                    Button("선택한 버전 복원…") { confirmsVersion = true }
                                }
                            }.padding(.top, 8)
                        }
                    }
                }.textFieldStyle(.roundedBorder).padding(12)
                    .disabled(model.hasRecoverableDraft)
            }
        }
    }
    private func handleNewEntryRequest() {
        guard model.requestsNewEntry, !model.isLocked, !model.hasRecoverableDraft else { return }
        model.requestsNewEntry = false
        showsTrash = false
        navigate(to: nil)
    }
    private func moveCell(from cell: CellFocus, backwards: Bool) -> KeyPress.Result {
        let cells = model.rows.flatMap { [CellFocus.key($0.id), .value($0.id)] }
        guard let index = cells.firstIndex(of: cell) else { return .ignored }
        let next = index + (backwards ? -1 : 1)
        guard cells.indices.contains(next) else { return .ignored }
        cellFocused = cells[next]
        return .handled
    }
    private func navigate(to item: SecretMetadata?) {
        pendingItem = item; pendingNew = item == nil
        if model.hasUnsavedRows { confirmsLeaving = true } else { finishNavigation() }
    }
    private func finishNavigation() {
        if let pendingItem { model.open(pendingItem) }
        else if pendingNew { model.beginNew(); titleFocused = true }
        pendingItem = nil; pendingNew = false
    }
}
#endif
