import Foundation

// 제출용 주간보고 초안 검증 (P-01, REP-T15). AI가 만든 초안 또는 사용자가 편집한 초안을
// ReportFacts로 검사한다. DB/AI/네트워크/Secret 접근 없음.

public enum SubmissionValidator {
    public static func validate(_ draft: SubmissionDraft, facts: ReportFacts) -> [ValidationFinding] {
        var findings: [ValidationFinding] = []

        if draft.schemaVersion != 1 || draft.jobType != "submission_weekly" {
            findings.append(ValidationFinding(
                severity: .error,
                code: "schema",
                message: "초안 스키마가 올바르지 않습니다(schemaVersion=\(draft.schemaVersion), jobType=\(draft.jobType)).",
                itemId: nil
            ))
        }

        let knownTaskIds = Set(facts.tasks.map(\.id))
        let knownProjectIds = Set(facts.projects.map(\.id))
        let knownPlanItemIds = Set(facts.confirmedPlans.flatMap(\.planItemIds))
        let confirmedPlanTaskIds = Set(facts.confirmedPlans.map(\.taskId))
        let sourceIds = facts.sourceIds
        let knownURLs = Set(facts.sources.flatMap(\.sourceUrls))

        let allItems = draft.groups.flatMap(\.items)

        var itemIdCounts: [String: Int] = [:]
        for item in allItems { itemIdCounts[item.itemId, default: 0] += 1 }

        for group in draft.groups {
            for item in group.items {
                let itemId: String? = item.itemId

                if item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    findings.append(ValidationFinding(
                        severity: .error, code: "empty_text", message: "빈 문장입니다.", itemId: itemId))
                } else if item.text.count > 200 {
                    findings.append(ValidationFinding(
                        severity: .warning, code: "text_too_long",
                        message: "문장이 너무 깁니다(\(item.text.count)자).", itemId: itemId))
                }

                if (itemIdCounts[item.itemId] ?? 0) > 1 {
                    findings.append(ValidationFinding(
                        severity: .error, code: "duplicate_item_id",
                        message: "itemId가 중복됩니다: \(item.itemId)", itemId: itemId))
                }

                if item.taskIds.isEmpty {
                    findings.append(ValidationFinding(
                        severity: .error, code: "missing_task", message: "Task가 지정되지 않았습니다.", itemId: itemId))
                }
                for taskId in item.taskIds where !knownTaskIds.contains(taskId) {
                    findings.append(ValidationFinding(
                        severity: .error, code: "unknown_task",
                        message: "존재하지 않는 Task입니다: \(taskId)", itemId: itemId))
                }
                for projectId in item.projectIds where !knownProjectIds.contains(projectId) {
                    findings.append(ValidationFinding(
                        severity: .error, code: "unknown_project",
                        message: "존재하지 않는 프로젝트입니다: \(projectId)", itemId: itemId))
                }
                for planItemId in item.planItemIds where !knownPlanItemIds.contains(planItemId) {
                    findings.append(ValidationFinding(
                        severity: .error, code: "unknown_plan_item",
                        message: "존재하지 않는 계획 항목입니다: \(planItemId)", itemId: itemId))
                }
                for evidenceId in item.evidenceIds where !sourceIds.contains(evidenceId) {
                    findings.append(ValidationFinding(
                        severity: .error, code: "unknown_evidence",
                        message: "존재하지 않는 근거입니다: \(evidenceId)", itemId: itemId))
                }

                switch item.category {
                case .completed, .inProgress:
                    for taskId in item.taskIds {
                        guard let task = facts.task(taskId) else { continue }
                        let expected = SubmissionComposer.expectedPastCategory(for: task)
                        if expected != item.category {
                            let actual = task.statusAtCutoff?.koreanLabel ?? "기록 없음"
                            findings.append(ValidationFinding(
                                severity: .error, code: "category_mismatch",
                                message: "분류 불일치: '\(task.title)'의 지난주 기준 상태는 \(actual)입니다.",
                                itemId: itemId))
                        }
                    }
                case .planned:
                    if item.planItemIds.isEmpty {
                        findings.append(ValidationFinding(
                            severity: .error, code: "unconfirmed_plan",
                            message: "확정되지 않은 계획입니다(계획 항목 없음).", itemId: itemId))
                    }
                    for taskId in item.taskIds where !confirmedPlanTaskIds.contains(taskId) {
                        findings.append(ValidationFinding(
                            severity: .error, code: "unconfirmed_plan",
                            message: "확정 계획에 없는 Task입니다: \(taskId)", itemId: itemId))
                    }
                }

                for url in extractURLs(from: item.text) where !knownURLs.contains(url) {
                    findings.append(ValidationFinding(
                        severity: .error, code: "unknown_url",
                        message: "근거에 없는 URL입니다: \(url)", itemId: itemId))
                }
            }
        }

        // 같은 category 안에서 같은 taskId가 2개 이상 item에 나오면 중복.
        for category in SubmissionCategory.allCases {
            var counts: [String: Int] = [:]
            for item in allItems where item.category == category {
                for taskId in item.taskIds { counts[taskId, default: 0] += 1 }
            }
            for item in allItems where item.category == category {
                for taskId in item.taskIds where (counts[taskId] ?? 0) > 1 {
                    findings.append(ValidationFinding(
                        severity: .error, code: "duplicate_in_category",
                        message: "같은 \(category.koreanLabel) 구분에서 Task가 중복됩니다: \(taskId)",
                        itemId: item.itemId))
                }
            }
        }

        // 보고 대상 Task가 초안에서 빠짐(사용자가 제외했을 수 있으므로 warning).
        for task in facts.tasks {
            guard let expected = SubmissionComposer.expectedPastCategory(for: task) else { continue }
            let present = allItems.contains { $0.category == expected && $0.taskIds.contains(task.id) }
            if !present {
                findings.append(ValidationFinding(
                    severity: .warning, code: "missing_reportable",
                    message: "지난주 보고 대상 Task가 초안에 없습니다: \(task.title)", itemId: nil))
            }
        }

        return findings
    }

    public static func hasErrors(_ findings: [ValidationFinding]) -> Bool {
        findings.contains { $0.severity == .error }
    }

    // MARK: - URL 추출

    private static let urlRegex = try? NSRegularExpression(pattern: "https?://[^\\s]+")
    private static let trailingPunctuation = ".,;:!?)]}>\"'、。·"

    private static func extractURLs(from text: String) -> [String] {
        guard let regex = urlRegex else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var urls: [String] = []
        for match in matches {
            var url = ns.substring(with: match.range)
            while let last = url.last, trailingPunctuation.contains(last) {
                url.removeLast()
            }
            if !url.isEmpty { urls.append(url) }
        }
        return urls
    }
}
