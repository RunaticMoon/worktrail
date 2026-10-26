#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WorkLogCore

struct MeetingsScreen: View {
    @Bindable var model: MeetingsModel
    @State private var showingMemoPicker = false
    @State private var confirmingDelete = false
    @State private var confirmingDiscardAudio = false
    @State private var memoDate: WorkDate = WorkDate("2026-01-01")!
    @State private var memoIDs: Set<String> = []

    var body: some View {
        HSplitView {
            library.frame(minWidth: 210, idealWidth: 250, maxWidth: 340)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let message = model.message { Text(message).foregroundStyle(.secondary).textSelection(.enabled) }
                    if let meeting = model.selected { editor(meeting) }
                    else if let url = model.recorder.recordingURL {
                        Text("복구할 녹음이 있지만 연결된 회의록을 찾지 못했습니다.")
                        Button("녹음 내보내기…") { exportAudio(url) }
                        Button("녹음 삭제", role: .destructive) { confirmingDiscardAudio = true }
                    }
                    else { ContentUnavailableView("회의록을 선택하세요", systemImage: "waveform", description: Text("새 회의를 만들고 녹음 또는 음성 파일을 전사하세요.")) }
                }.padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
            }.frame(minWidth: 380)
        }
        .toolbar {
            ToolbarItem {
                Button("새 회의", systemImage: "plus") { model.create() }
                    .disabled(model.isBusy || model.recorder.recordingURL != nil)
            }
        }
        .sheet(isPresented: $showingMemoPicker) { memoPicker }
        .confirmationDialog("회의록을 휴지통으로 이동할까요?", isPresented: $confirmingDelete) {
            Button("휴지통으로 이동", role: .destructive) { model.deleteSelected() }
        } message: { Text("회의록 목록의 휴지통에서 복원할 수 있습니다.") }
        .confirmationDialog("전사 전 녹음 파일을 삭제할까요?", isPresented: $confirmingDiscardAudio) {
            Button("녹음 파일 삭제", role: .destructive) { model.discardAudio() }
        } message: { Text("필요한 음성은 먼저 내보내세요. 저장된 회의록 원문은 유지됩니다.") }
        .task { await model.speech.refreshAvailability() }
        .onChange(of: model.title) { _, _ in model.scheduleAutosave() }
        .onChange(of: model.workDate) { _, _ in model.scheduleAutosave() }
        .onChange(of: model.transcript) { _, _ in model.scheduleAutosave() }
        .onChange(of: model.notes) { _, _ in model.scheduleAutosave() }
        .onChange(of: model.summaryDraft) { _, _ in model.scheduleAutosave() }
        .onDisappear { model.leaveScreen() }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("회의록 검색", text: $model.query).textFieldStyle(.roundedBorder)
            Picker("회의록 보관함", selection: $model.showingDeleted) {
                Text("회의록").tag(false)
                Text("휴지통").tag(true)
            }.pickerStyle(.segmented)
            List(selection: Binding<String?>(get: { model.selected?.id }, set: { if let id = $0 { model.select(id) } })) {
                ForEach(model.visibleRows, id: \.id) { meeting in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.title).lineLimit(2)
                        Text(meeting.workDate.iso).font(.caption).foregroundStyle(.secondary)
                        if meeting.isSummaryStale { Text("원문 변경 · 요약 갱신 필요").font(.caption).foregroundStyle(.secondary) }
                    }.tag(meeting.id)
                }
            }.listStyle(.inset)
        }.padding(12)
    }

    @ViewBuilder private func editor(_ meeting: Meeting) -> some View {
        if meeting.deletedAt != nil {
            Text(meeting.title).font(.title2)
            Text("휴지통에 보관된 회의록입니다.").foregroundStyle(.secondary)
            Button("회의록 복원") { model.restoreSelected() }
            Text(meeting.transcript).textSelection(.enabled)
            Text(meeting.notes).textSelection(.enabled)
            if let url = model.recorder.recordingURL {
                Button("녹음 내보내기…") { exportAudio(url) }
                Button("녹음 삭제", role: .destructive) { confirmingDiscardAudio = true }
            }
        } else {
            HStack {
                TextField("회의 제목", text: $model.title).font(.title2).textFieldStyle(.roundedBorder)
                WorkDatePicker(title: "회의 날짜", value: $model.workDate, calendar: model.calendar)
            }.disabled(model.isSummarizing)
            audioControls
            GroupBox("회의 전사") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("전사 결과를 확인하고 잘못 인식한 단어를 수정하세요. 추가 전사는 기존 원문 뒤에 붙습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $model.transcript).frame(minHeight: 160)
                        .accessibilityLabel("회의 전사 원문")
                        .disabled(model.speech.isTranscribing || model.isSummarizing)
                }.padding(6)
            }
            GroupBox("직접 작성한 메모") {
                TextEditor(text: $model.notes).frame(minHeight: 140).padding(6)
                    .accessibilityLabel("회의 메모").disabled(model.isSummarizing)
            }
            GroupBox("함께 요약할 기존 메모") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("선택한 일반 메모의 사본을 회의록에 보관합니다. 메모 원본은 변경하지 않습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(meeting.memoSnapshots, id: \.memoID) { memo in
                        Text(memo.body).lineLimit(3).textSelection(.enabled)
                    }
                    Button("메모 선택…") {
                        memoDate = model.workDate
                        memoIDs = Set(meeting.memoSnapshots.map(\.memoID))
                        showingMemoPicker = true
                    }.disabled(model.isBusy)
                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("저장") { _ = model.save() }.keyboardShortcut("s", modifiers: .command)
                    .disabled(model.isSummarizing || (!model.hasEdits && !model.hasSummaryEdits))
                Button(meeting.summary == nil ? "전사와 메모 요약" : "요약 다시 생성") { model.summarize() }
                    .disabled(model.isBusy || !model.canSummarize)
                if model.isSummarizing { ProgressView().controlSize(.small); Text("요약 중…") }
                Text(model.hasEdits || model.hasSummaryEdits ? "저장 대기" : "저장됨").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("내보내기…") { exportMeeting() }.disabled(model.isSummarizing)
                Button("삭제", role: .destructive) { confirmingDelete = true }
                    .disabled(model.isBusy || model.recorder.recordingURL != nil)
            }
            Text("요약을 실행하면 전사 텍스트·회의 메모·선택한 메모가 연결된 ChatGPT 계정으로 전송됩니다. 음성 파일은 전송하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            if !model.canSummarize { Text("AI 요약은 설정에서 AI 사용을 켜고 앱을 다시 연 뒤 사용할 수 있습니다. 녹음·전사·메모는 로컬에서 계속 사용할 수 있습니다.").font(.caption) }
            if let summary = meeting.summary {
                GroupBox("요약 초안 · 버전 \(summary.version)") {
                    VStack(alignment: .leading, spacing: 8) {
                        if meeting.isSummaryStale || model.hasEdits {
                            Text("원문이 변경되었습니다. 요약을 다시 생성해 확인하세요.").foregroundStyle(.orange)
                        }
                        Text("AI가 작성한 초안입니다. 결정사항·담당자·기한은 원문과 대조하세요.").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $model.summaryDraft).frame(minHeight: 220)
                            .accessibilityLabel("회의 요약 초안").disabled(model.isSummarizing)
                        if summary.isUserEdited { Text("직접 편집한 초안 · 아래 인용은 AI 생성 당시의 근거입니다.").font(.caption).foregroundStyle(.secondary) }
                        DisclosureGroup("AI 생성 근거 확인") {
                            let items = summary.structuredOutput.summary + summary.structuredOutput.decisions + summary.structuredOutput.actionItems + summary.structuredOutput.openQuestions
                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.text).font(.callout)
                                    ForEach(Array(item.citations.enumerated()), id: \.offset) { _, citation in
                                        let label = summary.sources.first { $0.id == citation.sourceID }?.kind.label ?? "근거"
                                        Text("\(label): \(citation.quote)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }.padding(.vertical, 5)
                            }
                        }
                    }.padding(6)
                }
            }
        }
    }

    private var audioControls: some View {
        GroupBox("한국어 음성 전사 · 이 Mac에서 처리") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if model.recorder.isRecording {
                        Label("녹음 중", systemImage: "record.circle").foregroundStyle(.red)
                        Button("녹음 중지 후 전사") { model.stopRecording() }
                    } else {
                        Button("녹음 시작", systemImage: "mic") { model.startRecording() }
                            .disabled(model.isBusy || !model.speech.isModelReady || model.recorder.recordingURL != nil)
                        Button("음성 파일 가져오기…") { importAudio() }
                            .disabled(model.isBusy || !model.speech.isModelReady)
                    }
                    if model.speech.isTranscribing {
                        ProgressView().controlSize(.small)
                        Button("전사 취소") { model.cancelTranscription() }
                    }
                }
                if let url = model.recorder.recordingURL, !model.recorder.isRecording {
                    HStack {
                        Button("녹음 다시 전사") { model.transcribe(url) }.disabled(model.isBusy)
                        Button("녹음 내보내기…") { exportAudio(url) }.disabled(model.isBusy)
                        Button("녹음 삭제", role: .destructive) { confirmingDiscardAudio = true }.disabled(model.isBusy)
                    }
                }
                if !model.speech.isModelReady {
                    Button("한국어 모델 준비") { model.prepareModel() }.disabled(model.isBusy)
                    Text("첫 사용 시 Apple 한국어 모델 다운로드에 인터넷이 필요합니다. 모델 설치 후 음성 인식은 기기에서 처리합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.speech.isPreparing {
                    HStack {
                        ProgressView("한국어 모델 준비 중…")
                        Button("준비 취소") { model.cancelTranscription() }
                    }
                }
                if let status = model.speech.statusMessage { Text(status).font(.caption).foregroundStyle(.secondary) }
                if let error = model.recorder.lastError { Text(error).font(.caption).foregroundStyle(.secondary) }
                Text("녹음은 이 Mac의 마이크를 사용합니다. 화면을 나가면 녹음을 중지합니다. 전사 저장에 성공하면 임시 녹음을 삭제하며, 실패한 녹음은 다시 전사하거나 내보낼 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var memoPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("요약에 함께 넣을 일반 메모").font(.headline)
            WorkDatePicker(title: "메모 날짜", value: $memoDate, calendar: model.calendar)
            Text("선택 \(memoIDs.count)개 · 다른 날짜의 선택도 유지됩니다.").font(.caption)
            List(model.availableMemos(on: memoDate), id: \.id) { memo in
                Toggle(isOn: Binding(get: { memoIDs.contains(memo.id) }, set: {
                    if $0 { memoIDs.insert(memo.id) } else { memoIDs.remove(memo.id) }
                })) { Text(memo.body).lineLimit(5) }
            }
            HStack {
                Button("선택 해제") { memoIDs = [] }
                Spacer()
                Button("취소") { showingMemoPicker = false }.keyboardShortcut(.cancelAction)
                Button("선택 저장") { model.linkMemos(Array(memoIDs).sorted()); showingMemoPicker = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 560, height: 440)
    }
    private func importAudio() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        panel.begin { result in
            if result == .OK, let url = panel.url { model.transcribe(url) }
        }
    }
    private func exportMeeting() {
        guard model.save(), let meeting = model.selected else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "회의록-\(meeting.workDate.iso).txt"
        let content = "\(meeting.title)\n\(meeting.workDate.iso)\n\n[요약 초안]\n\(meeting.summary?.content ?? "")\n\n[회의 전사]\n\(meeting.transcript)\n\n[직접 메모]\n\(meeting.notes)\n\n[선택한 메모]\n" + meeting.memoSnapshots.map(\.body).joined(separator: "\n\n")
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do { try content.write(to: url, atomically: true, encoding: .utf8) } catch { model.show(error) }
        }
    }
    private func exportAudio(_ url: URL) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Audio]; panel.nameFieldStringValue = "회의녹음.m4a"
        panel.begin { result in
            guard result == .OK, let destination = panel.url else { return }
            do { try Data(contentsOf: url).write(to: destination, options: .atomic) } catch { model.show(error) }
        }
    }
}
#endif
