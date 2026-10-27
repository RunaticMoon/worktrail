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
    public var aiConnection = AIConnectionSettings()
    public private(set) var apiKeyMessage: String?
    public private(set) var errors: [String] = []
    public private(set) var message: String?
    public private(set) var accountMessage = "로그인 상태를 아직 확인하지 않았습니다."
    public private(set) var isCheckingAccount = false
    private var hasVerifiedAccount = false
    public private(set) var isLoadingModels = false
    public private(set) var modelCatalogMessage = "모델 목록을 불러오면 계정에서 사용할 수 있는 모델과 추론 강도를 선택할 수 있습니다."
    public private(set) var aiTaskProfiles = AITaskProfiles()
    @ObservationIgnored private let profileStore: AITaskProfileStore
    @ObservationIgnored private let connectionStore: AIConnectionSettingsStore
    @ObservationIgnored private let credentialStore: (any ServiceCredentialStore)?
    @ObservationIgnored private var savedConnection = AIConnectionSettings()
    @ObservationIgnored private var connectionLoadFailed = false
    @ObservationIgnored private var savedProfiles = AITaskProfiles()
    @ObservationIgnored private var profileLoadFailed = false
    @ObservationIgnored private var catalogGeneration = 0
    @ObservationIgnored private var hasRequestedModels = false
    @ObservationIgnored private var requestedModelsExecutablePath: String?
    @ObservationIgnored private var environment: AppEnvironment?
    public static let transmissionNotice = "선택한 AI 공급자에는 일반 메모·업무·활동·계획·리포트·회의 전사와 메모·관련 근거·질문·스킬 지침을 작업에 필요한 범위로 전송합니다. 회의 음성 파일은 전송하지 않습니다. Secret은 제목·그룹·key·값·이전 버전·초안까지 모두 제외합니다."
    public init(environment: AppEnvironment, credentialStore: (any ServiceCredentialStore)? = nil) {
        self.environment = environment; draft = environment.settings
        self.credentialStore = credentialStore
        profileStore = AITaskProfileStore(dataRoot: environment.options.paths.dataRoot, ids: environment.options.ids)
        connectionStore = AIConnectionSettingsStore(dataRoot: environment.options.paths.dataRoot, ids: environment.options.ids)
        loadProfiles(); loadConnection()
    }
    public var hasChanges: Bool {
        environment.map { draft != $0.settings || aiTaskProfiles != savedProfiles || aiConnection != savedConnection } ?? false
    }
    public var defaultCaptureKind: CaptureKind {
        get { draft.defaultCaptureKind }
        set { draft.defaultCaptureKind = newValue }
    }
    public func detach() { catalogGeneration += 1; environment = nil }
    /// 설정 화면 상단의 AI 연결 상태. 런타임 AI 실행기가 없으면 미연결로 본다.
    public var aiConnectionSummary: AIConnectionSummary {
        guard let environment, environment.settings.aiEnabled, environment.aiRunner != nil, hasVerifiedAccount,
              !hasUnsavedAIConnection else { return .notConfigured }
        return .connected
    }
    public func reset() {
        if let environment { draft = environment.settings }
        catalogGeneration += 1
        errors = []; message = nil; loadProfiles(); loadConnection()
    }
    public func validate() -> Bool {
        // 단축키 검증·정규화 규칙은 HotkeyBinding 한 곳에서만 정의한다.
        errors = SettingsStore.validate(draft)
        if connectionLoadFailed { errors.append("AI 연결 설정을 읽을 수 없습니다. 기존 파일을 확인하세요.") }
        do { try aiConnection.validate() } catch let error as AIProviderError { errors.append(error.message) }
        catch { errors.append("AI 연결 설정을 확인하세요.") }
        if profileLoadFailed { errors.append("AI 작업 설정을 읽을 수 없습니다. 기존 파일을 확인한 뒤 다시 불러오세요.") }
        for type in AIJobType.allCases {
            let profile = aiTaskProfiles[type]
            if aiConnection.kind == .codexCLI, let model = profile.model, !aiTaskProfiles.models.isEmpty,
               !aiTaskProfiles.models.contains(where: { $0.id == model }) {
                errors.append("현재 목록에 없는 모델이 선택되어 있습니다. 작업별 AI 설정에서 모델을 다시 선택하세요.")
                break
            }
            if let effort = profile.effort, let model = aiTaskProfiles.selectedModel(for: type),
               !model.supportedEfforts.contains(effort) {
                errors.append("선택한 모델에서 지원하지 않는 추론 강도가 있습니다. 작업별 AI 설정을 확인하세요.")
                break
            }
        }
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
            let applySettings = {
                if let apply { try apply(self.draft) } else { try environment.updateSettings(self.draft) }
            }
            let connectionChanged = aiConnection != savedConnection || draft.codexExecutablePath != environment.settings.codexExecutablePath
            try connectionStore.save(aiConnection) {
                if aiTaskProfiles != savedProfiles {
                    try profileStore.save(aiTaskProfiles, applying: applySettings)
                } else { try applySettings() }
            }
            savedProfiles = aiTaskProfiles; savedConnection = aiConnection
            if connectionChanged { accountConnectionChanged() }
            message = "설정을 저장했습니다. 모델·추론 강도는 다음 AI 작업부터 적용됩니다. AI 사용을 새로 켰다면 앱을 다시 열어 주세요."
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

    public var hasUnsavedAIConnection: Bool {
        aiConnection != savedConnection || draft.codexExecutablePath != environment?.settings.codexExecutablePath
    }
    private func loadConnection() {
        do { aiConnection = try connectionStore.load(); savedConnection = aiConnection; connectionLoadFailed = false }
        catch { connectionLoadFailed = true; errors.append("AI 연결 설정을 읽을 수 없습니다. 기존 파일을 확인하세요.") }
    }
    public func selectConnection(_ kind: AIConnectionKind) {
        guard kind != aiConnection.kind else { return }
        aiConnection.kind = kind
        aiTaskProfiles = AITaskProfiles()
        hasVerifiedAccount = false; hasRequestedModels = false; catalogGeneration += 1
        accountMessage = "연결 방식을 저장한 뒤 상태를 확인하세요."
    }
    public func useDeepSeekPreset() {
        selectConnection(.openAICompatible)
        aiConnection.baseURL = "https://api.deepseek.com"; aiConnection.model = "deepseek-flash"
        aiTaskProfiles = AITaskProfiles()
    }
    @discardableResult public func saveAPIKey(_ value: String) async -> Bool {
        do {
            guard let credentialStore else { throw AIProviderError(.notLoggedIn, "안전한 인증 저장소를 사용할 수 없습니다.") }
            let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !key.contains("\r"), !key.contains("\n") else {
                throw AIProviderError(.notLoggedIn, "API 키를 입력하세요.")
            }
            let account = try aiConnection.credentialAccount()
            await (environment?.options.aiProvider as? ConfiguredAIProvider)?.invalidateConnection()
            try credentialStore.write(key, account: account)
            await (environment?.options.aiProvider as? ConfiguredAIProvider)?.invalidateConnection()
            accountConnectionChanged(); apiKeyMessage = "이 API 주소의 키를 Keychain에 저장했습니다. 연결 설정도 저장하세요."
            return true
        } catch let error as AIProviderError { apiKeyMessage = error.message }
        catch { apiKeyMessage = "API 키를 안전하게 저장하지 못했습니다." }
        return false
    }
    public func deleteAPIKey() async {
        do {
            guard let credentialStore else { return }
            let account = try aiConnection.credentialAccount()
            await (environment?.options.aiProvider as? ConfiguredAIProvider)?.invalidateConnection()
            try credentialStore.delete(account: account)
            await (environment?.options.aiProvider as? ConfiguredAIProvider)?.invalidateConnection()
            accountConnectionChanged(); apiKeyMessage = "이 API 주소의 저장된 키를 삭제했습니다."
        } catch { apiKeyMessage = "API 키를 삭제하지 못했습니다." }
    }

    private func loadProfiles() {
        do {
            aiTaskProfiles = try profileStore.load(); savedProfiles = aiTaskProfiles
            profileLoadFailed = false
            if !aiTaskProfiles.models.isEmpty {
                modelCatalogMessage = "저장된 모델 목록을 사용합니다. 선택한 AI 연결이 바뀌었다면 새로 불러오세요."
            } else {
                modelCatalogMessage = "모델 목록을 불러오면 계정에서 사용할 수 있는 모델과 추론 강도를 선택할 수 있습니다."
            }
        } catch {
            profileLoadFailed = true
            errors = ["AI 작업 설정을 읽을 수 없습니다. 기존 파일을 확인한 뒤 다시 불러오세요."]
        }
    }

    public func modelSelection(for type: AIJobType) -> String { aiTaskProfiles[type].model ?? "" }
    public func effortSelection(for type: AIJobType) -> String { aiTaskProfiles[type].effort ?? "" }
    public func setModel(_ value: String, for type: AIJobType) {
        aiTaskProfiles[type].model = value.isEmpty ? nil : value
        if let effort = aiTaskProfiles[type].effort,
           let model = aiTaskProfiles.selectedModel(for: type), !model.supportedEfforts.contains(effort) {
            aiTaskProfiles[type].effort = nil
        }
    }
    public func setEffort(_ value: String, for type: AIJobType) {
        aiTaskProfiles[type].effort = value.isEmpty ? nil : value
    }
    public func modelOptions(for type: AIJobType) -> [AIModelOption] {
        let automaticTitle: String
        if aiConnection.kind == .openAICompatible {
            automaticTitle = "자동 · \(aiConnection.model)"
        } else if let model = aiTaskProfiles.automaticModel(for: type) {
            automaticTitle = "자동 · \(model.id)"
        } else {
            automaticTitle = isLoadingModels ? "자동 · 모델 확인 중…" : "자동 · 계정 모델 확인 필요"
        }
        var options = [AIModelOption(id: "", title: automaticTitle)]
        options += aiTaskProfiles.models.map { AIModelOption(id: $0.id, title: $0.title) }
        if let selected = aiTaskProfiles[type].model, !options.contains(where: { $0.id == selected }) {
            options.append(AIModelOption(id: selected, title: "\(selected) · 목록 확인 필요"))
        }
        return options
    }
    public func effortOptions(for type: AIJobType) -> [AIEffortOption] {
        var automaticProfiles = aiTaskProfiles
        automaticProfiles[type].effort = nil
        let automaticEffort = automaticProfiles.executionProfile(for: type).effort
            .map(AITaskProfiles.effortTitle) ?? "모델 기본값"
        var options = [AIEffortOption(id: "", title: "자동 · \(automaticEffort)")]
        options += (aiTaskProfiles.selectedModel(for: type)?.supportedEfforts ?? []).map {
            AIEffortOption(id: $0, title: "\(AITaskProfiles.effortTitle($0)) (\($0))")
        }
        if let effort = aiTaskProfiles[type].effort, !options.contains(where: { $0.id == effort }) {
            options.append(AIEffortOption(id: effort, title: "\(effort) · 지원 확인 필요"))
        }
        return options
    }
    public func defaultProfileDescription(for type: AIJobType) -> String {
        let purpose: String
        switch type {
        case .memoTaskSuggestions: purpose = "메모에서 업무 후보를 빠르게 추출합니다."
        case .queryPlan: purpose = "질문을 검색 조건으로 빠르게 정리합니다."
        case .evidenceQuiz: purpose = "근거를 보완할 질문을 만듭니다."
        case .submissionWeekly: purpose = "주간 기록을 제출용 문장으로 정리합니다."
        case .groundedAnswer: purpose = "검색된 근거를 비교해 답변을 작성합니다."
        case .meetingSummary: purpose = "회의 전사와 직접 작성한 메모를 함께 요약합니다."
        case .performanceReport: purpose = "기간 전체의 근거와 성과를 깊이 있게 종합합니다."
        }
        if aiConnection.kind == .openAICompatible {
            return purpose + " 적용: \(aiTaskProfiles[type].model ?? aiConnection.model) · API 모델 기본 추론 설정."
        }
        guard let model = aiTaskProfiles.selectedModel(for: type) else {
            if let model = aiTaskProfiles[type].model {
                let effort = aiTaskProfiles[type].effort.map(AITaskProfiles.effortTitle) ?? "모델 기본값"
                return purpose + " 저장된 선택: \(model) · 추론 \(effort). 모델 목록을 확인하세요."
            }
            return purpose + " 선택한 AI 연결에서 사용 가능한 모델을 확인합니다. 모델을 조회할 수 없으면 실행 전에 안내합니다."
        }
        let effective = aiTaskProfiles.executionProfile(for: type)
        let effort = effective.effort.map(AITaskProfiles.effortTitle) ?? "모델 기본값"
        return purpose + " 적용: \(model.id) · 추론 \(effort)."
    }
    public func restoreDefaultAIProfiles() { aiTaskProfiles.profiles = [:] }

    /// Called only when the user opens task AI settings, never during app initialization.
    public func loadModelsIfNeeded(provider: AIModelCatalogProvider? = nil) async {
        guard draft.aiEnabled else { return }
        guard !hasRequestedModels || requestedModelsExecutablePath != draft.codexExecutablePath else { return }
        await refreshModels(provider: provider)
    }

    public func refreshModels(provider: AIModelCatalogProvider? = nil) async {
        guard !isLoadingModels, let environment else { return }
        guard !hasUnsavedAIConnection else { modelCatalogMessage = "연결 설정을 먼저 저장하세요."; return }
        hasRequestedModels = true
        requestedModelsExecutablePath = draft.codexExecutablePath
        isLoadingModels = true; defer { isLoadingModels = false }
        let generation = catalogGeneration
        let executablePath = draft.codexExecutablePath
        let connection = aiConnection
        guard let provider = provider ?? (environment.options.aiProvider as? AIModelCatalogProvider) else {
            modelCatalogMessage = "AI 연결을 사용할 수 없습니다. Codex CLI 경로 또는 API 설정을 확인하세요."; return
        }
        do {
            let models = try await provider.listAvailableModels()
            guard self.environment != nil, generation == catalogGeneration,
                  executablePath == draft.codexExecutablePath, connection == aiConnection else { return }
            aiTaskProfiles.models = models
            modelCatalogMessage = aiTaskProfiles.models.isEmpty
                ? "사용 가능한 모델이 없습니다. CLI 로그인 또는 API 키를 확인하세요."
                : "모델 \(aiTaskProfiles.models.count)개를 불러왔습니다. 저장하면 다음 AI 작업부터 적용됩니다."
        } catch {
            guard self.environment != nil, generation == catalogGeneration,
                  executablePath == draft.codexExecutablePath, connection == aiConnection else { return }
            modelCatalogMessage = "모델 목록을 불러오지 못했습니다. CLI 로그인 또는 API 주소·키를 확인하세요. 저장된 선택은 유지됩니다."
        }
    }
    /// Account changes invalidate in-flight catalog responses and persisted metadata, not user choices.
    public func accountConnectionChanged() {
        catalogGeneration += 1; hasRequestedModels = false; hasVerifiedAccount = false
        accountMessage = "로그인 상태를 다시 확인하세요."
        aiTaskProfiles.models = []; savedProfiles.models = []
        modelCatalogMessage = "계정이 바뀌었습니다. 사용할 수 있는 모델을 다시 불러오세요."
        do {
            var stored = try profileStore.load()
            stored.models = []
            try profileStore.save(stored)
        } catch {
            modelCatalogMessage = "기존 모델 목록 캐시를 지우지 못했습니다. 계정 모델을 다시 불러오세요."
        }
    }
    public func checkAccount(provider: AIProvider? = nil) async {
        guard !isCheckingAccount, let environment else { return }
        guard !hasUnsavedAIConnection else { accountMessage = "연결 설정을 먼저 저장하세요."; return }
        isCheckingAccount = true; hasVerifiedAccount = false; defer { isCheckingAccount = false }
        // No account reads at initialization, and no access to authentication files.
        guard let provider = provider ?? environment.options.aiProvider else {
            accountMessage = "AI 연결을 사용할 수 없습니다. Codex CLI 경로 또는 API 설정을 확인하세요."; return
        }
        let generation = catalogGeneration
        let connection = aiConnection
        do {
            let state = try await provider.getAccountStatus()
            guard self.environment != nil, generation == catalogGeneration, connection == aiConnection else { return }
            switch state {
            case .unknown: accountMessage = "로그인 상태를 확인할 수 없습니다."
            case .notInstalled: accountMessage = "AI 연결을 사용할 수 없습니다. Codex CLI 경로 또는 API 설정을 확인하세요."
            case .loggedOut: accountMessage = "로그인되어 있지 않습니다. 터미널에서 codex login을 실행하거나 API 키를 저장하세요."
            case .loggedIn(let type, let email, let plan):
                hasVerifiedAccount = true
                let enterprise = [type, plan].compactMap { $0 }.contains { $0.lowercased().contains("enterprise") }
                accountMessage = enterprise ? "Codex CLI 로그인됨 · Enterprise · 모델 사용 가능 여부는 실제 요청에서 확인합니다." : "AI 연결 확인됨 · 사용할 수 있는 모델을 조회하세요."
                if let email, !email.isEmpty { accountMessage = email + " · " + accountMessage }
            }
        } catch {
            guard self.environment != nil, generation == catalogGeneration, connection == aiConnection else { return }
            switch AIErrorClassifier.classify(error) {
            case .notInstalled: accountMessage = "AI 연결을 사용할 수 없습니다. Codex CLI 경로 또는 API 설정을 확인하세요."
            case .notLoggedIn, .authExpired: accountMessage = "인증을 확인하지 못했습니다. CLI 로그인 또는 API 키를 확인하세요."
            default: accountMessage = "로그인 상태 확인에 실패했습니다. CLI 또는 API 연결을 확인하세요."
            }
        }
    }
}
