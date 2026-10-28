#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkLogCore

@MainActor
struct DiagnosticSettingsSection: View {
    @State private var status: DiagnosticLogStatus?
    @State private var message: String?
    @State private var busy = false
    @State private var confirmsDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("문제가 발생한 뒤 이 리포트를 저장해 제출하면 앱 동작과 오류를 확인할 수 있습니다.")
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("보관", value: "최근 7일 · 최대 10 MB")
            if let status {
                LabeledContent("저장된 이벤트", value: "\(status.eventCount)개")
                LabeledContent("사용 용량", value: ByteCountFormatter.string(fromByteCount: Int64(status.byteCount), countStyle: .file))
                if !status.storageAvailable {
                    Label("진단 로그를 저장하지 못하고 있습니다. 저장 공간과 폴더 권한을 확인하세요.", systemImage: "exclamationmark.triangle")
                }
                if status.droppedEventCount > 0 {
                    Text("저장하지 못한 이벤트: \(status.droppedEventCount)개").foregroundStyle(.secondary)
                }
            }
            Text("앱 시작·종료, 업데이트, Keychain 접근 결과, 녹음·전사, AI 처리, 활동 수집과 저장 오류의 주요 상태·오류 코드를 기록합니다. 오래된 로그와 용량 한도를 넘은 로그는 자동 삭제합니다.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("메모·회의 내용·음성·Secret·토큰·계정·파일 경로는 포함하지 않습니다. 리포트에는 앱·macOS 버전과 이벤트 시각이 포함되며 자동 전송하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("진단 리포트 저장…", action: exportReport)
                .accessibilityIdentifier("diagnostics.export")
                .focusable().worklogKeyboardActivation(exportReport)
                .disabled(busy)
                Button("로그 삭제", role: .destructive) { confirmsDelete = true }
                    .focusable().worklogKeyboardActivation { confirmsDelete = true }
                    .disabled(busy)
                    .accessibilityIdentifier("diagnostics.delete")
                if busy { ProgressView().controlSize(.small) }
            }
            if let message { Text(message).font(.callout).accessibilityIdentifier("diagnostics.feedback") }
            Text("문제 재현 순서와 발생 시각을 리포트 파일과 함께 전달하세요. 내보낸 파일은 사용자가 직접 관리합니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { status = await AppDiagnostics.shared.status() }
        .confirmationDialog("저장된 진단 로그를 삭제할까요?", isPresented: $confirmsDelete) {
            Button("로그 삭제", role: .destructive) {
                busy = true
                Task {
                    do { try await AppDiagnostics.shared.deleteAll(); message = "저장된 진단 로그를 삭제했습니다." }
                    catch { message = "진단 로그를 삭제하지 못했습니다. 저장 공간과 폴더 권한을 확인하세요." }
                    status = await AppDiagnostics.shared.status()
                    busy = false
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("앱의 기록과 회의 원본은 유지됩니다. 이후 발생하는 진단 이벤트는 다시 기록합니다.")
        }
    }

    private func exportReport() {
        guard !busy else { return }
        busy = true
        Task {
            message = await DiagnosticReportExporter.save()
            status = await AppDiagnostics.shared.status()
            busy = false
        }
    }
}

@MainActor
enum DiagnosticReportExporter {
    static func save() async -> String? {
        let panel = NSSavePanel()
        panel.title = "진단 리포트 저장"
        panel.nameFieldStringValue = "WorkLog-diagnostics.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let url = panel.url else { return nil }
        do {
            let data = try await AppDiagnostics.shared.exportReport()
            try await Task.detached(priority: .utility) {
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }.value
            AppDiagnostics.shared.record(.logsExported, category: .diagnostics)
            return "진단 리포트를 저장했습니다. 문제 재현 순서와 발생 시각을 함께 제출하세요."
        } catch {
            AppDiagnostics.shared.recordFailure(error, category: .diagnostics)
            return "리포트를 저장하지 못했습니다. 저장 위치의 권한과 여유 공간을 확인하세요."
        }
    }
}
#endif
