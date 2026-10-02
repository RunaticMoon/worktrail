import Foundation
import Observation

@Observable @MainActor public final class SettingsModel {
    public var draft: AppSettings
    public private(set) var errors: [String] = []
    public private(set) var message: String?
    public private(set) var accountMessage = "로그인 상태를 아직 확인하지 않았습니다."
    public private(set) var isCheckingAccount = false
    @ObservationIgnored private var environment: AppEnvironment?
    public static let transmissionNotice = "회사 AI에는 일반 메모·업무·활동·계획·리포트와 관련 근거·질문·스킬 지침을 작업에 필요한 범위로 전송합니다. Secret은 제목·그룹·key·값·이전 버전·초안까지 모두 제외합니다."
    public init(environment: AppEnvironment) { self.environment = environment; draft = environment.settings }
    public var hasChanges: Bool { environment.map { draft != $0.settings } ?? false }
    public var defaultCaptureKind: CaptureKind {
        get { draft.defaultCaptureKind }
        set { draft.defaultCaptureKind = newValue }
    }
    public func detach() { environment = nil }
    public func reset() { if let environment { draft = environment.settings }; errors = []; message = nil }
    public func validate() -> Bool {
        errors = SettingsStore.validate(draft)
        if canonicalHotkey(draft.captureHotkey) == canonicalHotkey(draft.searchHotkey) {
            if !errors.contains(where: { $0.contains("서로 달라야") }) {
                errors.append("입력·검색 단축키가 충돌합니다. 기존 단축키를 유지합니다.")
            }
        }
        if draft.codexExecutablePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            draft.codexExecutablePath = nil
        }
        return errors.isEmpty
    }
    private func canonicalHotkey(_ binding: String) -> String {
        let parts = binding.lowercased().split(separator: "+").map { part -> String in
            switch part.trimmingCharacters(in: .whitespaces) {
            case "command": return "cmd"
            case "control": return "ctrl"
            case "option", "alt": return "opt"
            default: return part.trimmingCharacters(in: .whitespaces)
            }
        }
        guard let key = parts.last else { return "" }
        return Array(Set(parts.dropLast())).sorted().joined(separator: "+") + "+" + key
    }
    /// The macOS caller supplies transactional hotkey registration and persistence.
    @discardableResult public func save(apply: ((AppSettings) throws -> Void)? = nil) -> Bool {
        guard let environment, validate() else { message = "설정을 저장하지 못했습니다. 아래 항목을 확인하세요. 기존 설정은 유지됩니다."; return false }
        do {
            if let apply { try apply(draft) } else { try environment.updateSettings(draft) }
            message = "설정을 저장했습니다. AI 사용 여부·실행 경로 변경은 앱을 다시 열면 적용됩니다."
            errors = []; return true
        } catch {
            // Never echo executable paths, account responses or arbitrary persistence errors.
            errors = ["설정 저장 또는 단축키 등록에 실패했습니다. 기존 설정·단축키를 유지합니다."]
            message = nil; return false
        }
    }
    public func setSkill(_ value: String, for type: AIJobType) { draft.skillBindings[type.rawValue] = value }
    public func skillBinding(for type: AIJobType) -> String { draft.skillBindings[type.rawValue] ?? "" }
    public func checkAccount(provider: AIProvider? = nil) async {
        guard !isCheckingAccount, let environment else { return }
        isCheckingAccount = true; defer { isCheckingAccount = false }
        // No account reads at initialization, and no access to authentication files.
        let provider = provider ?? CodexAppServerProvider(config: CodexProviderConfig(
            executablePath: draft.codexExecutablePath, stagingRoot: environment.options.paths.aiJobsDirectory))
        do {
            switch try await provider.getAccountStatus() {
            case .unknown: accountMessage = "로그인 상태를 확인할 수 없습니다."
            case .notInstalled: accountMessage = "Codex가 설치되어 있지 않습니다. 실행 경로를 확인하세요."
            case .loggedOut: accountMessage = "로그인되어 있지 않습니다. 공식 Codex에서 회사 계정으로 로그인하세요."
            case .loggedIn(let type, _, let plan):
                let enterprise = [type, plan].compactMap { $0 }.contains { $0.lowercased().contains("enterprise") }
                accountMessage = enterprise ? "로그인됨 · Enterprise 계정으로 확인되었습니다." : "로그인됨 · 회사 Enterprise 계정 여부는 확인되지 않았습니다."
            }
        } catch {
            switch AIErrorClassifier.classify(error) {
            case .notInstalled: accountMessage = "Codex를 찾지 못했습니다. 실행 경로를 확인하세요."
            case .notLoggedIn, .authExpired: accountMessage = "인증을 확인하지 못했습니다. 공식 Codex에서 다시 로그인하세요."
            default: accountMessage = "로그인 상태 확인에 실패했습니다. Codex 연결을 확인하세요."
            }
        }
    }
}
