import Foundation

/// AI 작업과 편집 가능한 프롬프트 템플릿의 대응표 및 표시 정보.
public enum PromptCatalog {

    /// 작업별로 사용할 수 있는 템플릿 목적.
    public static func purposes(for job: AIJobType) -> [TemplatePurpose] {
        switch job {
        case .submissionWeekly:
            return [.submissionWeekly]
        case .performanceReport:
            return [.performanceDaily, .performancePeriodic]
        case .evidenceQuiz:
            return [.evidenceQuiz]
        case .memoTaskSuggestions:
            return [.memoTaskLinks]
        case .queryPlan:
            return [.queryPlan]
        case .groundedAnswer:
            return [.groundedAnswer]
        }
    }

    /// 템플릿 목적을 사용하는 AI 작업.
    public static func job(for purpose: TemplatePurpose) -> AIJobType {
        switch purpose {
        case .submissionWeekly:
            return .submissionWeekly
        case .performanceDaily, .performancePeriodic:
            return .performanceReport
        case .evidenceQuiz:
            return .evidenceQuiz
        case .memoTaskLinks:
            return .memoTaskSuggestions
        case .queryPlan:
            return .queryPlan
        case .groundedAnswer:
            return .groundedAnswer
        }
    }

    /// 설정 화면에서 사용할 한국어 표시명.
    public static func title(for purpose: TemplatePurpose) -> String {
        switch purpose {
        case .submissionWeekly:
            return "제출용 주간보고"
        case .performanceDaily:
            return "성과 리포트 · 일일"
        case .performancePeriodic:
            return "성과 리포트 · 주·월·분기·연간"
        case .evidenceQuiz:
            return "성과 보충 질문"
        case .memoTaskLinks:
            return "메모-업무 연결 제안"
        case .queryPlan:
            return "검색 질의 정리"
        case .groundedAnswer:
            return "기록 기반 답변"
        }
    }

    /// 해당 목적의 내장 기본 템플릿 원본.
    public static func builtInDefault(for purpose: TemplatePurpose) -> DefaultTemplate {
        DefaultPrompts.template(for: purpose)
    }

    /// 검색 질의 정리 템플릿은 현재 검색 경로에서 호출되지 않는다.
    public static func usageNote(for job: AIJobType) -> String? {
        switch job {
        case .submissionWeekly, .performanceReport, .evidenceQuiz,
             .memoTaskSuggestions, .groundedAnswer:
            return nil
        case .queryPlan:
            return "현재 검색 경로에서 사용되지 않습니다."
        }
    }

    /// TemplateStore가 사용자 지침 앞에 항상 붙이는 공통 보호 지침.
    public static var protectedPreamble: String {
        DefaultPrompts.commonInstructions
    }
}
