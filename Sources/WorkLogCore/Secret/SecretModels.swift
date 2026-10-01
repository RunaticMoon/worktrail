import Foundation

// Secret 경로는 AI와 완전히 분리된다. 이 파일의 타입은 AI 입력 타입(AIJobInput 등)에
// 포함되어서는 안 되며, Encodable이더라도 일반 work.sqlite·검색 인덱스·로그에 쓰지 않는다.

/// 표의 한 행(복호화된 메모리 상태). 모든 값은 문자열이다(숫자·불리언 변환 없음).
public struct SecretRow: Codable, Hashable, Sendable, Identifiable {
    /// key 이름이 바뀌어도 유지되는 안정적인 행 ID
    public var id: String
    public var key: String
    public var value: String
    public var order: Int
    public init(id: String, key: String, value: String, order: Int) {
        self.id = id; self.key = key; self.value = value; self.order = order
    }
}

/// 암호화되는 본문의 JSON 구조 (DecryptedPayload).
public struct SecretPayload: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var items: [SecretRow]
    public init(schemaVersion: Int = 1, items: [SecretRow]) {
        self.schemaVersion = schemaVersion; self.items = items
    }
}

/// 편집 화면에서 저장 요청으로 들어오는 행. id == nil이면 새 행.
public struct SecretRowInput: Hashable, Sendable {
    public var id: String?
    public var key: String
    public var value: String
    public init(id: String? = nil, key: String, value: String) {
        self.id = id; self.key = key; self.value = value
    }
}

/// 잠금 중에도 볼 수 있는 최소 메타데이터 (제목 검색용). 값·key는 포함하지 않는다.
public struct SecretMetadata: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var groupId: String?
    public var groupName: String?
    public var latestRevisionId: String?
    public var latestVersion: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public init(id: String, title: String, groupId: String? = nil, groupName: String? = nil,
                latestRevisionId: String? = nil, latestVersion: Int = 0, createdAt: Date,
                updatedAt: Date, deletedAt: Date? = nil) {
        self.id = id; self.title = title; self.groupId = groupId; self.groupName = groupName
        self.latestRevisionId = latestRevisionId; self.latestVersion = latestVersion
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}

/// 저장 시 정규화 결과에서 사용자 확인이 필요한 문제.
public enum SecretValidationIssue: Hashable, Sendable {
    /// trim 후 같은 key를 가진 행들 (값을 조용히 버리지 않는다)
    case duplicateKey(key: String, rowIds: [String])
    /// 존재하지 않는 행 ID로 수정 요청
    case unknownRowId(String)
}
