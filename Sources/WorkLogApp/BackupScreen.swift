#if os(macOS)
import SwiftUI
import AppKit
import WorkLogCore

struct BackupScreen: View {
    @Bindable var model: BackupModel
    let calendar: WorkCalendar
    let onRestore: (BackupInfo, Bool) -> Void
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("지금 백업", systemImage: "externaldrive.badge.plus") { Task { await model.create() } }.disabled(model.isBusy)
                    Button("백업 폴더 열기", systemImage: "folder") {
                        if let folder = model.folder, !NSWorkspace.shared.open(folder) {
                            model.recordFailure(BackupFailure.ioFailed("folder"))
                        }
                    }
                    Spacer()
                    Button("목록 새로고침", systemImage: "arrow.clockwise") { model.load() }.disabled(model.isBusy)
                    if model.isBusy { ProgressView().controlSize(.small) }
                }
                Text(BackupManifest.standardNote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let at = model.status.lastSuccessAt { Text("마지막 성공: \(timestamp(at))") }
                if let at = model.status.lastFailureAt { Text("마지막 실패: \(timestamp(at))").foregroundStyle(.red) }
                if let message = model.message { InlineNotice(message: message) }
                if model.backups.isEmpty {
                    EmptyMessage(title: "아직 복원 지점이 없습니다", detail: "‘지금 백업’으로 현재 기록과 암호화된 Secret을 보존하세요.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(model.backups, id: \.id) { backup in
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text(timestamp(backup.manifest.createdAt)).font(.headline)
                            HStack {
                                Text(BackupModel.reasonLabel(backup.manifest.reason))
                                Text(ByteCountFormatter.string(fromByteCount: BackupModel.size(backup), countStyle: .file))
                            }.foregroundStyle(.secondary)
                            HStack {
                                Button("검증") { Task { await model.verify(backup) } }
                                Button("복원…") { Task { await model.requestRestore(backup) } }
                                if model.verifiedIds.contains(backup.id) {
                                    Label("검증 통과", systemImage: "checkmark.shield").foregroundStyle(.secondary)
                                }
                            }.disabled(model.isBusy)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                    }
                }
            }.padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("백업")
        .onAppear { model.load() }
        .sheet(isPresented: Binding(get: { model.pendingRestore != nil }, set: { if !$0 { model.cancelRestore() } })) {
            if let backup = model.pendingRestore {
                VStack(alignment: .leading, spacing: 12) {
                    Text("이 복원 지점으로 되돌릴까요?").font(.title2)
                    Text(timestamp(backup.manifest.createdAt))
                    Text("현재 기록·설정을 이 백업으로 교체합니다. 복원 직전 현재 데이터를 별도 백업으로 보존하고, 모든 저장소 연결을 닫은 후 복원합니다.")
                    if model.offersOrdinaryOnlyRestore, let message = model.message { InlineNotice(message: message) }
                    Toggle("Secret 포함", isOn: $model.includeSecrets)
                    Text("Secret은 같은 Mac의 기존 Keychain 키가 있어야 복원할 수 있습니다. 제외하면 현재 Secret 보관함은 유지하고 일반 기록·설정만 복원합니다.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("취소") { model.cancelRestore() }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("복원하고 다시 열기", role: .destructive) {
                            let include = model.includeSecrets
                            model.cancelRestore(); onRestore(backup, include)
                        }
                    }
                }.padding(WorkLogTheme.contentInset).frame(minWidth: 440, idealWidth: 520)
            }
        }
    }
    private func timestamp(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .numeric, time: .standard, timeZone: calendar.timeZone))
    }
}
#endif
