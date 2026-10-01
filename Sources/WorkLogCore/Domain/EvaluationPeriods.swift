import Foundation

/// 연간 평가 기간의 시작·종료 경계 규칙.
/// 기간 ID와 리포트 버전 ID를 분리해, 같은 기간의 새 버전이 다음 시작일을 이동시키지 않게 한다.
public enum EvaluationPeriods {

    /// 확정된 평가 기간(`confirmedReportVersionId != nil`) 중 endExclusive가 가장 늦은 것의 endExclusive.
    /// 확정된 기간이 없으면 nil (첫 평가는 사용자가 시작일을 지정한다).
    public static func nextStart(after periods: [EvaluationPeriod]) -> WorkDate? {
        periods
            .filter { $0.confirmedReportVersionId != nil }
            .map { $0.range.endExclusive }
            .max()
    }

    /// 새 평가 구간. start: 사용자가 지정한 시작일(첫 평가) 또는 nil이면 nextStart.
    /// endInclusive: 사용자가 지정한 종료일(포함) → endExclusive = endInclusive + 1일.
    /// 시작을 정할 수 없거나 endInclusive < start면 WorkLogError.validation.
    public static func propose(start: WorkDate?, endInclusive: WorkDate,
                               existing: [EvaluationPeriod], calendar: WorkCalendar) throws -> DateRange {
        let resolvedStart: WorkDate
        if let start {
            resolvedStart = start
        } else if let derived = nextStart(after: existing) {
            resolvedStart = derived
        } else {
            throw WorkLogError.validation("첫 평가 기간은 시작일을 지정해야 합니다.")
        }

        guard endInclusive >= resolvedStart else {
            throw WorkLogError.validation(
                "평가 종료일(\(endInclusive.iso))이 시작일(\(resolvedStart.iso))보다 빠릅니다.")
        }

        let endExclusive = calendar.adding(days: 1, to: endInclusive)
        return DateRange(start: resolvedStart, endExclusive: endExclusive)
    }

    /// 기존 확정 기간과의 겹침/공백 경고(한국어 문자열 목록).
    /// 같은 id의 기존 기간은 비교에서 제외한다.
    public static func boundaryWarnings(_ range: DateRange, periodId: String?,
                                        existing: [EvaluationPeriod]) -> [String] {
        var warnings: [String] = []
        let others = existing.filter { $0.id != periodId && $0.confirmedReportVersionId != nil }
        for period in others {
            if range.intersection(period.range) != nil {
                warnings.append("새 평가 기간 [\(range.start.iso), \(range.endExclusive.iso))이 "
                    + "기존 확정 기간 [\(period.range.start.iso), \(period.range.endExclusive.iso))와 겹칩니다.")
            } else if range.endExclusive < period.range.start {
                warnings.append("새 평가 기간과 기존 확정 기간 "
                    + "[\(period.range.start.iso), \(period.range.endExclusive.iso)) 사이에 공백이 있습니다.")
            } else if period.range.endExclusive < range.start {
                warnings.append("기존 확정 기간 "
                    + "[\(period.range.start.iso), \(period.range.endExclusive.iso))과 새 평가 기간 사이에 공백이 있습니다.")
            }
        }
        return warnings
    }
}
