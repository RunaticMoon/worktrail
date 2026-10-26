import XCTest
@testable import WorkLogCore

final class MeetingPreviewMergerTests: XCTestCase {
    private func request(start: Double = 0, track: String = "mic", final: Bool = false) -> MeetingPreviewRequest {
        .init(sessionID: "session", recordingID: "recording", generation: 1, trackID: track,
            windowStart: start, samples: [Float](repeating: 0, count: 160_000), isFinal: final)
    }

    func testExtendedMergedSegmentPreservesNewTailAndLaterStabilizesIt() {
        var merger = MeetingPreviewMerger(ids: SequentialIDGenerator())
        merger.merge([.init(start: 0, end: 6, text: "첫 문장")], request: request())
        let firstID = merger.segments[0].id
        merger.merge([.init(start: 0, end: 9, text: "첫 문장 새 발언")], request: request())
        XCTAssertEqual(merger.segments.map(\.text), ["첫 문장", "새 발언"])
        XCTAssertEqual(merger.segments[0].id, firstID)
        XCTAssertEqual(merger.segments[1].start, 6)
        XCTAssertEqual(merger.segments[1].end, 9)
        XCTAssertEqual(merger.segments[1].stability, .partial)
        let tailID = merger.segments[1].id
        merger.merge([.init(start: 4, end: 7, text: "새 발언")], request: request(start: 2))
        XCTAssertEqual(merger.segments.count, 2)
        XCTAssertEqual(merger.segments[1].id, tailID)
        XCTAssertEqual(merger.segments[1].stability, .stablePreview)
    }

    func testDecoderMergingSeveralStableSegmentsKeepsOnlyNewTail() {
        var merger = MeetingPreviewMerger(ids: SequentialIDGenerator())
        merger.merge([.init(start: 0, end: 3, text: "첫 문장"), .init(start: 3, end: 6, text: "둘째 문장")], request: request())
        merger.merge([.init(start: 0, end: 9, text: "첫 문장 둘째 문장 새 발언")], request: request())
        XCTAssertEqual(merger.segments.map(\.text), ["첫 문장", "둘째 문장", "새 발언"])
        XCTAssertEqual(merger.segments.last?.start, 6)
    }

    func testDecoderSplittingSameStableContextDoesNotDuplicateIt() {
        var merger = MeetingPreviewMerger(ids: SequentialIDGenerator())
        merger.merge([.init(start: 0, end: 6, text: "첫 문장 둘째 문장")], request: request())
        let original = merger.segments[0]
        let changes = merger.merge([.init(start: 0, end: 3, text: "첫 문장"), .init(start: 3, end: 6, text: "둘째 문장")], request: request())
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(merger.segments, [original])
    }

    func testChangedStableContextIsPreservedAsAmbiguousPartialInsteadOfSilentlyDropped() {
        var merger = MeetingPreviewMerger(ids: SequentialIDGenerator())
        merger.merge([.init(start: 0, end: 6, text: "배포는 월요일")], request: request())
        merger.merge([.init(start: 0, end: 9, text: "배포는 화요일 새 발언")], request: request(final: true))
        XCTAssertEqual(merger.segments.count, 2)
        XCTAssertEqual(merger.segments.first?.text, "배포는 월요일")
        XCTAssertEqual(merger.segments.last?.text, "배포는 화요일 새 발언")
        XCTAssertEqual(merger.segments.last?.stability, .partial)
        XCTAssertTrue(merger.finish().isEmpty)
        XCTAssertEqual(merger.segments.last?.stability, .partial)
    }

    func testSameTextAtDifferentTimesAndRepeatedTailAreNeverTextDeduplicated() {
        var merger = MeetingPreviewMerger(ids: SequentialIDGenerator())
        merger.merge([.init(start: 0, end: 1, text: "네")], request: request())
        merger.merge([.init(start: 0, end: 2, text: "네 네"), .init(start: 4, end: 5, text: "네")], request: request())
        XCTAssertEqual(merger.segments.map(\.text), ["네", "네", "네"])
        XCTAssertEqual(merger.segments.map(\.start), [0, 1, 4])
        merger.merge([.init(start: 0, end: 1, text: "네")], request: request(track: "system"))
        XCTAssertEqual(merger.segments.count, 4)
    }

    func testSmallTimestampOverlapDoesNotCollapseTwoShortRepeatedUtterances() {
        var merger = MeetingPreviewMerger(ids: SequentialIDGenerator())
        merger.merge([.init(start: 1, end: 1.4, text: "네")], request: request())
        merger.merge([.init(start: 1.3, end: 1.7, text: "네")], request: request())
        XCTAssertEqual(merger.segments.count, 2)
        XCTAssertNotEqual(merger.segments[0].id, merger.segments[1].id)
    }

    func testWorkingSetEvictsPersistedStableTextBeforePendingHypothesis() {
        var merger = MeetingPreviewMerger(ids: SequentialIDGenerator())
        merger.merge([.init(start: 8, end: 9, text: "아직 임시")], request: request())
        let pendingID = merger.segments[0].id
        for index in 1...250 {
            merger.merge([.init(start: 0, end: 1, text: "확정 \(index)")], request: request(start: Double(index * 10)))
        }
        XCTAssertEqual(merger.segments.count, 240)
        XCTAssertEqual(merger.segments.first?.id, pendingID)
        XCTAssertEqual(merger.segments.first?.stability, .partial)
        XCTAssertTrue(merger.drainDiscardedGaps().isEmpty)
    }

    func testPathologicalPartialOverflowIsBoundedAndProducesExplicitPreviewGap() {
        var merger = MeetingPreviewMerger(ids: SequentialIDGenerator())
        let spans = (0..<241).map { index in
            MeetingRecognizedSpan(start: 8 + Double(index) * 0.002, end: 8.001 + Double(index) * 0.002, text: "임시 \(index)")
        }
        let changes = merger.merge(spans, request: request())
        XCTAssertEqual(changes.count, 241)
        XCTAssertEqual(merger.segments.count, 240)
        let gaps = merger.drainDiscardedGaps()
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.reason, "preview-working-set-limit")
        XCTAssertTrue(merger.drainDiscardedGaps().isEmpty)
    }
}
