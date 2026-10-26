import Foundation

/// Native tracks preserve gaps as metadata, not fabricated microphone samples.
public enum MeetingAudioTimeline {
    public static func sessionTime(fileTime: Double, startOffset: Double, interruptions: [MeetingTrackInterruption]) -> Double {
        var value = max(0, fileTime) + startOffset
        for gap in interruptions.sorted(by: { $0.start < $1.start }) {
            guard let end = gap.end, end > gap.start else { continue }
            if value >= gap.start { value += end - gap.start }
        }
        return value
    }
    public static func fileTime(sessionTime: Double, startOffset: Double, interruptions: [MeetingTrackInterruption]) -> Double {
        var removed = 0.0
        for gap in interruptions.sorted(by: { $0.start < $1.start }) {
            guard let end = gap.end, end > gap.start, sessionTime > gap.start else { continue }
            removed += min(sessionTime, end) - gap.start
        }
        return max(0, sessionTime - startOffset - removed)
    }
}

/// Conservative timestamp assignment. Overlapping speakers remain explicitly unknown.
public struct MeetingTimedSpeaker: Sendable {
    public let start: Double
    public let end: Double
    public let id: String
    public init(start: Double, end: Double, id: String) { self.start = start; self.end = end; self.id = id }
}
public enum MeetingSpeakerAlignment {
    public static func speaker(start: Double, end: Double, turns: [MeetingTimedSpeaker]) -> String? {
        guard end > start else { return nil }
        let candidates = turns.filter { min(end, $0.end) - max(start, $0.start) > 0 }
        for (index, first) in candidates.enumerated() {
            for second in candidates.dropFirst(index + 1) where first.id != second.id {
                if min(end, first.end, second.end) - max(start, first.start, second.start) > 0.1 { return nil }
            }
        }
        var durations: [String: Double] = [:]
        for (id, intervals) in Dictionary(grouping: candidates, by: \.id) {
            var merged: [(Double, Double)] = []
            for turn in intervals.sorted(by: { $0.start < $1.start }) {
                let lower = max(start, turn.start), upper = min(end, turn.end)
                if let last = merged.last, lower <= last.1 {
                    merged[merged.count - 1].1 = max(last.1, upper)
                } else { merged.append((lower, upper)) }
            }
            durations[id] = merged.reduce(0) { $0 + $1.1 - $1.0 }
        }
        let scores = durations.sorted { $0.value > $1.value }
        guard let best = scores.first, best.value >= (end - start) * 0.6,
              scores.count == 1 || best.value - scores[1].value > (end - start) * 0.2 else { return nil }
        return best.key
    }
}
