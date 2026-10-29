import XCTest
@testable import WorkLogCore

/// 저장소 연결 종료 대기 장부·백오프 정책 검증.
/// 창/AppKit 없이 weak 생존 확인과 폴링 일정 계산만 검증한다.
final class CloseLifetimeWatchTests: XCTestCase {

    private final class Holder {}

    // MARK: - 생존 장부

    func testEmptyWatchIsQuiescent() {
        let watch = CloseLifetimeWatch()
        XCTAssertTrue(watch.isQuiescent)
        XCTAssertEqual(watch.aliveCount, 0)
        XCTAssertEqual(watch.aliveMask, 0)
        XCTAssertEqual(watch.aliveNames, [])
        XCTAssertEqual(watch.slotNames, [])
    }

    func testTracksAliveSlotsInRegistrationOrder() {
        let first: Holder? = Holder()
        let second: Holder? = Holder()
        weak var weakFirst = first
        weak var weakSecond = second
        var watch = CloseLifetimeWatch()
        watch.track("environment") { weakFirst != nil }
        watch.track("day") { weakSecond != nil }

        XCTAssertEqual(watch.slotNames, ["environment", "day"])
        XCTAssertEqual(watch.aliveNames, ["environment", "day"])
        XCTAssertEqual(watch.aliveCount, 2)
        XCTAssertEqual(watch.aliveMask, 0b11)
        XCTAssertFalse(watch.isQuiescent)
    }

    func testReportsOnlySurvivingSlots() {
        var environment: Holder? = Holder()
        var day: Holder? = Holder()
        weak var weakEnvironment = environment
        weak var weakDay = day
        var watch = CloseLifetimeWatch()
        watch.track("environment") { weakEnvironment != nil }
        watch.track("day") { weakDay != nil }

        day = nil
        XCTAssertEqual(watch.aliveNames, ["environment"])
        XCTAssertEqual(watch.aliveCount, 1)
        XCTAssertEqual(watch.aliveMask, 0b01)
        XCTAssertFalse(watch.isQuiescent)

        environment = nil
        XCTAssertEqual(watch.aliveNames, [])
        XCTAssertTrue(watch.isQuiescent)
        XCTAssertEqual(watch.aliveMask, 0)
    }

    func testMaskUsesSlotIndexAsBitPosition() {
        let kept: Holder? = Holder()
        var released: Holder? = Holder()
        weak var weakKept = kept
        weak var weakReleased = released
        var watch = CloseLifetimeWatch()
        watch.track("zero") { weakReleased != nil }
        watch.track("one") { weakKept != nil }

        released = nil
        XCTAssertEqual(watch.aliveNames, ["one"])
        XCTAssertEqual(watch.aliveMask, 0b10)
    }

    func testTrackingDoesNotExtendLifetime() {
        var holder: Holder? = Holder()
        weak var weakHolder = holder
        var watch = CloseLifetimeWatch()
        watch.track("holder") { weakHolder != nil }

        holder = nil
        XCTAssertNil(weakHolder)
        XCTAssertTrue(watch.isQuiescent)
    }

    // MARK: - 대기 정책

    func testRestorePolicyIsBoundedToSixSeconds() {
        let policy = CloseWaitPolicy.restoreClose
        XCTAssertEqual(policy.fastPolls, 40)
        XCTAssertEqual(policy.fastIntervalMilliseconds, 50)
        XCTAssertEqual(policy.slowIntervalMilliseconds, 250)
        XCTAssertEqual(policy.maximumPolls, 56)
        XCTAssertEqual(policy.totalMilliseconds, 6_000)
    }

    func testIntervalUsesFastThenSlowCadence() {
        let policy = CloseWaitPolicy.restoreClose
        XCTAssertEqual(policy.intervalMilliseconds(forPoll: 0), 50)
        XCTAssertEqual(policy.intervalMilliseconds(forPoll: 39), 50)
        XCTAssertEqual(policy.intervalMilliseconds(forPoll: 40), 250)
        XCTAssertEqual(policy.intervalMilliseconds(forPoll: 55), 250)
    }

    func testElapsedMillisecondsMatchesCadence() {
        let policy = CloseWaitPolicy.restoreClose
        XCTAssertEqual(policy.elapsedMilliseconds(afterPolls: 0), 0)
        XCTAssertEqual(policy.elapsedMilliseconds(afterPolls: 1), 50)
        XCTAssertEqual(policy.elapsedMilliseconds(afterPolls: 40), 2_000)
        XCTAssertEqual(policy.elapsedMilliseconds(afterPolls: 41), 2_250)
        XCTAssertEqual(policy.elapsedMilliseconds(afterPolls: 56), 6_000)
    }

    func testElapsedMillisecondsClampsOutOfRangePolls() {
        let policy = CloseWaitPolicy.restoreClose
        XCTAssertEqual(policy.elapsedMilliseconds(afterPolls: -3), 0)
        XCTAssertEqual(policy.elapsedMilliseconds(afterPolls: 1_000), policy.totalMilliseconds)
    }

    func testPolicySanitizesInvalidValues() {
        let policy = CloseWaitPolicy(fastPolls: -2, fastIntervalMilliseconds: 0,
                                     slowIntervalMilliseconds: 5, maximumPolls: -1)
        XCTAssertEqual(policy.fastPolls, 0)
        XCTAssertEqual(policy.fastIntervalMilliseconds, 1)
        XCTAssertEqual(policy.slowIntervalMilliseconds, 5)
        XCTAssertEqual(policy.maximumPolls, 0)
        XCTAssertEqual(policy.totalMilliseconds, 0)
        XCTAssertTrue(policy.intervalMilliseconds(forPoll: 100) >= 1)
    }
}
