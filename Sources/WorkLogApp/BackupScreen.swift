#if os(macOS)
import SwiftUI
import AppKit
import WorkLogCore

@MainActor
struct BackupScreen: View {
    @Bindable var model: BackupModel
    let calendar: WorkCalendar
    let onRestore: (BackupInfo, Bool) -> Void
    @State private var failedOperation: Operation = .load
    private enum Operation { case load, create, folder, verify(BackupInfo), restore(BackupInfo) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ScreenHeader(title: "백업", purpose: "기록 보존·복원 지점 관리")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { backupActions }
                    VStack(alignment: .leading, spacing: 8) { backupActions }
                }
                LabeledContent("백업 위치", value: model.backupLocationLabel)
                    .textSelection(.enabled).accessibilityLabel("백업 위치: \(model.backupLocationLabel)")
                Label(model.lastSuccessLabel, systemImage: "clock.arrow.circlepath")
                    .fixedSize(horizontal: false, vertical: true).accessibilityLabel(model.lastSuccessLabel)
                if let at = model.status.lastFailureAt {
                    Label("마지막 실패: \(timestamp(at))", systemImage: "exclamationmark.triangle")
                        .accessibilityLabel("마지막 백업 실패: \(timestamp(at))")
                }
                Text(BackupManifest.standardNote).font(.callout).foregroundStyle(WorkLogTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                BackupFeedback(model: model, retryTitle: retryTitle, retry: { retry() }, canRetry: !model.isBusy)
                if model.isBusy {
                    StateView(kind: .loading, title: "백업 처리 중…", detail: "완료할 때까지 새 백업·검증·복원은 기다려 주세요.")
                }
                Text("복원 지점").font(.headline).accessibilityAddTraits(.isHeader)
                Text("복원할 날짜의 ‘복원…’을 누르세요. 복원 전 현재 데이터를 별도 백업으로 보존합니다.")
                    .font(.callout).foregroundStyle(WorkLogTheme.muted).fixedSize(horizontal: false, vertical: true)
                if model.backups.isEmpty && !model.isBusy {
                    StateView(kind: .empty, title: "아직 복원 지점이 없습니다",
                              detail: "지금 백업으로 현재 기록과 암호화된 Secret을 보존하세요.",
                              actionTitle: "지금 백업", action: { create() })
                } else {
                    ForEach(model.backups, id: \.id) { backup in backupRow(backup) }
                }
            }
            .frame(maxWidth: 1000, alignment: .leading).padding(WorkLogTheme.contentInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("백업")
        .onAppear { model.load() }
        .sheet(isPresented: Binding(get: { model.pendingRestore != nil }, set: { if !$0 { model.cancelRestore() } })) {
            if let backup = model.pendingRestore { restoreSheet(backup) }
        }
    }
    @ViewBuilder private var backupActions: some View {
        Button("지금 백업", systemImage: "externaldrive.badge.plus") { create() }
            .disabled(model.isBusy).worklogHelp("현재 기록·설정과 암호화된 Secret 백업")
        Button("백업 폴더 열기", systemImage: "folder") { openFolder() }
            .disabled(model.folder == nil).worklogHelp("Finder에서 백업 폴더 열기")
        Button("목록 새로고침", systemImage: "arrow.clockwise") { failedOperation = .load; model.load() }
            .disabled(model.isBusy).worklogHelp("복원 지점 목록 새로고침")
    }
    private func backupRow(_ backup: BackupInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(timestamp(backup.manifest.createdAt)).font(.headline)
            Text("\(BackupModel.reasonLabel(backup.manifest.reason)) · \(ByteCountFormatter.string(fromByteCount: BackupModel.size(backup), countStyle: .file))")
                .font(.callout).foregroundStyle(WorkLogTheme.muted)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { restoreActions(backup) }
                VStack(alignment: .leading, spacing: 8) { restoreActions(backup) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
    }
    @ViewBuilder private func restoreActions(_ backup: BackupInfo) -> some View {
        Button("검증") { verify(backup) }.disabled(model.isBusy)
            .accessibilityLabel("\(timestamp(backup.manifest.createdAt)) 백업 검증")
            .worklogHelp("백업 형식·해시·데이터베이스 무결성 확인")
        Button("복원…") { requestRestore(backup) }.disabled(model.isBusy)
            .accessibilityLabel("\(timestamp(backup.manifest.createdAt)) 백업 복원")
            .worklogHelp("백업 검증 후 복원 범위 확인")
        if model.verifiedIds.contains(backup.id) {
            StatusBadge(label: "검증 통과", systemImage: "checkmark.shield", tone: .success)
        }
    }
    private func restoreSheet(_ backup: BackupInfo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ScreenHeader(title: "이 복원 지점으로 되돌릴까요?", purpose: timestamp(backup.manifest.createdAt))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("현재 기록·설정을 이 백업으로 교체합니다. 복원 직전 현재 데이터를 별도 백업으로 보존하고, 모든 저장소 연결을 닫은 후 복원합니다.")
                    if model.offersOrdinaryOnlyRestore, let message = model.message { InlineNotice(message: message) }
                    Toggle("Secret 포함", isOn: $model.includeSecrets)
                        .accessibilityHint("같은 Mac의 기존 Keychain 키가 필요합니다. 제외하면 현재 Secret 보관함을 유지합니다.")
                    Text("Secret은 같은 Mac의 기존 Keychain 키가 있어야 복원할 수 있습니다. 제외하면 현재 Secret 보관함은 유지하고 일반 기록·설정만 복원합니다.")
                        .font(.callout).foregroundStyle(WorkLogTheme.muted)
                }.fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack { restoreSheetActions(backup) }
                VStack(alignment: .leading, spacing: 8) { restoreSheetActions(backup) }
            }
        }
        .padding(WorkLogTheme.contentInset).frame(minWidth: 440, idealWidth: 560, minHeight: 340, idealHeight: 420)
    }
    @ViewBuilder private func restoreSheetActions(_ backup: BackupInfo) -> some View {
        Button("취소") { model.cancelRestore() }.keyboardShortcut(.cancelAction)
            .worklogHelp("복원을 취소하고 백업 목록으로 돌아가기", keys: "Esc")
        Button("복원하고 다시 열기", role: .destructive) {
            let include = model.includeSecrets
            model.cancelRestore(); onRestore(backup, include)
        }.disabled(model.isBusy)
            .accessibilityLabel(model.includeSecrets ? "Secret을 포함해 백업 복원하고 다시 열기" : "Secret을 유지하고 일반 기록·설정 복원하고 다시 열기")
            .worklogHelp("현재 데이터를 별도 보존한 뒤 선택한 백업으로 교체")
    }
    private func create() { failedOperation = .create; Task { await model.create() } }
    private func verify(_ backup: BackupInfo) { failedOperation = .verify(backup); Task { await model.verify(backup) } }
    private func requestRestore(_ backup: BackupInfo) { failedOperation = .restore(backup); Task { await model.requestRestore(backup) } }
    private func openFolder() {
        failedOperation = .folder
        if let folder = model.folder, !NSWorkspace.shared.open(folder) { model.recordFailure(BackupFailure.ioFailed("folder")) }
    }
    private var retryTitle: String {
        switch failedOperation {
        case .load: return "목록 다시 불러오기"
        case .create: return "다시 백업"
        case .folder: return "폴더 다시 열기"
        case .verify: return "다시 검증"
        case .restore: return "복원 지점 다시 확인"
        }
    }
    private func retry() {
        guard !model.isBusy else { return }
        switch failedOperation {
        case .load: model.load()
        case .create: create()
        case .folder: openFolder()
        case .verify(let backup): verify(backup)
        case .restore(let backup): requestRestore(backup)
        }
    }
    private func timestamp(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .numeric, time: .standard, timeZone: calendar.timeZone))
    }
}

/// BackupModel exposes a shared message rather than a structured failure field.
/// Its three success messages are kept separate; every other message retains a recovery path.
@MainActor
struct BackupFeedback: View {
    let model: BackupModel
    let retryTitle: String
    let retry: () -> Void
    var canRetry = true
    private var isSuccess: Bool {
        guard let message = model.message else { return false }
        return message == "백업을 만들었습니다."
            || message == "백업 형식·해시·데이터베이스 무결성 검증을 통과했습니다."
            || message == "복원을 완료했습니다. 앱을 다시 열어 복원한 기록을 사용하세요."
    }
    var body: some View {
        if let message = model.message {
            if isSuccess {
                Label(message, systemImage: "checkmark.circle").font(.callout)
                    .fixedSize(horizontal: false, vertical: true).accessibilityLabel(message)
            } else {
                RecoveryNotice(failed: message, preserved: "기존 복원 지점은 그대로 보존됩니다.",
                               retryTitle: retryTitle, retry: retry).disabled(!canRetry || model.isBusy)
            }
        }
    }
}
#endif
