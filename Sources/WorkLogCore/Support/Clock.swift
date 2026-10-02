import Foundation

/// 테스트 가능한 시계. 도메인 로직은 Date()를 직접 호출하지 않는다.
public protocol Clock: Sendable {
    func now() -> Date
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}

/// 테스트용 고정/이동 가능한 시계.
public final class FixedClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    public init(_ date: Date) { current = date }
    public func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
    public func set(_ date: Date) { lock.lock(); current = date; lock.unlock() }
    public func advance(by seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
}

/// 안정적인 UUID 기반 ID 생성기. 테스트에서는 결정적 생성기를 주입한다.
public protocol IDGenerator: Sendable {
    func make() -> String
}

public struct UUIDGenerator: IDGenerator {
    public init() {}
    public func make() -> String { UUID().uuidString.lowercased() }
}

public final class SequentialIDGenerator: IDGenerator, @unchecked Sendable {
    private let lock = NSLock()
    private var counter = 0
    private let prefix: String
    public init(prefix: String = "id") { self.prefix = prefix }
    public func make() -> String {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        return "\(prefix)-\(counter)"
    }
}
