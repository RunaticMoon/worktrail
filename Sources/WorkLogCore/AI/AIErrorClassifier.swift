import Foundation

// 오류를 앱의 AIErrorClass로 분류한다. 메시지 키워드(대소문자 무시)와 JSON-RPC 코드를 함께 본다.
// 서버 원문 전체를 저장·로그하지 않기 위해 여기서는 짧은 판단만 한다.

/// Codex 실행 파일을 찾지 못했을 때(프로세스 실행 실패). notInstalled로 분류한다.
public struct AIExecutableNotFoundError: Error, Equatable, Sendable {
    public var path: String
    public init(path: String) { self.path = path }
}

public enum AIErrorClassifier {
    /// JSON-RPC 오류·전송 종료·타임아웃·디코딩 실패를 AIErrorClass로 분류한다.
    public static func classify(_ error: Error) -> AIErrorClass {
        if let provider = error as? AIProviderError { return provider.errorClass }
        if error is AIExecutableNotFoundError { return .notInstalled }

        if let rpc = error as? JSONRPCErrorPayload {
            return classifyMessage(rpc.message, code: rpc.code)
        }

        if let client = error as? JSONRPCClientError {
            switch client {
            case .rpc(let payload):
                return classifyMessage(payload.message, code: payload.code)
            case .timeout:
                return .timeout
            case .cancelled:
                return .cancelled
            case .closed(let reason):
                switch reason {
                case .closedByClient:
                    return .cancelled
                case .exited, .error:
                    return .network
                }
            case .malformed:
                return .protocolMismatch
            }
        }

        if error is DecodingError || error is EncodingError { return .protocolMismatch }

        if isFileNotFound(error) { return .notInstalled }

        return classifyMessage(String(describing: error), code: nil)
    }

    /// 서버가 준 오류 메시지·(선택) JSON-RPC 코드를 키워드로 분류한다.
    public static func classifyMessage(_ message: String, code: Int?) -> AIErrorClass {
        if let code, code == -32601 || code == -32602 { return .protocolMismatch }

        let lower = message.lowercased()

        // "login expired"처럼 겹치는 표현은 만료를 우선한다.
        if lower.contains("expired") { return .authExpired }
        if lower.contains("unauthorized") || lower.contains("401")
            || lower.contains("not logged in") || lower.contains("login") {
            return .notLoggedIn
        }
        if lower.contains("rate limit") || lower.contains("429")
            || lower.contains("usage limit") || lower.contains("quota") {
            return .rateLimited
        }
        if lower.contains("policy") || lower.contains("not allowed")
            || lower.contains("forbidden") || lower.contains("403")
            || lower.contains("disabled by") {
            return .policyRestricted
        }
        if lower.contains("network") || lower.contains("connection")
            || lower.contains("dns") || lower.contains("offline") {
            return .network
        }
        if lower.contains("timed out") || lower.contains("timeout") { return .timeout }
        if lower.contains("cancel") { return .cancelled }
        if lower.contains("protocol") || lower.contains("decode") { return .protocolMismatch }
        return .unknown
    }

    private static func isFileNotFound(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            if nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError {
                return true
            }
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
            return true
        }
        return false
    }
}
