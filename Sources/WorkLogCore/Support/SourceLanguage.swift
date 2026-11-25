import Foundation

/// 메모·진행 기록 같은 원문의 주된 언어. AI가 만드는 요약·보고 문장이 원문과 같은 언어를 따르게 한다.
/// 단어(공백·구두점으로 나눈 토큰)만 센다. 네트워크·외부 모델 없이 결정적으로 동작한다.
public enum SourceLanguage: String, Sendable, Hashable {
    case korean
    case english

    /// 판별할 단어가 없을 때의 기본값(앱 기본 로케일).
    public static let fallback: SourceLanguage = .korean

    /// 한글이 들어간 단어 1개를 영문 단어 몇 개와 같게 볼지.
    /// 한국어 업무 메모는 "API timeout 이슈 fix, retry 추가"처럼 영문 용어가 많이 섞이지만,
    /// 영어 메모에 한글 단어가 섞이는 일은 드물다. 그래서 한글 단어 하나에 더 큰 무게를 준다.
    static let koreanWordWeight = 3

    /// 여러 원문을 합쳐 한글이 들어간 단어와 영문만으로 된 단어 수를 비교한다.
    /// 숫자·기호·URL 조각처럼 글자가 없는 토큰은 세지 않는다.
    public static func detect(_ texts: [String]) -> SourceLanguage {
        var korean = 0, english = 0
        for text in texts {
            // URL은 영어 문장이 아니므로 통째로 뺀다.
            let words = text.split(whereSeparator: \.isWhitespace)
                .filter { !$0.contains("://") && !$0.lowercased().hasPrefix("www.") }
            for token in words.flatMap({ $0.split(whereSeparator: { $0.isPunctuation || $0.isSymbol }) }) {
                var hasHangul = false, hasLatin = false
                for scalar in token.unicodeScalars {
                    switch scalar.value {
                    case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F: hasHangul = true
                    case 0x41...0x5A, 0x61...0x7A: hasLatin = true
                    default: break
                    }
                }
                if hasHangul { korean += 1 } else if hasLatin { english += 1 }
            }
        }
        if korean == 0 && english == 0 { return fallback }
        return korean * koreanWordWeight >= english ? .korean : .english
    }

    public static func detect(_ text: String) -> SourceLanguage { detect([text]) }

    /// 지시문 맨 끝에 붙이는 출력 언어 지시. 저장된 예전 템플릿에 남은 언어 지시보다 우선한다.
    /// JSON 키·ID·열거값은 번역하지 않는다.
    public var outputDirective: String {
        switch self {
        case .korean:
            return "출력 언어: 입력 원문이 한국어이므로 JSON 안의 모든 문장을 한국어로 작성한다. 앞선 지시나 예시의 언어와 다르면 이 지시를 따른다. JSON 키, ID, 열거값은 번역하지 않는다."
        case .english:
            return "Output language: the source text is in English, so write every sentence inside the JSON in English. This overrides any earlier instruction or example about the output language. Do not translate JSON keys, IDs, or enum values."
        }
    }

    /// 앱이 지시문 맨 끝에 붙이는 출력 계약의 시작 문구(TemplateStore.composeInstructions).
    /// 계약과 JSON Schema가 지시문의 마지막에 오도록 언어 지시는 그 앞에 넣는다.
    static let appContractHeading = "\n\n앱 필수 주간보고 계약:"

    /// 원문 언어에 맞춘 출력 언어 지시를 사용자 템플릿 뒤(앱 출력 계약이 있으면 그 앞)에 넣는다.
    public static func appendingDirective(to instructions: String, sources: [String]) -> String {
        let directive = "\n\n" + detect(sources).outputDirective
        guard let contract = instructions.range(of: appContractHeading, options: .backwards) else {
            return instructions + directive
        }
        var result = instructions
        result.insert(contentsOf: directive, at: contract.lowerBound)
        return result
    }
}
