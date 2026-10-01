import Foundation
import Observation

@Observable @MainActor public final class DayViewModel {
    public var selectedDate: WorkDate
    public var includeHeldAndCancelled = false
    public private(set) var box: DayBox?
    /// Existing daily AI output only. Loading the day never generates a report or invokes AI.
    public private(set) var aiSummary: ReportVersion?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    @ObservationIgnored private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
        selectedDate = environment.calendar.workDate(of: environment.options.clock.now())
    }
    public func load() {
        isLoading = true
        defer { isLoading = false }
        do {
            box = try environment.dayBox.dayBox(for: selectedDate, includeHeldAndCancelled: includeHeldAndCancelled)
            aiSummary = nil
            if let report = try environment.repo.report(family: .performance, periodType: .daily,
                periodKey: environment.periods.periodKey(.daily, containing: selectedDate)) {
                aiSummary = try environment.repo.reportVersions(reportId: report.id)
                    .filter { $0.generator != "deterministic" }.max { $0.version < $1.version }
            }
            errorMessage = nil
        } catch { box = nil; aiSummary = nil; errorMessage = "하루 기록을 불러오지 못했습니다. 다시 시도하세요." }
    }
    public func move(days: Int) {
        selectedDate = environment.calendar.adding(days: days, to: selectedDate)
        load()
    }
    public func showToday() {
        selectedDate = environment.calendar.workDate(of: environment.options.clock.now())
        load()
    }
}
