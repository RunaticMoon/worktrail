import Foundation

/// AI가 만든 초안 또는 사용자가 편집한 성과 리포트 초안을 검사한다.
///
/// `PerformanceComposer.compose`가 만든 결정적 초안은 항상 `error`가 0이어야 한다.
/// 모든 메시지는 한국어이며, itemId가 있는 항목은 해당 아이템에 결부된다.
public enum PerformanceValidator {

    private static let allowedJobType = "performance_report"

    public static func hasErrors(_ findings: [ValidationFinding]) -> Bool {
        findings.contains { $0.severity == .error }
    }

    public static func validate(_ draft: PerformanceDraft, facts: ReportFacts) -> [ValidationFinding] {
        var findings: [ValidationFinding] = []

        // 1. 스키마
        if draft.schemaVersion != 1 {
            findings.append(.init(severity: .error, code: "schema",
                                  message: "schemaVersion이 1이 아닙니다."))
        }
        if draft.jobType != allowedJobType {
            findings.append(.init(severity: .error, code: "schema",
                                  message: "jobType이 \(allowedJobType)가 아닙니다."))
        }
        if draft.periodType != facts.periodType {
            findings.append(.init(severity: .error, code: "schema",
                                  message: "periodType이 입력 기간 유형(\(facts.periodType.rawValue))과 다릅니다."))
        }

        let validTaskIds = Set(facts.tasks.map(\.id))
        let validProjectIds = Set(facts.projects.map(\.id))
        let validEvidenceIds = facts.sourceIds
        let sourceById = Dictionary(facts.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let knownURLs = Set(facts.sources.flatMap(\.sourceUrls))

        // 섹션 프로젝트 검증
        for section in draft.sections {
            for projectId in section.projectIds where !validProjectIds.contains(projectId) {
                findings.append(.init(severity: .error, code: "unknown_project",
                                      message: "입력에 없는 프로젝트입니다: \(projectId)"))
            }
        }

        var seenItemIds = Set<String>()
        var stateTaskCounts: [String: Int] = [:]
        var coveredTaskIds = Set<String>()

        for section in draft.sections {
            for item in section.items {
                let itemId = item.itemId

                if !seenItemIds.insert(itemId).inserted {
                    findings.append(.init(severity: .error, code: "duplicate_item_id",
                                          message: "itemId가 중복됩니다: \(itemId)", itemId: itemId))
                }

                if item.text.isEmpty {
                    findings.append(.init(severity: .error, code: "empty_text",
                                          message: "본문이 비어 있습니다.", itemId: itemId))
                } else if item.text.count > 1000 {
                    findings.append(.init(severity: .warning, code: "text_too_long",
                                          message: "본문이 1000자를 넘습니다.", itemId: itemId))
                }

                for taskId in item.taskIds {
                    if validTaskIds.contains(taskId) {
                        coveredTaskIds.insert(taskId)
                    } else {
                        findings.append(.init(severity: .error, code: "unknown_task",
                                              message: "입력에 없는 Task입니다: \(taskId)", itemId: itemId))
                    }
                }
                for projectId in item.projectIds where !validProjectIds.contains(projectId) {
                    findings.append(.init(severity: .error, code: "unknown_project",
                                          message: "입력에 없는 프로젝트입니다: \(projectId)", itemId: itemId))
                }
                for evidenceId in item.evidenceIds where !validEvidenceIds.contains(evidenceId) {
                    findings.append(.init(severity: .error, code: "unknown_evidence",
                                          message: "입력에 없는 근거입니다: \(evidenceId)", itemId: itemId))
                }

                // REP-T16: 기간 밖 근거
                for evidenceId in item.evidenceIds {
                    guard let source = sourceById[evidenceId] else { continue }
                    if source.kind == .supplement, let applies = source.applies {
                        if facts.range.intersection(applies) == nil {
                            findings.append(.init(severity: .error, code: "evidence_out_of_range",
                                                  message: "보충 답변의 대상 기간이 리포트 기간과 겹치지 않습니다: \(evidenceId)",
                                                  itemId: itemId))
                        }
                    } else if let workDate = source.workDate {
                        if !facts.range.contains(workDate) {
                            findings.append(.init(severity: .error, code: "evidence_out_of_range",
                                                  message: "근거의 업무일이 리포트 기간 밖입니다: \(evidenceId)",
                                                  itemId: itemId))
                        }
                    }
                }

                // REP-T10: 프로젝트 근거 불일치
                if item.kind == .activity && !item.evidenceIds.isEmpty {
                    let evidenceSources = item.evidenceIds.compactMap { sourceById[$0] }
                    for projectId in item.projectIds {
                        let satisfied = evidenceSources.contains { source in
                            if source.projectIds.contains(projectId) { return true }
                            if source.projectIds.isEmpty, let taskId = source.taskId,
                               facts.task(taskId)?.projectIds == [projectId] {
                                return true
                            }
                            return false
                        }
                        if !satisfied {
                            findings.append(.init(severity: .error, code: "project_evidence_mismatch",
                                                  message: "근거가 뒷받침하지 않는 프로젝트 기여입니다: \(projectId)",
                                                  itemId: itemId))
                        }
                    }
                }

                // 동일 Task state 중복
                if item.kind == .state {
                    for taskId in item.taskIds {
                        let count = (stateTaskCounts[taskId] ?? 0) + 1
                        stateTaskCounts[taskId] = count
                        if count >= 2 {
                            findings.append(.init(severity: .error, code: "duplicate_task_state",
                                                  message: "같은 Task의 상태가 여러 건으로 중복됩니다: \(taskId)",
                                                  itemId: itemId))
                        }
                    }
                }

                // REP-T09: 근거로 확인되지 않은 수치
                let citedTexts = item.evidenceIds.compactMap { sourceById[$0]?.text }.map(normalized)
                for token in uniqueMatches(numberPattern, in: item.text) {
                    let needle = normalized(token)
                    if !citedTexts.contains(where: { $0.contains(needle) }) {
                        findings.append(.init(severity: .warning, code: "unverified_number",
                                              message: "근거에서 확인되지 않은 수치입니다(사용자 검토 필요): \(token)",
                                              itemId: itemId))
                    }
                }

                // 원문에 없는 URL
                for url in uniqueMatches(urlPattern, in: item.text) {
                    let cleaned = trimURLPunctuation(url)
                    if !knownURLs.contains(cleaned) {
                        findings.append(.init(severity: .error, code: "unknown_url",
                                              message: "입력 근거에 없는 URL입니다: \(cleaned)", itemId: itemId))
                    }
                }

                // 본문을 가져오지 않은 링크에 대한 주장
                let hasUnfetchedLink = item.evidenceIds
                    .compactMap { sourceById[$0] }
                    .contains { !$0.sourceUrls.isEmpty && !$0.urlBodyFetched }
                if hasUnfetchedLink {
                    let lower = item.text.lowercased()
                    let phrases = ["코드 변경을 확인", "diff", "pr 내용", "변경 내용을 검토", "링크 내용"]
                    if phrases.contains(where: { lower.contains($0) }) {
                        findings.append(.init(severity: .warning, code: "unfetched_link_claim",
                                              message: "본문을 가져오지 않은 링크의 내용을 주장하고 있습니다.",
                                              itemId: itemId))
                    }
                }

                // REP-T14: 취소·보류를 완료로 포장
                if item.kind == .state, let taskId = item.taskIds.first, let task = facts.task(taskId),
                   task.statusAtCutoff == .cancelled || task.statusAtCutoff == .onHold,
                   task.completionDatesInRange.isEmpty {
                    var probe = item.text.replacingOccurrences(of: "미완료", with: "")
                    probe = probe.replacingOccurrences(of: "적용 완료", with: "")
                    if probe.contains("완료") {
                        findings.append(.init(severity: .error, code: "status_misrepresented",
                                              message: "취소·보류 Task를 완료로 표현했습니다: \(taskId)",
                                              itemId: itemId))
                    }
                }
            }
        }

        for missing in draft.missingEvidence where !validTaskIds.contains(missing.taskId) {
            findings.append(.init(severity: .error, code: "unknown_task",
                                  message: "확인 필요 항목의 Task가 입력에 없습니다: \(missing.taskId)"))
        }

        // Task 커버리지
        for task in facts.tasks where !task.activitySourceIds.isEmpty {
            if !coveredTaskIds.contains(task.id) {
                findings.append(.init(severity: .warning, code: "missing_task_coverage",
                                      message: "활동 근거가 있는 Task가 리포트에 포함되지 않았습니다: \(task.id)"))
            }
        }

        return findings
    }

    // MARK: - 정규식 유틸

    private static let numberPattern = "[0-9]+(\\.[0-9]+)?\\s*(%|퍼센트|배|시간|분|초|건|원|명|ms)"
    private static let urlPattern = "https?://[^\\s]+"

    private static func uniqueMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        var seen = Set<String>()
        var result: [String] = []
        for match in regex.matches(in: text, range: range) {
            let token = ns.substring(with: match.range)
            if seen.insert(token).inserted { result.append(token) }
        }
        return result
    }

    /// 공백을 무시한 비교용 정규화.
    private static func normalized(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }

    private static func trimURLPunctuation(_ url: String) -> String {
        var result = url
        let trailing: Set<Character> = [")", "]", "}", ">", ",", ".", ";", ":", "!", "?", "\"", "'"]
        while let last = result.last, trailing.contains(last) { result.removeLast() }
        return result
    }
}
