import Foundation

/// 실패 복구 안내의 공통 문구. "무엇이 실패 · 무엇은 보존 · 재시도 방법" 순서를 항상 유지한다.
/// 화면은 실패가 해결될 때까지 이 문구를 유지하고, 토스트만으로 되돌리기를 제공하지 않는다.
public struct RecoveryMessage: Equatable, Sendable {
    public var failed: String
    public var preserved: String
    public var retry: String

    public init(failed: String, preserved: String, retry: String) {
        self.failed = failed
        self.preserved = preserved
        self.retry = retry
    }

    public var text: String { "\(failed) · \(preserved) · \(retry)" }

    /// 빠른 입력 저장 실패.
    public static let captureSaveFailed = RecoveryMessage(
        failed: "저장하지 못했습니다",
        preserved: "입력은 그대로 있습니다",
        retry: "다시 저장하세요")

    /// AI 초안 생성 실패.
    public static let aiDraftFailed = RecoveryMessage(
        failed: "AI 초안을 만들지 못했습니다",
        preserved: "기존 본문은 그대로입니다",
        retry: "다시 시도하세요")

    /// 검색 실패.
    public static let searchFailed = RecoveryMessage(
        failed: "검색하지 못했습니다",
        preserved: "이전 결과는 그대로입니다",
        retry: "다시 시도하세요")
}
