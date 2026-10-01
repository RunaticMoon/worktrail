import Foundation

// provider 출력 저장 전 민감 마커 검사.
// - Codex read-only sandbox는 로컬 파일 읽기를 막지 못하므로, 프롬프트 인젝션으로 인증 정보가
//   출력에 섞이면 ai_job.result_json(work.sqlite·백업·검색 대상)에 남을 수 있다. 저장 전에 차단한다.
// - 어떤 마커에 걸렸는지는 반환·저장·로그하지 않는다(Bool만).
public struct AIOutputGuard: Sendable {
    /// 대소문자 무시로 비교하는 기본 마커
    public static let defaultMarkers: [String] = [
        ".codex/", "auth.json", "refresh_token", "access_token", "id_token",
        "PRIVATE KEY", "OPENAI_API_KEY", "Bearer "
    ]
    public var markers: [String]
    public var blockedSubstrings: [String]
    public init(markers: [String] = AIOutputGuard.defaultMarkers, blockedSubstrings: [String] = []) {
        self.markers = markers
        self.blockedSubstrings = blockedSubstrings
    }

    /// 위반이면 true. 빈 문자열 규칙은 무시.
    public func containsSensitiveContent(_ text: String) -> Bool {
        for marker in markers where !marker.isEmpty {
            if text.range(of: marker, options: .caseInsensitive) != nil {
                return true
            }
        }
        for substring in blockedSubstrings where !substring.isEmpty {
            if text.contains(substring) {
                return true
            }
        }
        return false
    }
}
