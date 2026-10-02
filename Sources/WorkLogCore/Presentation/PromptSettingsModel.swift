import Foundation
import Observation

/// 설정 화면에서 작업별 프롬프트(템플릿 지침·출력 예시)를 보고·수정·기본값 복원하는 모델.
///
/// - 저장은 `work.sqlite`의 기존 `report_template.active_version_id` / `template_version`을 쓴다.
///   설정 JSON이나 `skillBindings`와 무관하게 독립적으로 동작한다.
/// - 공통 보호 지침(`protectedPreamble`)은 읽기 전용 표시이며 편집 대상이 아니다.
/// - 과거 버전은 삭제·수정하지 않는다. 수정·복원은 항상 새 버전을 만든다(동일 내용이면 no-op).
@Observable @MainActor public final class PromptSettingsModel {

    @ObservationIgnored private var templates: TemplateStore?
    @ObservationIgnored private var templateId: String?
    @ObservationIgnored private var activeSkillRef: String?

    /// 현재 편집 중인 템플릿 목적. `load` 전에는 nil.
    public private(set) var purpose: TemplatePurpose?

    /// 편집 중 초안.
    public var instructions: String = ""
    public var outputExample: String = ""

    /// 현재 활성 버전에 저장된 값.
    public private(set) var savedInstructions: String = ""
    public private(set) var savedOutputExample: String = ""

    /// 현재 활성 버전 번호.
    public private(set) var activeVersionNumber: Int?

    /// 내장 기본값(읽기 전용 표시).
    public private(set) var builtInInstructions: String = ""
    public private(set) var builtInOutputExample: String = ""

    public private(set) var errorMessage: String?
    public private(set) var message: String?

    public init(templates: TemplateStore) {
        self.templates = templates
    }

    /// TemplateStore가 항상 맨 앞에 붙이는 공통 보호 지침. 편집할 수 없다.
    public var protectedPreamble: String { PromptCatalog.protectedPreamble }

    /// 초안이 활성 버전과 다른가.
    public var hasChanges: Bool {
        purpose != nil && (instructions != savedInstructions || outputExample != savedOutputExample)
    }

    /// 활성 내용이 내장 기본값과 같은가.
    public var isBuiltInActive: Bool {
        purpose != nil
            && savedInstructions == builtInInstructions
            && savedOutputExample == builtInOutputExample
    }

    // MARK: - 불러오기

    /// 선호 템플릿 → 활성 버전을 읽어 초안과 내장 기본값을 채운다.
    /// 템플릿이 없으면 기본값을 시드한 뒤 한 번 더 시도하고, 그래도 없으면 오류 메시지를 남긴다.
    public func load(purpose: TemplatePurpose) {
        self.purpose = purpose
        errorMessage = nil
        message = nil

        let builtIn = PromptCatalog.builtInDefault(for: purpose)
        builtInInstructions = builtIn.instructions
        builtInOutputExample = builtIn.outputExample

        guard let templates else {
            templateId = nil
            clearActiveState()
            errorMessage = "프롬프트 저장소를 사용할 수 없습니다."
            return
        }

        do {
            var preferred = try templates.preferredTemplate(for: purpose)
            if preferred == nil {
                try templates.seedDefaults()
                preferred = try templates.preferredTemplate(for: purpose)
            }
            guard let template = preferred else {
                templateId = nil
                clearActiveState()
                errorMessage = "이 작업의 프롬프트 템플릿을 찾을 수 없습니다."
                return
            }
            templateId = template.id
            guard let active = try templates.activeVersion(templateId: template.id) else {
                templateId = nil
                clearActiveState()
                errorMessage = "활성 프롬프트 버전을 찾을 수 없습니다."
                return
            }
            apply(active)
        } catch {
            templateId = nil
            clearActiveState()
            errorMessage = "프롬프트를 불러오지 못했습니다."
        }
    }

    // MARK: - 저장

    /// 초안을 새 버전으로 저장하고 활성화한다.
    /// 빈 지침은 거절하고, 변경이 없으면 아무 것도 하지 않고 true를 반환한다.
    @discardableResult
    public func save() -> Bool {
        guard let templates, let templateId else {
            errorMessage = "프롬프트 템플릿을 먼저 불러오세요."
            message = nil
            return false
        }
        guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "프롬프트 지침을 비워 둘 수 없습니다."
            message = nil
            return false
        }
        guard hasChanges else {
            message = "변경된 내용이 없습니다."
            errorMessage = nil
            return true
        }
        do {
            let version = try templates.saveNewVersion(templateId: templateId,
                                                       instructions: instructions,
                                                       outputExample: outputExample,
                                                       skillRef: activeSkillRef)
            apply(version)
            message = "프롬프트를 저장했습니다."
            errorMessage = nil
            return true
        } catch {
            // 경로·SQL 원문은 노출하지 않는다.
            errorMessage = "프롬프트를 저장하지 못했습니다."
            message = nil
            return false
        }
    }

    /// 내장 기본 내용을 새 버전으로 저장한다. 과거 버전은 삭제·수정하지 않는다.
    /// 이미 내장 기본값이 활성이면 새 버전을 만들지 않고 초안만 되돌린다.
    @discardableResult
    public func restoreBuiltInDefault() -> Bool {
        guard let templates, let templateId else {
            errorMessage = "프롬프트 템플릿을 먼저 불러오세요."
            message = nil
            return false
        }
        if isBuiltInActive {
            instructions = savedInstructions
            outputExample = savedOutputExample
            message = "이미 내장 기본값을 사용하고 있습니다."
            errorMessage = nil
            return true
        }
        do {
            let version = try templates.saveNewVersion(templateId: templateId,
                                                       instructions: builtInInstructions,
                                                       outputExample: builtInOutputExample,
                                                       skillRef: activeSkillRef)
            apply(version)
            message = "내장 기본값으로 복원했습니다."
            errorMessage = nil
            return true
        } catch {
            errorMessage = "기본값을 복원하지 못했습니다."
            message = nil
            return false
        }
    }

    // MARK: - 초안

    /// 초안을 현재 활성 버전 값으로 되돌린다.
    public func discardChanges() {
        instructions = savedInstructions
        outputExample = savedOutputExample
        errorMessage = nil
        message = nil
    }

    /// 저장소 참조를 놓는다. 백업 복원 등에서 DB를 붙잡지 않게 한다.
    public func detach() {
        templates = nil
        templateId = nil
        activeSkillRef = nil
    }

    // MARK: - 내부

    private func apply(_ version: TemplateVersion) {
        activeSkillRef = version.skillRef
        savedInstructions = version.instructions
        savedOutputExample = version.outputExample
        activeVersionNumber = version.version
        instructions = version.instructions
        outputExample = version.outputExample
        errorMessage = nil
        message = nil
    }

    private func clearActiveState() {
        activeSkillRef = nil
        savedInstructions = ""
        savedOutputExample = ""
        activeVersionNumber = nil
        instructions = ""
        outputExample = ""
    }
}
