import XCTest
@testable import WorkLogCore

final class MeetingAudioTimelineTests: XCTestCase {
    private let gaps: [MeetingTrackInterruption] = [
        .init(start: 9, end: 10, reason: "second interruption"),
        .init(start: 4, end: 6, reason: "first interruption"),
    ]

    func testTrackOffsetAndMultipleGapsMapOriginalFileToMeetingTime() {
        // File contains contiguous original samples. Meeting time includes the
        // microphone's initial two seconds and two omitted capture intervals.
        for (file, expected) in [(0.0, 2.0), (1, 3), (2, 6), (4, 8), (5, 10), (6, 11)] {
            XCTAssertEqual(MeetingAudioTimeline.sessionTime(fileTime: file, startOffset: 2, interruptions: gaps), expected, accuracy: 0.000001)
        }
    }

    func testPlaybackInsideMissingIntervalClampsToNextAvailableFrame() {
        for (meeting, expected) in [(0.0, 0.0), (2, 0), (3, 1), (4, 2), (5, 2), (6, 2), (8, 4), (9, 5), (9.5, 5), (10, 5), (11, 6)] {
            XCTAssertEqual(MeetingAudioTimeline.fileTime(sessionTime: meeting, startOffset: 2, interruptions: gaps), expected, accuracy: 0.000001)
        }
    }

    func testFileTimeRoundTripIncludesExactGapBoundaries() {
        for file in [0.0, 1, 1.999, 2, 2.001, 4.999, 5, 5.001, 50_000] {
            let meeting = MeetingAudioTimeline.sessionTime(fileTime: file, startOffset: 2, interruptions: gaps)
            XCTAssertEqual(MeetingAudioTimeline.fileTime(sessionTime: meeting, startOffset: 2, interruptions: gaps), file, accuracy: 0.000001)
        }
    }

    func testNegativeSeekAndUnclosedOrEmptyGapsDoNotInventAudio() {
        let invalid = [MeetingTrackInterruption(start: 4, reason: "open"),
                       .init(start: 5, end: 5, reason: "empty"),
                       .init(start: 8, end: 7, reason: "backward")]
        XCTAssertEqual(MeetingAudioTimeline.sessionTime(fileTime: -1, startOffset: 2, interruptions: invalid), 2)
        XCTAssertEqual(MeetingAudioTimeline.fileTime(sessionTime: -1, startOffset: 2, interruptions: invalid), 0)
        XCTAssertEqual(MeetingAudioTimeline.sessionTime(fileTime: 10, startOffset: 2, interruptions: invalid), 12)
        XCTAssertEqual(MeetingAudioTimeline.fileTime(sessionTime: 12, startOffset: 2, interruptions: invalid), 10)
    }

    func testSingleConfidentSpeakerAndAdjacentTurnBoundary() {
        let turns = [MeetingTimedSpeaker(start: 0, end: 6, id: "speaker-a"),
                     .init(start: 6, end: 10, id: "speaker-b")]
        XCTAssertEqual(MeetingSpeakerAlignment.speaker(start: 0, end: 5, turns: turns), "speaker-a")
        XCTAssertEqual(MeetingSpeakerAlignment.speaker(start: 6, end: 10, turns: turns), "speaker-b")
        XCTAssertEqual(MeetingSpeakerAlignment.speaker(start: 0, end: 8, turns: turns), "speaker-a")
    }

    func testOverlappingSpeakersAndAmbiguousTurnRemainUnknown() {
        let overlapping = [MeetingTimedSpeaker(start: 0, end: 8, id: "speaker-a"),
                           .init(start: 7, end: 10, id: "speaker-b")]
        XCTAssertNil(MeetingSpeakerAlignment.speaker(start: 0, end: 10, turns: overlapping))
        let tied = [MeetingTimedSpeaker(start: 0, end: 5, id: "speaker-a"),
                    .init(start: 5, end: 10, id: "speaker-b")]
        XCTAssertNil(MeetingSpeakerAlignment.speaker(start: 0, end: 10, turns: tied))
        XCTAssertNil(MeetingSpeakerAlignment.speaker(start: 2, end: 2, turns: overlapping))
    }

    func testInsufficientCoverageAndAbsentSpeakerRemainUnknown() {
        XCTAssertNil(MeetingSpeakerAlignment.speaker(start: 0, end: 10, turns: []))
        XCTAssertNil(MeetingSpeakerAlignment.speaker(start: 0, end: 10, turns: [.init(start: 2, end: 7, id: "speaker-a")]))
        XCTAssertNil(MeetingSpeakerAlignment.speaker(start: 0, end: 1, turns: [.init(start: 1, end: 2, id: "speaker-a")]))
    }

    func testDuplicateSpeakerIntervalsCannotInflateCoverage() {
        let duplicate = [MeetingTimedSpeaker(start: 0, end: 2, id: "speaker-a"),
                         .init(start: 0, end: 2, id: "speaker-a")]
        // 40% actual coverage stays unknown even if an SDK repeats the same turn.
        XCTAssertNil(MeetingSpeakerAlignment.speaker(start: 0, end: 5, turns: duplicate))
    }
}
