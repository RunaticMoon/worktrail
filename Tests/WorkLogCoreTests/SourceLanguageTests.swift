import XCTest
@testable import WorkLogCore

final class SourceLanguageTests: XCTestCase {
    func testDetectsKoreanEnglishAndFallback() {
        XCTAssertEqual(SourceLanguage.detect("배포 파이프라인 점검"), .korean)
        XCTAssertEqual(SourceLanguage.detect("Reviewed the deploy pipeline"), .english)
        XCTAssertEqual(SourceLanguage.detect(""), .korean)
        XCTAssertEqual(SourceLanguage.detect("123 --- 456"), .korean)
    }

    func testMixedTextFollowsDominantScript() {
        XCTAssertEqual(SourceLanguage.detect("PR #12 merge 후 배포 결과를 확인하고 롤백 계획을 정리함"), .korean)
        XCTAssertEqual(SourceLanguage.detect("Fixed the 배포 script and verified staging"), .english)
        XCTAssertEqual(SourceLanguage.detect(["메모", "A longer English note about the release"]), .english)
        // 한국어 업무 메모에 영문 용어가 많이 섞여도 한국어로 본다.
        XCTAssertEqual(SourceLanguage.detect("API timeout 이슈 fix, retry logic 추가"), .korean)
        XCTAssertEqual(SourceLanguage.detect("https://example.com/a-b/c 확인"), .korean)
    }

    func testAppendingDirectivePutsLanguageLast() {
        let english = SourceLanguage.appendingDirective(to: "지시", sources: ["Shipped the release notes"])
        XCTAssertTrue(english.hasPrefix("지시\n\n"))
        XCTAssertTrue(english.hasSuffix(SourceLanguage.english.outputDirective))
        XCTAssertTrue(SourceLanguage.english.outputDirective.contains("overrides"))
    }

    func testDirectiveNamesLanguageAndKeepsKeys() {
        XCTAssertTrue(SourceLanguage.korean.outputDirective.contains("한국어"))
        XCTAssertTrue(SourceLanguage.english.outputDirective.contains("in English"))
        XCTAssertTrue(SourceLanguage.english.outputDirective.contains("JSON keys"))
    }

    func testCommonInstructionsAndMeetingContractFollowSourceLanguage() {
        XCTAssertTrue(DefaultPrompts.commonInstructions.contains("주된 언어를 따른다"))
        XCTAssertFalse(DefaultPrompts.groundedAnswer.contains("답변은 한국어로 작성하고"))
        XCTAssertTrue(MeetingSummaryContract.instructions.contains("주된 언어를 따른다"))
        XCTAssertFalse(MeetingSummaryContract.instructions.contains("한국어 회의 요약"))
        XCTAssertFalse(DefaultPrompts.all.map(\.name).contains { $0.contains("Memo-Task") })
    }
}
