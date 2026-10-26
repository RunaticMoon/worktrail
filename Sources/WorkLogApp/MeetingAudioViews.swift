#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkLogCore

struct MeetingAudioControlsView: View {
    @Bindable var model: MeetingsModel
    var body: some View {
        GroupBox("녹음과 로컬 전사") {
            VStack(alignment: .leading, spacing: 12) {
                if model.audio.isRecovering { ProgressView("보관한 녹음 복구 정보를 확인하는 중…") }
                MeetingCaptureSettingsView(audio: model.audio)
                HStack {
                    if model.audio.isCapturing {
                        Label("\(model.audio.meetingTitle) · \(meetingDuration(model.audio.elapsed))", systemImage: "record.circle")
                            .foregroundStyle(.red).monospacedDigit()
                        Button("녹음 중지") { model.stopRecording() }.disabled(model.audio.phase == .stopping)
                        if model.selected?.id != model.audio.meetingID, let id = model.audio.meetingID {
                            Button("녹음 중인 회의 보기") { model.select(id) }
                        }
                    } else {
                        Button("녹음 시작", systemImage: "mic") { model.startRecording() }.disabled(!model.canStartRecording)
                        Button("녹음만 시작") { model.startRecording(recordOnly: true) }.disabled(!model.canStartRecording)
                        Button("음성 파일 가져오기…") { importAudio() }
                            .disabled(model.audio.isRecovering || model.audio.isFinalizing || model.isImporting || model.selected == nil)
                    }
                    if model.isImporting { ProgressView().controlSize(.small); Button("가져오기 취소") { model.cancelTranscription() } }
                }
                if model.audio.isCapturing {
                    HStack {
                        level("마이크/현장", value: model.audio.levels["microphone"] ?? 0)
                        if model.audio.online { level("회의 앱", value: model.audio.levels["system"] ?? 0) }
                    }
                }
                if let value = model.audio.captureMessage { Text(value).font(.caption).foregroundStyle(.secondary) }
                if model.audio.isSavePending {
                    Button("저장 재시도") { _ = model.audio.retrySaving(); model.refreshAudio() }
                        .disabled(model.audio.isCapturing)
                }
                if let value = model.audio.finalMessage { Text(value).font(.caption).foregroundStyle(.secondary) }
                if model.audio.isFinalizing {
                    HStack { ProgressView().controlSize(.small); Text("원본으로 정밀 처리 중…"); Button("정밀 처리 중지") { model.audio.cancelFinalization() } }
                }
                Text("화면을 이동해도 녹음은 시작한 회의에 계속 저장됩니다. 녹음 원본은 명시적으로 삭제할 때까지 보관하며 일반 백업에는 포함되지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                MeetingModelPreparationView(model: model)
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func level(_ label: String, value: Float) -> some View {
        HStack { Text(label).font(.caption); ProgressView(value: min(1, Double(max(0, value)) * 5)).frame(maxWidth: 130) }
            .accessibilityLabel("\(label) 입력 음량")
    }
    private func importAudio() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        panel.begin { if $0 == .OK, let url = panel.url { model.transcribe(url) } }
    }
}

private struct MeetingCaptureSettingsView: View {
    @Bindable var audio: MeetingRecordingSession
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("회의 방식", selection: $audio.online) { Text("대면 · 마이크/현장").tag(false); Text("온라인 · 앱 + 마이크").tag(true) }
                    .frame(maxWidth: 300)
                Picker("마이크/현장", selection: $audio.microphoneID) {
                    Text("장치 선택").tag("")
                    ForEach(audio.microphones) { Text($0.name).tag($0.id) }
                }.frame(maxWidth: 320)
                Button("장치 새로고침") { audio.refreshMicrophones() }
            }.disabled(audio.isCapturing)
            if audio.online {
                HStack {
                    Picker("녹음할 회의 앱", selection: $audio.applicationPID) {
                        Text("앱 선택").tag(Int32(0))
                        ForEach(audio.applications) { Text($0.name).tag($0.id) }
                    }.frame(maxWidth: 380)
                    Button("앱 목록 열기…") { Task { await audio.refreshApplications() } }
                }.disabled(audio.isCapturing)
                Text("선택한 앱의 소리와 마이크를 별도 트랙으로 보관합니다. 앱 목록을 열 때 시스템 권한을 요청할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("실시간 전사 미리보기", isOn: $audio.preferences.liveEnabled)
                .disabled(audio.isCapturing && !audio.preferences.liveEnabled)
            if audio.isCapturing { Text("녹음 중 미리보기를 끌 수 있습니다. 다시 켜기는 다음 녹음부터 적용합니다.").font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("전사 설정") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("녹음 종료 후 정밀 전사와 화자 구분", isOn: $audio.preferences.automaticFinalization)
                    Toggle("무음 구간 감지", isOn: $audio.preferences.vadEnabled)
                    Picker("원본 정리 기준", selection: $audio.preferences.retentionDays) {
                        Text("기한 없음").tag(0)
                        Text("30일").tag(30)
                        Text("90일").tag(90)
                        Text("365일").tag(365)
                    }
                    Text("자동 삭제 없음 · 기간이 지난 원본도 직접 삭제합니다.").font(.caption).foregroundStyle(.secondary)
                    Stepper("미리보기 갱신 \(Int(audio.preferences.updateInterval))초", value: $audio.preferences.updateInterval, in: 2...10, step: 1)
                    Stepper("미리보기 문맥 \(Int(audio.preferences.rollingContext))초", value: $audio.preferences.rollingContext, in: 8...12, step: 1)
                    Text("처리 지연이 쌓이면 미리보기를 건너뛰고 종료 후 원본에서 복원합니다. 안정 미리보기도 최종 전사와 다를 수 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 6).disabled(audio.isCapturing)
            }
        }.onChange(of: audio.preferences) { _, _ in audio.savePreferences() }
    }
}

private struct MeetingModelPreparationView: View {
    @Bindable var model: MeetingsModel
    var body: some View {
        DisclosureGroup("로컬 모델 준비 · 다운로드와 라이선스") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(MeetingModelRegistry.models, id: \.role) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.role.label)
                            Text("다운로드 \(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)) · \(item.license) · \(item.revision.prefix(8))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.audio.models.readyRoles.contains(item.role) { Image(systemName: "checkmark.circle").accessibilityLabel("준비됨") }
                        Button(model.audio.models.readyRoles.contains(item.role) ? "검증 / 다시 준비" : "준비") { model.audio.prepare(item.role) }
                            .disabled(model.isBusy)
                    }
                }
                if model.audio.models.isPreparing {
                    ProgressView(value: model.audio.models.progress?.fraction ?? 0)
                    Button("모델 준비 취소") { model.audio.models.cancel() }
                }
                if let text = model.audio.models.message { Text(text).font(.caption).foregroundStyle(.secondary) }
                Text("준비를 누를 때만 Hugging Face에서 고정 버전의 공개 모델을 받습니다. 음성·메모를 보내지 않으며 추론 중 자동 다운로드하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Whisper: OpenAI / Argmax · SpeakerKit: Pyannote/CNRS, WeSpeaker/WeNet, VBx/Brno University of Technology, Argmax Core ML 변환. 모델은 WorkLog에서 변경하지 않았습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Link("SDK 및 고지", destination: URL(string: "https://github.com/argmaxinc/argmax-oss-swift/tree/v1.1.1")!)
                    Link("화자 모델 출처", destination: URL(string: "https://huggingface.co/argmaxinc/speakerkit-coreml")!)
                    Link("CC BY 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                }.font(.caption)
            }.padding(.top, 8)
        }
    }
}

struct MeetingLiveTranscriptView: View {
    @Bindable var audio: MeetingRecordingSession
    @State private var follow = true
    var body: some View {
        GroupBox("실시간 미리보기 · \(audio.meetingTitle)") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("최신 내용 따라가기", isOn: $follow)
                    Spacer()
                    Text("최근 200개 구간").font(.caption).foregroundStyle(.secondary)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(audio.visible.suffix(200))) { segment in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text("\(meetingDuration(segment.start)) · \(segment.trackID == "system" ? "회의 앱" : "마이크/현장")")
                                        Text(segment.stability == .partial ? "인식 중" : "안정 미리보기")
                                    }.font(.caption).foregroundStyle(.secondary)
                                    Text(segment.text).textSelection(.enabled)
                                }.id(segment.id)
                            }
                            Color.clear.frame(height: 1).id("live-end")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 100, maxHeight: 260)
                        .onScrollPhaseChange { _, phase in if phase == .interacting { follow = false } }
                        .onChange(of: audio.visible) { _, _ in if follow { proxy.scrollTo("live-end", anchor: .bottom) } }
                        .onChange(of: follow) { _, value in if value { proxy.scrollTo("live-end", anchor: .bottom) } }
                }
                if audio.visible.isEmpty { Text("음성을 기다리는 중입니다. 모델이 없으면 원본만 녹음합니다.").font(.caption).foregroundStyle(.secondary) }
                if let message = audio.previewMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            }.padding(6)
        }
    }
}

struct MeetingRecordingLibraryView: View {
    @Bindable var model: MeetingsModel
    @State private var deleting: MeetingRecording?
    var body: some View {
        GroupBox("보관한 녹음") {
            VStack(alignment: .leading, spacing: 10) {
                if model.recordings.isEmpty { Text("아직 보관한 녹음이 없습니다.").foregroundStyle(.secondary) }
                ForEach(model.recordings) { recording in
                    recordingRow(recording)
                }
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("이 녹음의 원본 음성을 삭제할까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("원본 영구 삭제", role: .destructive) {
                if let deleting { model.audio.deleteOriginal(deleting.id); model.refreshAudio() }
                deleting = nil
            }
        } message: { Text("음성 원본은 되돌릴 수 없습니다. 저장된 전사와 메모는 유지됩니다. 필요한 원본은 먼저 내보내세요.") }
    }
    private func recordingRow(_ recording: MeetingRecording) -> some View {
        let tracks = model.tracks.filter { $0.recordingID == recording.id }
        let running = model.audio.isCapturing && model.audio.recordingID == recording.id
        let processing = model.audio.finalRecordingID == recording.id
        let available = tracks.contains { $0.fileState == .available }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(recording.startedAt, format: .dateTime.month().day().hour().minute())
                Text(recording.state.meetingLabel).foregroundStyle(.secondary)
                Spacer()
                Button("정밀 처리 다시 시도") { model.audio.retryFinalization(recording.id) }
                    .disabled(!available || model.audio.isRecovering || model.audio.isCapturing || model.audio.isFinalizing || model.audio.models.isPreparing || model.selected?.deletedAt != nil)
                Button("원본 내보내기…") { export(recording) }.disabled(!available || running || model.audio.isRecovering)
                Button("원본 삭제", role: .destructive) { deleting = recording }
                    .disabled(running || processing || model.audio.isRecovering || model.audio.isFinalizing || recording.state == .discarded)
            }
            if model.audio.isPastRetention(recording) { Text("정리 기준 기간이 지난 원본 · 자동 삭제되지 않습니다.").font(.caption).foregroundStyle(.secondary) }
            ForEach(tracks) { track in
                Text("\(track.kind == .systemAudio ? "회의 앱" : "마이크/현장 · 가져온 음성") · \(meetingDuration(track.duration ?? 0)) · \(track.fileState.meetingLabel)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if recording.state == .interrupted || tracks.contains(where: { $0.fileState == .missing }) {
                Text("중단되었거나 원본을 찾을 수 없습니다. 원본 보관 폴더를 확인한 뒤 처리할 수 있습니다.").font(.caption).foregroundStyle(.orange)
            }
        }.padding(.vertical, 4)
    }
    private func export(_ recording: MeetingRecording) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.prompt = "이 폴더에 내보내기"
        panel.begin { result in
            guard result == .OK, let directory = panel.url else { return }
            model.audio.exportOriginal(recording.id, to: directory.appendingPathComponent("회의녹음-\(recording.id)", isDirectory: true))
        }
    }
}

struct MeetingTranscriptVersionsView: View {
    @Bindable var model: MeetingsModel
    @State private var confirmingActivation = false
    @State private var activationMeetingID: String?
    @State private var activationRunID: String?
    @State private var editingSegment: MeetingTranscriptSegment?
    @State private var editingSpeaker: MeetingSpeaker?
    var body: some View {
        GroupBox("전사 버전 비교와 수정") {
            VStack(alignment: .leading, spacing: 10) {
                if model.runs.isEmpty { Text("녹음이나 파일을 처리하면 전사 버전이 여기에 쌓입니다.").foregroundStyle(.secondary) }
                else { versionControls }
                if let run = model.viewedRun {
                    Text("\(run.stage.meetingLabel) · \(run.status.meetingLabel)\(run.id == model.selected?.activeTranscriptRunID ? " · 활성 전사본" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.speakers.isEmpty { speakerControls }
                    if let manual = run.manualText { Text(manual).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.segments) { segment in segmentRow(segment) }
                    }
                    DisclosureGroup("모델 및 버전 정보") {
                        Text("\(run.engine) · \(run.modelIdentifier)\nrevision: \(run.modelRevision ?? "직접 작성")")
                            .font(.caption).textSelection(.enabled)
                    }
                }
                Text("버전을 고르는 것은 비교 화면만 바꿉니다. 활성 전사본 변경은 확인 후 적용하며 이전 버전과 직접 수정 이력은 보존합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: model.viewedRunID) { _, _ in model.refreshRun() }
        .confirmationDialog("선택한 버전을 활성 전사본으로 사용할까요?", isPresented: $confirmingActivation) {
            Button("활성 전사본으로 사용") {
                if let activationMeetingID, let activationRunID {
                    model.activateViewedRun(confirmedMeetingID: activationMeetingID, confirmedRunID: activationRunID)
                }
            }
        } message: { Text("현재 직접 수정한 전사도 이전 버전으로 남습니다. 회의의 활성 원문과 이후 요약 근거는 선택한 버전으로 바뀝니다.") }
        .sheet(item: $editingSegment) { MeetingSegmentEditor(model: model, segment: $0) }
        .sheet(item: $editingSpeaker) { MeetingSpeakerEditor(model: model, speaker: $0) }
    }
    private var versionControls: some View {
        HStack {
            Picker("전사 버전", selection: $model.viewedRunID) {
                Text("버전 선택").tag(Optional<String>.none)
                ForEach(model.runs) { run in
                    Text("v\(run.version) · \(run.stage.meetingLabel) · \(run.status.meetingLabel)").tag(Optional(run.id))
                }
            }
            Button("활성 전사본으로 사용…") {
                activationMeetingID = model.selected?.id; activationRunID = model.viewedRunID
                confirmingActivation = true
            }
                .disabled(model.viewedRun == nil || model.viewedRun?.status != .completed || model.viewedRunID == model.selected?.activeTranscriptRunID || model.isSummarizing || model.selected?.deletedAt != nil)
            Button("전사 내보내기…") { exportTranscript() }.disabled(model.viewedRun == nil)
        }
    }
    private var speakerControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("화자 표시는 추정입니다. 목소리 특징만으로 실명이나 동일인을 확정하지 않습니다.").font(.caption).foregroundStyle(.secondary)
            ForEach(model.speakers) { speaker in
                HStack {
                    Text(speaker.displayName)
                    if speaker.isUserEdited { Text("이름 수정됨").font(.caption).foregroundStyle(.secondary) }
                    Button("이름 수정…") { editingSpeaker = speaker }.disabled(model.selected?.deletedAt != nil || model.isSummarizing)
                }
            }
        }
    }
    private func segmentRow(_ segment: MeetingTranscriptSegment) -> some View {
        let name = model.speakers.first { $0.id == segment.speakerID }?.displayName ?? "화자 미확정"
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Button("\(meetingDuration(segment.start))–\(meetingDuration(segment.end))", systemImage: "play.circle") { model.audio.play(segment) }
                    .disabled(model.tracks.first { $0.id == segment.trackID }?.fileState != .available)
                Text(name).font(.caption)
                if !segment.isFinal { Text("미확정 구간").font(.caption).foregroundStyle(.secondary) }
                if segment.isUserEdited { Text("수정됨").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("수정…") { editingSegment = segment }.disabled(model.selected?.deletedAt != nil || model.isSummarizing || model.viewedRun?.status == .running)
            }
            Text(segment.text).textSelection(.enabled)
            if segment.isUserEdited {
                DisclosureGroup("모델 원문") { Text(segment.originalText).font(.caption).textSelection(.enabled) }
            }
        }.padding(.vertical, 4)
    }
    private func exportTranscript() {
        guard let id = model.viewedRunID else { return }
        do {
            let content = try model.audio.store.renderedTranscript(runID: id)
            let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue = "회의전사-v\(model.viewedRun?.version ?? 0).txt"
            panel.begin { result in
                guard result == .OK, let url = panel.url else { return }
                do { try content.write(to: url, atomically: true, encoding: .utf8) } catch { model.show(error) }
            }
        } catch { model.show(error) }
    }
}

private struct MeetingSegmentEditor: View {
    @Bindable var model: MeetingsModel
    let segment: MeetingTranscriptSegment
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var speakerID: String
    init(model: MeetingsModel, segment: MeetingTranscriptSegment) {
        self.model = model; self.segment = segment
        _text = State(initialValue: segment.text); _speakerID = State(initialValue: segment.speakerID ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("전사 구간 수정 · \(meetingDuration(segment.start))").font(.headline)
            TextEditor(text: $text).frame(minHeight: 180).accessibilityLabel("수정할 전사 구간")
            Picker("화자", selection: $speakerID) {
                Text("미확정").tag("")
                ForEach(model.speakers) { Text($0.displayName).tag($0.id) }
            }
            Text("모델 원문과 기존 수정 이력은 유지됩니다.").font(.caption).foregroundStyle(.secondary)
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("수정 저장") { if model.editSegment(segment, text: text, speakerID: speakerID.isEmpty ? nil : speakerID) { dismiss() } }
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 560)
    }
}

private struct MeetingSpeakerEditor: View {
    @Bindable var model: MeetingsModel
    let speaker: MeetingSpeaker
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    init(model: MeetingsModel, speaker: MeetingSpeaker) { self.model = model; self.speaker = speaker; _name = State(initialValue: speaker.displayName) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("이 전사 버전의 화자 이름 수정").font(.headline)
            TextField("표시 이름", text: $name)
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("이름 저장") { if model.renameSpeaker(speaker, name: name) { dismiss() } }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 420)
    }
}

private func meetingDuration(_ value: Double) -> String {
    let seconds = Int(max(0, value.isFinite ? value : 0))
    return seconds >= 3_600 ? String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60) : String(format: "%02d:%02d", seconds / 60, seconds % 60)
}
private extension MeetingRecordingState {
    var meetingLabel: String { switch self { case .recording: "녹음 중"; case .paused: "일시 정지"; case .completed: "보관됨"; case .interrupted: "중단 복구"; case .failed: "처리 실패"; case .discarded: "원본 삭제됨" } }
}
private extension MeetingTrackFileState {
    var meetingLabel: String { switch self { case .pending: "준비 중"; case .writing: "저장 중"; case .available: "원본 있음"; case .needsRecovery: "복구 필요"; case .missing: "원본 없음"; case .deleted: "삭제됨" } }
}
private extension MeetingTranscriptStage {
    var meetingLabel: String { switch self { case .live: "실시간 미리보기"; case .refined: "정밀 전사"; case .diarized: "화자 구분"; case .manual: "직접 수정"; case .imported: "가져온 전사" } }
}
private extension MeetingTranscriptRunStatus {
    var meetingLabel: String { switch self { case .running: "처리 중"; case .completed: "완료"; case .failed: "실패 · 부분 보존"; case .cancelled: "취소 · 부분 보존"; case .interrupted: "중단 · 부분 보존" } }
}
#endif
