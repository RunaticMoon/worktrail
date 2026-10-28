#if os(macOS)
import Foundation
import Observation
import WorkLogCore

struct MeetingTaskReview: Identifiable {
    let meetingID: String
    let revision: Int
    let key: String
    let text: String
    let runID: String?
    let segmentID: String?
    var id: String { key }
}

/// Retained by AppController: selection, navigation and editor lifetime do not own capture.
@Observable @MainActor final class MeetingsModel {
    var environment: AppEnvironment?
    var service: MeetingService?
    let calendar: WorkCalendar
    let audio: MeetingRecordingSession
    /// Only for recovering recordings made by versions before the archive migration.
    let recorder: MeetingAudioRecorder
    var rows: [Meeting] = []
    var selected: Meeting?
    var title = ""
    var workDate: WorkDate
    var transcript = ""
    var notes = ""
    var summaryDraft = ""
    var manualSummary = ""
    var manualDecisions = ""
    var manualActions = ""
    var manualQuestions = ""
    var metadataDraft = MeetingMetadata()
    var filterProjectID = ""
    var filterTagID = ""
    var filterStart: WorkDate?
    var filterEnd: WorkDate?
    var oldestFirst = false
    var segmentFilter = MeetingSegmentFilter()
    var transcriptExpanded = false
    var selectedSegmentID: String?
    var taskReview: MeetingTaskReview?
    var summaryHistory: [MeetingSummary] = []
    var conflictingSummary: MeetingSummary?
    var taskLinks: [MeetingTaskLink] = []
    var onOpenTask: ((String) -> Void)?
    private struct NavigationState {
        var runID: String?
        var filter: MeetingSegmentFilter
        var selectedSegmentID: String?
    }
    private var navigationStates: [String: NavigationState] = [:]
    private var savedManualOutput = MeetingSummaryOutput(summary: [])
    var query = ""
    var showingDeleted = false
    var message: String?
    var isSummarizing = false
    private(set) var isImporting = false
    private(set) var recordings: [MeetingRecording] = []
    private(set) var runs: [MeetingTranscriptRun] = []
    private(set) var segments: [MeetingTranscriptSegment] = []
    private(set) var speakers: [MeetingSpeaker] = []
    private(set) var tracks: [MeetingAudioTrack] = []
    var viewedRunID: String?
    private var audioTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?

    init(environment: AppEnvironment, audio: MeetingRecordingSession? = nil) {
        self.environment = environment
        self.audio = audio ?? MeetingRecordingSession(environment: environment)
        recorder = MeetingAudioRecorder(directory: environment.options.paths.dataRoot.appendingPathComponent("meeting-audio", isDirectory: true), ids: environment.options.ids)
        service = MeetingService(repo: environment.repo, runner: environment.aiRunner)
        calendar = environment.calendar
        workDate = calendar.workDate(of: environment.options.clock.now())
        reload()
        if let pendingID = recorder.pendingMeetingID,
           let pending = try? service?.meeting(id: pendingID, includeDeleted: true) {
            load(pending)
            showingDeleted = pending.deletedAt != nil
            message = "이전 녹음을 복구했습니다. 원본을 보존하면서 새 녹음 보관함으로 가져올 수 있습니다."
        }
    }
    /// Backup restore/detach must wait for all storage-affecting audio operations.
    var isBusy: Bool { audio.isSavePending || audio.isRecovering || audio.isCapturing || audio.isFinalizing || audio.models.isPreparing || isImporting || isSummarizing }
    var canSummarize: Bool {
        environment?.aiRunner != nil && environment?.settings.aiEnabled == true && selected?.localOnly == false
    }
    var canStartRecording: Bool { selected?.deletedAt == nil && selected != nil && !audio.isSavePending && !audio.isRecovering && !audio.isCapturing && !audio.models.isPreparing && !isImporting }
    var canDeleteSelected: Bool {
        guard !audio.isSavePending, let selected else { return false }
        return !audio.isRecovering && !(audio.isCapturing && audio.meetingID == selected.id) &&
            !(audio.isFinalizing && audio.meetingID == selected.id) &&
            !recordings.contains { $0.id == audio.finalRecordingID } && !isImporting && !isSummarizing
    }
    var viewedRun: MeetingTranscriptRun? { runs.first { $0.id == viewedRunID } }
    var visibleRows: [Meeting] {
        let filtered = rows.filter { ($0.deletedAt != nil) == showingDeleted && (query.isEmpty ||
            ($0.title + "\n" + $0.transcript + "\n" + $0.notes).localizedCaseInsensitiveContains(query)) &&
            (filterProjectID.isEmpty || ($0.metadata?.projectIDs ?? []).contains(filterProjectID)) &&
            (filterTagID.isEmpty || ($0.metadata?.tagIDs ?? []).contains(filterTagID)) &&
            (filterStart == nil || $0.workDate >= filterStart!) && (filterEnd == nil || $0.workDate <= filterEnd!) }
        return oldestFirst ? filtered.reversed() : filtered
    }
    var hasEdits: Bool {
        guard let selected, selected.deletedAt == nil else { return false }
        return selected.title != title || selected.workDate != workDate || selected.transcript != transcript || selected.notes != notes
    }
    var hasSummaryEdits: Bool { (selected?.summary != nil && summaryDraft != selected?.summary?.content) || manualOutput != savedManualOutput }
    var hasMetadataEdits: Bool { metadataDraft != (selected?.metadata ?? MeetingMetadata()) }
    var manualOutput: MeetingSummaryOutput {
        func items(_ text: String) -> [MeetingSummaryItem] { text.split(separator: "\n").map { .init(text: String($0), citations: []) } }
        return .init(summary: items(manualSummary), decisions: items(manualDecisions), actionItems: items(manualActions), openQuestions: items(manualQuestions))
    }
    var projects: [Project] { (try? environment?.repo.projects(includeArchived: true)) ?? [] }
    var tags: [Tag] { (try? environment?.repo.tags()) ?? [] }
    var availableTasks: [WorkTask] { (try? environment?.repo.tasks()) ?? [] }
    var filteredSegments: [MeetingTranscriptSegment] { segments.filter(segmentFilter.matches) }
    func openLocalSearchHit(_ hit: MeetingLocalSearchHit) {
        select(hit.meetingID)
        guard selected?.id == hit.meetingID else { return }
        if let runID = hit.runID { viewedRunID = runID; refreshRun(); transcriptExpanded = true }
        if let segment = segments.first(where: { $0.id == hit.segmentID }), !segmentFilter.matches(segment) {
            segmentFilter = MeetingSegmentFilter()
            message = "검색한 구간을 표시하기 위해 전사 필터를 해제했습니다."
        }
        selectedSegmentID = hit.segmentID
        if let segment = segments.first(where: { $0.id == hit.segmentID }) { audio.play(segment) }
    }
    func reload() {
        do { rows = try service?.meetings(includeDeleted: true) ?? [] }
        catch { show(error) }
    }
    func create() {
        guard save() else { return }
        do {
            guard let environment, let service else { return }
            let meeting = try service.create(title: "새 회의", workDate: calendar.workDate(of: environment.options.clock.now()), transcript: "", notes: "", memoIDs: [])
            showingDeleted = false; query = ""; load(meeting); reload()
        } catch { show(error) }
    }
    func select(_ id: String) {
        guard selected?.id != id, save() else { return }
        do { if let meeting = try service?.meeting(id: id, includeDeleted: true) { load(meeting) } }
        catch { show(error) }
    }
    private func load(_ meeting: Meeting) {
        if let previous = selected, previous.id != meeting.id {
            navigationStates[previous.id] = .init(runID: viewedRunID, filter: segmentFilter, selectedSegmentID: selectedSegmentID)
            audio.stopPlayback()
        }
        let navigation = navigationStates[meeting.id]
        segmentFilter = navigation?.filter ?? MeetingSegmentFilter()
        selectedSegmentID = navigation?.selectedSegmentID
        selected = meeting; title = meeting.title; workDate = meeting.workDate
        transcript = meeting.transcript; notes = meeting.notes; summaryDraft = meeting.summary?.content ?? ""
        metadataDraft = meeting.metadata ?? MeetingMetadata()
        loadManualDraft(meeting.summary)
        viewedRunID = navigation?.runID ?? meeting.activeTranscriptRunID
        message = nil
        refreshAudio()
    }
    private func loadManualDraft(_ summary: MeetingSummary?) {
        let output = summary?.isManual == true ? summary!.structuredOutput : MeetingSummaryOutput(summary: [])
        manualSummary = output.summary.map(\.text).joined(separator: "\n")
        manualDecisions = output.decisions.map(\.text).joined(separator: "\n")
        manualActions = output.actionItems.map(\.text).joined(separator: "\n")
        manualQuestions = output.openQuestions.map(\.text).joined(separator: "\n")
        savedManualOutput = output
    }
    /// Merge background metadata without replacing unsaved notes, IME text or selection.
    func refreshAudio() {
        guard let selected else { recordings = []; runs = []; segments = []; speakers = []; tracks = []; viewedRunID = nil; return }
        do {
            summaryHistory = try service?.summaryHistory(meetingID: selected.id) ?? []
            taskLinks = try environment.map { try MeetingTaskService(repo: $0.repo).links(meetingID: selected.id) } ?? []
            recordings = try audio.store.recordings(meetingID: selected.id)
            runs = try audio.store.runs(meetingID: selected.id)
            tracks = try recordings.flatMap { try audio.store.tracks(recordingID: $0.id) }
            if !runs.contains(where: { $0.id == viewedRunID }) { viewedRunID = selected.activeTranscriptRunID ?? runs.first?.id }
            refreshRun()
            refreshSelectedMetadata()
            reload()
        } catch { show(error) }
    }
    private func refreshSelectedMetadata() {
        guard let old = selected else { return }
        do {
            guard var current = try service?.meeting(id: old.id, includeDeleted: true) else { return }
            let pendingSummary = manualOutput != savedManualOutput || summaryDraft != (old.summary?.content ?? "")
            if title == old.title { title = current.title }
            if workDate == old.workDate { workDate = current.workDate }
            if transcript == old.transcript { transcript = current.transcript }
            if notes == old.notes { notes = current.notes }
            if summaryDraft == (old.summary?.content ?? "") { summaryDraft = current.summary?.content ?? "" }
            if metadataDraft == (old.metadata ?? MeetingMetadata()) { metadataDraft = current.metadata ?? MeetingMetadata() }
            if !pendingSummary { loadManualDraft(current.summary) }
            else { current.summary = old.summary } // A background refresh must not silently rebase an unsaved draft.
            selected = current
        } catch { show(error) }
    }
    func refreshRun() {
        do {
            segments = try viewedRunID.map { try audio.store.segments(runID: $0) } ?? []
            speakers = try viewedRunID.map { try audio.store.speakers(runID: $0) } ?? []
        } catch { show(error) }
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
            if hasMetadataEdits {
                selected = try service.updateMetadata(meetingID: selected.id, expectedRevision: selected.revision, metadata: metadataDraft)
                self.selected = selected
            }
            if manualOutput != savedManualOutput {
                _ = try service.saveManualSummary(meetingID: selected.id, expectedMeetingRevision: selected.revision,
                    expectedSummaryRevision: selected.summary?.revision, output: manualOutput)
                savedManualOutput = manualOutput
                self.selected = try service.meeting(id: selected.id)
                summaryDraft = self.selected?.summary?.content ?? ""
            } else if summaryDraft != selected.summary?.content, let summary = selected.summary {
                _ = try service.editSummary(meetingID: selected.id, expectedRevision: summary.revision, content: summaryDraft)
                self.selected = try service.meeting(id: selected.id)
            }
            runs = try audio.store.runs(meetingID: selected.id)
            summaryHistory = try service.summaryHistory(meetingID: selected.id)
            conflictingSummary = nil
            reload(); return true
        } catch {
            if case WorkLogError.conflict = error, hasSummaryEdits {
                conflictingSummary = try? service.meeting(id: selected.id)?.summary
            }
            show(error); return false
        }
    }
    func retrySummaryAfterReview() {
        guard !hasEdits, !hasMetadataEdits, let selected, let latest = try? service?.meeting(id: selected.id) else { return }
        self.selected = latest
        _ = save()
    }
    func deleteSelected() {
        guard canDeleteSelected, save(), let selected, let service else { return }
        do { try service.delete(id: selected.id, expectedRevision: selected.revision); self.selected = nil; refreshAudio(); reload() }
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
        guard canSummarize else { message = selected?.localOnly == true ? "로컬 전용 회의는 외부 AI 요약을 사용할 수 없습니다." : "설정에서 AI 사용과 ChatGPT 연결을 확인하세요."; return }
        guard !isBusy, save(), let target = selected, let service else { return }
        isSummarizing = true; message = nil
        summaryTask = Task { [weak self] in
            guard let self else { return }
            defer { isSummarizing = false; summaryTask = nil }
            do {
                _ = try await service.generateSummary(id: target.id, regenerate: target.summary != nil)
                if selected?.id == target.id { refreshSelectedMetadata() }
                reload()
            } catch { show(error) }
        }
    }
    func startRecording(recordOnly: Bool = false) {
        guard canStartRecording, save(), let target = selected else { return }
        audio.start(meeting: target, recordOnly: recordOnly)
    }
    func stopRecording() { audio.stop() }
    func transcribe(_ url: URL) {
        guard !audio.isRecovering, !audio.isCapturing, !audio.isFinalizing, !isImporting, save(), let selected else { return }
        let legacy = recorder.recordingURL == url
        let targetID = legacy ? (recorder.pendingMeetingID ?? selected.id) : selected.id
        isImporting = true
        audioTask = Task { [weak self] in
            guard let self else { return }
            defer { isImporting = false; audioTask = nil; refreshAudio() }
            do {
                try await audio.importAudio(url, meetingID: targetID)
                // Release only the legacy manifest. Both its original and the new archive remain.
                if legacy { try recorder.releasePendingKeepingAudio() }
                message = "음성 파일을 녹음 보관함에 복사했습니다. 원본은 자동 삭제하지 않습니다."
            } catch { show(error) }
        }
    }
    func cancelTranscription() { audioTask?.cancel(); audio.cancelFinalization(); audio.models.cancel() }
    func discardAudio() { do { try recorder.discardRecording() } catch { show(error) } }
    func activateViewedRun(confirmedMeetingID: String, confirmedRunID: String) {
        guard selected?.id == confirmedMeetingID, viewedRunID == confirmedRunID,
              save(), let selected, let run = viewedRun else { return }
        do {
            let updated = try audio.store.activateRun(meetingID: selected.id, runID: run.id,
                expectedMeetingRevision: selected.revision, allowReplacingUserEdits: true)
            load(updated); reload()
        } catch { show(error) }
    }
    @discardableResult func editSegment(_ segment: MeetingTranscriptSegment, text: String, speakerID: String?) -> Bool {
        guard segment.runID == viewedRunID, save() else { return false }
        do {
            _ = try audio.store.editSegment(id: segment.id, expectedRevision: segment.revision, text: text,
                                           speakerID: speakerID, editSpeaker: true)
            refreshAudio(); return true
        } catch { show(error); return false }
    }
    @discardableResult func renameSpeaker(_ speaker: MeetingSpeaker, name: String) -> Bool {
        guard speaker.runID == viewedRunID, save() else { return false }
        do {
            _ = try audio.store.renameSpeaker(id: speaker.id, expectedRevision: speaker.revision, displayName: name)
            refreshAudio(); return true
        } catch { show(error); return false }
    }
    func reviewTask(text: String, key: String, segment: MeetingTranscriptSegment? = nil) {
        guard save(), let selected else { return }
        taskReview = MeetingTaskReview(meetingID: selected.id, revision: selected.revision, key: key,
            text: text, runID: segment?.runID, segmentID: segment?.id)
    }
    func confirmTask(_ review: MeetingTaskReview, title: String, owner: String, dueOn: WorkDate?, projectIDs: [String], existingTaskID: String?) -> Bool {
        guard let environment else { return false }
        do {
            _ = try MeetingTaskService(repo: environment.repo).confirm(meetingID: review.meetingID,
                expectedRevision: review.revision, actionKey: review.key, title: title, owner: owner,
                dueOn: dueOn, projectIDs: projectIDs, quote: review.text, transcriptRunID: review.runID,
                segmentID: review.segmentID, existingTaskID: existingTaskID)
            refreshAudio(); return true
        } catch { show(error); return false }
    }
    func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, !worklogHasMarkedText, !isSummarizing, hasEdits || hasSummaryEdits || hasMetadataEdits,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            _ = save()
        }
    }
    @discardableResult func leaveScreen() -> Bool {
        autosaveTask?.cancel()
        audio.stopPlayback()
        return save()
    }
    func shutdownAudio() async -> Bool {
        audioTask?.cancel()
        await audioTask?.value
        return await audio.shutdown()
    }
    func detach() {
        leaveScreen(); audioTask?.cancel(); summaryTask?.cancel(); audio.models.cancel()
        if audio.isCapturing { audio.stop() }
        audio.cancelFinalization()
        service = nil; environment = nil
    }
    func show(_ error: Error) {
        if let error = error as? WorkLogError { message = error.localizedDescription }
        else if let error = error as? MeetingLocalModelError { message = error.localizedDescription }
        else if let error = error as? MeetingAudioCaptureError { message = error.localizedDescription }
        else if let error = error as? MeetingRecordingError { message = error.localizedDescription }
        else if error is CancellationError { message = "음성 작업을 취소했습니다. 원본과 저장된 전사는 유지됩니다." }
        else { message = "처리하지 못했습니다. 기존 기록은 유지됩니다. 연결·권한·음성 파일을 확인하고 다시 시도하세요." }
    }
}
#endif
