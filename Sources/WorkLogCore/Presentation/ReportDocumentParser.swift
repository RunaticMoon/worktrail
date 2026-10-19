import Foundation

/// Display-only blocks. The original Markdown remains the editable/copyable source.
public enum MarkdownDocumentBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(marker: String, text: String, depth: Int)
    case code(language: String, text: String)
    case quote(String)
    case rule
}

public enum MarkdownDocumentParser {
    public static func parse(_ markdown: String) -> [MarkdownDocumentBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownDocumentBlock] = []
        var paragraph: [String] = []
        var index = 0
        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph.removeAll(keepingCapacity: true)
        }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
            } else if let fence = fenceStart(trimmed) {
                flushParagraph()
                var code: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    let run = candidate.prefix(while: { $0 == fence.character })
                    if run.count >= fence.count && candidate.dropFirst(run.count).isEmpty { break }
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: fence.language, text: code.joined(separator: "\n")))
            } else if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
            } else if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
            } else if let item = listItem(line) {
                flushParagraph()
                blocks.append(.listItem(marker: item.marker, text: item.text, depth: item.depth))
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var content = candidate.dropFirst()
                    if content.first == " " { content = content.dropFirst() }
                    quote.append(String(content))
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            } else {
                paragraph.append(line)
            }
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first?.isWhitespace == true else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, "*-_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func fenceStart(_ line: String) -> (character: Character, count: Int, language: String)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let count = line.prefix(while: { $0 == first }).count
        guard count >= 3 else { return nil }
        return (first, count, line.dropFirst(count).trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> (marker: String, text: String, depth: Int)? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        let depth = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
        let content = line.dropFirst(indent.count)
        guard let first = content.first else { return nil }
        if "-*+".contains(first), content.dropFirst().first?.isWhitespace == true {
            return ("•", content.dropFirst().trimmingCharacters(in: .whitespaces), depth)
        }
        let digits = content.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let remainder = content.dropFirst(digits.count)
        guard remainder.first == ".", remainder.dropFirst().first?.isWhitespace == true else { return nil }
        return (String(digits) + ".", remainder.dropFirst().trimmingCharacters(in: .whitespaces), depth)
    }
}

public struct SubmissionDocumentLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading
        case item(status: TaskStatus, text: String)
        case text
        case blank
    }
    public let source: String
    public let kind: Kind
}

/// Conservatively recognizes WEEK-02/03 without rewriting stored report text.
public enum SubmissionDocumentParser {
    public static func parse(_ text: String) -> [SubmissionDocumentLine] {
        // CRLF is one Swift Character; split at the LF byte to retain each original CR.
        let lines = text.utf8.split(separator: 10, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        var atGroupStart = true
        return lines.indices.map { index in
            let line = lines[index]
            let kind: SubmissionDocumentLine.Kind
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                kind = .blank
                atGroupStart = true
            } else if let item = item(line) {
                kind = .item(status: item.status, text: item.text)
                atGroupStart = false
            } else {
                let nextIsItem = index + 1 < lines.count && item(lines[index + 1]) != nil
                kind = atGroupStart && nextIsItem ? .heading : .text
                atGroupStart = false
            }
            return SubmissionDocumentLine(source: line, kind: kind)
        }
    }

    /// HTML is supplemental; callers must also put the exact source on the plain-text pasteboard.
    public static func html(_ text: String) -> String {
        let body = parse(text).map { line -> String in
            switch line.kind {
            case .heading:
                return "<h3 style=\"margin:20px 0 8px;white-space:pre-wrap\">\(escape(line.source))</h3>"
            case .item(let status, _):
                // Escape the whole source and retain its spacing, including indentation.
                guard let range = line.source.range(of: status.koreanLabel) else { return "<p>\(escape(line.source))</p>" }
                let before = escape(String(line.source[..<range.lowerBound]))
                let after = escape(String(line.source[range.upperBound...]))
                return "<p style=\"margin:4px 0;white-space:pre-wrap\">\(before)<strong>\(status.koreanLabel)</strong>\(after)</p>"
            case .text:
                return "<p style=\"margin:4px 0;white-space:pre-wrap\">\(escape(line.source))</p>"
            case .blank:
                return "<p style=\"margin:0\"><br></p>"
            }
        }.joined(separator: "\n")
        return "<!doctype html><html><head><meta charset=\"utf-8\"></head><body style=\"font-family:system-ui,sans-serif;font-size:14px\">\(body)</body></html>"
    }

    private static func item(_ source: String) -> (status: TaskStatus, text: String)? {
        let line = source.trimmingCharacters(in: .whitespacesAndNewlines)
        for status in TaskStatus.allCases {
            let label = status.koreanLabel
            guard line.hasPrefix(label) else { continue }
            let rest = line.dropFirst(label.count)
            guard rest.first?.isWhitespace == true,
                  !rest.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            return (status, rest.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
