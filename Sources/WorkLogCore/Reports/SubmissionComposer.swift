import Foundation

// 제출용 주간보고 결정적 분류·렌더링 (WEEK-01~04, P-01).
// ReportFacts만 입력으로 받는 순수 함수다. DB/AI/네트워크/Secret 접근 없음.
// 이 파일은 상세 성과 리포트(performance_report)와 무관하다.

private enum SubmissionGroupKey: Hashable {
    case project(String)
    case common
    case other
}

private struct SubmissionLine {
    var category: SubmissionCategory
    var text: String
    var taskIds: [String]
    var projectIds: [String]
    var planItemIds: [String]
    var evidenceIds: [String]
    var groupKey: SubmissionGroupKey
    var order: Int
}

public enum SubmissionComposer {
    public static let commonHeading = "공통 업무"
    public static let otherHeading = "기타"

    /// 프로젝트별 적용 상태 표기 (perProject Task)
    private static let projectStatusWords: [TaskStatus: String] = [
        .completed: "적용 완료",
        .inProgress: "진행 중",
        .planned: "예정",
        .onHold: "보류",
        .cancelled: "취소",
    ]

    // MARK: - 지난주 기대 분류

    /// 지난주 Task의 기대 분류. completed / inProgress / nil(보고 제외 또는 reviewNotes 대상).
    public static func expectedPastCategory(for task: FactTask) -> SubmissionCategory? {
        switch task.statusAtCutoff {
        case .completed:
            return task.completionDatesInRange.isEmpty ? nil : .completed
        case .inProgress:
            return .inProgress
        default:
            return nil
        }
    }

    // MARK: - 결정적 초안

    public static func compose(_ facts: ReportFacts) -> SubmissionDraft {
        let sourceIds = facts.sourceIds
        var lines: [SubmissionLine] = []
        var reviewNotes: [String] = []
        var warnings: [String] = []

        // 2. 지난주 줄: facts.tasks 순서대로 expectedPastCategory != nil인 Task마다 1줄.
        for (index, task) in facts.tasks.enumerated() {
            guard let category = expectedPastCategory(for: task) else { continue }
            var text = task.title
            if task.reopenedInRange {
                text += " (재개)"
            }
            if task.trackingMode == .perProject,
               task.projectIds.count >= 2,
               !task.projectStatuses.isEmpty {
                let notations = facts.projects.compactMap { project -> String? in
                    guard let status = task.projectStatuses[project.id],
                          let word = projectStatusWords[status] else { return nil }
                    return "\(project.name) \(word)"
                }
                if !notations.isEmpty {
                    text += " — " + notations.joined(separator: ", ")
                }
            }
            let evidence = task.activitySourceIds.filter { sourceIds.contains($0) }
            lines.append(SubmissionLine(
                category: category,
                text: text,
                taskIds: [task.id],
                projectIds: task.projectIds,
                planItemIds: [],
                evidenceIds: evidence,
                groupKey: groupKey(forProjectIds: task.projectIds, facts: facts),
                order: index
            ))
        }

        // 3. reviewNotes: 보류·취소는 세 표기 중 하나로 거짓 변환하지 않는다.
        for task in facts.tasks {
            switch task.statusAtCutoff {
            case .onHold: reviewNotes.append("보류: \(task.title)")
            case .cancelled: reviewNotes.append("취소: \(task.title)")
            default: break
            }
        }

        // 4. 예정 줄: confirmedPlans만 사용, 같은 taskId는 한 줄로 합친다.
        var planOrder: [String] = []
        var planGroups: [String: [FactPlanItem]] = [:]
        for plan in facts.confirmedPlans {
            if planGroups[plan.taskId] == nil {
                planOrder.append(plan.taskId)
                planGroups[plan.taskId] = []
            }
            planGroups[plan.taskId]!.append(plan)
        }

        for (index, taskId) in planOrder.enumerated() {
            let plans = planGroups[taskId] ?? []
            let planItemIds = orderedUnion(plans.flatMap { $0.planItemIds })
            let explicitLabels = orderedUnion(plans.flatMap { $0.labels })

            if let task = facts.task(taskId) {
                var effectiveLabels = explicitLabels
                if effectiveLabels.isEmpty {
                    effectiveLabels = orderedUnion(plans.flatMap {
                        scopeLabel(for: $0, task: task, facts: facts)
                    })
                }
                let text = effectiveLabels.isEmpty
                    ? task.title
                    : task.title + " — " + effectiveLabels.joined(separator: ", ")
                lines.append(SubmissionLine(
                    category: .planned,
                    text: text,
                    taskIds: [task.id],
                    projectIds: task.projectIds,
                    planItemIds: planItemIds,
                    evidenceIds: [],
                    groupKey: groupKey(forProjectIds: task.projectIds, facts: facts),
                    order: index
                ))
            } else {
                warnings.append("계획 Task 정보 없음: \(taskId)")
                guard !explicitLabels.isEmpty else { continue }
                lines.append(SubmissionLine(
                    category: .planned,
                    text: explicitLabels.joined(separator: ", "),
                    taskIds: [taskId],
                    projectIds: [],
                    planItemIds: planItemIds,
                    evidenceIds: [],
                    groupKey: .other,
                    order: index
                ))
            }
        }

        // 5-6. 그룹 구성·정렬.
        var grouped: [SubmissionGroupKey: [SubmissionLine]] = [:]
        for line in lines {
            grouped[line.groupKey, default: []].append(line)
        }

        var orderedKeys: [SubmissionGroupKey] = []
        for project in facts.projects {
            let key = SubmissionGroupKey.project(project.id)
            if grouped[key] != nil { orderedKeys.append(key) }
        }
        if grouped[.common] != nil { orderedKeys.append(.common) }
        if grouped[.other] != nil { orderedKeys.append(.other) }

        var groups: [SubmissionGroup] = []
        var counter = 0
        for key in orderedKeys {
            let sorted = (grouped[key] ?? []).sorted { lhs, rhs in
                let lr = categoryRank(lhs.category)
                let rr = categoryRank(rhs.category)
                if lr != rr { return lr < rr }
                return lhs.order < rhs.order
            }
            var items: [SubmissionItem] = []
            for line in sorted {
                counter += 1
                items.append(SubmissionItem(
                    itemId: "line-\(counter)",
                    category: line.category,
                    text: line.text,
                    taskIds: line.taskIds,
                    projectIds: line.projectIds,
                    planItemIds: line.planItemIds,
                    evidenceIds: line.evidenceIds
                ))
            }
            groups.append(SubmissionGroup(heading: heading(for: key, facts: facts), items: items))
        }

        return SubmissionDraft(groups: groups, reviewNotes: reviewNotes, warnings: warnings)
    }

    // MARK: - 렌더링

    public static func render(_ draft: SubmissionDraft) -> String {
        var blocks: [String] = []
        for group in draft.groups {
            guard !group.items.isEmpty else { continue }
            var lines = [group.heading]
            for item in group.items {
                lines.append("\(item.category.koreanLabel) \(item.text)")
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    // MARK: - 내부 헬퍼

    private static func categoryRank(_ category: SubmissionCategory) -> Int {
        switch category {
        case .completed: return 0
        case .inProgress: return 1
        case .planned: return 2
        }
    }

    private static func groupKey(forProjectIds projectIds: [String], facts: ReportFacts) -> SubmissionGroupKey {
        switch projectIds.count {
        case 0:
            return .other
        case 1:
            return facts.project(projectIds[0]).map { .project($0.id) } ?? .other
        default:
            return .common
        }
    }

    private static func heading(for key: SubmissionGroupKey, facts: ReportFacts) -> String {
        switch key {
        case .project(let id): return facts.project(id)?.name ?? otherHeading
        case .common: return commonHeading
        case .other: return otherHeading
        }
    }

    /// 배열 순서를 유지하며 중복을 제거한다.
    private static func orderedUnion(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }

    /// label이 비었을 때 scope에서 표시 문구를 유도한다.
    private static func scopeLabel(for plan: FactPlanItem, task: FactTask, facts: ReportFacts) -> [String] {
        switch plan.scopeType {
        case .taskProject:
            guard let scopeId = plan.scopeId,
                  let projectId = projectId(fromScopeId: scopeId),
                  let project = facts.project(projectId) else { return [] }
            return ["\(project.name) 적용"]
        case .checklistItem:
            guard let scopeId = plan.scopeId,
                  let item = task.checklist.first(where: { $0.id == scopeId }) else { return [] }
            return [item.text]
        case .wholeTask:
            return []
        }
    }

    /// "taskId/projectId"에서 projectId를 얻는다.
    private static func projectId(fromScopeId scopeId: String) -> String? {
        guard let separator = scopeId.firstIndex(of: "/") else { return nil }
        let projectId = scopeId[scopeId.index(after: separator)...]
        return projectId.isEmpty ? nil : String(projectId)
    }
}
