#if os(macOS)
import Foundation
import Observation
import WorkLogCore

/// Retained by AppController so navigating away never discards unsaved text.
@Observable @MainActor final class MeetingsModel {
    private var environment: AppEnvironment?
    private var service: MeetingService?
    let calendar: WorkCalendar
    var rows: [Meeting] = []
    var selected: Meeting?
    var title = ""
    var workDate: WorkDate
    var transcript = ""
    var notes = ""
    var summaryDraft = ""
    var query = ""
    var showingDeleted = false
    var message: String?
    var isSummarizing = false
    let speech = MeetingSpeechTranscriber()
    let recorder: MeetingAudioRecorder
    private var audioTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?

    init(environment: AppEnvironment) {
        self.environment = environment
        recorder = MeetingAudioRecorder(directory: environment.options.paths.dataRoot.appendingPathComponent("meeting-audio", isDirectory: true), ids: environment.options.ids)
        service = MeetingService(repo: environment.repo, runner: environment.aiRunner)
        calendar = environment.calendar
        workDate = calendar.workDate(of: environment.options.clock.now())
        reload()
        if let pendingID = recorder.pendingMeetingID,
           let pending = try? service?.meeting(id: pendingID, includeDeleted: true) {
            load(pending)
            showingDeleted = pending.deletedAt != nil
            message = "이전 녹음을 복구했습니다. 전사하거나 내보낸 뒤 삭제할 수 있습니다."
        }
    }
    var isBusy: Bool { speech.isTranscribing || speech.isPreparing || recorder.isRecording || recorder.isStarting || isSummarizing }
    var canSummarize: Bool { environment?.aiRunner != nil && environment?.settings.aiEnabled == true }
    var visibleRows: [Meeting] {
        rows.filter { ($0.deletedAt != nil) == showingDeleted && (query.isEmpty ||
            ($0.title + "\n" + $0.transcript + "\n" + $0.notes).localizedCaseInsensitiveContains(query)) }
    }
    var hasEdits: Bool {
        guard let selected, selected.deletedAt == nil else { return false }
        return selected.title != title || selected.workDate != workDate || selected.transcript != transcript || selected.notes != notes
    }
    var hasSummaryEdits: Bool { selected?.summary != nil && summaryDraft != selected?.summary?.content }
    func reload() {
        do { rows = try service?.meetings(includeDeleted: true) ?? [] }
        catch { show(error) }
    }
    func create() {
        guard !isBusy, recorder.recordingURL == nil, save() else { return }
        do {
            guard let environment, let service else { return }
            let meeting = try service.create(title: "새 회의", workDate: calendar.workDate(of: environment.options.clock.now()), transcript: "", notes: "", memoIDs: [])
            showingDeleted = false; query = ""; load(meeting); reload()
        } catch { show(error) }
    }
    func select(_ id: String) {
        guard !isBusy, recorder.recordingURL == nil, selected?.id != id, save() else { return }
        do { if let meeting = try service?.meeting(id: id, includeDeleted: true) { load(meeting) } }
        catch { show(error) }
    }
    private func load(_ meeting: Meeting) {
        selected = meeting; title = meeting.title; workDate = meeting.workDate
        transcript = meeting.transcript; notes = meeting.notes; summaryDraft = meeting.summary?.content ?? ""
        message = nil
    }
    @discardableResult func save() -> Bool {
        guard var selected, selected.deletedAt == nil, let service else { return true }
        do {
            if hasEdits {
                selected = try service.update(id: selected.id, expectedRevision: selected.revision,
                    title: title, workDate: workDate, transcript: transcript, notes: notes)
                self.selected = selected
                title = selected.title
            }
            if hasSummaryEdits, let summary = selected.summary {
                _ = try service.editSummary(meetingID: selected.id, expectedRevision: summary.revision, content: summaryDraft)
                self.selected = try service.meeting(id: selected.id)
            }
            reload(); return true
        } catch { show(error); return false }
    }
    func deleteSelected() {
        guard !isBusy, save(), let selected, let service else { return }
        do { try service.delete(id: selected.id, expectedRevision: selected.revision); self.selected = nil; reload() }
        catch { show(error) }
    }
    func restoreSelected() {
        guard let selected, let service else { return }
        do { load(try service.restore(id: selected.id, expectedRevision: selected.revision)); showingDeleted = false; reload() }
        catch { show(error) }
    }
    func availableMemos(on date: WorkDate) -> [Memo] {
        do { return try environment?.repo.memos(on: date) ?? [] }
        catch { show(error); return [] }
    }
    func linkMemos(_ ids: [String]) {
        guard save(), let selected, let service else { return }
        do { load(try service.setLinkedMemos(id: selected.id, expectedRevision: selected.revision, memoIDs: ids)); reload() }
        catch { show(error) }
    }
    func summarize() {
        guard canSummarize else { message = "설정에서 AI 사용과 ChatGPT 연결을 확인하세요."; return }
        guard !isBusy, save(), let selected, let service else { return }
        isSummarizing = true; message = nil
        summaryTask = Task { [weak self] in
            guard let self else { return }
            defer { isSummarizing = false; summaryTask = nil }
            do {
                _ = try await service.generateSummary(id: selected.id, regenerate: selected.summary != nil)
                if let current = try service.meeting(id: selected.id) { load(current) }
                reload()
            } catch { show(error) }
        }
    }
    func prepareModel() {
        guard !isBusy else { return }
        audioTask = Task { [weak self] in
            guard let self else { return }; defer { audioTask = nil }
            do { try await speech.prepareKoreanModel() } catch { show(error) }
        }
    }
    func startRecording() {
        guard !isBusy, selected != nil, save() else { return }
        audioTask = Task { [weak self] in
            guard let self else { return }; defer { audioTask = nil }
            do {
                guard let meetingID = selected?.id else { return }
                try await recorder.start(meetingID: meetingID)
            } catch { show(error) }
        }
    }
    func stopRecording() {
        do { let url = try recorder.stop(); transcribe(url) } catch { show(error) }
    }
    func transcribe(_ url: URL) {
        guard !isBusy, let meetingID = selected?.id, save() else { return }
        audioTask = Task { [weak self] in
            guard let self else { return }; defer { audioTask = nil }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try await speech.transcribe(fileURL: url)
                guard selected?.id == meetingID else { return }
                transcript += (transcript.isEmpty ? "" : "\n\n") + text
                if save(), recorder.recordingURL == url { try recorder.discardRecording() }
            } catch { show(error) }
        }
    }
    func cancelTranscription() { speech.cancel(); audioTask?.cancel() }
    func discardAudio() { do { try recorder.discardRecording() } catch { show(error) } }
    func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, !worklogHasMarkedText, !isSummarizing, hasEdits || hasSummaryEdits,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            _ = save()
        }
    }
    @discardableResult func leaveScreen() -> Bool {
        autosaveTask?.cancel()
        if recorder.isStarting { audioTask?.cancel() }
        if recorder.isRecording {
            do { _ = try recorder.stop(); message = "녹음을 중지했습니다. 저장된 음성을 전사하거나 내보낼 수 있습니다." }
            catch { show(error) }
        }
        return save()
    }
    func detach() {
        leaveScreen(); speech.cancel(); audioTask?.cancel(); summaryTask?.cancel()
        service = nil; environment = nil
    }
    func show(_ error: Error) {
        // Only domain errors expose their authored message. Never display raw provider/OS payloads.
        if let error = error as? WorkLogError { message = error.localizedDescription }
        else if let error = error as? MeetingSpeechError { message = error.localizedDescription }
        else if let error = error as? MeetingRecordingError { message = error.localizedDescription }
        else if error is CancellationError { message = "전사를 취소했습니다. 기존 원문은 유지됩니다." }
        else { message = "처리하지 못했습니다. 기존 기록은 유지됩니다. 연결·권한·음성 파일을 확인하고 다시 시도하세요." }
    }
}
#endif
