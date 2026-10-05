import Foundation
import Observation

@Observable @MainActor public final class QuizModel {
    public private(set) var questions: [QuizQuestion] = []
    public var answers: [String: String] = [:]
    public private(set) var recorded: [String: SupplementOutcome] = [:]
    public private(set) var isGenerating = false
    public private(set) var message: String?
    /// 한 장씩 보여줄 때의 현재 위치(질문 배열 인덱스).
    public private(set) var currentIndex = 0
    /// 아직 기록되지 않은 질문 중 currentIndex 이상 첫 번째. 없으면 앞쪽에서 찾는다.
    public var currentQuestion: QuizQuestion? {
        guard !questions.isEmpty else { return nil }
        if currentIndex < questions.count,
           let forward = questions[currentIndex...].first(where: { recorded[$0.id] == nil }) {
            return forward
        }
        return questions[..<min(currentIndex, questions.count)].first(where: { recorded[$0.id] == nil })
    }
    /// 아직 기록되지 않은 질문 수.
    public var remainingCount: Int { questions.filter { recorded[$0.id] == nil }.count }
    public var isAvailable: Bool { environment.quiz != nil }
    public var canGenerate: Bool { isAvailable && !isGenerating }
    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private var generation = UUID()
    public init(environment: AppEnvironment) { self.environment = environment }
    public func reset() {
        generation = UUID(); questions = []; answers = [:]; recorded = [:]; message = nil; currentIndex = 0
    }
    public func generate(reportDate: WorkDate) async {
        guard canGenerate, let service = environment.quiz else { return }
        let token = generation
        isGenerating = true; message = nil
        defer { isGenerating = false }
        do {
            let facts = try environment.factsBuilder.submissionFacts(reportDate: reportDate, knownAt: environment.options.clock.now())
            let result = try await service.generate(facts: facts)
            guard generation == token else { return }
            questions = result.questions; recorded = [:]; currentIndex = 0
            if result.jobStatus != .succeeded { message = "질문 생성 상태: \(result.jobStatus.rawValue). AI 연결을 확인하고 다시 요청하세요." }
            else if !result.warnings.isEmpty { message = result.warnings.joined(separator: "\n") }
            else if questions.isEmpty { message = "현재 근거에서 보충할 질문이 없습니다." }
        } catch { if generation == token { message = "질문을 생성하지 못했습니다. 다시 요청하세요." } }
    }
    /// 기록되지 않은 다음 질문으로 이동한다(현재 위치에서 앞으로, 없으면 그대로 둔다).
    public func showNext() {
        guard let current = currentQuestion,
              let index = questions.firstIndex(where: { $0.id == current.id }) else { return }
        currentIndex = questions.indices.first(where: { $0 > index && recorded[questions[$0].id] == nil }) ?? index
    }
    /// 기록되지 않은 이전 질문으로 이동한다(현재 위치에서 뒤로, 없으면 그대로 둔다).
    public func showPrevious() {
        guard let current = currentQuestion,
              let index = questions.firstIndex(where: { $0.id == current.id }) else { return }
        currentIndex = questions.indices.last(where: { $0 < index && recorded[questions[$0].id] == nil }) ?? index
    }
    public func record(_ id: String, outcome: SupplementOutcome) {
        guard let service = environment.quiz, let index = questions.firstIndex(where: { $0.id == id }),
              recorded[id] == nil else { return }
        do {
            _ = try service.record(questions[index], outcome: outcome, answer: answers[id])
            recorded[id] = outcome; message = nil
            // 기록한 질문을 지나 다음 미기록 질문으로 자동 이동한다.
            currentIndex = questions.indices.first(where: { $0 > index && recorded[questions[$0].id] == nil }) ?? index
        } catch { message = "답변을 저장하지 못했습니다. 답변 내용을 확인하고 다시 저장하세요." }
    }
}
