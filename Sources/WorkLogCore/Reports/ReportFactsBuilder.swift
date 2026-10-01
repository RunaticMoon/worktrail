import Foundation
import Crypto

// MARK: - 리포트 사실 생성기 (DAY-01~03 / WEEK-01 / PERF-01~02 / QUIZ-02)
//
// 저장소 원본에서 특정 기간·상태 기준 시점·"그때 알던 정보(knownAt)"로 `ReportFacts`를
// 결정적으로 만든다. 문장 생성·AI·리포트 저장은 하지 않는다.
//
// - 이벤트는 항상 `StateReplay`로 knownAt 필터·정정 반영 후 재생한다.
// - 상태 기준 시점: range.endExclusive 지역 자정(periods.stateCutoff).
// - Secret/vault 자료형은 이 코드에서 참조하지 않는다.
public final class ReportFactsBuilder: @unchecked Sendable {
    private let repo: WorkRepository
    private let periods: Periods
    private let planService: WeekPlanService

    public init(repo: WorkRepository, periods: Periods, planService: WeekPlanService) {
        self.repo = repo
        self.periods = periods
        self.planService = planService
    }

    // MARK: - 범용 빌드

    /// range [start, endExclusive) / 상태 기준 = range.endExclusive 자정(periods.stateCutoff) /
    /// knownAt 이후 기록 제외. planRange가 주어지면 그 주의 확정 계획을 넣는다.
    public func build(family: ReportFamily, periodType: PeriodType, range: DateRange,
                      knownAt: Date, planRange: DateRange? = nil) throws -> ReportFacts {
        let calendar = periods.calendar
        let through = calendar.adding(days: -1, to: range.endExclusive)
        let beforeStart = calendar.adding(days: -1, to: range.start)

        let allEvents = try repo.allEvents()
        let cutoffReplay = StateReplay.replay(allEvents, through: through, knownAt: knownAt)
        let startReplay = StateReplay.replay(allEvents, through: beforeStart, knownAt: knownAt)
        let effective = StateReplay.effectiveEvents(allEvents, knownAt: knownAt)

        let confirmedPlans: [FactPlanItem]
        if let planRange {
            confirmedPlans = try planService.confirmedFacts(weekStart: planRange.start)
        } else {
            confirmedPlans = []
        }
        let plannedTaskIds = Set(confirmedPlans.map(\.taskId))

        let rangeActivities = try repo.activities(in: range).filter { $0.recordedAt <= knownAt }
        let activityTaskIds = Set(rangeActivities.map(\.taskId))

        var factTasks: [FactTask] = []
        for task in try repo.tasks() {
            guard createdByKnownAt(task, effective: effective, knownAt: knownAt) else { continue }

            let statusAtCutoff = cutoffReplay.taskStatus(task.id)
            let hasActivity = activityTaskIds.contains(task.id)
            let hasEventInRange = effective.contains {
                $0.taskId == task.id && range.contains($0.effectiveDate)
            }
            let isPlanned = plannedTaskIds.contains(task.id)

            let include: Bool
            if let statusAtCutoff {
                include = hasActivity || hasEventInRange || statusAtCutoff == .inProgress || isPlanned
            } else {
                // 상태가 없으면(생성·유효 사건이 knownAt/through 밖) 확정 계획이 참조할 때만 포함.
                include = isPlanned
            }
            guard include else { continue }

            factTasks.append(try makeFactTask(task, through: through, range: range, allEvents: allEvents,
                                              effective: effective, rangeActivities: rangeActivities,
                                              cutoffReplay: cutoffReplay, startReplay: startReplay,
                                              knownAt: knownAt))
        }

        let sources = try makeSources(range: range, rangeActivities: rangeActivities, knownAt: knownAt)

        let taskIds = Set(factTasks.map(\.id))
        let sourceIds = Set(sources.map(\.id))
        let memoLinksAccepted = try repo.memoTaskLinks(status: .accepted)
            .filter { link in
                let decided = link.decidedAt ?? link.createdAt
                guard decided <= knownAt else { return false }
                return sourceIds.contains(FactSource.memoId(link.memoId)) || taskIds.contains(link.taskId)
            }
            .map { AcceptedMemoLink(memoId: $0.memoId, taskId: $0.taskId) }

        var referencedProjectIds = Set<String>()
        for task in factTasks { referencedProjectIds.formUnion(task.projectIds) }
        for source in sources { referencedProjectIds.formUnion(source.projectIds) }
        let projects = try referencedProjectIds.sorted().map { id in
            FactProject(id: id, name: try repo.project(id: id)?.name ?? id)
        }

        let projectCompletionEventCount = effective.filter {
            $0.scopeType == .taskProject && $0.kind == .completed && range.contains($0.effectiveDate)
        }.count

        let metrics = ReportMetrics(
            uniqueTaskCount: factTasks.count,
            activityCount: sources.filter { $0.kind == .activity }.count,
            completionEventCount: factTasks.reduce(0) { $0 + $1.completionDatesInRange.count },
            completedTaskCount: factTasks.filter {
                $0.statusAtCutoff == .completed && !$0.completionDatesInRange.isEmpty
            }.count,
            projectAssociationCount: factTasks.reduce(0) { $0 + $1.projectIds.count },
            projectCompletionEventCount: projectCompletionEventCount)

        return ReportFacts(family: family, periodType: periodType, timezone: calendar.timeZone.identifier,
                           generatedAt: repo.clock.now(), range: range,
                           statusCutoff: periods.stateCutoff(of: range), knownAt: knownAt,
                           planRange: planRange, projects: projects, tasks: factTasks, sources: sources,
                           confirmedPlans: confirmedPlans, memoLinksAccepted: memoLinksAccepted,
                           metrics: metrics)
    }

    // MARK: - 제출용 주간보고

    /// (previous, plan) = periods.submissionWeek(reportDate). range = previous, planRange = plan.
    /// confirmedPlans = planService.confirmedFacts(weekStart: plan.start).
    public func submissionFacts(reportDate: WorkDate, knownAt: Date) throws -> ReportFacts {
        let (previous, plan) = periods.submissionWeek(reportDate: reportDate)
        return try build(family: .submission, periodType: .weekly, range: previous,
                         knownAt: knownAt, planRange: plan)
    }

    // MARK: - digest

    /// generatedAt을 제외한 내용의 SHA256 hex (StableJSON). 원본 변화 감지·스냅샷 digest용.
    public static func digest(_ facts: ReportFacts) throws -> String {
        var normalized = facts
        normalized.generatedAt = Date(timeIntervalSince1970: 0)
        let data = try StableJSON.encode(normalized)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 내부

    private static let earliest = WorkDate(year: 1, month: 1, day: 1)

    /// knownAt까지 기록된 Task 생성 사건이 있으면 true. 없으면 row의 createdAt으로 판단한다.
    private func createdByKnownAt(_ task: WorkTask, effective: [DomainEvent], knownAt: Date) -> Bool {
        let hasCreated = effective.contains {
            $0.scopeType == .task && $0.scopeId == task.id && $0.kind == .created
        }
        return hasCreated || task.createdAt <= knownAt
    }

    private func makeFactTask(_ task: WorkTask, through: WorkDate, range: DateRange,
                              allEvents: [DomainEvent], effective: [DomainEvent],
                              rangeActivities: [Activity], cutoffReplay: ReplayResult,
                              startReplay: ReplayResult, knownAt: Date) throws -> FactTask {
        let links = try repo.taskProjects(taskId: task.id, includeRemoved: true)
            .filter { $0.linkedOn <= through && ($0.removedOn == nil || $0.removedOn! > through) }
            .sorted { ($0.linkedOn, $0.projectId) < ($1.linkedOn, $1.projectId) }
        let projectIds = links.map(\.projectId)

        var projectStatuses: [String: TaskStatus] = [:]
        for link in links where link.trackingEnabled {
            if let status = cutoffReplay.projectStatus(taskId: task.id, projectId: link.projectId) {
                projectStatuses[link.projectId] = status
            }
        }

        let checklist = try repo.checklistItems(taskId: task.id).map { item in
            FactChecklistItem(id: item.id, text: item.text, projectIds: item.projectIds,
                              doneAtCutoff: cutoffReplay.checklistStatus(item.id) == .completed)
        }

        let completionDatesInRange = StateReplay.completionDates(taskId: task.id, allEvents,
                                                                 knownAt: knownAt)
            .filter { range.contains($0) }

        let reopenedInRange = effective.contains {
            $0.taskId == task.id && $0.kind == .reopened && range.contains($0.effectiveDate)
        }

        let eventsInRange = effective.filter { event in
            event.taskId == task.id && range.contains(event.effectiveDate)
                && (event.kind.isStatusEvent || event.kind == .projectLinked
                    || event.kind == .projectUnlinked)
        }.map { event in
            FactEvent(id: event.id, taskId: event.taskId, scopeType: event.scopeType,
                      scopeId: event.scopeId, kind: event.kind, toStatus: event.toStatus,
                      effectiveDate: event.effectiveDate)
        }

        let activitySourceIds = rangeActivities.filter { $0.taskId == task.id }
            .map { FactSource.activityId($0.id) }

        return FactTask(id: task.id, title: task.title, trackingMode: task.projectTrackingMode,
                        statusAtStart: startReplay.taskStatus(task.id), statusAtCutoff: cutoffReplay.taskStatus(task.id),
                        projectIds: projectIds, projectStatuses: projectStatuses, dueOn: task.dueOn,
                        firstStartedOn: StateReplay.firstStartedOn(taskId: task.id, allEvents, knownAt: knownAt),
                        completionDatesInRange: completionDatesInRange, reopenedInRange: reopenedInRange,
                        eventsInRange: eventsInRange, checklist: checklist, activitySourceIds: activitySourceIds)
    }

    private func makeSources(range: DateRange, rangeActivities: [Activity],
                             knownAt: Date) throws -> [FactSource] {
        var sources: [FactSource] = []

        for activity in rangeActivities {
            let urls = try repo.links(ownerType: .activity, ownerId: activity.id).map(\.url)
            sources.append(FactSource(id: FactSource.activityId(activity.id), kind: .activity,
                                      revision: activity.revision, recordedAt: activity.recordedAt,
                                      workDate: activity.workDate, taskId: activity.taskId,
                                      projectIds: activity.projectIds, text: activity.body,
                                      sourceUrls: urls, urlBodyFetched: false))
        }

        for memo in try repo.memos(in: range).filter({ $0.recordedAt <= knownAt }) {
            let urls = try repo.links(ownerType: .memo, ownerId: memo.id).map(\.url)
            sources.append(FactSource(id: FactSource.memoId(memo.id), kind: .memo,
                                      revision: memo.revision, recordedAt: memo.recordedAt,
                                      workDate: memo.workDate, taskId: nil, projectIds: memo.projectIds,
                                      text: memo.body, sourceUrls: urls, urlBodyFetched: false))
        }

        let supplements = try repo.supplements(overlapping: range)
            .filter { $0.recordedAt <= knownAt && $0.outcome == .answered }
        for supplement in supplements {
            let text = "Q: \(supplement.question)\nA: \(supplement.answer ?? "")"
            sources.append(FactSource(id: FactSource.supplementId(supplement.id), kind: .supplement,
                                      revision: 1, recordedAt: supplement.recordedAt, workDate: nil,
                                      applies: supplement.applies, taskId: supplement.taskId,
                                      projectIds: [], text: text, sourceUrls: [], urlBodyFetched: false))
        }

        sources.sort { lhs, rhs in
            let lhsDate = lhs.workDate ?? lhs.applies?.start ?? Self.earliest
            let rhsDate = rhs.workDate ?? rhs.applies?.start ?? Self.earliest
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt < rhs.recordedAt }
            return lhs.id < rhs.id
        }
        return sources
    }
}
