import Foundation
import Observation

/// 검색 화면의 복원 가능한 상태 묶음. 상세 sheet를 닫거나 패널을 다시 열 때 그대로 되돌린다.
/// restore는 AI를 호출하지 않는다.
public struct SearchState: Equatable, Sendable {
    public var text: String
    public var types: Set<SearchSourceType>?
    public var projectIds: [String]
    public var tagIds: [String]
    public var range: DateRange?
    public var selectedKey: SearchHitKey?
    public var isPreviewVisible: Bool

    public init(text: String, types: Set<SearchSourceType>? = nil, projectIds: [String] = [],
                tagIds: [String] = [], range: DateRange? = nil,
                selectedKey: SearchHitKey? = nil, isPreviewVisible: Bool = false) {
        self.text = text
        self.types = types
        self.projectIds = projectIds
        self.tagIds = tagIds
        self.range = range
        self.selectedKey = selectedKey
        self.isPreviewVisible = isPreviewVisible
    }
}

@Observable @MainActor public final class SearchModel {
    public var text = "" { didSet { invalidateAnswer() } }
    public var types: Set<SearchSourceType>? { didSet { invalidateAnswer() } }
    public var projectIds: [String] = [] { didSet { invalidateAnswer() } }
    public var tagIds: [String] = [] { didSet { invalidateAnswer() } }
    public var range: DateRange? { didSet { invalidateAnswer() } }
    public private(set) var hits: [SearchHit] = []
    public private(set) var selectedKey: SearchHitKey?
    public var isPreviewVisible = false
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

    /// 현재 선택된 결과. 결과 목록에 없으면 nil.
    public var selectedHit: SearchHit? {
        guard let selectedKey else { return nil }
        return hits.first { $0.key == selectedKey }
    }

    /// 적용 중인 필터 개수(유형·프로젝트·태그·기간).
    public var activeFilterCount: Int {
        (types == nil ? 0 : 1) + projectIds.count + tagIds.count + (range == nil ? 0 : 1)
    }

    /// 검색어는 있으나 결과가 없을 때의 안내 문구. 그 외에는 nil.
    public var emptyMessage: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, hits.isEmpty, !isSearching, errorMessage == nil else { return nil }
        let suffix = activeFilterCount > 0 ? " · 필터 \(activeFilterCount)개 적용 중" : ""
        return "‘\(trimmed)’와 일치하는 원문이 없습니다\(suffix)"
    }

    /// AI 답변을 지금 실행할 수 있는지. 검색어가 필요하고 태그 필터가 없어야 한다.
    public var canAskAI: Bool {
        isAIAvailable && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isAskingAI && tagIds.isEmpty
    }

    /// Called after UI debounce. Never invokes a provider.
    public func search() {
        isSearching = true
        defer { isSearching = false }
        do {
            hits = try environment.search.search(SearchQuery(text: text, types: types,
                projectIds: projectIds, tagIds: tagIds, range: range))
            errorMessage = nil
            if let selectedKey, !hits.contains(where: { $0.key == selectedKey }) {
                self.selectedKey = nil
            }
        } catch {
            hits = []; selectedKey = nil
            errorMessage = "검색하지 못했습니다. 다시 시도하세요."
        }
    }

    // MARK: - 선택

    /// 결과 항목을 선택한다.
    public func select(_ hit: SearchHit) { selectedKey = hit.key }

    /// ↑↓ 이동. nil에서 아래면 첫 결과, 위면 마지막. 양 끝에서 clamp된다.
    public func moveSelection(by delta: Int) {
        guard !hits.isEmpty else { selectedKey = nil; return }
        guard delta != 0 else { return }
        if let selectedKey, let index = hits.firstIndex(where: { $0.key == selectedKey }) {
            let next = min(max(index + delta, 0), hits.count - 1)
            self.selectedKey = hits[next].key
        } else {
            self.selectedKey = delta > 0 ? hits.first?.key : hits.last?.key
        }
    }

    /// Space 미리보기 토글. 선택이 없으면 무시한다.
    public func togglePreview() {
        guard selectedHit != nil else { return }
        isPreviewVisible.toggle()
    }

    // MARK: - 필터·상태

    /// 모든 필터를 해제하고 결과를 다시 조회한다.
    public func clearFilters() {
        types = nil
        projectIds = []
        tagIds = []
        range = nil
        search()
    }

    /// 현재 검색 상태를 복원용으로 복사한다.
    public func snapshot() -> SearchState {
        SearchState(text: text, types: types, projectIds: projectIds, tagIds: tagIds,
                    range: range, selectedKey: selectedKey, isPreviewVisible: isPreviewVisible)
    }

    /// 저장한 상태를 되돌리고 결과를 다시 조회한다. 선택은 결과에 있을 때만 유지한다.
    /// AI를 호출하지 않는다.
    public func restore(_ state: SearchState) {
        text = state.text
        types = state.types
        projectIds = state.projectIds
        tagIds = state.tagIds
        range = state.range
        selectedKey = state.selectedKey
        isPreviewVisible = state.isPreviewVisible
        search()
    }

    // MARK: - AI

    /// The only AI entry point. Ignore obsolete responses after the user changes the query.
    public func askAI() async {
        guard !isAskingAI else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            aiMessage = "질문할 내용을 입력하세요."; return
        }
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
