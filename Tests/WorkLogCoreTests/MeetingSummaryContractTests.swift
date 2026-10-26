import XCTest
@testable import WorkLogCore

final class MeetingSummaryContractTests: XCTestCase {
    private let source = MeetingSummarySource(id: "transcript:meeting:1", kind: .transcript,
        text: "제품 출시 일정을 금요일에 다시 논의하기로 했다.", sourceRevision: 1)

    func testRequiresKnownSourceAndExactNonemptyQuotation() throws {
        let good = MeetingSummaryItem(text: "금요일에 출시 일정을 재논의합니다.",
            citations: [MeetingCitation(sourceID: source.id, quote: "금요일에 다시 논의")])
        XCTAssertNoThrow(try MeetingSummaryContract.validate(MeetingSummaryOutput(summary: [good]), sources: [source]))
        let invalid = [
            MeetingSummaryItem(text: "근거 없음", citations: []),
            MeetingSummaryItem(text: "잘못된 출처", citations: [.init(sourceID: "memo:unknown", quote: "금요일")]),
            MeetingSummaryItem(text: "허구 인용", citations: [.init(sourceID: source.id, quote: "목요일 출시 확정")]),
            MeetingSummaryItem(text: "빈 인용", citations: [.init(sourceID: source.id, quote: " ")]),
            MeetingSummaryItem(text: " ", citations: good.citations)
        ]
        for item in invalid {
            XCTAssertThrowsError(try MeetingSummaryContract.validate(MeetingSummaryOutput(summary: [item]), sources: [source]))
        }
        XCTAssertThrowsError(try MeetingSummaryContract.validate(MeetingSummaryOutput(summary: []), sources: [source]))
        XCTAssertThrowsError(try MeetingSummaryContract.validate(MeetingSummaryOutput(summary: [good]), sources: [source, source]))
    }

    func testRejectsOversizedItemAndExcessiveItemCount() throws {
        let citation = MeetingCitation(sourceID: source.id, quote: "금요일")
        let long = MeetingSummaryItem(text: String(repeating: "가", count: 2_001), citations: [citation])
        XCTAssertThrowsError(try MeetingSummaryContract.validate(MeetingSummaryOutput(summary: [long]), sources: [source]))
        let item = MeetingSummaryItem(text: "논의", citations: [citation])
        XCTAssertThrowsError(try MeetingSummaryContract.validate(
            MeetingSummaryOutput(summary: Array(repeating: item, count: 81)), sources: [source]))
    }
}
