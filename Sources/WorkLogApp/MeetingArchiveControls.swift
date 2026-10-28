#if os(macOS)
import AppKit
import SwiftUI
import WorkLogCore

struct MeetingArchiveControls: View {
    @Bindable var model: MeetingsModel
    @State private var presented = false
    var body: some View {
        Button("회의 아카이브…", systemImage: "archivebox") { presented = true }
            .disabled(model.isBusy)
            .sheet(isPresented: $presented) { MeetingArchiveSheet(model: model) }
    }
}

private struct MeetingArchiveSheet: View {
    @Bindable var model: MeetingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var includeAudio = true
    @State private var exportPreview: MeetingArchivePreview?
    @State private var importPreview: MeetingArchivePreview?
    @State private var importURL: URL?
    @State private var newCopy = false
    @State private var busy = false
    @State private var message: String?
    @State private var worker: Task<String?, Error>?
    private var service: MeetingArchiveService {
        MeetingArchiveService(repo: model.audio.store.repo, audioRoot: model.audio.archive.root)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("회의 아카이브").font(.title2)
            Text("선택한 회의의 메모·요약·모든 전사본·화자·수정 이력을 하나의 폴더로 보관합니다. 원본 음성 포함 여부를 선택하세요. 모델과 일반 업무·Secret은 포함하지 않습니다.")
                .fixedSize(horizontal: false, vertical: true)
            GroupBox("내보내기") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.selected?.title ?? "회의를 먼저 선택하세요")
                    Toggle("원본 음성 포함", isOn: $includeAudio)
                        .onChange(of: includeAudio) { _, _ in exportPreview = nil }
                    if let preview = exportPreview { previewLabel(preview) }
                    HStack {
                        Button("파일 수·용량 확인") { prepareExport() }.disabled(model.selected == nil)
                        Button("아카이브 저장…") { exportArchive() }.disabled(exportPreview == nil)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GroupBox("가져오기") {
                VStack(alignment: .leading, spacing: 10) {
                    Button("아카이브 폴더 선택…") { chooseImport() }
                    if let preview = importPreview {
                        Text(preview.title).font(.headline)
                        previewLabel(preview)
                        Toggle("새 복사본으로 가져오기", isOn: $newCopy)
                        Text("끄면 같은 식별자의 기존 회의가 있을 때 중단합니다. 켜면 모든 내부 식별자를 새로 만들며 기존 회의를 유지합니다. 가져온 회의는 로컬 전용입니다.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("검증하고 가져오기") { restoreArchive() }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            if let message { Text(message).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if busy { ProgressView().controlSize(.small); Text("로컬 파일 처리 중…"); Button("작업 취소") { worker?.cancel() } }
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }
        }
        .padding(24).frame(width: 540)
        .interactiveDismissDisabled(busy)
        .onDisappear { worker?.cancel() }
    }
    private func previewLabel(_ preview: MeetingArchivePreview) -> some View {
        Text("\(preview.includesAudio ? "원본 포함" : "텍스트만") · 음성 \(preview.audioFileCount)개 · \(ByteCountFormatter.string(fromByteCount: preview.audioBytes, countStyle: .file)) · 미포함/누락 원본 \(preview.missingTrackCount)개")
            .font(.caption).foregroundStyle(.secondary)
    }
    private func prepareExport() {
        guard !busy, model.save(), let id = model.selected?.id else { return }
        busy = true; message = nil
        let service = service, include = includeAudio
        Task {
            do { exportPreview = try await Task.detached { try service.preview(meetingID: id, includeAudio: include) }.value }
            catch { message = error.localizedDescription }
            busy = false
        }
    }
    private func exportArchive() {
        guard !busy, model.save(), let meeting = model.selected else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "회의-\(meeting.workDate.iso).worklogmeeting"
        panel.canCreateDirectories = true
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            let service = service, include = includeAudio, id = meeting.id
            run {
                try service.export(meetingID: id, includeAudio: include, to: url) { try Task.checkCancellation() }
                return nil
            }
        }
    }
    private func chooseImport() {
        guard !busy, model.save() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "manifest.json이 들어 있는 .worklogmeeting 아카이브 폴더를 선택하세요."
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            busy = true; message = nil; importPreview = nil; importURL = nil
            let service = service
            Task {
                do {
                    importPreview = try await Task.detached { try service.inspect(url) }.value
                    importURL = url
                } catch { message = error.localizedDescription }
                busy = false
            }
        }
    }
    private func restoreArchive() {
        guard !busy, let url = importURL, model.save() else { return }
        let service = service, policy: MeetingArchiveDuplicatePolicy = newCopy ? .newCopy : .reject
        run { try service.restore(url, duplicatePolicy: policy) { try Task.checkCancellation() } }
    }
    private func run(_ operation: @escaping @Sendable () throws -> String?) {
        busy = true; message = nil
        let task = Task.detached(operation: operation)
        worker = task
        Task {
            do {
                let restoredID = try await task.value
                if let restoredID { model.reload(); model.select(restoredID) }
                message = restoredID == nil ? "회의 아카이브를 저장했습니다." : "회의를 가져왔습니다. 외부 AI 사용은 허용되지 않았습니다."
            } catch is CancellationError { message = "취소했습니다. 기존 회의와 원본은 유지됩니다." }
            catch { message = error.localizedDescription }
            worker = nil; busy = false
        }
    }
}
#endif
