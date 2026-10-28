import XCTest
@testable import WorkLogCore

/// MDLP-4E3B: 모델 다운로드 진행 텍스트 포맷터 검증.
/// 로캘과 무관한 결정적 출력과 경계 동작(단위 승격, 클램프, 빈 문자열)을 확인한다.
final class ModelDownloadProgressTextTests: XCTestCase {

    // MARK: - bytes(_:)

    func testBytesSpecExamples() {
        XCTAssertEqual(ModelDownloadProgressText.bytes(0), "0 B")
        XCTAssertEqual(ModelDownloadProgressText.bytes(243), "243 B")
        XCTAssertEqual(ModelDownloadProgressText.bytes(11_200_000), "11.2 MB")
        XCTAssertEqual(ModelDownloadProgressText.bytes(412_000_000), "412 MB")
        XCTAssertEqual(ModelDownloadProgressText.bytes(343_933_748), "344 MB")
        XCTAssertEqual(ModelDownloadProgressText.bytes(1_630_000_000), "1.63 GB")
        XCTAssertEqual(ModelDownloadProgressText.bytes(3_090_000_000), "3.09 GB")
        XCTAssertEqual(ModelDownloadProgressText.bytes(1_500), "1.50 KB")
        XCTAssertEqual(ModelDownloadProgressText.bytes(1_000_000_000), "1.00 GB")
    }

    func testBytesRoundingPromotesToNextUnit() {
        // 정수 자리 반올림이 1000에 도달하면 다음 단위로 승격한다.
        XCTAssertEqual(ModelDownloadProgressText.bytes(999_999_999), "1.00 GB")
        XCTAssertEqual(ModelDownloadProgressText.bytes(999_999_999_999), "1.00 TB")
        // half-up 경계: 999.5 KB 부터 승격, 그 아래는 반올림하지 않는다.
        XCTAssertEqual(ModelDownloadProgressText.bytes(999_500), "1.00 MB")
        XCTAssertEqual(ModelDownloadProgressText.bytes(999_499), "999 KB")
    }

    func testBytesKeepsTrailingZeros() {
        XCTAssertEqual(ModelDownloadProgressText.bytes(1_000), "1.00 KB")
        XCTAssertEqual(ModelDownloadProgressText.bytes(1_000_000), "1.00 MB")
        XCTAssertEqual(ModelDownloadProgressText.bytes(10_000), "10.0 KB")
    }

    func testBytesKeepsThreeSignificantDigits() {
        // 1 KB 미만은 바이트 정수로 표시하고, 소수 반올림으로 자릿수가 늘면 자릿수를 줄인다.
        XCTAssertEqual(ModelDownloadProgressText.bytes(5), "5 B")
        XCTAssertEqual(ModelDownloadProgressText.bytes(999), "999 B")
        XCTAssertEqual(ModelDownloadProgressText.bytes(9_995), "10.0 KB")
        XCTAssertEqual(ModelDownloadProgressText.bytes(99_950), "100 KB")
    }

    func testBytesNegativeTreatedAsZero() {
        XCTAssertEqual(ModelDownloadProgressText.bytes(-1), "0 B")
        XCTAssertEqual(ModelDownloadProgressText.bytes(Int64.min), "0 B")
        XCTAssertEqual(ModelDownloadProgressText.bytes(-999_999_999), "0 B")
    }

    // MARK: - percent(completed:total:)

    func testPercentSpecExamplesAndClamping() {
        XCTAssertEqual(ModelDownloadProgressText.percent(completed: 412_000_000, total: 1_630_000_000), 25)
        // completed > total -> 100
        XCTAssertEqual(ModelDownloadProgressText.percent(completed: 1_000, total: 1_000), 100)
        XCTAssertEqual(ModelDownloadProgressText.percent(completed: 1_001, total: 1_000), 100)
        // total <= 0 -> 0
        XCTAssertEqual(ModelDownloadProgressText.percent(completed: 0, total: 0), 0)
        XCTAssertEqual(ModelDownloadProgressText.percent(completed: 100, total: 0), 0)
        XCTAssertEqual(ModelDownloadProgressText.percent(completed: -5, total: -10), 0)
        // 음수 completed는 0으로 잘라낸다.
        XCTAssertEqual(ModelDownloadProgressText.percent(completed: -1, total: 1_000), 0)
        XCTAssertEqual(ModelDownloadProgressText.percent(completed: 0, total: 1_000), 0)
    }

    func testPercentFloorsInsteadOfRounding() {
        // 999/1000 -> 99 (버림)
        XCTAssertEqual(ModelDownloadProgressText.percent(completed: 999, total: 1_000), 99)
        XCTAssertEqual(ModelDownloadProgressText.percent(completed: 249, total: 1_000), 24)
        XCTAssertEqual(ModelDownloadProgressText.percent(completed: 1, total: 3), 33)
        XCTAssertEqual(ModelDownloadProgressText.percent(completed: 2, total: 3), 66)
    }

    func testPercentHandlesLargeValuesWithoutOverflow() {
        // completed * 100 이 Int64 를 넘는 경우에도 정확해야 한다.
        XCTAssertEqual(
            ModelDownloadProgressText.percent(
                completed: 9_000_000_000_000_000_000,
                total: 9_100_000_000_000_000_000
            ),
            98
        )
        XCTAssertEqual(
            ModelDownloadProgressText.percent(
                completed: Int64.max - 1,
                total: Int64.max
            ),
            99
        )
    }

    // MARK: - speed(bytesPerSecond:)

    func testSpeedSpecExample() {
        XCTAssertEqual(ModelDownloadProgressText.speed(bytesPerSecond: 38_500_000), "38.5 MB/s")
    }

    func testSpeedRoundsAndFormats() {
        XCTAssertEqual(ModelDownloadProgressText.speed(bytesPerSecond: 1_000_000), "1.00 MB/s")
        XCTAssertEqual(ModelDownloadProgressText.speed(bytesPerSecond: 999.4), "999 B/s")
        XCTAssertEqual(ModelDownloadProgressText.speed(bytesPerSecond: 999.5), "1.00 KB/s")
    }

    func testSpeedNonPositiveIsZero() {
        XCTAssertEqual(ModelDownloadProgressText.speed(bytesPerSecond: 0), "0 B/s")
        XCTAssertEqual(ModelDownloadProgressText.speed(bytesPerSecond: -100), "0 B/s")
        XCTAssertEqual(ModelDownloadProgressText.speed(bytesPerSecond: .infinity), "0 B/s")
        XCTAssertEqual(ModelDownloadProgressText.speed(bytesPerSecond: .nan), "0 B/s")
    }

    // MARK: - remaining(seconds:)

    func testRemainingSpecBoundaries() {
        XCTAssertEqual(ModelDownloadProgressText.remaining(seconds: 0), "약 1초 남음")
        XCTAssertEqual(ModelDownloadProgressText.remaining(seconds: 0.2), "약 1초 남음")
        XCTAssertEqual(ModelDownloadProgressText.remaining(seconds: 59), "약 59초 남음")
        XCTAssertEqual(ModelDownloadProgressText.remaining(seconds: 59.5), "약 1분 남음")
        XCTAssertEqual(ModelDownloadProgressText.remaining(seconds: 61), "약 2분 남음")
        XCTAssertEqual(ModelDownloadProgressText.remaining(seconds: 3_600), "약 1시간 남음")
        XCTAssertEqual(ModelDownloadProgressText.remaining(seconds: 3_661), "약 1시간 2분 남음")
    }

    func testRemainingOmitsZeroMinutes() {
        XCTAssertEqual(ModelDownloadProgressText.remaining(seconds: 7_200), "약 2시간 남음")
        XCTAssertEqual(ModelDownloadProgressText.remaining(seconds: 3_540), "약 59분 남음")
        XCTAssertEqual(ModelDownloadProgressText.remaining(seconds: 120), "약 2분 남음")
    }

    func testRemainingInvalidInputIsEmpty() {
        XCTAssertEqual(ModelDownloadProgressText.remaining(seconds: -1), "")
        XCTAssertEqual(ModelDownloadProgressText.remaining(seconds: -.infinity), "")
        XCTAssertEqual(ModelDownloadProgressText.remaining(seconds: .infinity), "")
        XCTAssertEqual(ModelDownloadProgressText.remaining(seconds: .nan), "")
    }

    // MARK: - caption(completed:total:bytesPerSecond:)

    func testCaptionWithRateMatchesSpecExample() {
        XCTAssertEqual(
            ModelDownloadProgressText.caption(
                completed: 412_000_000,
                total: 1_630_000_000,
                bytesPerSecond: 38_500_000
            ),
            "25% · 412 MB / 1.63 GB · 38.5 MB/s · 약 32초 남음"
        )
    }

    func testCaptionWithoutRateOmitsSpeedAndETA() {
        XCTAssertEqual(
            ModelDownloadProgressText.caption(
                completed: 412_000_000,
                total: 1_630_000_000,
                bytesPerSecond: nil
            ),
            "25% · 412 MB / 1.63 GB"
        )
    }

    func testCaptionCompletedEqualsTotalHasNoETA() {
        XCTAssertEqual(
            ModelDownloadProgressText.caption(
                completed: 1_630_000_000,
                total: 1_630_000_000,
                bytesPerSecond: 38_500_000
            ),
            "100% · 1.63 GB / 1.63 GB · 38.5 MB/s"
        )
        XCTAssertEqual(
            ModelDownloadProgressText.caption(
                completed: 1_630_000_000,
                total: 1_630_000_000,
                bytesPerSecond: nil
            ),
            "100% · 1.63 GB / 1.63 GB"
        )
    }

    func testCaptionSkipsSpeedForNonPositiveOrNonFiniteRate() {
        XCTAssertEqual(
            ModelDownloadProgressText.caption(
                completed: 412_000_000,
                total: 1_630_000_000,
                bytesPerSecond: 0
            ),
            "25% · 412 MB / 1.63 GB"
        )
        XCTAssertEqual(
            ModelDownloadProgressText.caption(
                completed: 412_000_000,
                total: 1_630_000_000,
                bytesPerSecond: -1
            ),
            "25% · 412 MB / 1.63 GB"
        )
        XCTAssertEqual(
            ModelDownloadProgressText.caption(
                completed: 412_000_000,
                total: 1_630_000_000,
                bytesPerSecond: .infinity
            ),
            "25% · 412 MB / 1.63 GB"
        )
    }

    func testCaptionOverTotalClampsAndHasNoETA() {
        XCTAssertEqual(
            ModelDownloadProgressText.caption(
                completed: 2_000_000_000,
                total: 1_630_000_000,
                bytesPerSecond: 38_500_000
            ),
            "100% · 2.00 GB / 1.63 GB · 38.5 MB/s"
        )
    }

    func testCaptionZeroTotal() {
        XCTAssertEqual(
            ModelDownloadProgressText.caption(completed: 0, total: 0, bytesPerSecond: nil),
            "0% · 0 B / 0 B"
        )
    }
}
