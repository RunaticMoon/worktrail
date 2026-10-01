import Foundation

/// 원문 본문에서 URL을 뽑아 보관한다. 내용을 가져오지 않는다(fetch 없음).
public enum LinkExtractor {

    /// 본문에서 http/https URL을 등장 순서대로 추출하고 중복을 제거한다.
    /// 문장 끝의 마침표·괄호 같은 구두점은 URL에서 제외한다.
    public static func urls(in text: String) -> [String] {
        guard !text.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"'`]+"#,
                                                   options: [.caseInsensitive]) else {
            return []
        }

        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var seen = Set<String>()
        var result: [String] = []

        for match in regex.matches(in: text, options: [], range: full) {
            var url = ns.substring(with: match.range)
            while let last = url.last, trailingPunctuation.contains(last) {
                url.removeLast()
            }
            guard !url.isEmpty else { continue }
            if seen.insert(url).inserted { result.append(url) }
        }
        return result
    }

    private static let trailingPunctuation: Set<Character> =
        [".", ",", ";", ":", "!", "?", ")", "]", "}", "\"", "'", ">"]
}
