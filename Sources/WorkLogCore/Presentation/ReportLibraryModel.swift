import Foundation
import Observation

// MARK: - 리포트 보관함 (저장된 리포트를 기간 종류별로 둘러보는 표시 모델)
//
// 생성·저장은 ReportService/ReportStore가 이미 담당한다. 이 파일은 저장된 Report와
// ReportVersion을 읽기 전용으로 나열·선택하는 표시 계층만 만든다.
// - 새 리포트를 만들거나 AI를 호출하지 않는다.
// - 제출용 주간보고(submission)와 성과자료(performance)는 라벨·필터에서도 분리한다.
// - Secret 자료형은 이 경로에 들어오지 않는다.

/// 보관함 한 행. 리포트와 그 버전 요약, 사람이 읽는 기간·계열·상태 라벨을 담는다.
public struct ReportLibraryItem: Identifiable, Hashable, Sendable {
    /// report.id
    public var id: String { report.id }
    public let report: Report
    /// version 번호가 가장 큰 버전(없으면 nil)
    public let latestVersion: ReportVersion?
    /// state == .confirmed 인 버전 중 version 번호가 가장 큰 것
    public let confirmedVersion: ReportVersion?
    public let versionCount: Int
    /// 사람이 읽는 기간 라벨. 예: daily "2026-10-19 (월)", weekly "2026-10-13 ~ 2026-10-19",
    /// monthly "2026년 10월", quarterly "2026년 4분기", yearly "평가 기간 2025-11-01 ~ 2026-10-31"
    /// (끝 날짜는 endExclusive 하루 전, 포함 표기)
    public let periodLabel: String
    /// "성과자료"(performance) / "주간보고"(submission)
    public let familyLabel: String
    /// 상태 라벨: latestVersion.state 기준 "초안"(draft) / "수정본"(edited) / "확정"(confirmed) /
    /// "이전 버전"(superseded) / 버전 없음이면 "본문 없음"
    public let stateLabel: String

    public init(report: Report, latestVersion: ReportVersion?, confirmedVersion: ReportVersion?,
                versionCount: Int, periodLabel: String, familyLabel: String, stateLabel: String) {
        self.report = report
        self.latestVersion = latestVersion
        self.confirmedVersion = confirmedVersion
        self.versionCount = versionCount
        self.periodLabel = periodLabel
        self.familyLabel = familyLabel
        self.stateLabel = stateLabel
    }
}

/// 저장된 리포트 보관함 화면 모델. `load()`가 repo에서 전체 리포트와 버전을 다시 읽는다.
@Observable @MainActor public final class ReportLibraryModel {
    /// 현재 보고 있는 기간 종류. 기본 .weekly
    public var periodType: PeriodType {
        didSet { dropSelectionIfHidden() }
    }
    /// nil = 두 계열 모두. weekly 외 기간에는 submission이 없으므로 결과적으로 performance만 나온다.
    public var familyFilter: ReportFamily? {
        didSet { dropSelectionIfHidden() }
    }
    public private(set) var allItems: [ReportLibraryItem]
    /// allItems 중 periodType·familyFilter에 맞는 것. range.start 내림차순, 같으면 submission 먼저.
    public var items: [ReportLibraryItem] {
        allItems.filter { item in
            guard item.report.periodType == periodType else { return false }
            guard let familyFilter else { return true }
            return item.report.family == familyFilter
        }
    }
    public var selectedId: String?
    /// items에 없는 id면 nil.
    public var selectedItem: ReportLibraryItem? {
        guard let selectedId else { return nil }
        return items.first { $0.id == selectedId }
    }
    /// 선택 항목의 표시 본문: latestVersion?.content (없으면 nil)
    public var selectedContent: String? { selectedItem?.latestVersion?.content }
    public private(set) var errorMessage: String?

    @ObservationIgnored private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
        self.periodType = .weekly
        self.familyFilter = nil
        self.allItems = []
    }

    /// familyFilter 적용 개수. periodType은 인자로 받는다.
    public func count(for type: PeriodType) -> Int {
        allItems.filter { item in
            guard item.report.periodType == type else { return false }
            guard let familyFilter else { return true }
            return item.report.family == familyFilter
        }.count
    }

    /// repo에서 전체 리포트와 버전을 다시 읽는다. 실패 시 allItems 유지, errorMessage 설정(한국어 문구).
    /// 성공 시 errorMessage=nil, 선택이 사라졌으면 selectedId=nil.
    public func load() {
        do {
            let reports = try environment.repo.reports()
            var loaded: [ReportLibraryItem] = []
            loaded.reserveCapacity(reports.count)
            for report in reports {
                let versions = try environment.repo.reportVersions(reportId: report.id)
                loaded.append(Self.item(for: report, versions: versions,
                                        calendar: environment.calendar))
            }
            allItems = loaded.sorted(by: Self.precedes)
            errorMessage = nil
            dropSelectionIfHidden()
        } catch {
            errorMessage = "리포트 보관함을 불러오지 못했습니다. 다시 불러오세요."
        }
    }

    /// nil이면 선택 해제. items에 없는 id도 선택 해제로 처리한다.
    public func select(_ id: String?) {
        guard let id else { selectedId = nil; return }
        selectedId = items.contains { $0.id == id } ? id : nil
    }

    // MARK: - 내부

    /// 기간 종류·계열 필터가 바뀌어 현재 선택이 목록에서 사라지면 선택을 푼다.
    private func dropSelectionIfHidden() {
        guard let selectedId else { return }
        if !items.contains(where: { $0.id == selectedId }) { self.selectedId = nil }
    }

    /// range.start 내림차순, 같으면 submission 먼저, 그다음 id 오름차순.
    private static func precedes(_ lhs: ReportLibraryItem, _ rhs: ReportLibraryItem) -> Bool {
        if lhs.report.range.start != rhs.report.range.start {
            return lhs.report.range.start > rhs.report.range.start
        }
        if lhs.report.family != rhs.report.family {
            return lhs.report.family == .submission
        }
        return lhs.id < rhs.id
    }

    private static func item(for report: Report, versions: [ReportVersion],
                             calendar: WorkCalendar) -> ReportLibraryItem {
        let latest = versions.max { $0.version < $1.version }
        let confirmed = versions
            .filter { $0.state == .confirmed }
            .max { $0.version < $1.version }
        return ReportLibraryItem(
            report: report,
            latestVersion: latest,
            confirmedVersion: confirmed,
            versionCount: versions.count,
            periodLabel: periodLabel(for: report, calendar: calendar),
            familyLabel: familyLabel(for: report.family),
            stateLabel: stateLabel(for: latest))
    }

    private static func periodLabel(for report: Report, calendar: WorkCalendar) -> String {
        let range = report.range
        // 표시는 끝을 포함한다: endExclusive 하루 전.
        let last = calendar.adding(days: -1, to: range.endExclusive)
        switch report.periodType {
        case .daily:
            let weekday = KoreanDateLabel.weekdayName(calendar.isoWeekday(range.start))
            return "\(range.start.iso) (\(weekday))"
        case .weekly:
            return "\(range.start.iso) ~ \(last.iso)"
        case .monthly:
            return "\(range.start.year)년 \(range.start.month)월"
        case .quarterly:
            return "\(range.start.year)년 \(((range.start.month - 1) / 3) + 1)분기"
        case .yearly:
            // 평가 기간 제목을 돌려주는 public API가 없어 기본 형식을 쓴다.
            return "평가 기간 \(range.start.iso) ~ \(last.iso)"
        }
    }

    private static func familyLabel(for family: ReportFamily) -> String {
        switch family {
        case .submission: return "주간보고"
        case .performance: return "성과자료"
        }
    }

    private static func stateLabel(for version: ReportVersion?) -> String {
        guard let version else { return "본문 없음" }
        switch version.state {
        case .draft: return "초안"
        case .edited: return "수정본"
        case .confirmed: return "확정"
        case .superseded: return "이전 버전"
        }
    }
}
