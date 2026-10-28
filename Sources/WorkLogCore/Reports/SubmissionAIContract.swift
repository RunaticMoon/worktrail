// AI가 문장을 다듬어도 앱이 계산한 업무·분류·계획과 근거 연결은 유지한다.
// 사용자 편집·포함/제외에는 적용하지 않으며 일반 SubmissionValidator와 함께 호출한다.
enum SubmissionAIContract {
    static func validate(draft: SubmissionDraft, seed: SubmissionDraft,
                         facts: ReportFacts) -> [ValidationFinding] {
        let items = draft.groups.flatMap(\.items)
        let seedItems = seed.groups.flatMap(\.items)
        let seedById = Dictionary(seedItems.map { ($0.itemId, $0) },
                                  uniquingKeysWith: { first, _ in first })
        var findings: [ValidationFinding] = []

        // 순서·그룹 제목은 문체에 맞춰 바꿀 수 있지만 항목 추가·삭제·중복은 안 된다.
        if items.map(\.itemId).sorted() != seedItems.map(\.itemId).sorted() {
            findings.append(ValidationFinding(
                severity: .error, code: "ai_submission_items_mismatch",
                message: "AI가 앱에서 계산한 주간보고 항목을 추가하거나 누락했습니다."))
        }

        let sourceById = Dictionary(facts.sources.map { ($0.id, $0) },
                                    uniquingKeysWith: { first, _ in first })
        var acceptedMemoTasks: [String: Set<String>] = [:]
        for link in facts.memoLinksAccepted {
            acceptedMemoTasks[FactSource.memoId(link.memoId), default: []].insert(link.taskId)
        }

        for item in items {
            if let original = seedById[item.itemId],
               item.category != original.category
                || item.taskIds.sorted() != original.taskIds.sorted()
                || item.projectIds.sorted() != original.projectIds.sorted()
                || item.planItemIds.sorted() != original.planItemIds.sorted() {
                findings.append(ValidationFinding(
                    severity: .error, code: "ai_submission_binding_mismatch",
                    message: "AI가 주간보고 항목의 업무·분류·프로젝트·확정 계획 연결을 변경했습니다.",
                    itemId: item.itemId))
            }

            let taskIds = Set(item.taskIds)
            for sourceId in item.evidenceIds {
                // 존재하지 않는 ID는 SubmissionValidator가 unknown_evidence로 보고한다.
                guard let source = sourceById[sourceId] else { continue }
                let related: Bool
                if source.kind.usesMemoIdentity {
                    related = !(acceptedMemoTasks[sourceId] ?? []).isDisjoint(with: taskIds)
                } else {
                    related = source.taskId.map { taskIds.contains($0) } ?? false
                }
                if !related {
                    findings.append(ValidationFinding(
                        severity: .error, code: "ai_submission_unrelated_evidence",
                        message: "AI가 해당 업무에 연결되지 않은 기록을 주간보고 근거로 사용했습니다.",
                        itemId: item.itemId))
                }
            }
        }
        return findings
    }
}
