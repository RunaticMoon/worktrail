#if os(macOS)
import Combine
import Sparkle
import SwiftUI

/// Sparkle owns update scheduling, preferences, signature checks and installation.
/// This service only uses public release metadata; it never receives application records.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    let isConfigured: Bool
    let version: String
    private let controller: SPUStandardUpdaterController?

    private init(bundle: Bundle = .main) {
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "개발 빌드"
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isConfigured = bundle.bundleURL.pathExtension == "app" && Data(base64Encoded: key)?.count == 32
        guard isConfigured else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloadsUpdates)
        controller.startUpdater()
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
    func setAutomaticChecks(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled }
    func setAutomaticDownloads(_ enabled: Bool) { controller?.updater.automaticallyDownloadsUpdates = enabled }

    /// CI exercises the embedded dynamic framework without opening application storage,
    /// starting update requests, reading Keychain items or launching Codex.
    static func runLoaderSmokeTest() {
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        _ = controller.updater
        precondition(Bundle.main.bundleIdentifier == "dev.worklog.WorkLog")
        print("WorkLog Sparkle loader smoke test passed")
    }
}

@MainActor
struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = AppUpdater.shared
    var body: some View {
        Button("업데이트 확인…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

@MainActor
struct UpdateSettingsSection: View {
    @ObservedObject private var updater = AppUpdater.shared
    var body: some View {
        Section("앱 업데이트") {
            LabeledContent("현재 버전", value: updater.version)
            Toggle("새 버전 자동 확인", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates }, set: updater.setAutomaticChecks))
                .disabled(!updater.isConfigured)
            Toggle("업데이트 자동 다운로드", isOn: Binding(
                get: { updater.automaticallyDownloadsUpdates }, set: updater.setAutomaticDownloads))
                .disabled(!updater.isConfigured || !updater.automaticallyChecksForUpdates)
            CheckForUpdatesButton()
            Text(updater.isConfigured
                 ? "하루에 한 번 새 버전을 확인합니다. 다운로드 후 앱에서 설치와 재시작을 선택할 수 있습니다. 변경은 바로 적용됩니다."
                 : "자동 업데이트는 배포된 WorkLog 앱에서 사용할 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
