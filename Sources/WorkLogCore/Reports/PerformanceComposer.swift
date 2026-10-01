import Foundation

/// 성과 축적용 상세 리포트(Daily/Weekly/Monthly/Quarterly/Yearly)를 결정적으로 생성·렌더링한다.
///
/// `ReportFacts`만 입력으로 받는 순수 함수 모음이다. DB·AI·네트워크·Secret에 접근하지 않으며,
/// 원문에 없는 수치·효과·기여율을 만들어내지 않는다. 제출용 주간보고(SubmissionDraft)와는
/// 별개의 산출물이다.
public enum PerformanceComposer {

    public static let commonHeading = "공통 업무"
    public static let otherHeading = "기타"
    public static let noRecordText = "기록 없음"

    // MARK: - 제목

    /// 기간 유형별 기본 제목. `range`는 [start, endExclusive)이며 마지막 날은 endExclusive 하루 전이다.
    /// 연간은 사용자가 지정한 평가 기간을 그대로 쓰며 달력 연도로 확장하지 않는다.
    public static func defaultTitle(for facts: ReportFacts) -> String {
        let start = facts.range.start
        let lastDay = lastDay(of: facts)
        switch facts.periodType {
        case .daily:
            return "\(start.iso) Daily 업무 리포트"
        case .weekly:
            return "\(start.iso) ~ \(lastDay.iso) 주간 상세 리포트"
        case .monthly:
            return String(format: "%04d-%02d 월간 상세 리포트", start.year, start.month)
        case .quarterly:
            let quarter = ((start.month - 1) / 3) + 1
            return "\(start.year) Q\(quarter) 분기 상세 리포트"
        case .yearly:
            return "\(start.iso) ~ \(lastDay.iso) 평가 기간 상세 리포트"
        }
    }

    private static func lastDay(of facts: ReportFacts) -> WorkDate {
        let calendar = WorkCalendar(timeZone: TimeZone(identifier: facts.timezone) ?? WorkCalendar().timeZone)
        return calendar.adding(days: -1, to: facts.range.endExclusive)
    }

    // MARK: - 초안 생성

    /// 결정적 초안. AI 없이도 동작하는 기본 초안이다.
    public static func compose(_ facts: ReportFacts) -> PerformanceDraft {
        let title = defaultTitle(for: facts)

        if facts.tasks.isEmpty && facts.sources.isEmpty {
            let item = PerformanceItem(itemId: "item-1", taskIds: [], projectIds: [],
                                       kind: .unknown, text: noRecordText, evidenceIds: [])
            let section = PerformanceSection(heading: noRecordText, projectIds: [], items: [item])
            return PerformanceDraft(periodType: facts.periodType, title: title,
                                    sections: [section], missingEvidence: [],
                                    warnings: ["기간 내 기록 없음"])
        }

        // 승인된 메모 연결: memoId(접두어 없는 값) → 연결된 taskId 집합
        var accepted: [String: Set<String>] = [:]
        for link in facts.memoLinksAccepted {
            accepted[link.memoId, default: []].insert(link.taskId)
        }

        var single: [String: [PerformanceItem]] = [:]
        var commonItems: [PerformanceItem] = []
        var otherItems: [PerformanceItem] = []
        var missing: [MissingEvidence] = []

        for task in facts.tasks {
            let candidates = evidenceSources(for: task, facts: facts, accepted: accepted)
            let evidence = candidates.map { item(for: $0, task: task) }
            let state = stateItem(for: task, facts: facts)
            let taskItems = [state] + evidence

            if task.projectIds.count >= 2 {
                commonItems.append(contentsOf: taskItems)
            } else if task.projectIds.count == 1, let projectId = task.projectIds.first,
                      facts.project(projectId) != nil {
                single[projectId, default: []].append(contentsOf: taskItems)
            } else {
                otherItems.append(contentsOf: taskItems)
            }

            let activitySupplementCount = candidates.filter { $0.kind == .activity || $0.kind == .supplement }.count
            let supplementCount = candidates.filter { $0.kind == .supplement }.count

            if (task.statusAtCutoff == .inProgress || task.statusAtCutoff == .completed),
               activitySupplementCount == 0 {
                missing.append(MissingEvidence(taskId: task.id, field: "activity",
                                               reason: "기간 내 수행 기록 없음 — 상태만 확인됨"))
            }
            if !task.completionDatesInRange.isEmpty && supplementCount == 0 {
                missing.append(MissingEvidence(taskId: task.id, field: "result",
                                               reason: "확인된 결과·효과 기록 없음 — 사용자 확인 필요"))
            }
        }

        // Task에 연결되지 않은 메모 근거 → 기타 섹션
        for source in facts.sources where source.kind == .memo {
            let memoId = stripMemoPrefix(source.id)
            if accepted[memoId] != nil { continue }
            if source.taskId == nil {
                otherItems.append(PerformanceItem(itemId: "", taskIds: [], projectIds: source.projectIds,
                                                  kind: .discussion, text: text(for: source),
                                                  evidenceIds: [source.id]))
            }
        }

        // 섹션 조립: 단일 프로젝트들 → 공통 업무 → 기타
        var sections: [PerformanceSection] = []
        for project in facts.projects {
            if let items = single[project.id], !items.isEmpty {
                sections.append(PerformanceSection(heading: project.name, projectIds: [project.id], items: items))
            }
        }
        if !commonItems.isEmpty {
            let union = facts.projects.map(\.id).filter { projectId in
                facts.tasks.contains { $0.projectIds.count >= 2 && $0.projectIds.contains(projectId) }
            }
            sections.append(PerformanceSection(heading: commonHeading, projectIds: union, items: commonItems))
        }
        if !otherItems.isEmpty {
            sections.append(PerformanceSection(heading: otherHeading, projectIds: [], items: otherItems))
        }

        // itemId를 전체 순서대로 부여
        var counter = 0
        let numbered = sections.map { section -> PerformanceSection in
            let items = section.items.map { item -> PerformanceItem in
                counter += 1
                return PerformanceItem(itemId: "item-\(counter)", taskIds: item.taskIds,
                                       projectIds: item.projectIds, kind: item.kind,
                                       text: item.text, evidenceIds: item.evidenceIds)
            }
            return PerformanceSection(heading: section.heading, projectIds: section.projectIds, items: items)
        }

        return PerformanceDraft(periodType: facts.periodType, title: title, sections: numbered,
                                missingEvidence: missing, warnings: [])
    }

    // MARK: - Task 아이템

    private static func stateItem(for task: FactTask, facts: ReportFacts) -> PerformanceItem {
        var text = "\(task.title) — 상태: \(statusLabel(task.statusAtStart)) → \(statusLabel(task.statusAtCutoff))"

        if !task.completionDatesInRange.isEmpty {
            let dates = task.completionDatesInRange.map(\.iso).joined(separator: ", ")
            text += "; 완료 \(dates)"
        }
        if task.reopenedInRange {
            text += "; 기간 중 재개"
        }
        if task.trackingMode == .perProject && !task.projectStatuses.isEmpty {
            var entries: [String] = []
            for project in facts.projects {
                if let status = task.projectStatuses[project.id] {
                    entries.append("\(project.name) \(projectStatusWord(status))")
                }
            }
            if !entries.isEmpty {
                text += "; 프로젝트별: \(entries.joined(separator: ", "))"
            }
        }

        return PerformanceItem(itemId: "", taskIds: [task.id], projectIds: task.projectIds,
                               kind: .state, text: text, evidenceIds: [])
    }

    private static func evidenceSources(for task: FactTask, facts: ReportFacts,
                                        accepted: [String: Set<String>]) -> [FactSource] {
        facts.sources.filter { source in
            if source.kind == .activity && task.activitySourceIds.contains(source.id) { return true }
            if source.taskId == task.id { return true }
            if source.kind == .memo, accepted[stripMemoPrefix(source.id)]?.contains(task.id) == true {
                return true
            }
            return false
        }.sorted(by: sourceOrder)
    }

    private static func item(for source: FactSource, task: FactTask) -> PerformanceItem {
        let projectIds = source.projectIds.isEmpty ? task.projectIds : source.projectIds
        return PerformanceItem(itemId: "", taskIds: [task.id], projectIds: projectIds,
                               kind: kind(for: source.kind), text: text(for: source),
                               evidenceIds: [source.id])
    }

    private static func sourceOrder(_ a: FactSource, _ b: FactSource) -> Bool {
        switch (a.workDate, b.workDate) {
        case let (x?, y?):
            if x != y { return x < y }
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        case (nil, nil):
            break
        }
        if a.recordedAt != b.recordedAt { return a.recordedAt < b.recordedAt }
        return a.id < b.id
    }

    // MARK: - 텍스트/매핑

    /// 날짜 접두어 + 원문 첫 줄(앞뒤 공백 제거, 최대 200자). 원문에 없는 문장은 덧붙이지 않는다.
    private static func text(for source: FactSource) -> String {
        var prefix = ""
        if source.kind == .supplement, let applies = source.applies {
            prefix = "[보충 답변 \(applies.start.iso)~\(applies.endExclusive.iso)] "
        } else if let workDate = source.workDate {
            prefix = "[\(workDate.iso)] "
        }
        let firstLine = source.text.components(separatedBy: .newlines).first ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return prefix + String(trimmed.prefix(200))
    }

    private static func kind(for sourceKind: FactSourceKind) -> PerformanceItemKind {
        switch sourceKind {
        case .activity: return .activity
        case .memo: return .discussion
        case .supplement: return .activity
        case .report: return .unknown
        }
    }

    private static func statusLabel(_ status: TaskStatus?) -> String {
        status?.koreanLabel ?? "신규"
    }

    private static func projectStatusWord(_ status: TaskStatus) -> String {
        switch status {
        case .completed: return "적용 완료"
        case .inProgress: return "진행 중"
        case .planned: return "예정"
        case .onHold: return "보류"
        case .cancelled: return "취소"
        }
    }

    private static func stripMemoPrefix(_ id: String) -> String {
        id.hasPrefix("memo:") ? String(id.dropFirst("memo:".count)) : id
    }

    // MARK: - 렌더링

    /// 앱 화면/복사용 Markdown. 끝에 개행을 붙이지 않는다.
    public static func render(_ draft: PerformanceDraft) -> String {
        var lines: [String] = ["# \(draft.title)", ""]

        for section in draft.sections {
            lines.append("## \(section.heading)")
            for item in section.items {
                var line = "- \(item.text)"
                if !item.evidenceIds.isEmpty {
                    line += " [근거: \(item.evidenceIds.joined(separator: ", "))]"
                }
                lines.append(line)
            }
            lines.append("")
        }

        if !draft.missingEvidence.isEmpty {
            lines.append("## 확인 필요")
            for missing in draft.missingEvidence {
                lines.append("- \(missing.taskId): \(missing.reason)")
            }
            lines.append("")
        }

        if !draft.warnings.isEmpty {
            lines.append("## 경고")
            for warning in draft.warnings {
                lines.append("- \(warning)")
            }
            lines.append("")
        }

        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
