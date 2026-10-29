#if os(macOS)
import Foundation
import WorkLogCore

/// Performance and gap notifications cannot dismiss an unresolved decoder error.
/// Only a successful request from the same track clears that track's failure.
struct MeetingPreviewStatus {
    var progressMessage: String?
    private(set) var failures: [String: MeetingOperationFailure] = [:]

    var message: String? {
        if let track = failures.keys.sorted().first, let failure = failures[track] {
            return MeetingFailurePresentation.previewMessage(for: failure)
        }
        return progressMessage
    }

    /// Returns a changed failure for one diagnostic event per distinct failure episode.
    mutating func receive(_ event: MeetingPreviewEvent) -> MeetingOperationFailure? {
        switch event {
        case .failed(let track, let failure):
            let previous = failures.updateValue(failure, forKey: track)
            return previous == failure ? nil : failure
        case .succeeded(let track):
            failures.removeValue(forKey: track)
            progressMessage = "실시간 전사를 갱신했습니다."
        case .load(let interval, let duration, _):
            progressMessage = "최근 추론 \(String(format: "%.1f", duration))초 · 갱신 시도 \(String(format: "%.1f", interval))초 간격"
        case .skipped:
            progressMessage = "미리보기 일부 구간을 건너뛰었습니다. 종료 후 원본에서 다시 전사합니다."
        case .updated: break
        }
        return nil
    }
}
#endif
