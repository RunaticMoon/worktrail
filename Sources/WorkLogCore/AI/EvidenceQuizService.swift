import Foundation
import Crypto

// 성과 보충 질문 카드(QUIZ-01 / QUIZ-02).
//
// - ReportFacts에서 부족한 성과 근거를 묻는 질문을 회사 AI(AIJobRunner)로 만든다.
// - 답변은 입력한 날(recordedAt)이 아니라 질문의 적용 기간(applies)에 귀속한다.
// - 이미 답한/제외한 주제는 같은 근거(digest)에서 반복 생성하지 않는다.
// - Secret 자료형·파일 경로·설정은 이 경로의 어떤 입력에도 넣지 않는다.

/// 회사 AI가 돌려주는 성과 보충 질문 결과 계약(P-04).
public struct EvidenceQuizOutput: Codable, Sendable, Hashable {
    public struct Question: Codable, Sendable, Hashable {
        public var taskId: String
        public var topicKey: String
        public var question: String
        public var context: String?
        public var evidenceIds: [String]
        public var appliesStart: String?
        public var appliesEndExclusive: String?
    }

    public var schemaVersion: Int
    public var jobType: String
    public var questions: [Question]
}

/// 검증을 통과한 질문 카드. 답변 저장의 기준이 된다.
public struct QuizQuestion: Codable, Sendable, Hashable, Identifiable {
    /// "quiz:<taskId>:<topicKey>:<sourceDigest 앞 12자>"
    public var id: String
    public var taskId: String
    public var topicKey: String
    public var question: String
    public var context: String?
    public var evidenceIds: [String]
    /// 질문이 설명하는 업무 기간(입력한 날이 아님).
    public var applies: DateRange
    public var sourceDigest: String
}

public struct QuizResult: Sendable {
    public var questions: [QuizQuestion]
    public var jobStatus: AIJobStatus
    public var warnings: [String]

    public init(questions: [QuizQuestion], jobStatus: AIJobStatus, warnings: [String]) {
        self.questions = questions
        self.jobStatus = jobStatus
        self.warnings = warnings
    }
}

public final class EvidenceQuizService: @unchecked Sendable {

    private let repo: WorkRepository
    private let runner: AIJobRunner
    private let templates: TemplateStore
    private let maxQuestions: Int

    public init(repo: WorkRepository, runner: AIJobRunner, templates: TemplateStore,
                maxQuestions: Int = 3) {
        self.repo = repo
        self.runner = runner
        self.templates = templates
        self.maxQuestions = maxQuestions
    }

    // MARK: - Digest

    /// Task별 근거 digest. Task와 그 Task에 속한 FactSource들을 결정적 JSON으로 묶어 SHA256.
    /// source.taskId로 연결된 근거와 activitySourceIds로 연결된 근거를 모두 포함한다.
    public static func taskDigest(_ task: FactTask, facts: ReportFacts) throws -> String {
        let sources = facts.sources
            .filter { task.activitySourceIds.contains($0.id) || $0.taskId == task.id }
            .sorted { $0.id < $1.id }
        let input = TaskDigestInput(task: task, sources: sources)
        let json = try StableJSON.encode(input)
        return SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Payload

    /// AI에 보낼 입력 JSON(StableJSON). Secret·파일 경로·설정은 포함하지 않는다.
    public func buildPayload(facts: ReportFacts) throws -> String {
        try payload(facts: facts, excludedTopics: try excludedTopicPairs(facts))
    }

    // MARK: - 생성

    public func generate(facts: ReportFacts) async throws -> QuizResult {
        let excluded = try excludedTopicPairs(facts)
        let payloadJSON = try payload(facts: facts, excludedTopics: excluded)
        let (versionId, instructions) = try resolveTemplate()

        let request = AIJobRequest(jobType: .evidenceQuiz,
                                   periodStart: facts.range.start,
                                   periodEndExclusive: facts.range.endExclusive,
                                   instructions: instructions,
                                   payloadJSON: payloadJSON,
                                   templateVersionId: versionId)
        let result = try await runner.submit(request)

        // AI 실패·차단은 예외가 아니라 상태로 환원한다.
        guard result.job.status == .succeeded else {
            return QuizResult(questions: [], jobStatus: result.job.status, warnings: [])
        }
        guard let raw = result.output?.rawJSON.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return QuizResult(questions: [], jobStatus: result.job.status,
                              warnings: ["AI가 성과 보충 질문 결과를 반환하지 않았습니다."])
        }

        let output: EvidenceQuizOutput
        do {
            output = try StableJSON.decode(EvidenceQuizOutput.self, from: raw)
        } catch {
            return QuizResult(questions: [], jobStatus: result.job.status,
                              warnings: ["성과 보충 질문 결과 형식이 올바르지 않습니다."])
        }
        guard output.schemaVersion == 1, output.jobType == AIJobType.evidenceQuiz.rawValue else {
            return QuizResult(questions: [], jobStatus: result.job.status,
                              warnings: ["성과 보충 질문 결과 계약이 맞지 않습니다."])
        }

        return try validateQuestions(output.questions, facts: facts, excluded: Set(excluded))
    }

    // MARK: - 답변 저장

    /// 답변/확인한 결과 없음/나중에/제외를 EvidenceSupplement로 저장한다.
    /// answered는 trim 후 비면 validation 오류, 나머지 outcome의 answer는 nil로 저장한다.
    /// Task 상태는 바꾸지 않는다.
    public func record(_ question: QuizQuestion, outcome: SupplementOutcome,
                       answer: String?) throws -> EvidenceSupplement {
        let storedAnswer: String?
        switch outcome {
        case .answered:
            let trimmed = (answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw WorkLogError.validation("성과 보충 답변이 비어 있습니다.")
            }
            storedAnswer = trimmed
        case .noResult, .later, .excluded:
            storedAnswer = nil
        }

        let supplement = EvidenceSupplement(id: repo.ids.make(), taskId: question.taskId,
                                            topicKey: question.topicKey, question: question.question,
                                            answer: storedAnswer, outcome: outcome,
                                            applies: question.applies, sourceDigest: question.sourceDigest,
                                            recordedAt: repo.clock.now())
        try repo.insertSupplement(supplement)
        return supplement
    }

    // MARK: - 내부

    /// (taskId, topicKey) 쌍. digest 변화와 무관하게 항상 제외되는 excluded도 포함한다.
    private func excludedTopicPairs(_ facts: ReportFacts) throws -> [TopicKeyPair] {
        var result: [TopicKeyPair] = []
        var seen = Set<TopicKeyPair>()
        for task in facts.tasks {
            let digest = try Self.taskDigest(task, facts: facts)
            for supplement in try repo.supplements(taskId: task.id) {
                let excluded: Bool
                switch supplement.outcome {
                case .answered, .noResult:
                    // 같은 근거(digest)에서만 반복을 막는다. 근거가 바뀌면 다시 물을 수 있다.
                    excluded = supplement.sourceDigest == digest
                case .excluded:
                    // 사용자가 제외한 주제는 근거가 바뀌어도 계속 제외한다.
                    excluded = true
                case .later:
                    excluded = false
                }
                guard excluded else { continue }
                let pair = TopicKeyPair(taskId: supplement.taskId, topicKey: supplement.topicKey)
                if seen.insert(pair).inserted {
                    result.append(pair)
                }
            }
        }
        return result
    }

    private func payload(facts: ReportFacts, excludedTopics: [TopicKeyPair]) throws -> String {
        let tasks = facts.tasks.map { task in
            QuizPayload.Task(id: task.id, title: task.title,
                             statusAtCutoff: task.statusAtCutoff?.rawValue,
                             completionDatesInRange: task.completionDatesInRange.map(\.iso),
                             sourceIds: task.activitySourceIds)
        }
        let sources = facts.sources.map { source in
            QuizPayload.Source(id: source.id, kind: source.kind.rawValue,
                               workDate: source.workDate?.iso, text: source.text)
        }
        let excluded = excludedTopics.map {
            QuizPayload.ExcludedTopic(taskId: $0.taskId, topicKey: $0.topicKey)
        }
        let body = QuizPayload(jobType: AIJobType.evidenceQuiz.rawValue, maxQuestions: maxQuestions,
                               range: QuizPayload.Range(start: facts.range.start.iso,
                                                        endExclusive: facts.range.endExclusive.iso),
                               tasks: tasks, sources: sources, excludedTopics: excluded)
        return try StableJSON.string(body)
    }

    /// 질문별 검증. 실패는 건너뛰고 warning으로 남긴다. 입력 순서를 유지하고 maxQuestions로 제한한다.
    private func validateQuestions(_ rawQuestions: [EvidenceQuizOutput.Question],
                                   facts: ReportFacts, excluded: Set<TopicKeyPair>) throws
        -> QuizResult {
        var warnings: [String] = []
        var questions: [QuizQuestion] = []
        var seenTopics = Set<TopicKeyPair>()
        let sourceIds = facts.sourceIds
        let pattern = #"^[a-z][a-z0-9_]{0,39}$"#

        for raw in rawQuestions {
            if questions.count >= maxQuestions { break }

            guard let task = facts.task(raw.taskId) else {
                warnings.append("알 수 없는 Task의 질문을 건너뜀")
                continue
            }

            let topicKey = raw.topicKey
            guard topicKey.range(of: pattern, options: .regularExpression) != nil else {
                warnings.append("주제 키 형식이 올바르지 않은 질문을 건너뜀")
                continue
            }

            let text = raw.question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 200 else {
                warnings.append("질문 길이가 올바르지 않은 질문을 건너뜀")
                continue
            }

            guard sourceIds.isSuperset(of: raw.evidenceIds) else {
                warnings.append("근거 ID를 확인할 수 없는 질문을 건너뜀")
                continue
            }

            let pair = TopicKeyPair(taskId: raw.taskId, topicKey: topicKey)
            guard !excluded.contains(pair) else {
                warnings.append("이미 답했거나 제외한 주제의 질문을 건너뜀")
                continue
            }
            guard seenTopics.insert(pair).inserted else {
                warnings.append("중복 주제의 질문을 건너뜀")
                continue
            }

            var applies = facts.range
            if let start = raw.appliesStart.flatMap({ WorkDate($0) }),
               let end = raw.appliesEndExclusive.flatMap({ WorkDate($0) }),
               start < end {
                let candidate = DateRange(start: start, endExclusive: end)
                if facts.range.start <= candidate.start,
                   candidate.endExclusive <= facts.range.endExclusive {
                    applies = candidate
                } else {
                    warnings.append("적용 기간을 리포트 기간으로 보정")
                }
            } else {
                warnings.append("적용 기간을 리포트 기간으로 보정")
            }

            if text.contains("%") || text.contains("퍼센트") {
                warnings.append("수치 전제 질문 검토 필요")
            }

            let digest = try Self.taskDigest(task, facts: facts)
            let id = "quiz:\(raw.taskId):\(topicKey):\(digest.prefix(12))"
            questions.append(QuizQuestion(id: id, taskId: raw.taskId, topicKey: topicKey,
                                          question: text, context: raw.context,
                                          evidenceIds: raw.evidenceIds, applies: applies,
                                          sourceDigest: digest))
        }

        return QuizResult(questions: questions, jobStatus: .succeeded, warnings: warnings)
    }

    /// 템플릿이 없으면 seedDefaults 후 재시도한다. {{maxQuestions}}를 숫자로 치환한다.
    private func resolveTemplate() throws -> (versionId: String, instructions: String) {
        var template = try templates.preferredTemplate(for: .evidenceQuiz)
        if template == nil {
            try templates.seedDefaults()
            template = try templates.preferredTemplate(for: .evidenceQuiz)
        }
        guard let template else {
            throw WorkLogError.notFound("evidence_quiz 템플릿이 없습니다.")
        }
        guard let version = try templates.activeVersion(templateId: template.id) else {
            throw WorkLogError.notFound("evidence_quiz 활성 템플릿 버전이 없습니다.")
        }
        let instructions = try templates.composeInstructions(versionId: version.id)
            .replacingOccurrences(of: "{{maxQuestions}}", with: String(maxQuestions))
        return (version.id, instructions)
    }
}

// MARK: - 부속 타입

/// (taskId, topicKey)로 질문 주제를 식별한다.
private struct TopicKeyPair: Hashable {
    var taskId: String
    var topicKey: String
}

/// digest 입력 구조. 키 정렬 인코딩으로 결정적이다.
private struct TaskDigestInput: Codable {
    var task: FactTask
    var sources: [FactSource]
}

/// AI 입력 payload 계약. Secret·파일 경로·설정을 포함하지 않는다.
private struct QuizPayload: Codable {
    struct Range: Codable {
        var start: String
        var endExclusive: String
    }
    struct Task: Codable {
        var id: String
        var title: String
        var statusAtCutoff: String?
        var completionDatesInRange: [String]
        var sourceIds: [String]
    }
    struct Source: Codable {
        var id: String
        var kind: String
        var workDate: String?
        var text: String
    }
    struct ExcludedTopic: Codable {
        var taskId: String
        var topicKey: String
    }

    var jobType: String
    var maxQuestions: Int
    var range: Range
    var tasks: [Task]
    var sources: [Source]
    var excludedTopics: [ExcludedTopic]
}
