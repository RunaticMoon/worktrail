import Foundation

/// Audio time is independent of civil time, sleep/wake clock adjustments and WorkDate.
public protocol MeetingMonotonicClock: Sendable { func seconds() -> Double }

public struct SystemMeetingMonotonicClock: MeetingMonotonicClock {
    public init() {}
    public func seconds() -> Double { ProcessInfo.processInfo.systemUptime }
}
