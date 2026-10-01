import Foundation

/// 놓친 예약 작업을 idempotent하게 실행하는 실행기.
/// 실제 리포트 생성은 handler 클로저가 담당하며, 이 클래스는 상태 전이와 영속화만 책임진다.
public final class SchedulerRunner: @unchecked Sendable {
    private let repo: WorkRepository
    private let periods: Periods
    private let clock: Clock
    private let settings: AppSettings
    private let since: WorkDate

    public init(repo: WorkRepository, periods: Periods, clock: Clock,
                settings: AppSettings, since: WorkDate) {
        self.repo = repo
        self.periods = periods
        self.clock = clock
        self.settings = settings
        self.since = since
    }

    /// 1) 죽은 running을 pending으로 되돌린다.
    /// 2) 실행 시점이 지난 작업을 pending으로 넣는다(이미 있는 기간은 건너뛴다).
    /// 3) pending/failed(attempts < maxAttempts)를 scheduledFor 순서로 하나씩 실행한다.
    ///    이미 succeeded인 작업은 다시 실행하지 않는다.
    @discardableResult
    public func runDue(maxAttempts: Int = 3,
                       handler: (DueJob) async throws -> Void) async throws -> [ScheduledJob] {
        try repo.resetStaleRunningJobs()

        let now = clock.now()
        let existingKeys = try repo.scheduledJobKeys()
        let due = SchedulePlanner.dueJobs(now: now, since: since, existingKeys: existingKeys,
                                          settings: settings, periods: periods)
        for job in due {
            _ = try repo.insertScheduledJobIfAbsent(ScheduledJob(
                id: repo.ids.make(), type: job.type, periodKey: job.periodKey,
                scheduledFor: job.scheduledFor, state: .pending))
        }

        let candidates = try repo.scheduledJobs(states: [.pending, .failed])
            .filter { $0.attempts < maxAttempts }

        var processed: [ScheduledJob] = []
        for candidate in candidates {
            guard var job = try repo.scheduledJob(type: candidate.type, periodKey: candidate.periodKey)
            else { continue }
            guard let range = SchedulePlanner.range(for: job.type, periodKey: job.periodKey,
                                                    periods: periods) else {
                // 이 실행기가 다루지 않는 유형(예: backup)은 건드리지 않는다.
                continue
            }
            let dueJob = DueJob(type: job.type, periodKey: job.periodKey,
                                range: range, scheduledFor: job.scheduledFor)

            job.state = .running
            job.lastAttemptAt = clock.now()
            try repo.updateScheduledJob(job)

            do {
                try await handler(dueJob)
                job.state = .succeeded
                job.lastError = nil
            } catch {
                job.state = .failed
                job.lastError = String(describing: error)
            }
            job.attempts += 1
            job.recoveredLate = SchedulePlanner.isLate(scheduledFor: job.scheduledFor,
                                                       executedAt: clock.now())
            job.lastAttemptAt = clock.now()
            try repo.updateScheduledJob(job)
            processed.append(job)
        }

        return processed
    }
}
