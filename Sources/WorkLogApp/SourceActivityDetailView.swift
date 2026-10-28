#if os(macOS)
import AppKit
import SwiftUI
import WorkLogCore

/// Presentation uses stored source metadata; memo text never determines its source.
struct SourceActivityPresentation {
    let record: ImportedActivityRecord

    var sourceName: String { record.source == .github ? "GitHub" : "Jira" }
    var symbol: String { record.source == .github ? "arrow.triangle.branch" : "ticket" }

    var headline: String {
        let display = record.display
        let repository = nonempty(display.repository) ?? "GitHub"
        let issue = nonempty(display.issueKey) ?? "Jira"
        switch display.kind {
        case .githubPush:
            let branch = nonempty(display.branch).map { " · \($0)" } ?? ""
            let count = display.commitCount.map { " · 커밋 \($0)개" } ?? ""
            return "\(repository)\(branch) push\(count)"
        case .githubPullRequest:
            return "\(repository) · \(pullRequestLabel) \(actionLabel(display.action, fallback: "활동"))"
        case .githubReview:
            return "\(repository) · \(pullRequestLabel) 리뷰 \(actionLabel(display.action, fallback: "등록"))"
        case .jiraCreated:
            return "\(issue) 생성"
        case .jiraTransition:
            let from = nonempty(display.statusFrom) ?? "이전 상태"
            let to = nonempty(display.statusTo) ?? "새 상태"
            return "\(issue) · \(from) → \(to)"
        case .jiraUpdated:
            return "\(issue) 업데이트"
        case .jiraWorklog:
            let duration = display.durationSeconds.map { " · \(durationLabel($0))" } ?? ""
            return "\(issue) 작업 시간 기록\(duration)"
        case .unknown:
            return nonempty(display.title) ?? firstLine ?? "\(sourceName) 수집 활동"
        }
    }

    var subtitle: String? {
        if let title = nonempty(record.display.title), title != headline { return title }
        if record.display.kind == .jiraUpdated, !record.display.changedFields.isEmpty {
            let fields = record.display.changedFields.prefix(3).joined(separator: ", ")
            let remainder = record.display.changedFields.count - 3
            return "변경: \(fields)" + (remainder > 0 ? " 외 \(remainder)개" : "")
        }
        return nil
    }

    var sourceURL: URL? {
        guard let parts = URLComponents(string: record.sourceURL),
              parts.scheme?.lowercased() == "https", parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil else { return nil }
        return parts.url
    }

    private var pullRequestLabel: String { record.display.number.map { "PR #\($0)" } ?? "PR" }
    private var firstLine: String? {
        guard let line = record.memo.body.split(whereSeparator: \.isNewline).first else { return nil }
        let prefix = "[\(record.source.title)] "
        let text = String(line)
        return text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func actionLabel(_ action: String?, fallback: String) -> String {
        guard let action = nonempty(action) else { return fallback }
        switch action.lowercased() {
        case "merged": return "병합됨"
        case "opened", "created": return "생성됨"
        case "closed": return "닫힘"
        case "reopened": return "다시 열림"
        case "edited", "updated", "synchronize": return "수정됨"
        case "submitted": return "등록됨"
        case "approved": return "승인됨"
        case "changes_requested": return "수정 요청"
        case "commented": return "의견 등록"
        case "dismissed": return "해제됨"
        default: return action.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func durationLabel(_ seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        if minutes >= 60 {
            let remainder = minutes % 60
            return "\(minutes / 60)시간" + (remainder > 0 ? " \(remainder)분" : "")
        }
        return minutes > 0 ? "\(minutes)분" : "\(max(0, seconds))초"
    }
}

@MainActor struct SourceActivityDetailView: View {
    let record: ImportedActivityRecord
    let calendar: WorkCalendar
    let onClose: () -> Void
    var onEdit: (() -> Void)? = nil
    @FocusState private var closeFocused: Bool

    private var presentation: SourceActivityPresentation { SourceActivityPresentation(record: record) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(presentation.sourceName) 활동", systemImage: presentation.symbol)
                        .font(.headline)
                    Text(presentation.headline).font(.title2.weight(.semibold)).textSelection(.enabled)
                    if let subtitle = presentation.subtitle { Text(subtitle).foregroundStyle(.secondary).textSelection(.enabled) }
                    HStack(spacing: 6) {
                        Text(record.occurredAt, style: .date)
                        Text(record.occurredAt, style: .time)
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    .environment(\.timeZone, calendar.timeZone)
                }
                Spacer(minLength: 12)
                Button("닫기", action: onClose).keyboardShortcut(.cancelAction).focused($closeFocused)
            }
            HStack(spacing: 12) {
                if let url = presentation.sourceURL {
                    Link(destination: url) { Label("\(presentation.sourceName)에서 원본 열기", systemImage: "arrow.up.right.square") }
                        .accessibilityIdentifier("source-activity.original-link")
                }
                if let onEdit {
                    Button("기록 편집 · 업무 연결", action: onEdit)
                        .accessibilityIdentifier("source-activity.edit")
                }
            }
            Divider()
            ScrollView {
                Text(record.memo.body).frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("source-activity.body")
            }
        }
        .padding(WorkLogTheme.contentInset)
        .frame(minWidth: 540, minHeight: 440)
        .accessibilityIdentifier("source-activity.detail")
        .background(WorkLogKeyHandler { event in
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard modifiers == .command, event.keyCode == 13 else { return false }
            if !event.isARepeat { onClose() }
            return true
        })
        .onAppear { closeFocused = true }
    }
}
#endif
