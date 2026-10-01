import Foundation

// `A=B`, `A : B` 같은 여러 줄 텍스트를 표 행으로 나누는 로컬 보조 파서.
// 네트워크·AI 호출 없음. 값이 불명확하면 행 전체를 value로 남기고 ambiguous=true로 표시한다.

public struct PastedRow: Hashable, Sendable {
    public var input: SecretRowInput
    public var ambiguous: Bool
    public init(input: SecretRowInput, ambiguous: Bool) {
        self.input = input
        self.ambiguous = ambiguous
    }
}

public enum SecretPasteParser {
    public static func parse(_ text: String) -> [PastedRow] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var result: [PastedRow] = []
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let whole = SecretNormalizer.trim(String(rawLine))
            if whole.isEmpty { continue }
            result.append(parseLine(whole))
        }
        return result
    }

    private static func parseLine(_ whole: String) -> PastedRow {
        let chars = Array(whole)
        var separatorIndex: Int?
        var separator: Character = "="
        for (index, character) in chars.enumerated() where character == "=" || character == ":" {
            separatorIndex = index
            separator = character
            break
        }

        guard let index = separatorIndex else {
            // 구분자가 없으면 key 없이 전체를 value로.
            return PastedRow(input: SecretRowInput(key: "", value: whole), ambiguous: false)
        }

        let keyPart = String(chars[0..<index])
        let valuePart = String(chars[(index + 1)...])
        let key = SecretNormalizer.trim(keyPart)
        let value = SecretNormalizer.trim(valuePart)

        var ambiguous = false
        if key.isEmpty { ambiguous = true }
        if key.count > 64 { ambiguous = true }
        if separator == ":" && valuePart.hasPrefix("//") { ambiguous = true }

        if ambiguous {
            // 값 손실 없이 행 전체를 value로 남긴다. 자동 key는 apply가 부여한다.
            return PastedRow(input: SecretRowInput(key: "", value: whole), ambiguous: true)
        }
        return PastedRow(input: SecretRowInput(key: key, value: value), ambiguous: false)
    }
}
