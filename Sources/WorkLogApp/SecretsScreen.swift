#if os(macOS)
import SwiftUI
import WorkLogCore

@MainActor struct SecretsScreen: View {
    @Bindable var model: SecretsModel
    let calendar: WorkCalendar
    @State private var showsTrash = false
    @State private var purgeId: String?
    @State private var confirmsVersion = false
    @State private var confirmsTrash = false
    @State private var pendingItem: SecretMetadata?
    @State private var pendingNew = false
    @State private var confirmsLeaving = false
    @State private var titleFocusRequest = 0
    @State private var isActive = false

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
            if model.hasRecoverableDraft && !model.isLocked && model.canEdit(from: .main) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("저장하지 않은 암호화 초안이 있습니다. 제목·그룹·편집한 행을 복구할 수 있습니다.")
                    HStack {
                        Button("초안 복구") { if model.canEdit(from: .main) { model.recoverDraft() } }
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
        .onAppear {
            isActive = true
            model.tick(); _ = model.acquireEditor(.main)
            model.searchTitles(); handleNewEntryRequest()
        }
        .onChange(of: model.requestsNewEntry) { _, _ in handleNewEntryRequest() }
        .onChange(of: model.isLocked) { _, locked in
            if isActive && !locked { _ = model.acquireEditor(.main) }
            handleNewEntryRequest()
        }
        .onChange(of: model.hasRecoverableDraft) { _, _ in handleNewEntryRequest() }
        .onDisappear {
            isActive = false
            if model.canEdit(from: .main) { model.showsValues = false }
            model.releaseEditor(.main)
        }
        .alert("현재 보관함에서 영구 삭제할까요?", isPresented: Binding(
            get: { purgeId != nil }, set: { if !$0 { purgeId = nil } })) {
            Button("취소", role: .cancel) { purgeId = nil }
            Button("영구 삭제", role: .destructive) { if model.canEdit(from: .main), let id = purgeId { model.purge(id) }; purgeId = nil }
        } message: { Text("현재 항목과 모든 버전을 삭제합니다. 과거 백업에는 남을 수 있습니다.") }
        .alert("선택한 버전을 복원할까요?", isPresented: $confirmsVersion) {
            Button("취소", role: .cancel) {}
            Button("버전 복원") { if model.canEdit(from: .main) { model.restoreSelectedRevision() } }
        } message: { Text("선택한 내용을 새 버전으로 저장합니다. 현재 편집 중인 변경은 버립니다.") }
        .alert("휴지통으로 옮길까요?", isPresented: $confirmsTrash) {
            Button("취소", role: .cancel) {}
            Button("휴지통으로 이동", role: .destructive) { if model.canEdit(from: .main) { model.moveToTrash() } }
        } message: { Text("항목 전체와 이전 버전을 함께 이동합니다. 휴지통에서 복원할 수 있습니다.") }
        .alert("편집한 행을 저장할까요?", isPresented: $confirmsLeaving) {
            Button("계속 편집", role: .cancel) { pendingItem = nil; pendingNew = false }
            Button("저장하고 이동") { if model.canEdit(from: .main), model.save() { finishNavigation() } }
            Button("변경 버리고 이동", role: .destructive) { if model.canEdit(from: .main) { model.discardDraft(); finishNavigation() } }
        } message: { Text("현재 표의 변경을 저장하거나 버린 후 다른 항목을 여세요.") }
        .alert("암호화 초안을 버릴까요?", isPresented: $confirmsDiscardDraft) {
            Button("취소", role: .cancel) {}
            Button("초안 버리기", role: .destructive) { if model.canEdit(from: .main) { model.discardDraft() } }
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
                        .disabled(model.hasRecoverableDraft || !model.canEdit(from: .main))
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
                                Button("복원") { if model.canEdit(from: .main) { model.restoreTrash(item.id) } }
                                Button("영구 삭제…", role: .destructive) { purgeId = item.id }
                            }
                        }.padding(.vertical, 4).disabled(!model.canEdit(from: .main))
                    }
                } else {
                    if model.titles.isEmpty {
                        Text(model.query.isEmpty ? "아직 보관 항목이 없습니다." : "일치하는 제목이 없습니다.").foregroundStyle(.secondary)
                    }
                    ForEach(model.titles) { item in
                        Button {
                            if model.isLocked {
                                Task {
                                    await model.unlock()
                                    if isActive && !model.isLocked && model.acquireEditor(.main) && !model.hasRecoverableDraft {
                                        navigate(to: item)
                                    }
                                }
                            } else { navigate(to: item) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).fontWeight(model.selectedId == item.id ? .semibold : .regular)
                                if let group = item.groupName { Text(group).font(.caption).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).padding(.vertical, 4)
                            .disabled(model.isUnlocking || model.hasRecoverableDraft || (!model.isLocked && !model.canEdit(from: .main)))
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
            VStack(alignment: .leading, spacing: 8) {
                if !model.canEdit(from: .main) {
                    Button("다시 시도") {
                        if model.acquireEditor(.main) { handleNewEntryRequest() }
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        SecretEditorView(model: model, host: .main, keyboardMode: .cellNavigation,
                            onSave: { model.canEdit(from: .main) && model.save() },
                            titleFocusRequest: titleFocusRequest, onMoveToTrash: { confirmsTrash = true })
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
                                                Text(model.showsValues && model.canEdit(from: .main) ? row.value : "•••")
                                            }
                                        }
                                        Button("선택한 버전 복원…") { confirmsVersion = true }
                                    }
                                }.padding(.top, 8)
                            }
                        }
                    }.textFieldStyle(.roundedBorder).padding(12)
                        .disabled(model.hasRecoverableDraft || !model.canEdit(from: .main))
                }
            }
        }
    }
    private func handleNewEntryRequest() {
        guard isActive, model.canEdit(from: .main), model.requestsNewEntry, !model.isLocked, !model.hasRecoverableDraft else { return }
        model.requestsNewEntry = false
        showsTrash = false
        navigate(to: nil)
    }
    private func navigate(to item: SecretMetadata?) {
        guard isActive, model.canEdit(from: .main), !model.isLocked, !model.hasRecoverableDraft else { return }
        pendingItem = item; pendingNew = item == nil
        if model.hasUnsavedRows { confirmsLeaving = true } else { finishNavigation() }
    }
    private func finishNavigation() {
        guard isActive, model.canEdit(from: .main), !model.isLocked, !model.hasRecoverableDraft else { return }
        if let pendingItem { model.open(pendingItem) }
        else if pendingNew { model.beginNew(); titleFocusRequest += 1 }
        pendingItem = nil; pendingNew = false
    }
}
#endif
