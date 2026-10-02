import Foundation
import Observation

@Observable @MainActor public final class QuizModel {
    public private(set) var questions: [QuizQuestion] = []
    public var answers: [String: String] = [:]
    public private(set) var recorded: [String: SupplementOutcome] = [:]
    public private(set) var isGenerating = false
    public private(set) var message: String?
    public var isAvailable: Bool { environment.quiz != nil }
    public var canGenerate: Bool { isAvailable && !isGenerating }
    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private var generation = UUID()
    public init(environment: AppEnvironment) { self.environment = environment }
    public func reset() {
        generation = UUID(); questions = []; answers = [:]; recorded = [:]; message = nil
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
            questions = result.questions; recorded = [:]
            if result.jobStatus != .succeeded { message = "질문 생성 상태: \(result.jobStatus.rawValue). AI 연결을 확인하고 다시 요청하세요." }
            else if !result.warnings.isEmpty { message = result.warnings.joined(separator: "\n") }
            else if questions.isEmpty { message = "현재 근거에서 보충할 질문이 없습니다." }
        } catch { if generation == token { message = "질문을 생성하지 못했습니다. 다시 요청하세요." } }
    }
    public func record(_ id: String, outcome: SupplementOutcome) {
        guard let service = environment.quiz, let question = questions.first(where: { $0.id == id }), recorded[id] == nil else { return }
        do {
            _ = try service.record(question, outcome: outcome, answer: answers[id])
            recorded[id] = outcome; message = nil
        } catch { message = "답변을 저장하지 못했습니다. 답변 내용을 확인하고 다시 저장하세요." }
    }
}
