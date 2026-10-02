import Foundation

/// 앱 공통 오류. 사용자에게 보여줄 한국어 메시지를 함께 둔다.
public enum WorkLogError: Error, Equatable, LocalizedError {
    case notFound(String)
    case validation(String)
    case invalidTransition(String)
    case conflict(String)
    case storage(String)
    case integrity(String)
    case vaultLocked
    case vaultKeyMissing
    case policyBlocked(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let s): return "찾을 수 없음: \(s)"
        case .validation(let s): return "입력 확인 필요: \(s)"
        case .invalidTransition(let s): return "허용되지 않는 상태 변경: \(s)"
        case .conflict(let s): return "충돌: \(s)"
        case .storage(let s): return "저장소 오류: \(s)"
        case .integrity(let s): return "무결성 오류: \(s)"
        case .vaultLocked: return "Secret 보관함이 잠겨 있습니다."
        case .vaultKeyMissing: return "Secret 암호화 키를 찾을 수 없습니다. 기존 보관함은 변경하지 않았습니다."
        case .policyBlocked(let s): return "정책상 실행 불가: \(s)"
        }
    }
}
