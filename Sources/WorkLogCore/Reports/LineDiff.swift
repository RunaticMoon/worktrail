import Foundation

// MARK: - 줄 단위 비교 (재생성 보호)
//
// 화면에 보던 본문과 새로 만들어진 초안의 차이를 줄 단위로 보여주기 위한 결정적 계산이다.
// - 순수 함수이며 저장소·AI·Secret을 다루지 않는다.
// - 너무 큰 본문(2000줄 초과)은 LCS 대신 전체 removed + added로 표시한다.

/// 한 줄의 비교 결과.
public struct DiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case same
        case added
        case removed
    }

    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public enum LineDiff {

    /// LCS를 쓰는 최대 줄 수. 이보다 크면 단순 표시로 대체한다.
    public static let maxLCSLineCount = 2000

    /// 줄 단위 비교. `old`에서 사라진 줄은 removed, `new`에 새로 생긴 줄은 added.
    public static func diff(old: String, new: String) -> [DiffLine] {
        let oldLines = lines(old)
        let newLines = lines(new)

        if oldLines.count > maxLCSLineCount || newLines.count > maxLCSLineCount {
            return oldLines.map { DiffLine(kind: .removed, text: $0) }
                + newLines.map { DiffLine(kind: .added, text: $0) }
        }

        let n = oldLines.count
        let m = newLines.count
        if n == 0 {
            return newLines.map { DiffLine(kind: .added, text: $0) }
        }
        if m == 0 {
            return oldLines.map { DiffLine(kind: .removed, text: $0) }
        }

        let width = m + 1
        // lcs[i * width + j] = oldLines[i...]와 newLines[j...]의 LCS 길이.
        var lcs = [Int](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if oldLines[i] == newLines[j] {
                    lcs[i * width + j] = lcs[(i + 1) * width + (j + 1)] + 1
                } else {
                    lcs[i * width + j] = max(lcs[(i + 1) * width + j], lcs[i * width + (j + 1)])
                }
            }
        }

        var result: [DiffLine] = []
        var i = 0
        var j = 0
        while i < n && j < m {
            if oldLines[i] == newLines[j] {
                result.append(DiffLine(kind: .same, text: oldLines[i]))
                i += 1; j += 1
            } else if lcs[(i + 1) * width + j] >= lcs[i * width + (j + 1)] {
                result.append(DiffLine(kind: .removed, text: oldLines[i]))
                i += 1
            } else {
                result.append(DiffLine(kind: .added, text: newLines[j]))
                j += 1
            }
        }
        while i < n {
            result.append(DiffLine(kind: .removed, text: oldLines[i])); i += 1
        }
        while j < m {
            result.append(DiffLine(kind: .added, text: newLines[j])); j += 1
        }
        return result
    }

    /// 빈 문자열은 0줄로 본다. 그 외에는 "\n"으로 나눈다(마지막 개행도 한 줄로 유지).
    private static func lines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        return text.components(separatedBy: "\n")
    }
}
