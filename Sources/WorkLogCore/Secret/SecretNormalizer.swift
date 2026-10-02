import Foundation

// Secret 표 저장 직전의 순수 정규화 로직. 암호화·DB·UI·AI 없음.
// 이 코드는 어떤 네트워크·AI도 호출하지 않는다.

/// 편집 화면이 만든 부분 변경 묶음. upsert의 id == nil이면 새 행, id != nil이면 기존 행 수정.
public struct SecretChangeSet: Hashable, Sendable {
    public var upserts: [SecretRowInput]
    public var deletedRowIds: [String]
    public init(upserts: [SecretRowInput] = [], deletedRowIds: [String] = []) {
        self.upserts = upserts
        self.deletedRowIds = deletedRowIds
    }
}

/// 정규화 결과. issues가 비어 있지 않으면 호출자는 저장하지 않는다.
public struct SecretNormalizationResult: Hashable, Sendable {
    /// 최종 행 (order 0..n-1로 재번호)
    public var rows: [SecretRow]
    public var issues: [SecretValidationIssue]
    /// 직전 rows와 (id,key,value,순서) 비교해 실제 변경이 있으면 true
    public var changed: Bool
    public init(rows: [SecretRow], issues: [SecretValidationIssue], changed: Bool) {
        self.rows = rows
        self.issues = issues
        self.changed = changed
    }
}

public enum SecretNormalizer {
    /// 앞뒤의 공백·탭·개행만 제거 (CharacterSet.whitespacesAndNewlines 기준).
    /// 내부 문자·대소문자·Unicode 정규화·따옴표·URL 인코딩은 절대 변경하지 않는다.
    public static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func apply(existing: [SecretRow],
                             changes: SecretChangeSet,
                             ids: IDGenerator) -> SecretNormalizationResult {
        // 1. existing 순서(order 기준)를 유지한다.
        let original = existing.sorted { $0.order < $1.order }
        var rows = original
        var issues: [SecretValidationIssue] = []

        // 2. 삭제된 행 제거, 존재하지 않는 ID는 issue.
        for deletedId in changes.deletedRowIds {
            if let index = rows.firstIndex(where: { $0.id == deletedId }) {
                rows.remove(at: index)
            } else {
                issues.append(.unknownRowId(deletedId))
            }
        }

        // 3/4. upsert 처리.
        for upsert in changes.upserts {
            let key = trim(upsert.key)
            let value = trim(upsert.value)
            if let id = upsert.id {
                if let index = rows.firstIndex(where: { $0.id == id }) {
                    rows[index].key = key
                    rows[index].value = value
                } else {
                    issues.append(.unknownRowId(id))
                }
            } else {
                // 완전히 빈 새 행은 무시.
                if key.isEmpty && value.isEmpty { continue }
                rows.append(SecretRow(id: ids.make(), key: key, value: value, order: rows.count))
            }
        }

        // 6. trim 후 key가 빈 행에 충돌 없는 자동 key 부여.
        var used = Set(rows.filter { !trim($0.key).isEmpty }.map { $0.key })
        for index in rows.indices where trim(rows[index].key).isEmpty {
            var n = 1
            while used.contains("key\(n)") { n += 1 }
            let assigned = "key\(n)"
            rows[index].key = assigned
            used.insert(assigned)
        }

        // 8. 최종 order를 0부터 재번호.
        for index in rows.indices { rows[index].order = index }

        // 7. 같은 key(대소문자 구분, 정확히 일치)가 2개 이상이면 duplicateKey.
        var keyOrder: [String] = []
        var grouped: [String: [String]] = [:]
        for row in rows {
            if grouped[row.key] == nil { keyOrder.append(row.key) }
            grouped[row.key, default: []].append(row.id)
        }
        for key in keyOrder {
            if let rowIds = grouped[key], rowIds.count >= 2 {
                issues.append(.duplicateKey(key: key, rowIds: rowIds))
            }
        }

        // changed: existing(order)과 최종 (id,key,value) 순서열 비교.
        let changed = !isUnchanged(original: original, final: rows)
        return SecretNormalizationResult(rows: rows, issues: issues, changed: changed)
    }

    private static func isUnchanged(original: [SecretRow], final rows: [SecretRow]) -> Bool {
        guard original.count == rows.count else { return false }
        for (a, b) in zip(original, rows) {
            if a.id != b.id || a.key != b.key || a.value != b.value { return false }
        }
        return true
    }
}
