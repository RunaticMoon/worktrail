import Foundation

// MARK: - 계획 정규화 (PLAN-02)
//
// 확정(state == .confirmed) 항목만 대상으로 한다. 후보·제외 항목은 결과에 들어가지 않는다.
// 계획 포함은 착수·상태 변경이 아니므로 여기서 domain_event를 만들지 않는다.
public enum PlanNormalizer {

    /// 확정 항목을 보고서용 `FactPlanItem`으로 정규화한다.
    ///
    /// - Task별로: `wholeTask` 확정 항목이 하나라도 있으면 그 Task의 모든 확정 항목을
    ///   `FactPlanItem` 하나(scopeType `.wholeTask`, scopeId nil)로 합친다. `planItemIds`는
    ///   전부, `labels`는 `wholeTask` label 먼저 + 나머지 label(nil 제외, 중복 제거, 순서 유지).
    /// - `wholeTask`가 없으면 `(scopeType, scopeId)`가 같은 항목끼리 하나로 합친다
    ///   (같은 체크리스트 ID는 한 번).
    /// - 출력 순서: 입력에서 Task가 처음 나온 순서, 그 안에서 입력 순서.
    public static func normalize(_ items: [WeekPlanItem]) -> [FactPlanItem] {
        let confirmed = items.filter { $0.state == .confirmed }

        var taskOrder: [String] = []
        var byTask: [String: [WeekPlanItem]] = [:]
        for item in confirmed {
            if byTask[item.taskId] == nil { taskOrder.append(item.taskId) }
            byTask[item.taskId, default: []].append(item)
        }

        var result: [FactPlanItem] = []
        for taskId in taskOrder {
            let taskItems = byTask[taskId] ?? []

            if let wholeTask = taskItems.first(where: { $0.scopeType == .wholeTask }) {
                var labels: [String] = []
                if let label = wholeTask.label { labels.append(label) }
                for item in taskItems where item.id != wholeTask.id {
                    if let label = item.label, !labels.contains(label) { labels.append(label) }
                }
                result.append(FactPlanItem(planItemIds: taskItems.map(\.id), taskId: taskId,
                                           scopeType: .wholeTask, scopeId: nil, labels: labels))
                continue
            }

            // (scopeType, scopeId) 기준으로 입력 순서를 유지하며 그룹화.
            var groupOrder: [PlanScopeKey] = []
            var groups: [PlanScopeKey: [WeekPlanItem]] = [:]
            for item in taskItems {
                let key = PlanScopeKey(scopeType: item.scopeType, scopeId: item.scopeId)
                if groups[key] == nil { groupOrder.append(key) }
                groups[key, default: []].append(item)
            }
            for key in groupOrder {
                let group = groups[key] ?? []
                var labels: [String] = []
                for item in group {
                    if let label = item.label, !labels.contains(label) { labels.append(label) }
                }
                result.append(FactPlanItem(planItemIds: group.map(\.id), taskId: taskId,
                                           scopeType: key.scopeType, scopeId: key.scopeId, labels: labels))
            }
        }
        return result
    }
}

/// `(scopeType, scopeId)` 그룹 키.
private struct PlanScopeKey: Hashable {
    let scopeType: PlanScopeType
    let scopeId: String?
}
