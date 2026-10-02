import Foundation

// MARK: - 기록 경계 집계 (읽기 전용)
//
// 일반 기록 테이블에서만 경계 값을 SQL 집계로 구한다. 전체 행을 메모리에 올리지 않는다.
// Secret(vault) 테이블은 별도 DB이며 여기서 절대 조회하지 않는다.
extension WorkRepository {

    /// 일반 기록(memo·activity·domain_event)에 등장하는 가장 이른 업무일.
    /// 기록이 없으면 nil. 정정(voided) 여부와 무관하게 실제 기록된 날짜를 본다.
    public func earliestRecordedWorkDate() throws -> WorkDate? {
        let row = try db.queryOneV("""
            SELECT MIN(d) AS earliest FROM (
                SELECT MIN(work_date) AS d FROM memo WHERE deleted_at IS NULL
                UNION ALL
                SELECT MIN(work_date) AS d FROM activity WHERE deleted_at IS NULL
                UNION ALL
                SELECT MIN(effective_date) AS d FROM domain_event
            )
            """)
        guard let text = row?.string("earliest") else { return nil }
        return WorkDate(text)
    }
}
