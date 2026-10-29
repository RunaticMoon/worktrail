import Foundation

/// 저장소 연결을 닫는 동안 추적 중인 객체가 실제로 해제됐는지 확인하는 순수 장부.
///
/// 타이머·시계·플랫폼 타입을 쓰지 않는다. 호출자가 폴링 횟수와 간격을 정하고,
/// 이 타입은 "무엇이 아직 살아 있는가"만 기록한다. 덕분에 Linux를 포함한 모든
/// 플랫폼에서 그대로 테스트할 수 있고, 대기 정책도 결정적으로 검증할 수 있다.
///
/// 등록 순서가 곧 비트마스크의 자리 순서다. 진단 로그에는 자유 문자열(모델 이름,
/// 경로 등)을 남길 수 없으므로, 실패 시에는 `aliveMask`와 `slotNames` 순서를
/// 함께 남겨 어느 연결이 남았는지 식별한다.
public struct CloseLifetimeWatch {
    public struct Slot {
        public let name: String
        let isAlive: () -> Bool
    }

    private var slots: [Slot] = []

    public init() {}

    /// 이름과 생존 확인 클로저를 등록한다. `isAlive`는 값을 보관하지 않고
    /// weak 참조를 읽기만 해야 한다(그렇지 않으면 스스로 수명을 늘린다).
    public mutating func track(_ name: String, isAlive: @escaping () -> Bool) {
        slots.append(Slot(name: name, isAlive: isAlive))
    }

    /// 등록 순서대로의 이름 목록. 비트마스크 해석에 쓴다.
    public var slotNames: [String] { slots.map(\.name) }

    /// 아직 살아 있는 슬롯의 이름 목록(등록 순서).
    public var aliveNames: [String] { slots.filter { $0.isAlive() }.map(\.name) }

    public var aliveCount: Int { slots.reduce(0) { $0 + ($1.isAlive() ? 1 : 0) } }

    public var isQuiescent: Bool { !slots.contains { $0.isAlive() } }

    /// 살아 있는 슬롯의 비트마스크. 0번 슬롯이 최하위 비트다.
    public var aliveMask: Int {
        var mask = 0
        for (index, slot) in slots.enumerated() where slot.isAlive() { mask |= 1 << index }
        return mask
    }
}

/// 저장소 연결 종료를 기다리는 폴링 일정.
///
/// 처음에는 촘촘하게(빠르게 끝나는 정상 경로), 이후에는 느슨하게(늦게 풀리는
/// 뷰·작업 정리) 확인해 사용자가 불필요하게 오래 기다리지 않게 한다. 상한이
/// 있으므로 참조가 영구히 남아도 복원이 무한 대기하지 않는다.
public struct CloseWaitPolicy: Equatable {
    /// 촘촘한 간격을 쓰는 폴링 횟수.
    public let fastPolls: Int
    public let fastIntervalMilliseconds: Int
    public let slowIntervalMilliseconds: Int
    public let maximumPolls: Int

    public init(fastPolls: Int, fastIntervalMilliseconds: Int,
                slowIntervalMilliseconds: Int, maximumPolls: Int) {
        self.fastPolls = max(fastPolls, 0)
        self.fastIntervalMilliseconds = max(fastIntervalMilliseconds, 1)
        self.slowIntervalMilliseconds = max(slowIntervalMilliseconds, self.fastIntervalMilliseconds)
        self.maximumPolls = max(maximumPolls, 0)
    }

    /// 백업 복원처럼 저장소를 교체하기 전 연결 종료에 쓰는 기본값.
    /// 40회 × 50ms + 16회 × 250ms = 최대 6초.
    public static let restoreClose = CloseWaitPolicy(
        fastPolls: 40, fastIntervalMilliseconds: 50,
        slowIntervalMilliseconds: 250, maximumPolls: 56)

    /// `poll`은 0부터 시작하는 폴링 순번이다.
    public func intervalMilliseconds(forPoll poll: Int) -> Int {
        poll < fastPolls ? fastIntervalMilliseconds : slowIntervalMilliseconds
    }

    /// `polls`번 폴링한 뒤 누적 대기 시간(ms).
    public func elapsedMilliseconds(afterPolls polls: Int) -> Int {
        let clamped = min(max(polls, 0), maximumPolls)
        let fast = min(clamped, fastPolls)
        return fast * fastIntervalMilliseconds + (clamped - fast) * slowIntervalMilliseconds
    }

    /// 모든 폴링을 소진했을 때의 총 대기 시간(ms).
    public var totalMilliseconds: Int { elapsedMilliseconds(afterPolls: maximumPolls) }
}
