import Foundation
import Observation

/// 설정 화면의 단축키 입력 필드. 작업 T의 `HotkeyAction`과 이름이 충돌하지 않도록 별도 이름을 쓴다.
public enum SettingsHotkeyField: String, CaseIterable, Sendable {
    case capture, search
}

/// 설정 화면의 AI 연결 상태 요약. 오프라인/실패를 판별하는 Core 신호가 없어
/// `unavailable(reason:)`은 호출자(검사 결과를 아는 UI)가 채운다.
public enum AIConnectionSummary: Equatable, Sendable {
    case notConfigured
    case connected
    case unavailable(reason: String)

    public var title: String {
        switch self {
        case .notConfigured: return "AI에 연결되어 있지 않습니다"
        case .connected: return "AI에 연결되어 있습니다"
        case .unavailable: return "AI에 연결할 수 없습니다"
        }
    }
    public var detail: String {
        switch self {
        case .notConfigured:
            return "기록·검색·기록 기반 초안은 그대로 사용할 수 있습니다. 필요할 때 설정에서 연결하세요."
        case .connected:
            return "기록을 바탕으로 한 AI 답변과 초안을 사용할 수 있습니다."
        case .unavailable(let reason):
            return reason
        }
    }
}

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
    /// 설정 화면 상단의 AI 연결 상태. 런타임 AI 실행기가 없으면 미연결로 본다.
    public var aiConnectionSummary: AIConnectionSummary {
        guard let environment, environment.aiRunner != nil else { return .notConfigured }
        return .connected
    }
    public func reset() { if let environment { draft = environment.settings }; errors = []; message = nil }
    public func validate() -> Bool {
        // 단축키 검증·정규화 규칙은 HotkeyBinding 한 곳에서만 정의한다.
        errors = SettingsStore.validate(draft)
        if draft.codexExecutablePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            draft.codexExecutablePath = nil
        }
        guard errors.isEmpty else { return false }
        if let capture = try? HotkeyBinding(parsing: draft.captureHotkey) {
            draft.captureHotkey = capture.canonicalString
        }
        if let search = try? HotkeyBinding(parsing: draft.searchHotkey) {
            draft.searchHotkey = search.canonicalString
        }
        return true
    }

    /// 레코더가 녹화한 조합을 해당 필드에 정규화 문자열로 설정한다.
    public func setHotkey(_ binding: HotkeyBinding, for action: SettingsHotkeyField) {
        switch action {
        case .capture: draft.captureHotkey = binding.canonicalString
        case .search: draft.searchHotkey = binding.canonicalString
        }
    }

    /// 두 단축키를 AppSettings 기본값(capture "ctrl+opt+space", search "ctrl+opt+d")으로 되돌린다.
    public func restoreDefaultHotkeys() {
        let defaults = AppSettings()
        draft.captureHotkey = defaults.captureHotkey
        draft.searchHotkey = defaults.searchHotkey
    }

    /// 표시용 문자열. 파싱에 성공하면 심볼 표시를, 실패하면 원문을 그대로 돌려준다.
    public func hotkeyDisplay(for action: SettingsHotkeyField) -> String {
        let raw: String
        switch action {
        case .capture: raw = draft.captureHotkey
        case .search: raw = draft.searchHotkey
        }
        return (try? HotkeyBinding(parsing: raw))?.displayString ?? raw
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
            // 단축키 조정기(T)의 LocalizedError는 사용자가 고칠 수 있는 원인을 담고 있으므로
            // 그 설명만 노출하고, 임의 문자열을 담을 수 있는 WorkLogError는 일반 문구로 숨긴다.
            if let localized = error as? LocalizedError, !(error is WorkLogError),
               let description = localized.errorDescription {
                errors = [description]
            } else {
                errors = ["설정 저장 또는 단축키 등록에 실패했습니다. 기존 설정·단축키를 유지합니다."]
            }
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
