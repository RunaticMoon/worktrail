import Foundation

public struct MeetingAudioPreferences: Codable, Equatable, Sendable {
    public var liveEnabled = true
    public var updateInterval: Double = 2
    public var rollingContext: Double = 10
    public var overlap: Double = 2
    public var vadEnabled = true
    public var automaticFinalization = true
    /// Zero means automatic deletion is disabled. Removal always requires an explicit action.
    public var retentionDays = 0
    public init() {}
    public var effectiveWindow: Double { min(12, max(8, rollingContext.isFinite ? rollingContext : 10)) }
    public var effectiveInterval: Double { min(10, max(2, updateInterval.isFinite ? updateInterval : 2)) }
}

public struct MeetingRecognizedSpan: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}
public struct MeetingPreviewRequest: Sendable {
    public let sessionID: String
    public let recordingID: String
    public let generation: Int
    public let trackID: String
    public let windowStart: Double
    public let windowEnd: Double
    public let samples: [Float]
    public let isFinal: Bool
    public let sampleRate = 16_000
    public init(sessionID: String, recordingID: String, generation: Int, trackID: String,
                windowStart: Double, samples: [Float], isFinal: Bool = false) {
        self.sessionID = sessionID; self.recordingID = recordingID; self.generation = generation
        self.trackID = trackID; self.windowStart = windowStart; self.samples = samples
        self.windowEnd = windowStart + Double(samples.count) / 16_000
        self.isFinal = isFinal
    }
}
public protocol MeetingPreviewEngine: Sendable {
    func transcribe(_ request: MeetingPreviewRequest) async throws -> [MeetingRecognizedSpan]
}
public enum MeetingPreviewStability: String, Codable, Sendable { case partial, stablePreview }
public struct MeetingPreviewSegment: Identifiable, Equatable, Sendable {
    public let id: String
    public let trackID: String
    public var start: Double
    public var end: Double
    public var text: String
    public var stability: MeetingPreviewStability
}
public struct MeetingPreviewGap: Codable, Equatable, Sendable {
    public var trackID: String
    public var start: Double
    public var end: Double
    public var reason: String
    public init(trackID: String, start: Double, end: Double, reason: String) {
        self.trackID = trackID; self.start = start; self.end = end; self.reason = reason
    }
}

/// Uses SDK segment timestamps plus text context within one track, never text-only deduplication.
/// There are no word timestamps: a matching stable prefix may use the preceding segment's end
/// as an approximate tail boundary. Conflicting overlaps stay partial for review, even at finish.
/// This is rolling-window decoding, not native streaming or a correctness guarantee.
public struct MeetingPreviewMerger: Sendable {
    public private(set) var segments: [MeetingPreviewSegment] = []
    private let ids: any IDGenerator
    private let overlap: Double
    // Keep the standalone decoder pipeline independent of storage. One model span is capped
    // at 256,000 UTF-8 bytes, matching the persisted segment bound (whole-run cap is separate).
    private static let maximumSpanTextBytes = 256_000
    private var ambiguousIDs = Set<String>()
    private var discardedGaps: [MeetingPreviewGap] = []
    public init(ids: any IDGenerator, overlap: Double = 2) {
        self.ids = ids; self.overlap = overlap.isFinite ? min(12, max(0, overlap)) : 2
    }

    @discardableResult public mutating func merge(_ spans: [MeetingRecognizedSpan], request: MeetingPreviewRequest) -> [MeetingPreviewSegment] {
        guard request.windowStart.isFinite, request.windowEnd.isFinite,
              request.windowStart >= 0, request.windowEnd > request.windowStart else { return [] }
        let old = segments.filter { $0.trackID == request.trackID && $0.end >= request.windowStart }
        let stable = old.filter { $0.stability == .stablePreview }.sorted { $0.start < $1.start }
        let incoming = spans.compactMap { span -> MeetingRecognizedSpan? in
            guard span.start.isFinite, span.end.isFinite, span.start >= 0, span.end > span.start,
                  span.text.utf8.count <= Self.maximumSpanTextBytes else { return nil }
            let text = Self.context(span.text)
            let start = request.windowStart + span.start, end = min(request.windowEnd, request.windowStart + span.end)
            guard !text.isEmpty, start < end else { return nil }
            return MeetingRecognizedSpan(start: start, end: end, text: text)
        }.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        // A decoder may split a previously stable sentence into several timestamped segments.
        // Suppress that group only when both its complete context and outer time bounds agree.
        var redundant = Set<Int>()
        for prior in stable {
            let group = incoming.indices.filter {
                incoming[$0].start >= prior.start - 0.15 && incoming[$0].end <= prior.end + 0.15
                    && Self.intersection(incoming[$0].start, incoming[$0].end, prior.start, prior.end) > 0
            }
            if let first = group.first, let last = group.last,
               Self.sameBounds(incoming[first].start, incoming[last].end, prior.start, prior.end),
               Self.context(group.map { incoming[$0].text }.joined(separator: " ")) == Self.context(prior.text) {
                redundant.formUnion(group)
            }
        }
        // An unconfirmed hypothesis in this window is replaced, never repeatedly appended.
        segments.removeAll { $0.trackID == request.trackID && $0.stability == .partial && $0.end > request.windowStart }
        var changes: [MeetingPreviewSegment] = []
        var matched = Set<String>()
        for (index, span) in incoming.enumerated() where !redundant.contains(index) {
            var start = span.start, text = span.text
            let end = span.end
            if stable.contains(where: { Self.sameBounds(start, end, $0.start, $0.end) && text == Self.context($0.text) }) { continue }
            // Preserve an extended segment's new tail. A text prefix alone is insufficient:
            // the prefix must begin at the same audio timestamp and have a later tail boundary.
            for prior in stable where abs(start - prior.start) <= 0.15 && end > prior.end + 0.15 {
                let prefix = Self.context(prior.text) + " "
                if text.hasPrefix(prefix) {
                    text = String(text.dropFirst(prefix.count)); start = prior.end
                }
            }
            let conflictsWithStable = stable.contains { Self.intersection(start, end, $0.start, $0.end) > 0.15 }
            let previous = old.filter { candidate in
                guard candidate.stability == .partial, !matched.contains(candidate.id) else { return false }
                let ratio = Self.intersection(start, end, candidate.start, candidate.end) / max(end - start, candidate.end - candidate.start, 0.01)
                let priorText = Self.context(candidate.text)
                let related = text == priorText || text.hasPrefix(priorText + " ") || priorText.hasPrefix(text + " ")
                return ratio > 0.55 && (related || Self.sameBounds(start, end, candidate.start, candidate.end))
            }.max {
                Self.intersection(start, end, $0.start, $0.end) < Self.intersection(start, end, $1.start, $1.end)
            }
            if let previous { matched.insert(previous.id) }
            let isStable = !conflictsWithStable && (request.isFinal || end <= request.windowEnd - overlap)
            let segment = MeetingPreviewSegment(id: previous?.id ?? ids.make(), trackID: request.trackID,
                start: start, end: end, text: text, stability: isStable ? .stablePreview : .partial)
            segments.removeAll { $0.id == segment.id }
            segments.append(segment); changes.append(segment)
            if conflictsWithStable { ambiguousIDs.insert(segment.id) } else { ambiguousIDs.remove(segment.id) }
        }
        segments.sort { $0.start == $1.start ? $0.trackID < $1.trackID : $0.start < $1.start }
        // Evict persisted stable text before any pending hypotheses. Pathological >240 partials
        // are explicitly reported as preview gaps rather than pretending they became stable.
        while segments.count > 240 {
            if let index = segments.firstIndex(where: { $0.stability == .stablePreview }) { segments.remove(at: index) }
            else {
                let removed = segments.removeFirst()
                discardedGaps.append(.init(trackID: removed.trackID, start: removed.start, end: removed.end, reason: "preview-working-set-limit"))
            }
        }
        ambiguousIDs.formIntersection(segments.map(\.id))
        return changes
    }

    public mutating func finish() -> [MeetingPreviewSegment] {
        var changes: [MeetingPreviewSegment] = []
        for index in segments.indices where segments[index].stability == .partial && !ambiguousIDs.contains(segments[index].id) {
            segments[index].stability = .stablePreview; changes.append(segments[index])
        }
        return changes
    }

    public mutating func drainDiscardedGaps() -> [MeetingPreviewGap] {
        let result = discardedGaps; discardedGaps = []; return result
    }
    private static func context(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    private static func sameBounds(_ start: Double, _ end: Double, _ otherStart: Double, _ otherEnd: Double) -> Bool {
        let tolerance = min(0.35, max(0.05, min(end - start, otherEnd - otherStart) * 0.15))
        return abs(start - otherStart) <= tolerance && abs(end - otherEnd) <= tolerance
    }
    private static func intersection(_ start: Double, _ end: Double, _ otherStart: Double, _ otherEnd: Double) -> Double {
        max(0, min(end, otherEnd) - max(start, otherStart))
    }
}

public enum MeetingPreviewEvent: Sendable {
    case updated(visible: [MeetingPreviewSegment], changed: [MeetingPreviewSegment])
    /// An actual decoder success, including silence. Finish-only updates are not recovery.
    case succeeded(trackID: String)
    case skipped(MeetingPreviewGap)
    case load(interval: Double, inferenceSeconds: Double, queued: Int)
    case failed(trackID: String, failure: MeetingOperationFailure)
}

/// One SDK call at a time and at most one pending window per known track.
/// Cancellation invalidates results immediately, but never claims an uncooperative SDK stopped.
public actor MeetingPreviewScheduler {
    private let sessionID: String
    private let recordingID: String
    private let generation: Int
    private let tracks: [String]
    private let engine: any MeetingPreviewEngine
    private let clock: any MeetingMonotonicClock
    private let onEvent: @Sendable (MeetingPreviewEvent) async -> Void
    private var merger: MeetingPreviewMerger
    private var pending: [String: MeetingPreviewRequest] = [:]
    private var active: MeetingPreviewRequest?
    private var task: Task<Void, Never>?
    private var lastTrack: String?
    private var accepting = true
    private var invalidated = false
    private var finished = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private enum Completion {
        case success([MeetingRecognizedSpan])
        case failure(MeetingOperationFailure)
        case cancelled
    }
    public private(set) var interval: Double = 2
    public private(set) var maximumPendingCount = 0

    public init(sessionID: String, recordingID: String, generation: Int, tracks: [String],
                engine: any MeetingPreviewEngine, ids: any IDGenerator,
                clock: any MeetingMonotonicClock = SystemMeetingMonotonicClock(), overlap: Double = 2,
                onEvent: @escaping @Sendable (MeetingPreviewEvent) async -> Void) {
        self.sessionID = sessionID; self.recordingID = recordingID; self.generation = generation
        self.tracks = Array(tracks.prefix(2)); self.engine = engine; self.clock = clock
        self.merger = MeetingPreviewMerger(ids: ids, overlap: overlap); self.onEvent = onEvent
    }
    public var pendingCount: Int { pending.count }
    public var isInferenceRunning: Bool { active != nil }

    public func submit(_ request: MeetingPreviewRequest) async {
        guard accepting, !invalidated, request.sessionID == sessionID, request.recordingID == recordingID,
              request.generation == generation, tracks.contains(request.trackID),
              request.samples.count <= 16_000 * 12, !request.samples.isEmpty,
              request.windowStart.isFinite, request.windowStart >= 0 else { return }
        if let stale = pending.updateValue(request, forKey: request.trackID) {
            await onEvent(.skipped(.init(trackID: stale.trackID, start: stale.windowStart,
                end: stale.windowEnd, reason: "superseded-preview")))
        }
        maximumPendingCount = max(maximumPendingCount, pending.count)
        await startNext()
    }

    private func startNext() async {
        guard active == nil, !invalidated else { return }
        // Rotate away from the previous track whenever both tracks have work.
        let next = tracks.first { $0 != lastTrack && pending[$0] != nil } ?? tracks.first { pending[$0] != nil }
        guard let next, let request = pending.removeValue(forKey: next) else {
            if !accepting { await settleFinish() }
            return
        }
        active = request; lastTrack = next
        let start = clock.seconds()
        task = Task { [engine] in
            do {
                let spans = try await engine.transcribe(request)
                try Task.checkCancellation()
                await self.complete(request, result: .success(spans), started: start)
            } catch {
                let failure = MeetingOperationFailure.sanitized(error, phase: .preview)
                let result: Completion = failure.reason == .cancelled || Task.isCancelled
                    ? .cancelled : .failure(failure)
                await self.complete(request, result: result, started: start)
            }
        }
    }

    private func complete(_ request: MeetingPreviewRequest, result: Completion, started: Double) async {
        active = nil; task = nil
        if !invalidated {
            switch result {
            case .success(let spans):
                await onEvent(.succeeded(trackID: request.trackID))
                let changed = merger.merge(spans, request: request)
                await onEvent(.updated(visible: merger.segments, changed: changed))
                for gap in merger.drainDiscardedGaps() { await onEvent(.skipped(gap)) }
            case .failure(let failure):
                await onEvent(.failed(trackID: request.trackID, failure: failure))
                await onEvent(.skipped(.init(trackID: request.trackID, start: request.windowStart,
                                            end: request.windowEnd, reason: "preview-error")))
            case .cancelled:
                break
            }
            let duration = max(0, clock.seconds() - started)
            interval = min(10, max(2, duration > 2 ? duration * 1.25 : interval * 0.8))
            await onEvent(.load(interval: interval, inferenceSeconds: duration, queued: pending.count))
            await startNext()
        }
        if active == nil { let waiters = idleWaiters; idleWaiters = []; waiters.forEach { $0.resume() } }
    }

    /// The caller must submit the last buffered window before this call.
    public func finish(graceSeconds: Double = 8) async {
        if finished { return }
        accepting = false
        if active == nil && pending.isEmpty { await settleFinish(); return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, graceSeconds)))
            await self?.expireFinish()
        }
        await withCheckedContinuation { finishWaiters.append($0) }
    }
    /// Also exposed for deterministic timeout tests without waiting for wall time.
    public func expireFinish() async {
        guard !finished else { return }
        invalidated = true; task?.cancel()
        for request in Array(pending.values) + (active.map { [$0] } ?? []) {
            await onEvent(.skipped(.init(trackID: request.trackID, start: request.windowStart,
                                        end: request.windowEnd, reason: "finish-timeout")))
        }
        pending = [:]; await settleFinish()
    }
    public func cancel() async {
        accepting = false; invalidated = true; pending = [:]; task?.cancel(); await settleFinish()
    }
    /// Wait before releasing an engine or starting a new model on the same inference lane.
    public func waitUntilIdle() async {
        if active == nil { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }
    private func settleFinish() async {
        guard !finished else { return }; finished = true
        let changed = merger.finish(), visible = merger.segments
        await onEvent(.updated(visible: visible, changed: changed))
        let waiters = finishWaiters; finishWaiters = []; waiters.forEach { $0.resume() }
    }
}

/// Bounded 16 kHz mono preview history. VAD never affects the original writer.
public struct MeetingRollingAudio: Sendable {
    public private(set) var samples: [Float] = []
    public private(set) var start: Double = 0
    private var lastRequestEnd: Double = -.infinity
    private var lastVoiceEnd: Double = -.infinity
    private var settings: MeetingAudioPreferences
    public init(settings: MeetingAudioPreferences = .init()) { self.settings = settings }
    public mutating func append(_ incoming: [Float], at timestamp: Double) {
        guard timestamp.isFinite, timestamp >= 0, !incoming.isEmpty else { return }
        let expected = start + Double(samples.count) / 16_000
        if samples.isEmpty || abs(timestamp - expected) > 0.1 { samples = []; start = timestamp }
        let energy = incoming.reduce(Double(0)) { $0 + Double($1 * $1) } / Double(incoming.count)
        if energy.isFinite && sqrt(energy) >= 0.008 { lastVoiceEnd = timestamp + Double(incoming.count) / 16_000 }
        samples.append(contentsOf: incoming)
        let excess = samples.count - Int(settings.effectiveWindow * 16_000)
        if excess > 0 { samples.removeFirst(excess); start += Double(excess) / 16_000 }
    }
    public mutating func window(sessionID: String, recordingID: String, generation: Int, trackID: String,
                                interval: Double, final: Bool = false) -> MeetingPreviewRequest? {
        let end = start + Double(samples.count) / 16_000
        guard !samples.isEmpty, final || samples.count >= 8_000 else { return nil }
        guard final || end - lastRequestEnd >= max(settings.effectiveInterval, interval) else { return nil }
        // Include 1 s trailing allowance; the rolling history supplies leading context.
        guard !settings.vadEnabled || lastVoiceEnd >= start && (final || end - lastVoiceEnd <= 1) else { return nil }
        lastRequestEnd = end
        return .init(sessionID: sessionID, recordingID: recordingID, generation: generation,
                     trackID: trackID, windowStart: start, samples: samples, isFinal: final)
    }
}
