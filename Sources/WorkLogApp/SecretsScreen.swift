#if os(macOS)
import AppKit
import SwiftUI
import WorkLogCore

@MainActor struct SecretsScreen: View {
    @Bindable var model: SecretsModel
    let calendar: WorkCalendar
    @State private var showsTrash = false
    @State private var confirmsVersion = false
    @State private var confirmsTrash = false
    @State private var pendingItem: SecretMetadata?
    @State private var pendingNew = false
    @State private var lockedSelection: SecretMetadata?
    @State private var newAfterUnlock = false
    @State private var confirmsLeaving = false
    @State private var confirmsCancel = false
    @State private var confirmsDiscardDraft = false
    @State private var titleFocusRequest = 0
    @State private var isActive = false

    private var canUseEditor: Bool {
        !model.isLocked && model.canEdit(from: .main) && !model.hasRecoverableDraft
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: "Secret", purpose: "로컬 보관함 · 제목 검색 후 값 복사") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { headerActions }
                    VStack(alignment: .leading, spacing: 8) { headerActions }
                }
            }
            if let message = model.message { InlineNotice(message: message) }
            if model.hasRecoverableDraft && !model.isLocked && model.canEdit(from: .main) {
                RecoveryNotice(failed: "저장하지 않은 Secret 초안이 있습니다",
                               preserved: "제목·그룹·편집한 행은 암호화해 보존했습니다",
                               retryTitle: "초안 복구", retry: {
                    guard canOwnEditor else { return }
                    model.recoverDraft()
                    if !model.hasRecoverableDraft { lockedSelection = nil; newAfterUnlock = false }
                })
                Button("초안 버리기…", role: .destructive) { confirmsDiscardDraft = true }
            }
            GeometryReader { geometry in
                if geometry.size.width < 740 {
                    VStack(spacing: 12) {
                        titleList.frame(height: 190)
                        detail
                    }
                } else {
                    HSplitView {
                        titleList.frame(minWidth: 190, idealWidth: 240, maxWidth: 300)
                        detail.frame(minWidth: 400)
                    }
                }
            }
        }
        .padding(WorkLogTheme.contentInset).navigationTitle("Secret")
        .onAppear {
            isActive = true
            model.tick()
            if !model.isLocked { _ = model.acquireEditor(.main) }
            model.searchTitles()
        }
        .onChange(of: model.isLocked) { _, locked in
            if locked {
                showsTrash = false
                confirmsCancel = false; confirmsLeaving = false
                confirmsTrash = false; confirmsVersion = false
            } else if isActive { _ = model.acquireEditor(.main) }
        }
        .onDisappear {
            isActive = false
            if model.canEdit(from: .main) { model.showsValues = false }
            model.releaseEditor(.main)
        }
        .sheet(isPresented: $showsTrash) {
            VStack(alignment: .leading, spacing: 12) {
                ScreenHeader(title: "Secret 휴지통", purpose: "항목과 이전 버전을 함께 복원") {
                    Button("닫기") { showsTrash = false }.worklogHelp("휴지통 닫기")
                }
                SecretTrashList(model: model)
            }.padding(16).frame(minWidth: 440, idealWidth: 540, minHeight: 360)
        }
        .alert("선택한 버전을 복원할까요?", isPresented: $confirmsVersion) {
            Button("취소", role: .cancel) {}
            Button("버전 복원") { if canUseEditor { model.restoreSelectedRevision() } }
        } message: { Text("선택한 내용을 새 버전으로 저장합니다. 현재 편집 중인 변경은 버립니다.") }
        .alert("휴지통으로 옮길까요?", isPresented: $confirmsTrash) {
            Button("취소", role: .cancel) {}
            Button("휴지통으로 이동", role: .destructive) { if canUseEditor { model.moveToTrash() } }
        } message: { Text("항목 전체와 이전 버전을 함께 이동합니다. 휴지통에서 복원할 수 있습니다.") }
        .alert("편집한 내용을 저장할까요?", isPresented: $confirmsLeaving) {
            Button("계속 편집", role: .cancel) { pendingItem = nil; pendingNew = false }
            Button("저장하고 이동") { if canUseEditor, save() { finishNavigation() } }
            Button("변경 버리고 이동", role: .destructive) {
                if canUseEditor { model.cancelEditing(); model.discardDraft(); finishNavigation() }
            }
        } message: { Text("제목·그룹·표의 변경을 저장하거나 버린 후 다른 항목을 여세요.") }
        .alert("편집한 변경을 버릴까요?", isPresented: $confirmsCancel) {
            Button("계속 편집", role: .cancel) {}
            Button("변경 버리기", role: .destructive) { cancelEditing() }
        } message: { Text("마지막으로 저장한 제목·그룹·행으로 돌아갑니다.") }
        .alert("암호화 초안을 버릴까요?", isPresented: $confirmsDiscardDraft) {
            Button("취소", role: .cancel) {}
            Button("초안 버리기", role: .destructive) {
                if canOwnEditor {
                    model.discardDraft()
                    resumeLockedSelection()
                }
            }
        } message: { Text("저장하지 않은 제목·그룹·행을 복구할 수 없게 됩니다.") }
    }

    @ViewBuilder private var headerActions: some View {
        StatusBadge(label: model.isLocked ? "잠김" : "잠금 해제됨",
                    systemImage: model.isLocked ? "lock.fill" : "lock.open", tone: .neutral)
        Button("새 Secret", systemImage: "plus") { requestNew() }
            .worklogHelp("새 Secret 입력")
            .disabled(model.isUnlocking || model.hasRecoverableDraft || (!model.isLocked && !model.canEdit(from: .main)))
        Button("휴지통", systemImage: "trash") { showsTrash = true }
            .worklogHelp("Secret 휴지통 열기")
            .disabled(!canUseEditor)
        if !model.isLocked {
            Button("지금 잠금", systemImage: "lock") { model.lock() }.worklogHelp("Secret 보관함 잠금")
        }
    }

    private var titleList: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("제목 검색", text: $model.query).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Secret 제목 검색")
                .accessibilityHint("잠금 중에도 제목만 검색합니다")
            if model.titles.isEmpty {
                if model.query.isEmpty {
                    StateView(kind: .empty, title: "저장된 Secret이 없습니다", detail: "새 Secret을 입력하세요.",
                              actionTitle: "새 Secret", action: requestNew)
                        .disabled(model.isUnlocking || model.hasRecoverableDraft || (!model.isLocked && !model.canEdit(from: .main)))
                } else {
                    StateView(kind: .noResults, title: "일치하는 제목이 없습니다", detail: "제목의 철자를 확인하거나 검색어를 지우세요.",
                              actionTitle: "검색어 지우기", action: { model.query = "" })
                }
                Spacer(minLength: 0)
            } else {
                List {
                    ForEach(model.titles) { item in
                        Button {
                            if model.isLocked { lockedSelection = item; newAfterUnlock = false }
                            else { navigate(to: item) }
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).fixedSize(horizontal: false, vertical: true)
                                    if let group = item.groupName { Text(group).font(.caption).foregroundStyle(WorkLogTheme.muted) }
                                }
                                Spacer(minLength: 0)
                                if selectedTitleId == item.id {
                                    Image(systemName: "checkmark").accessibilityLabel("선택됨")
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(selectedTitleId == item.id ? WorkLogTheme.accentSoft : Color.clear)
                        .disabled(model.isUnlocking || model.hasRecoverableDraft || (!model.isLocked && !model.canEdit(from: .main)))
                    }
                }
            }
        }
    }

    private var selectedTitleId: String? { model.isLocked ? lockedSelection?.id : model.selectedId }

    @ViewBuilder private var detail: some View {
        if model.isLocked {
            VStack(alignment: .leading, spacing: 12) {
                if let lockedSelection { Text(lockedSelection.title).font(.headline) }
                StateView(kind: model.isUnlocking ? .loading : .empty,
                          title: model.isUnlocking ? "잠금 해제 중…" : "값은 잠겨 있습니다",
                          detail: "기기 인증 한 번으로 값 조회·복사·편집을 사용할 수 있습니다.")
                Button("잠금 해제") { unlock() }.buttonStyle(.borderedProminent)
                    .disabled(model.isUnlocking).worklogHelp("기기 인증으로 Secret 잠금 해제")
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if !model.canEdit(from: .main) {
            StateView(kind: .failure, title: "빠른 입력창에서 Secret을 편집 중입니다",
                      detail: "입력은 보존됩니다. 빠른 입력창을 닫은 뒤 다시 시도하세요.",
                      actionTitle: "다시 시도", action: {
                if model.acquireEditor(.main) { resumeLockedSelection() }
            }).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if model.isEditing {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SecretEditorView(model: model, host: .main, keyboardMode: .cellNavigation,
                                     onSave: { save() }, titleFocusRequest: titleFocusRequest,
                                     onMoveToTrash: { confirmsTrash = true }, onCancel: requestCancel)
                    versionHistory
                }.padding(12).disabled(model.hasRecoverableDraft)
            }
        } else if model.selectedId != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ScreenHeader(title: model.title, purpose: model.groupName.isEmpty ? "Secret 조회" : model.groupName) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { viewerActions }
                            VStack(alignment: .leading, spacing: 8) { viewerActions }
                        }
                    }
                    SecretViewerTable(model: model)
                    versionHistory
                    Button("휴지통으로 이동…", role: .destructive) { confirmsTrash = true }
                        .worklogHelp("항목과 이전 버전을 휴지통으로 이동")
                }.padding(12).disabled(model.hasRecoverableDraft)
            }
        } else {
            StateView(kind: .empty, title: "제목을 선택하세요", detail: "항목을 열고 행을 클릭하면 값을 복사합니다.")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private var viewerActions: some View {
        SecretValueVisibilityButton(model: model)
        Button("편집", systemImage: "pencil") {
            guard canUseEditor, !hasMarkedText else { return }
            model.showsValues = false
            model.beginEditing()
        }.keyboardShortcut("e", modifiers: .command).worklogHelp("Secret 표 편집", keys: "⌘E")
    }

    @ViewBuilder private var versionHistory: some View {
        if !model.revisions.isEmpty {
            Divider()
            DisclosureGroup("이전 버전 (\(model.revisions.count))") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.revisions, id: \.id) { revision in
                        Button("버전 \(revision.version) · \(revision.createdAt.formatted(Date.FormatStyle(date: .numeric, time: .shortened, timeZone: calendar.timeZone)))") {
                            if canUseEditor { model.selectRevision(revision) }
                        }
                    }
                    if model.selectedRevisionId != nil {
                        SecretValueVisibilityButton(model: model)
                        ForEach(model.revisionRows) { row in
                            HStack(alignment: .top, spacing: 12) {
                                Text(row.key).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                if model.showsValues && canUseEditor {
                                    Text(row.value).textSelection(.disabled).fixedSize(horizontal: false, vertical: true)
                                } else { MaskedValueText() }
                            }
                        }
                        Button("선택한 버전 복원…") { confirmsVersion = true }
                            .worklogHelp("이전 내용을 새 버전으로 복원")
                    }
                }.padding(.top, 8)
            }
        }
    }

    private var canOwnEditor: Bool { isActive && !model.isLocked && model.canEdit(from: .main) }
    private var hasMarkedText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }
    private func unlock() {
        Task {
            await model.unlock()
            guard isActive, !model.isLocked, model.acquireEditor(.main) else { return }
            resumeLockedSelection()
        }
    }
    private func resumeLockedSelection() {
        guard canUseEditor else { return }
        if newAfterUnlock { navigate(to: nil) }
        else if let lockedSelection { navigate(to: lockedSelection) }
        lockedSelection = nil; newAfterUnlock = false
    }
    private func requestNew() {
        if model.isLocked { lockedSelection = nil; newAfterUnlock = true }
        else { navigate(to: nil) }
    }
    private func navigate(to item: SecretMetadata?) {
        guard isActive, canUseEditor else { return }
        if let item, item.id == model.selectedId { return }
        pendingItem = item; pendingNew = item == nil
        if model.hasUnsavedDraft { confirmsLeaving = true } else { finishNavigation() }
    }
    private func finishNavigation() {
        guard isActive, canUseEditor else { return }
        if let pendingItem { model.open(pendingItem) }
        else if pendingNew { model.beginNew(); titleFocusRequest += 1 }
        pendingItem = nil; pendingNew = false
    }
    private func save() -> Bool {
        guard isActive, canUseEditor, !hasMarkedText else { return false }
        return model.save()
    }
    private func requestCancel() {
        guard canUseEditor, !hasMarkedText else { return }
        if model.hasUnsavedDraft { confirmsCancel = true } else { cancelEditing() }
    }
    private func cancelEditing() {
        guard canUseEditor else { return }
        model.showsValues = false
        model.cancelEditing()
        model.discardDraft()
    }
}

/// Reusable by the Secret screen sheet and the sidebar's future trash destination.
/// Claims ownership only when needed; it never releases an enclosing screen's claim.
@MainActor struct SecretTrashList: View {
    @Bindable var model: SecretsModel
    @State private var purgeId: String?
    @State private var ownsClaim = false
    @State private var isActive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusBadge(label: model.isLocked ? "잠김" : "잠금 해제됨",
                        systemImage: model.isLocked ? "lock.fill" : "lock.open", tone: .neutral)
            if let message = model.message { InlineNotice(message: message) }
            if model.isLocked {
                StateView(kind: model.isUnlocking ? .loading : .empty, title: "휴지통이 잠겨 있습니다",
                          detail: "기기 인증 후 항목을 복원하거나 영구 삭제하세요.")
                Button("잠금 해제") { Task { await model.unlock(); prepare() } }
                    .disabled(model.isUnlocking).worklogHelp("Secret 휴지통 잠금 해제")
            } else if !model.canEdit(from: .main) {
                StateView(kind: .failure, title: "빠른 입력창에서 편집 중입니다", detail: "빠른 입력창을 닫은 뒤 다시 시도하세요.",
                          actionTitle: "다시 시도", action: prepare)
            } else if model.hasRecoverableDraft {
                StateView(kind: .failure, title: "저장하지 않은 Secret 초안이 있습니다",
                          detail: "초안은 암호화해 보존했습니다. Secret 화면에서 초안을 복구하거나 버린 뒤 휴지통을 사용하세요.")
            } else if model.trashItems.isEmpty {
                StateView(kind: .empty, title: "휴지통이 비어 있습니다", detail: "휴지통으로 옮긴 Secret과 이전 버전이 여기에 표시됩니다.")
            } else {
                List(model.trashItems) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                        if let group = item.groupName { Text(group).foregroundStyle(WorkLogTheme.muted) }
                        HStack {
                            Button("복원") { if canMutate { model.restoreTrash(item.id) } }
                                .accessibilityLabel(Text("\(item.title) 복원")).worklogHelp("항목과 이전 버전 복원")
                            Button("영구 삭제…", role: .destructive) { purgeId = item.id }
                                .accessibilityLabel(Text("\(item.title) 영구 삭제")).worklogHelp("현재 보관함에서 영구 삭제")
                        }.disabled(!canMutate)
                    }.padding(.vertical, 4)
                }
            }
        }
        .onAppear { isActive = true; model.tick(); prepare() }
        .onChange(of: model.isLocked) { _, locked in
            if locked { purgeId = nil; ownsClaim = false }
            else { prepare() }
        }
        .onDisappear {
            isActive = false
            if ownsClaim { model.releaseEditor(.main) }
            ownsClaim = false
        }
        .alert("현재 보관함에서 영구 삭제할까요?", isPresented: Binding(
            get: { purgeId != nil }, set: { if !$0 { purgeId = nil } })) {
            Button("취소", role: .cancel) { purgeId = nil }
            Button("영구 삭제", role: .destructive) {
                if canMutate, let purgeId { model.purge(purgeId) }
                purgeId = nil
            }
        } message: { Text("현재 항목과 모든 버전을 삭제합니다. 과거 백업에는 남을 수 있습니다.") }
    }

    private var canMutate: Bool { isActive && !model.isLocked && model.canEdit(from: .main) && !model.hasRecoverableDraft }
    private func prepare() {
        guard isActive, !model.isLocked else { return }
        if !model.canEdit(from: .main) { ownsClaim = model.acquireEditor(.main) }
        if model.canEdit(from: .main) { model.loadTrash() }
    }
}
#endif
