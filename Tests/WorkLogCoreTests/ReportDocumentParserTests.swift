import XCTest
@testable import WorkLogCore

final class ReportDocumentParserTests: XCTestCase {
    func testMarkdownReportContainsReadableHeadingsListsQuoteAndRule() {
        let source = """
        # 주간 성과
        ## 고객 경험
        ### 확인 결과
        **굵게**와 *기울임*, `코드`, [근거](https://example.com)

        - 첫 항목
        * 두 번째
        3. 셋째
          - 하위 항목
        > 인용 첫 줄
        > 인용 둘째 줄

        ---
        """
        XCTAssertEqual(MarkdownDocumentParser.parse(source), [
            .heading(level: 1, text: "주간 성과"),
            .heading(level: 2, text: "고객 경험"),
            .heading(level: 3, text: "확인 결과"),
            .paragraph("**굵게**와 *기울임*, `코드`, [근거](https://example.com)"),
            .listItem(marker: "•", text: "첫 항목", depth: 0),
            .listItem(marker: "•", text: "두 번째", depth: 0),
            .listItem(marker: "3.", text: "셋째", depth: 0),
            .listItem(marker: "•", text: "하위 항목", depth: 1),
            .quote("인용 첫 줄\n인용 둘째 줄"), .rule
        ])
    }

    func testFencedCodePreservesWhitespaceAndDoesNotParseContentAsMarkdown() {
        let source = "````swift\n  # literal\n```\n- literal\n````\n뒤 문장"
        XCTAssertEqual(MarkdownDocumentParser.parse(source), [
            .code(language: "swift", text: "  # literal\n```\n- literal"),
            .paragraph("뒤 문장")
        ])
    }

    func testTildeAndUnclosedFencesKeepAllCode() {
        XCTAssertEqual(MarkdownDocumentParser.parse("~~~text\nfirst\n~~~\n```\nlast\n"), [
            .code(language: "text", text: "first"), .code(language: "", text: "last\n")
        ])
    }

    func testUnknownSyntaxAndInvalidMarkersRemainText() {
        let source = "#태그\n-업무\n1.2 버전\n문장\n| 미지원 표 |\n<html>"
        XCTAssertEqual(MarkdownDocumentParser.parse(source), [.paragraph(source)])
    }

    func testCRLFAndSpacedHorizontalRules() {
        XCTAssertEqual(MarkdownDocumentParser.parse("첫 줄\r\n둘째 줄\r\n\r\n* * *\r\n___"), [
            .paragraph("첫 줄\n둘째 줄"), .rule, .rule
        ])
        XCTAssertEqual(MarkdownDocumentParser.parse(""), [])
        XCTAssertEqual(MarkdownDocumentParser.parse(" \n\t"), [])
    }

    func testLargeDocumentKeepsEveryItemAndOrder() {
        let source = (1...2000).map { "- 업무 \($0)" }.joined(separator: "\n")
        let blocks = MarkdownDocumentParser.parse(source)
        XCTAssertEqual(blocks.count, 2000)
        XCTAssertEqual(blocks.first, .listItem(marker: "•", text: "업무 1", depth: 0))
        XCTAssertEqual(blocks.last, .listItem(marker: "•", text: "업무 2000", depth: 0))
    }

    func testWeeklyExampleAndCommonWorkUseHeadingsAndStatuses() {
        let source = "대중교통 길찾기\n완료 Java 자동 포맷팅\n진행 배포 정리\n예정 운영 문서\n\n공통 인프라\n보류 검토 대기\n취소 이전 계획"
        let lines = SubmissionDocumentParser.parse(source)
        XCTAssertEqual(lines.map(\.kind), [
            .heading, .item(status: .completed, text: "Java 자동 포맷팅"),
            .item(status: .inProgress, text: "배포 정리"), .item(status: .planned, text: "운영 문서"),
            .blank, .heading, .item(status: .onHold, text: "검토 대기"),
            .item(status: .cancelled, text: "이전 계획")
        ])
        XCTAssertEqual(lines.map(\.source).joined(separator: "\n"), source)
    }

    func testUnknownWeeklyLinesAndCustomStatusesAreNeverDroppedOrRelabeled() {
        let source = "머리말\n임의 설명\n[지연] 외부 검토\n완료\n완료된 업무에 대한 설명\n진행률 30%\n보류: 사용자 표기\n"
        let lines = SubmissionDocumentParser.parse(source)
        XCTAssertTrue(lines.dropLast().allSatisfy { $0.kind == .text })
        XCTAssertEqual(lines.last?.kind, .blank)
        XCTAssertEqual(lines.map(\.source).joined(separator: "\n"), source)
    }

    func testWeeklySourceRetainsIndentationCRLFAndEmptyLines() {
        let source = "프로젝트\r\n  완료\t본문 <수정>\r\n\r\n\r\n"
        let lines = SubmissionDocumentParser.parse(source)
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines.first?.kind, .heading)
        XCTAssertEqual(lines.dropFirst().first?.kind, .item(status: .completed, text: "본문 <수정>"))
        XCTAssertEqual(lines.map(\.source).joined(separator: "\n"), source)
    }

    func testRichCopyEscapesMarkupAndKeepsUserText() {
        let source = "<프로젝트 & 이름>\n완료 <script>alert('x')</script> & \"검토\"\n낯선 줄 <img src=x>"
        let html = SubmissionDocumentParser.html(source)
        XCTAssertTrue(html.contains("<h3"))
        XCTAssertTrue(html.contains("&lt;프로젝트 &amp; 이름&gt;"))
        XCTAssertTrue(html.contains("<strong>완료</strong> &lt;script&gt;"))
        XCTAssertTrue(html.contains("&lt;/script&gt; &amp; &quot;검토&quot;"))
        XCTAssertTrue(html.contains("낯선 줄 &lt;img src=x&gt;"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("<img"))
    }
}
