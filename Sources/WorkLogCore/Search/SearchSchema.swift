import Foundation

/// 검색 전용 migration (work.sqlite v2). 검색 담당 작업에서 FTS5 가상 테이블을 정의한다.
public enum SearchSchema {
    /// TODO(검색 작업): FTS5 trigram 인덱스 DDL. 비어 있으면 LIKE 경로만 사용.
    static let v2 = "SELECT 1;"
}
