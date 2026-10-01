import Foundation

#if os(macOS)
import AppKit
#endif

// 클립보드 보호. 앱이 넣은 항목만 change marker로 추적해 조건부로 지운다.
// 값 문자열을 저장하지 않는다(marker와 시각만). 값 비교를 위해 전역 이력을 남기지 않는다.

/// 클립보드 추상화. 테스트에서는 InMemoryPasteboard를 주입한다.
public protocol Pasteboard: AnyObject {
    var changeCount: Int { get }
    /// 문자열을 쓰고 새 changeCount를 반환한다.
    @discardableResult
    func writeString(_ value: String, concealed: Bool) -> Int
    func clearContents()
}

/// 테스트용 클립보드. 쓰기·지우기마다 changeCount가 1 증가한다.
public final class InMemoryPasteboard: Pasteboard, @unchecked Sendable {
    private let mutex = NSLock()
    private var current: String?
    private var count = 0

    public init() {}

    public var string: String? {
        mutex.lock(); defer { mutex.unlock() }
        return current
    }

    public var changeCount: Int {
        mutex.lock(); defer { mutex.unlock() }
        return count
    }

    @discardableResult
    public func writeString(_ value: String, concealed: Bool) -> Int {
        mutex.lock()
        count += 1
        current = value
        let newCount = count
        mutex.unlock()
        return newCount
    }

    public func clearContents() {
        mutex.lock()
        count += 1
        current = nil
        mutex.unlock()
    }

    /// 다른 앱이 클립보드에 복사한 상황을 시뮬레이션한다. 내용 비교용이 아니라 marker 변화만 만든다.
    public func simulateExternalCopy(_ value: String) {
        mutex.lock()
        count += 1
        current = value
        mutex.unlock()
    }
}

#if os(macOS)
/// NSPasteboard.general 어댑터.
/// concealed면 "org.nspasteboard.ConcealedType" 타입도 함께 기록해 클립보드 관리자 이력에서 제외하는 관례를 따른다.
///
/// 주의: Linux 검증 환경에서는 컴파일 대상이 아니라 실행 검증이 불가능하다(미검증).
public final class SystemPasteboard: Pasteboard, @unchecked Sendable {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    @discardableResult
    public func writeString(_ value: String, concealed: Bool) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        if concealed {
            let type = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
            pasteboard.setData(Data(), forType: type)
        }
        return pasteboard.changeCount
    }

    public func clearContents() {
        pasteboard.clearContents()
    }
}
#endif

/// 조건부 클립보드 삭제기.
///
/// - copySecret 시 앱이 쓴 항목의 change marker와 시각만 기록한다(값은 저장하지 않음).
/// - 기한 이후 tick/clearNowIfUnchanged에서 marker가 그대로일 때만 지운다.
///   다른 앱이 다른/같은 문자열을 복사해 marker가 바뀌었으면 지우지 않는다.
public final class ClipboardGuard: @unchecked Sendable {
    private let pasteboard: Pasteboard
    private let clock: Clock
    private let mutex = NSLock()
    private var timeout: TimeInterval
    private var marker: Int?
    private var copiedAt: Date?

    public init(pasteboard: Pasteboard, clock: Clock, clearAfter: TimeInterval = 120) {
        self.pasteboard = pasteboard
        self.clock = clock
        self.timeout = clearAfter
    }

    /// 삭제까지 대기하는 시간(초). 설정 화면에서 변경할 수 있다.
    public var clearAfter: TimeInterval {
        get { mutex.lock(); defer { mutex.unlock() }; return timeout }
        set { mutex.lock(); timeout = newValue; mutex.unlock() }
    }

    /// concealed: true로 쓰고 marker와 시각을 기록한다. 이전 대기 항목은 새 것으로 교체한다.
    public func copySecret(_ value: String) {
        let newMarker = pasteboard.writeString(value, concealed: true)
        mutex.lock()
        marker = newMarker
        copiedAt = clock.now()
        mutex.unlock()
    }

    public var hasPendingClear: Bool {
        mutex.lock(); defer { mutex.unlock() }
        return marker != nil
    }

    /// 앱 타이머가 주기적으로 호출한다. 기한 전이면 false.
    /// 기한 이후 marker가 일치하면 지우고 true, 아니면 지우지 않고 대기를 해제한 뒤 false.
    @discardableResult
    public func tick() -> Bool {
        mutex.lock()
        guard let currentMarker = marker, let at = copiedAt else {
            mutex.unlock()
            return false
        }
        guard clock.now().timeIntervalSince(at) >= timeout else {
            mutex.unlock()
            return false
        }
        marker = nil
        copiedAt = nil
        mutex.unlock()

        guard pasteboard.changeCount == currentMarker else { return false }
        pasteboard.clearContents()
        return true
    }

    /// 앱 종료·잠금 시 즉시 확인용: 기한과 무관하게 marker가 일치할 때만 지운다.
    @discardableResult
    public func clearNowIfUnchanged() -> Bool {
        mutex.lock()
        guard let currentMarker = marker else {
            mutex.unlock()
            return false
        }
        marker = nil
        copiedAt = nil
        mutex.unlock()

        guard pasteboard.changeCount == currentMarker else { return false }
        pasteboard.clearContents()
        return true
    }
}
