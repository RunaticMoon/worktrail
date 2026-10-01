import Foundation

// 기록 기반 AI 답변(SEARCH-02 / P-07).
//
// - 사용자가 명시적으로 실행할 때만 동작한다. 타이핑 중 자동 실행은 없다.
// - 로컬 원문 검색(SearchIndex)으로 일반 기록 근거를 모아 회사 AI(AIJobRunner)에 보내고,
//   결과를 검증해 근거 링크가 붙은 답변으로 돌려준다.
// - Secret(vault)은 검색 인덱스에 없으며 이 코드는 vault 관련 타입을 참조하지 않는다.
// - 답변 결과는 DB에 저장하지 않는다(답변 히스토리는 범위 밖).

/// 답변 검색 범위. 주어지지 않은 항목은 넓히지 않는다.
public struct GroundedAnswerScope: Sendable, Hashable {
    public var range: DateRange?
    public var projectIds: [String]
    public var types: Set<SearchSourceType>?

    public init(range: DateRange? = nil, projectIds: [String] = [], types: Set<SearchSourceType>? = nil) {
        self.range = range
        self.projectIds = projectIds
        self.types = types
    }
}

/// AI에 보낸 근거 한 건. id는 원문 이동 UI용 "<sourceType>:<sourceId>" 형식이다.
public struct EvidenceRef: Sendable, Hashable, Codable {
    public var id: String
    public var sourceType: SearchSourceType
    public var sourceId: String
    public var workDate: WorkDate?
    public var snippet: String

    public init(id: String, sourceType: SearchSourceType, sourceId: String,
                workDate: WorkDate?, snippet: String) {
        self.id = id
        self.sourceType = sourceType
        self.sourceId = sourceId
        self.workDate = workDate
        self.snippet = snippet
    }
}

/// 검증된 답변 문단. evidence는 이 문단이 실제로 인용한 유효 근거만 담는다.
public struct GroundedParagraph: Sendable, Hashable {
    public var text: String
    public var evidence: [EvidenceRef]

    public init(text: String, evidence: [EvidenceRef]) {
        self.text = text
        self.evidence = evidence
    }
}

/// 기록 기반 답변 결과.
public struct GroundedAnswer: Sendable {
    public var question: String
    public var paragraphs: [GroundedParagraph]
    public var missingEvidence: [String]
    public var warnings: [String]
    /// AI를 호출하지 않았으면 nil.
    public var jobStatus: AIJobStatus?
    /// AI에 보낸 근거 전체.
    public var evidencePool: [EvidenceRef]

    public init(question: String, paragraphs: [GroundedParagraph], missingEvidence: [String],
                warnings: [String], jobStatus: AIJobStatus?, evidencePool: [EvidenceRef]) {
        self.question = question
        self.paragraphs = paragraphs
        self.missingEvidence = missingEvidence
        self.warnings = warnings
        self.jobStatus = jobStatus
        self.evidencePool = evidencePool
    }
}

/// P-07 결과 계약(P-07 반환 형식)과 1:1 대응하는 검증용 모델.
public struct GroundedAnswerOutput: Codable, Sendable, Hashable {
    public struct Paragraph: Codable, Sendable, Hashable {
        public var text: String
        public var evidenceIds: [String]

        public init(text: String, evidenceIds: [String]) {
            self.text = text
            self.evidenceIds = evidenceIds
        }
    }

    public var schemaVersion: Int
    public var jobType: String
    public var paragraphs: [Paragraph]
    public var missingEvidence: [String]
    public var warnings: [String]

    public init(schemaVersion: Int, jobType: String, paragraphs: [Paragraph],
                missingEvidence: [String], warnings: [String]) {
        self.schemaVersion = schemaVersion
        self.jobType = jobType
        self.paragraphs = paragraphs
        self.missingEvidence = missingEvidence
        self.warnings = warnings
    }
}

/// 명시적으로 실행하는 기록 기반 AI 답변 서비스.
///
/// `collectEvidence`는 AI 없이 결정적으로 근거만 모은다(UI 미리보기·테스트용).
/// `answer`는 근거가 없으면 AI를 호출하지 않고, 있으면 템플릿 지시문·StableJSON payload로
/// `AIJobRunner`에 보낸 뒤 출력을 검증한다.
public final class GroundedAnswerService {

    /// 근거를 찾지 못했을 때의 missingEvidence 문구.
    public static let missingEvidenceMessage = "질문과 관련된 기록을 찾지 못했습니다."
    /// AI 결과가 계약을 벗어났을 때의 warning 문구.
    public static let formatErrorMessage = "AI 결과 형식 오류"
    /// 질문 최대 길이(문자).
    public static let maxQuestionLength = 500

    private let index: SearchIndex
    private let runner: AIJobRunner
    private let templates: TemplateStore
    private let maxEvidence: Int

    public init(index: SearchIndex, runner: AIJobRunner, templates: TemplateStore, maxEvidence: Int = 20) {
        self.index = index
        self.runner = runner
        self.templates = templates
        self.maxEvidence = maxEvidence
    }

    // MARK: - 근거 수집

    /// AI 없이 결정적으로 근거만 모은다.
    /// (a) 질문 전체 문자열 검색 → (b) 질문을 공백으로 나눈 각 단어(문장부호 제거) 검색.
    /// (sourceType, sourceId) 기준 중복 제거, 최대 maxEvidence.
    public func collectEvidence(question: String, scope: GroundedAnswerScope) throws -> [EvidenceRef] {
        let trimmed = try Self.validatedQuestion(question)

        var terms: [String] = [trimmed]
        for raw in trimmed.split(whereSeparator: { $0.isWhitespace }) {
            let cleaned = Self.stripPunctuation(String(raw))
            if !cleaned.isEmpty { terms.append(cleaned) }
        }

        var seen = Set<String>()
        var refs: [EvidenceRef] = []
        for term in terms {
            if refs.count >= maxEvidence { break }
            let hits = try index.search(SearchQuery(text: term, types: scope.types,
                                                    projectIds: scope.projectIds,
                                                    range: scope.range, limit: maxEvidence))
            for hit in hits {
                if refs.count >= maxEvidence { break }
                let id = Self.evidenceId(sourceType: hit.sourceType, sourceId: hit.sourceId)
                guard seen.insert(id).inserted else { continue }
                refs.append(EvidenceRef(id: id, sourceType: hit.sourceType, sourceId: hit.sourceId,
                                        workDate: hit.workDate, snippet: hit.snippet))
            }
        }
        return refs
    }

    // MARK: - payload

    /// AI에 보내는 StableJSON payload. 파일 경로·설정·Secret을 넣지 않는다.
    public func buildPayload(question: String, evidence: [EvidenceRef]) throws -> String {
        let trimmed = try Self.validatedQuestion(question)
        let payload = Payload(
            jobType: AIJobType.groundedAnswer.rawValue,
            question: trimmed,
            sources: evidence.map {
                Payload.Source(id: $0.id, sourceType: $0.sourceType.rawValue,
                               workDate: $0.workDate, text: $0.snippet)
            }
        )
        return try StableJSON.string(payload)
    }

    // MARK: - 답변

    /// 명시 실행 경로. 근거가 없으면 AI를 호출하지 않는다.
    public func answer(question: String, scope: GroundedAnswerScope) async throws -> GroundedAnswer {
        let trimmed = try Self.validatedQuestion(question)
        let pool = try collectEvidence(question: trimmed, scope: scope)

        // 근거 0개 → AI 호출 없음.
        guard !pool.isEmpty else {
            return GroundedAnswer(question: trimmed, paragraphs: [],
                                  missingEvidence: [Self.missingEvidenceMessage],
                                  warnings: [], jobStatus: nil, evidencePool: [])
        }

        let payload = try buildPayload(question: trimmed, evidence: pool)
        guard let template = try resolvedTemplate() else {
            throw WorkLogError.storage("기록 기반 답변 템플릿을 찾을 수 없습니다.")
        }
        let instructions = template.instructions
            .replacingOccurrences(of: "{{question}}", with: trimmed)
        let request = AIJobRequest(jobType: .groundedAnswer, instructions: instructions,
                                   payloadJSON: payload, templateVersionId: template.versionId,
                                   regenerationNonce: nil)

        let result = try await runner.submit(request)
        return Self.interpret(result: result, question: trimmed, pool: pool)
    }

    // MARK: - 내부

    /// preferredTemplate → activeVersion → composeInstructions.
    /// 템플릿이 없으면 seedDefaults 후 한 번 더 시도한다.
    private func resolvedTemplate() throws -> (versionId: String, instructions: String)? {
        func active() throws -> (versionId: String, instructions: String)? {
            guard let preferred = try templates.preferredTemplate(for: .groundedAnswer),
                  let version = try templates.activeVersion(templateId: preferred.id) else {
                return nil
            }
            return (version.id, try templates.composeInstructions(versionId: version.id))
        }
        if let found = try active() { return found }
        _ = try templates.seedDefaults()
        return try active()
    }

    /// provider 오류는 예외로 던지지 않고 상태로 환원한다.
    private static func interpret(result: AIJobResult, question: String, pool: [EvidenceRef]) -> GroundedAnswer {
        guard result.job.status == .succeeded else {
            return GroundedAnswer(question: question, paragraphs: [], missingEvidence: [],
                                  warnings: [], jobStatus: result.job.status, evidencePool: pool)
        }

        guard let output = result.output,
              let decoded = try? decodeOutput(output.rawJSON) else {
            return GroundedAnswer(question: question, paragraphs: [], missingEvidence: [],
                                  warnings: [Self.formatErrorMessage],
                                  jobStatus: result.job.status, evidencePool: pool)
        }

        let poolById = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var warnings: [String] = []
        var paragraphs: [GroundedParagraph] = []

        for paragraph in decoded.paragraphs {
            var evidence: [EvidenceRef] = []
            var seenIds = Set<String>()
            for id in paragraph.evidenceIds {
                guard let ref = poolById[id] else {
                    warnings.append("알 수 없는 근거 제거: \(id)")
                    continue
                }
                guard seenIds.insert(id).inserted else { continue }
                evidence.append(ref)
            }

            var text = paragraph.text
            let html = removeHTMLTags(text)
            text = html.text
            if html.removed { warnings.append("본문에서 HTML 태그를 제거했습니다.") }

            let links = replaceUngroundedLinks(in: text, evidenceSnippets: evidence.map(\.snippet))
            text = links.text
            for url in links.removedURLs { warnings.append("근거에 없는 링크 제거: \(url)") }

            let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if finalText.isEmpty { continue }
            paragraphs.append(GroundedParagraph(text: finalText, evidence: evidence))
        }

        warnings.append(contentsOf: decoded.warnings.map { String($0.prefix(300)) })
        let missingEvidence = decoded.missingEvidence.map { String($0.prefix(300)) }

        return GroundedAnswer(question: question, paragraphs: paragraphs,
                              missingEvidence: missingEvidence, warnings: warnings,
                              jobStatus: result.job.status, evidencePool: pool)
    }

    /// trim → decode → schemaVersion == 1 && jobType == "grounded_answer" 검증.
    private static func decodeOutput(_ rawJSON: String) throws -> GroundedAnswerOutput {
        let trimmed = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WorkLogError.validation("빈 AI 결과")
        }
        let decoded = try StableJSON.decode(GroundedAnswerOutput.self, from: trimmed)
        guard decoded.schemaVersion == 1,
              decoded.jobType == AIJobType.groundedAnswer.rawValue else {
            throw WorkLogError.validation("AI 결과 계약 불일치")
        }
        return decoded
    }

    private static func evidenceId(sourceType: SearchSourceType, sourceId: String) -> String {
        "\(sourceType.rawValue):\(sourceId)"
    }

    private static func validatedQuestion(_ question: String) throws -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WorkLogError.validation("질문이 비어 있습니다.")
        }
        guard trimmed.count <= maxQuestionLength else {
            throw WorkLogError.validation("질문이 너무 깁니다. \(maxQuestionLength)자 이하로 입력하세요.")
        }
        return trimmed
    }

    /// 단어 앞뒤의 문장부호를 제거한다. 내부 문자는 보존한다.
    private static func stripPunctuation(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters)
    }

    /// `<[^>]+>` 패턴을 제거한다. 태그가 있었으면 removed = true.
    private static func removeHTMLTags(_ text: String) -> (text: String, removed: Bool) {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>") else { return (text, false) }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard regex.numberOfMatches(in: text, range: range) > 0 else { return (text, false) }
        let cleaned = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return (cleaned, true)
    }

    /// http/https URL이 근거 snippet에 그대로 있으면 유지하고, 없으면 대체 문구로 바꾼다.
    private static func replaceUngroundedLinks(in text: String,
                                               evidenceSnippets: [String]) -> (text: String, removedURLs: [String]) {
        guard let regex = try? NSRegularExpression(pattern: "https?://\\S+") else { return (text, []) }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (text, []) }

        let placeholder = "[확인되지 않은 링크 제거]"
        var result = ""
        var cursor = 0
        var removedURLs: [String] = []
        for match in matches {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let raw = ns.substring(with: match.range)
            let url = trimTrailingPunctuation(raw)
            if evidenceSnippets.contains(where: { $0.contains(url) }) {
                result += raw
            } else {
                result += placeholder
                result += String(raw.dropFirst(url.count))  // URL 뒤에 붙은 문장부호는 보존
                removedURLs.append(url)
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return (result, removedURLs)
    }

    private static func trimTrailingPunctuation(_ value: String) -> String {
        let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "\"", "'", "”", "’", "…"]
        var trimmed = value
        while let last = trimmed.last, trailing.contains(last) { trimmed.removeLast() }
        return trimmed
    }
}

// MARK: - payload 모델

private struct Payload: Codable {
    var jobType: String
    var question: String
    var sources: [Source]

    struct Source: Codable {
        var id: String
        var sourceType: String
        var workDate: WorkDate?
        var text: String
    }
}
