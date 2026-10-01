import Foundation
import Observation

/// Local-only editor. All value access goes through the authenticated session.
@Observable @MainActor public final class SecretsModel {
    public var query = "" { didSet { searchTitles() } }
    public private(set) var titles: [SecretMetadata] = []
    public private(set) var trashItems: [SecretMetadata] = []
    public private(set) var isLocked = true
    public private(set) var isUnlocking = false
    public private(set) var message: String?
    public private(set) var selectedId: String?
    public private(set) var revisions: [SecretRevisionInfo] = []
    public private(set) var revisionRows: [SecretRow] = []
    public private(set) var selectedRevisionId: String?
    public private(set) var duplicateRowIds: Set<String> = []
    public private(set) var hasRecoverableDraft = false
    public var requestsNewEntry = false
    public var title = "" { didSet { preserveDraft() } }
    public var groupName = "" { didSet { preserveDraft() } }
    public var showsValues = false
    public var rows: [SecretRow] = [] { didSet { preserveDraft() } }
    public var pasteText = "" { didSet { preserveDraft() } }
    public var preview: [PastedRow] = [] { didSet { preserveDraft() } }
    @ObservationIgnored private var environment: AppEnvironment?
    @ObservationIgnored private var originalRows: [SecretRow] = []
    @ObservationIgnored private var originalTitle = ""
    @ObservationIgnored private var originalGroup = ""
    // Presentation-owned envelope inside the existing encrypted draft slot. Never sent to ordinary storage.
    private struct DraftPreview: Codable {
        var key: String
        var value: String
        var ambiguous: Bool
    }
    private struct EditorDraft: Codable {
        var selectedId: String?
        var title: String
        var group: String
        var originalRows: [SecretRow]
        var originalTitle: String
        var originalGroup: String
        var rows: [SecretRow]
        var pasteText: String
        var preview: [DraftPreview]
    }
    private static let draftEnvelopeId = "worklog.secret.editor-draft.v1"
    @ObservationIgnored private var suppressDraft = false
    @ObservationIgnored private var recoveredDraft: SecretPayload?
    public var clipboardClearSeconds: Int { environment?.settings.clipboardClearSeconds ?? 120 }
    public var hasUnsavedRows: Bool { rows != originalRows || title != originalTitle || groupName != originalGroup || !preview.isEmpty || !pasteText.isEmpty }

    public init(environment: AppEnvironment) {
        self.environment = environment
        environment.vaultSession.onLock = { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.synchronizeLock() }
            } else {
                Task { @MainActor [weak self] in self?.synchronizeLock() }
            }
        }
        searchTitles()
        synchronizeLock()
    }

    public func searchTitles() {
        guard let environment else { return }
        do { titles = try environment.vaultSession.searchTitles(query) }
        catch { message = "제목 목록을 불러오지 못했습니다. 다시 시도하세요." }
    }
    public func tick() {
        environment?.vaultSession.checkIdle()
        environment?.clipboard.tick()
        synchronizeLock()
    }
    public func synchronizeLock() {
        let locked = environment?.vaultSession.state != .unlocked
        if isLocked != locked { isLocked = locked }
        if locked && (selectedId != nil || !rows.isEmpty || !originalRows.isEmpty || !preview.isEmpty ||
            !pasteText.isEmpty || !revisionRows.isEmpty || !revisions.isEmpty || recoveredDraft != nil ||
            hasRecoverableDraft || showsValues || !title.isEmpty || !groupName.isEmpty || !trashItems.isEmpty) {
            conceal()
        }
    }
    private func conceal() {
        suppressDraft = true
        rows = []; originalRows = []; preview = []; pasteText = ""
        revisions = []; revisionRows = []; selectedRevisionId = nil
        recoveredDraft = nil; hasRecoverableDraft = false
        selectedId = nil; title = ""; groupName = ""; originalTitle = ""; originalGroup = ""; showsValues = false
        duplicateRowIds = []; trashItems = []
        suppressDraft = false
    }
    private func requireUnlocked() -> AppEnvironment? {
        synchronizeLock()
        guard !isLocked, let environment else {
            message = "보관함이 잠겨 있습니다. 기기 인증 후 다시 시도하세요."
            return nil
        }
        return environment
    }
    public func unlock() async {
        guard !isUnlocking, let environment else { return }
        isUnlocking = true
        defer { isUnlocking = false }
        do {
            try await environment.vaultSession.unlock(reason: "Secret 보관함 열기")
            synchronizeLock()
            recoveredDraft = try environment.vaultSession.loadDraft()
            hasRecoverableDraft = recoveredDraft != nil
            message = nil
            loadTrash()
        } catch { fail(error) }
    }
    public func lock() { environment?.lockSecrets(.manual); synchronizeLock() }
    public func detach() { lock(); environment = nil }

    public func beginNew() {
        guard requireUnlocked() != nil else { return }
        replaceEditor(id: nil, title: "", group: "", items: [])
        message = nil
    }
    /// The screen handles authentication and any existing encrypted draft before navigation.
    public func requestNewEntry() { synchronizeLock(); requestsNewEntry = true }
    public func open(_ item: SecretMetadata) {
        guard let environment = requireUnlocked() else { return }
        do {
            let items = try environment.vaultSession.currentRows(secretId: item.id)
            replaceEditor(id: item.id, title: item.title, group: item.groupName ?? "", items: items)
            revisions = try environment.vaultSession.revisions(secretId: item.id)
            message = nil
        } catch { fail(error) }
    }
    private func replaceEditor(id: String?, title: String, group: String, items: [SecretRow]) {
        suppressDraft = true
        selectedId = id; self.title = title; groupName = group
        originalRows = items; originalTitle = title; originalGroup = group
        rows = items; pasteText = ""; preview = []
        duplicateRowIds = []; revisions = []; revisionRows = []; selectedRevisionId = nil
        showsValues = false
        suppressDraft = false
    }
    public func recoverDraft() {
        guard let environment = requireUnlocked(), let recoveredDraft else { return }
        do {
            let envelope = recoveredDraft.items.first
            let saved = envelope?.id == Self.draftEnvelopeId
                ? try StableJSON.decode(EditorDraft.self, from: Data((envelope?.value ?? "").utf8)) : nil
            suppressDraft = true
            if let saved {
                var id = saved.selectedId
                if let candidate = id {
                    let latest = try? environment.vaultSession.currentRows(secretId: candidate)
                    let deleted = (try? environment.vaultSession.trash().contains { $0.id == candidate }) ?? true
                    if latest != saved.originalRows || deleted { id = nil }
                }
                replaceEditor(id: id, title: saved.title, group: saved.group, items: id == nil ? [] : saved.originalRows)
                suppressDraft = true
                originalTitle = id == nil ? "" : saved.originalTitle
                originalGroup = id == nil ? "" : saved.originalGroup
                rows = saved.rows; pasteText = saved.pasteText
                preview = saved.preview.map { PastedRow(input: SecretRowInput(key: $0.key, value: $0.value), ambiguous: $0.ambiguous) }
                if let id { revisions = try environment.vaultSession.revisions(secretId: id) }
            } else {
                replaceEditor(id: nil, title: "복구한 초안", group: "", items: [])
                suppressDraft = true; rows = recoveredDraft.items
            }
            self.recoveredDraft = nil; hasRecoverableDraft = false
            suppressDraft = false
            message = "암호화 초안을 복구했습니다. 제목·그룹·행을 확인하고 저장하세요. 원래 항목이 변경되었으면 새 항목으로 보존합니다."
        } catch { suppressDraft = false; fail(error) }
    }
    public func discardDraft() {
        guard let environment = requireUnlocked() else { return }
        do { try environment.vaultSession.clearDraft(); recoveredDraft = nil; hasRecoverableDraft = false }
        catch { fail(error) }
    }
    public func addRow() {
        guard let environment = requireUnlocked() else { return }
        rows.append(SecretRow(id: environment.options.ids.make(), key: "", value: "", order: rows.count))
    }
    public func removeRow(_ id: String) {
        guard requireUnlocked() != nil else { return }
        rows.removeAll { $0.id == id }
    }
    public func acceptPaste(_ text: String) {
        guard requireUnlocked() != nil else { return }
        pasteText = text
        makePastePreview()
    }
    public func makePastePreview() {
        guard requireUnlocked() != nil else { return }
        suppressDraft = true
        preview = SecretPasteParser.parse(pasteText); pasteText = ""
        suppressDraft = false
        preserveDraft()
    }
    public func appendPreview() {
        guard let environment = requireUnlocked() else { return }
        suppressDraft = true
        for item in preview {
            rows.append(SecretRow(id: environment.options.ids.make(), key: item.input.key,
                                  value: item.input.value, order: rows.count))
        }
        preview = []
        suppressDraft = false
        preserveDraft()
    }
    public func cancelPreview() { preview = []; pasteText = "" }
    /// Encrypt every edit without creating a revision or leaving a plaintext temporary file.
    public func preserveDraft() {
        guard !suppressDraft, let environment else { return }
        guard environment.vaultSession.state == .unlocked else { synchronizeLock(); return }
        guard !hasRecoverableDraft else { return }
        do {
            let saved = EditorDraft(selectedId: selectedId, title: title, group: groupName,
                originalRows: originalRows, originalTitle: originalTitle, originalGroup: originalGroup,
                rows: rows, pasteText: pasteText,
                preview: preview.map { DraftPreview(key: $0.input.key, value: $0.input.value, ambiguous: $0.ambiguous) })
            let data = try StableJSON.encode(saved)
            let envelope = SecretRow(id: Self.draftEnvelopeId, key: "", value: String(decoding: data, as: UTF8.self), order: 0)
            try environment.vaultSession.saveDraft(SecretPayload(items: [envelope]))
        } catch { fail(error) }
    }
    @discardableResult public func save() -> Bool {
        guard let environment = requireUnlocked() else { return false }
        guard preview.isEmpty && pasteText.isEmpty else {
            message = "붙여넣기 미리보기를 확인하고 행에 추가한 뒤 저장하세요."; return false
        }
        // Use only local IDs for validation; never consume persisted IDs just to preview.
        let normalized = SecretNormalizer.apply(existing: [], changes: SecretChangeSet(upserts:
            rows.map { SecretRowInput(key: $0.key, value: $0.value) }), ids: SequentialIDGenerator(prefix: "preview"))
        if !normalized.issues.isEmpty {
            let counts = Dictionary(grouping: rows, by: { SecretNormalizer.trim($0.key) })
            duplicateRowIds = Set(counts.filter { !$0.key.isEmpty && $0.value.count > 1 }.values.flatMap { $0.map(\.id) })
            message = "같은 key가 있습니다. 표시된 행의 key를 수정하세요. 모든 값과 행을 보존했습니다."
            return false
        }
        do {
            let inputs = rows.map { row in SecretRowInput(
                id: originalRows.contains(where: { $0.id == row.id }) ? row.id : nil, key: row.key, value: row.value) }
            let id: String
            if let selectedId {
                _ = try environment.vaultSession.save(secretId: selectedId, changes: SecretChangeSet(
                    upserts: inputs, deletedRowIds: originalRows.filter { old in !rows.contains { $0.id == old.id } }.map(\.id)))
                try environment.vaultSession.rename(secretId: selectedId, title: title,
                                                     groupName: groupName.isEmpty ? nil : groupName)
                id = selectedId
            } else {
                id = try environment.vaultSession.create(title: title, groupName: groupName.isEmpty ? nil : groupName,
                                                          rows: inputs).id
            }
            try environment.vaultSession.clearDraft()
            recoveredDraft = nil; hasRecoverableDraft = false
            searchTitles()
            if let item = titles.first(where: { $0.id == id }) { open(item) }
            else {
                let items = try environment.vaultSession.currentRows(secretId: id)
                replaceEditor(id: id, title: title, group: groupName, items: items)
                revisions = try environment.vaultSession.revisions(secretId: id)
            }
            message = "저장했습니다."
            return true
        } catch { fail(error); return false }
    }
    public func copyRow(_ row: SecretRow) {
        guard let environment = requireUnlocked() else { return }
        do {
            if let selectedId, originalRows.contains(row) {
                try environment.vaultSession.copyValue(secretId: selectedId, rowId: row.id, to: environment.clipboard)
            } else { environment.clipboard.copySecret(row.value); preserveDraft() }
            message = "복사했습니다. \(clipboardClearSeconds)초 후 같은 복사 항목이 남아 있을 때만 지웁니다."
        } catch { fail(error) }
    }
    public func selectRevision(_ revision: SecretRevisionInfo) {
        guard let environment = requireUnlocked(), let selectedId else { return }
        do {
            revisionRows = try environment.vaultSession.rows(secretId: selectedId, revisionId: revision.id)
            selectedRevisionId = revision.id; showsValues = false
        } catch { fail(error) }
    }
    public func restoreSelectedRevision() {
        guard let environment = requireUnlocked(), let selectedId, let selectedRevisionId else { return }
        do {
            _ = try environment.vaultSession.restoreRevision(secretId: selectedId, revisionId: selectedRevisionId)
            try environment.vaultSession.clearDraft()
            if let item = titles.first(where: { $0.id == selectedId }) { open(item) }
            searchTitles(); message = "이전 버전을 새 버전으로 복원했습니다."
        } catch { fail(error) }
    }
    public func moveToTrash() {
        guard let environment = requireUnlocked(), let selectedId else { return }
        do {
            try environment.vaultSession.moveToTrash(secretId: selectedId)
            try environment.vaultSession.clearDraft()
            replaceEditor(id: nil, title: "", group: "", items: [])
            searchTitles(); loadTrash(); message = "항목과 버전을 휴지통으로 옮겼습니다."
        } catch { fail(error) }
    }
    public func loadTrash() {
        guard let environment = requireUnlocked() else { return }
        do { trashItems = try environment.vaultSession.trash() } catch { fail(error) }
    }
    public func restoreTrash(_ id: String) {
        guard let environment = requireUnlocked() else { return }
        do { try environment.vaultSession.restoreFromTrash(secretId: id); searchTitles(); loadTrash() }
        catch { fail(error) }
    }
    /// Caller presents a separate destructive confirmation, including the backup limitation.
    public func purge(_ id: String) {
        guard let environment = requireUnlocked() else { return }
        do { try environment.vaultSession.purge(secretId: id); loadTrash(); message = "현재 보관함에서 영구 삭제했습니다. 과거 백업에는 남을 수 있습니다." }
        catch { fail(error) }
    }
    private func fail(_ error: Error) {
        synchronizeLock()
        if let error = error as? WorkLogError, error == .vaultKeyMissing {
            message = "기존 Secret 키가 없습니다. 같은 Mac의 기존 Keychain 키 없이 복구할 수 없습니다."
        } else if isLocked {
            message = "보관함이 잠겨 있습니다. 기기 인증 후 다시 시도하세요."
        } else { message = "요청을 처리하지 못했습니다. 입력은 보존했습니다. 다시 시도하세요." }
    }
}
