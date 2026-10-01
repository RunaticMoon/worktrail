import Foundation
import Observation

@Observable @MainActor public final class SearchModel {
    public var text = "" { didSet { invalidateAnswer() } }
    public var types: Set<SearchSourceType>? { didSet { invalidateAnswer() } }
    public var projectIds: [String] = [] { didSet { invalidateAnswer() } }
    public var tagIds: [String] = [] { didSet { invalidateAnswer() } }
    public var range: DateRange? { didSet { invalidateAnswer() } }
    public private(set) var hits: [SearchHit] = []
    public private(set) var answer: GroundedAnswer?
    public private(set) var isSearching = false
    public private(set) var isAskingAI = false
    public private(set) var errorMessage: String?
    public private(set) var aiMessage: String?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private let environment: AppEnvironment
    public var isAIAvailable: Bool { environment.groundedAnswers != nil }
    public init(environment: AppEnvironment) {
        self.environment = environment
        if environment.groundedAnswers == nil { aiMessage = "AI가 비활성화되어 있습니다. 원문 검색은 사용할 수 있습니다." }
    }
    private func invalidateAnswer() { revision += 1; answer = nil; if isAIAvailable { aiMessage = nil } }
    /// Called after UI debounce. Never invokes a provider.
    public func search() {
        isSearching = true
        defer { isSearching = false }
        do {
            hits = try environment.search.search(SearchQuery(text: text, types: types,
                projectIds: projectIds, tagIds: tagIds, range: range))
            errorMessage = nil
        } catch { hits = []; errorMessage = "검색하지 못했습니다. 다시 시도하세요." }
    }
    /// The only AI entry point. Ignore obsolete responses after the user changes the query.
    public func askAI() async {
        guard !isAskingAI else { return }
        guard let service = environment.groundedAnswers else {
            aiMessage = "AI가 비활성화되어 있습니다. 원문 검색은 사용할 수 있습니다."; return
        }
        guard tagIds.isEmpty else {
            aiMessage = "태그 필터를 해제한 뒤 AI 답변을 요청하세요."; return
        }
        let requestRevision = revision
        isAskingAI = true; answer = nil; aiMessage = nil
        defer { isAskingAI = false }
        do {
            let result = try await service.answer(question: text,
                scope: GroundedAnswerScope(range: range, projectIds: projectIds, types: types))
            guard requestRevision == revision else { return }
            answer = result
            switch result.jobStatus {
            case .blockedAuth: aiMessage = "AI 인증을 확인한 뒤 다시 요청하세요."
            case .blockedPolicy: aiMessage = "회사 정책에 따라 AI 요청이 차단되었습니다."
            case .failed: aiMessage = "AI 답변을 만들지 못했습니다. 잠시 후 다시 요청하세요."
            case .cancelled: aiMessage = "AI 요청이 취소되었습니다."
            default: break
            }
        } catch {
            if requestRevision == revision { aiMessage = "질문을 확인한 뒤 AI 답변을 다시 요청하세요." }
        }
    }
}
