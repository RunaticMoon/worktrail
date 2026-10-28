import Foundation

/// 모델 다운로드 진행 표시의 공통 텍스트 포맷터.
/// 화면마다 다른 형식이 생기지 않도록 하고, 로캘 설정에 의존하지 않는 결정적
/// 출력을 보장한다. 소수점 구분자는 항상 `.`, 단위는 십진(1000 기반)이며,
/// ByteCountFormatter 같은 로캘 의존 포맷터 대신 정수 연산으로 만든다.
public enum ModelDownloadProgressText {

    private static let unitNames = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]

    /// 소수점 아래 자릿수 d에 대응하는 10^d.
    private static let decimalScale: [Int64] = [1, 10, 100]

    /// 바이트 수를 십진(1000 기반) 단위 B, KB, MB, GB, TB로 유효숫자 3자리로 나타낸다.
    /// 0 -> "0 B", 243 -> "243 B", 11_200_000 -> "11.2 MB", 412_000_000 -> "412 MB",
    /// 343_933_748 -> "344 MB", 1_630_000_000 -> "1.63 GB", 3_090_000_000 -> "3.09 GB",
    /// 1_500 -> "1.50 KB".
    /// 규칙: v = bytes / 1000^k 가 [1, 1000) 이 되는 단위를 고르고, v < 10 이면
    /// 소수점 둘째 자리, v < 100 이면 첫째 자리, 아니면 정수로 반올림(half-up)한다.
    /// 뒤따르는 0은 유지한다(1_000_000_000 -> "1.00 GB", 1_500 -> "1.50 KB").
    /// 정수 반올림이 1000에 도달하면(999_999_999) 다음 단위로 승격한다("1.00 GB").
    /// 음수 입력은 0으로 취급한다.
    public static func bytes(_ count: Int64) -> String {
        let value = max(0, count)
        guard value > 0 else { return "0 B" }

        // v 가 [1, 1000) 이 되는 단위를 고른다. Int64 전체 범위(약 9.22 EB)까지
        // 표현할 수 있도록 문서의 단위 외에 PB, EB까지 사다리를 유지한다.
        var index = 0
        var unit: Int64 = 1
        while index < unitNames.count - 1 && value / (unit * 1000) >= 1 {
            unit *= 1000
            index += 1
        }

        var quotient = value / unit
        var remainder = value % unit
        var decimals = unit == 1 ? 0 : fractionDigits(for: quotient)
        var scaled = quotient * decimalScale[decimals]
            + roundedFraction(remainder, decimals: decimals, unit: unit)
        // 소수 자리 반올림으로 자릿수가 늘면(9.995 -> 10.00) 유효숫자 3자리를 유지하도록 자릿수를 줄인다.
        while decimals > 0 && scaled >= 1000 {
            decimals -= 1
            scaled = quotient * decimalScale[decimals]
                + roundedFraction(remainder, decimals: decimals, unit: unit)
        }

        // 정수 자리(소수점 없음) 반올림이 1000에 도달한 경우만 다음 단위로 승격한다.
        if decimals == 0 && scaled >= 1000 {
            unit *= 1000
            index += 1
            quotient = value / unit
            remainder = value % unit
            decimals = fractionDigits(for: quotient)
            scaled = quotient * decimalScale[decimals]
                + roundedFraction(remainder, decimals: decimals, unit: unit)
        }

        return render(scaled, decimals: decimals, unitName: unitNames[index])
    }

    /// floor(completed * 100 / total) 을 0...100 으로 잘라낸 값.
    /// total <= 0 이면 0, completed >= total 일 때만 100을 돌려준다.
    public static func percent(completed: Int64, total: Int64) -> Int {
        guard total > 0, completed > 0 else { return 0 }
        guard completed < total else { return 100 }
        // completed * 100 이 Int64 범위를 넘을 수 있어 128비트로 나눈다.
        return Int(Int128(completed) * 100 / Int128(total))
    }

    /// 초당 바이트를 bytes(_:) 표기에 "/s"를 붙여 나타낸다. 38_500_000 -> "38.5 MB/s".
    /// 비유한·0 이하 입력은 0 B/s 로 둔다.
    public static func speed(bytesPerSecond: Double) -> String {
        let rate: Int64
        if !bytesPerSecond.isFinite || bytesPerSecond <= 0 {
            rate = 0
        } else if bytesPerSecond >= Double(Int64.max) {
            rate = Int64.max
        } else {
            rate = Int64(bytesPerSecond.rounded())
        }
        return bytes(rate) + "/s"
    }

    /// 남은 시간을 한국어 문구로 나타낸다. 0 -> "약 1초 남음", 59.5 -> "약 1분 남음",
    /// 3661 -> "약 1시간 2분 남음". 시간의 분이 0이면 생략한다("약 2시간 남음").
    /// 비유한·음수 입력은 빈 문자열.
    public static func remaining(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let firstSeconds = seconds.rounded(.up)
        if firstSeconds < 60 {
            return "약 \(max(1, Int(firstSeconds)))초 남음"
        }
        let minutesValue = (seconds / 60).rounded(.up)
        let totalMinutes = minutesValue >= Double(Int64.max) ? Int64.max : Int64(minutesValue)
        if totalMinutes < 60 {
            return "약 \(Int(totalMinutes))분 남음"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "약 \(hours)시간 남음" : "약 \(hours)시간 \(minutes)분 남음"
    }

    /// 진행 캡션. 예: "25% · 412 MB / 1.63 GB · 38.5 MB/s · 약 32초 남음".
    /// 속도는 rate가 유한하고 0보다 클 때만 붙고, 예상 남은 시간은 거기에
    /// completed < total 인 경우에만 붙인다.
    public static func caption(completed: Int64, total: Int64, bytesPerSecond: Double?) -> String {
        var text = "\(percent(completed: completed, total: total))% · \(bytes(completed)) / \(bytes(total))"
        guard let rate = bytesPerSecond, rate.isFinite, rate > 0 else { return text }
        text += " · \(speed(bytesPerSecond: rate))"
        if completed < total {
            let eta = remaining(seconds: Double(Int128(total) - Int128(completed)) / rate)
            if !eta.isEmpty { text += " · \(eta)" }
        }
        return text
    }

    // MARK: - 내부 helper

    private static func fractionDigits(for quotient: Int64) -> Int {
        if quotient < 10 { return 2 }
        if quotient < 100 { return 1 }
        return 0
    }

    /// remainder / (unit / 10^decimals) 를 half-up으로 반올림한다(0...10^decimals).
    /// 부동소수점 없이 (2*remainder + divisor) / (2*divisor) 정수 나눗셈으로 계산한다.
    private static func roundedFraction(_ remainder: Int64, decimals: Int, unit: Int64) -> Int64 {
        guard remainder > 0 else { return 0 }
        let divisor = unit / decimalScale[decimals]
        return (2 * remainder + divisor) / (2 * divisor)
    }

    /// scaled = 표시값 * 10^decimals. 소수점 구분자는 항상 `.`이고 자릿수는 고정
    /// (뒤따르는 0 유지)이므로 로캘과 무관하다.
    private static func render(_ scaled: Int64, decimals: Int, unitName: String) -> String {
        let scale = decimalScale[decimals]
        let whole = scaled / scale
        guard decimals > 0 else { return "\(whole) \(unitName)" }
        var fraction = String(scaled % scale)
        while fraction.count < decimals { fraction = "0" + fraction }
        return "\(whole).\(fraction) \(unitName)"
    }
}
