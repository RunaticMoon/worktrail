import XCTest
@testable import WorkLogCore

final class MeetingPreviewPipelineTests: XCTestCase {
    private func request(_ track: String = "mic", start: Double = 0, final: Bool = false,
                         generation: Int = 1) -> MeetingPreviewRequest {
        .init(sessionID: "session", recordingID: "recording", generation: generation, trackID: track,
              windowStart: start, samples: [Float](repeating: 0.1, count: 160_000), isFinal: final)
    }
    func testPartialIsReplacedAndStableIsNotAppendedAgain() {
        var merger = MeetingPreviewMerger(ids: SequentialIDGenerator())
        merger.merge([.init(start: 8, end: 9, text: "draft")], request: request())
        let id = merger.segments[0].id
        merger.merge([.init(start: 8, end: 9, text: "revised")], request: request())
        XCTAssertEqual(merger.segments.count, 1)
        XCTAssertEqual(merger.segments[0].id, id)
        XCTAssertEqual(merger.segments[0].text, "revised")
        merger.merge([.init(start: 6, end: 7, text: "revised")], request: request(start: 2))
        XCTAssertEqual(merger.segments[0].stability, .stablePreview)
        merger.merge([.init(start: 5, end: 6, text: "revised")], request: request(start: 3))
        XCTAssertEqual(merger.segments.count, 1)
    }
    func testActualRepetitionsAndDifferentTracksRemain() {
        var merger = MeetingPreviewMerger(ids: SequentialIDGenerator())
        let repeated = [MeetingRecognizedSpan(start: 1, end: 1.4, text: "네"), .init(start: 1.5, end: 1.9, text: "네")]
        merger.merge(repeated, request: request())
        merger.merge(repeated, request: request("remote"))
        XCTAssertEqual(merger.segments.count, 4)
        XCTAssertEqual(Set(merger.segments.map(\.id)).count, 4)
        XCTAssertEqual(merger.segments.filter { $0.trackID == "mic" }.count, 2)
    }
    func testFinalTailBecomesStableWithoutWaitingForFullWindow() {
        var rolling = MeetingRollingAudio()
        rolling.append([Float](repeating: 0.2, count: 8_000), at: 0)
        let first = rolling.window(sessionID: "s", recordingID: "r", generation: 1, trackID: "mic", interval: 2)
        XCTAssertEqual(first?.windowEnd, 0.5)
        XCTAssertNil(rolling.window(sessionID: "s", recordingID: "r", generation: 1, trackID: "mic", interval: 2))
        let last = rolling.window(sessionID: "s", recordingID: "r", generation: 1, trackID: "mic", interval: 2, final: true)!
        var merger = MeetingPreviewMerger(ids: SequentialIDGenerator())
        merger.merge([.init(start: 0, end: 0.5, text: "tail")], request: last)
        XCTAssertEqual(merger.segments.first?.stability, .stablePreview)
    }
    func testSilentVADAndRollingMemoryBound() {
        var rolling = MeetingRollingAudio()
        for index in 0..<100 {
            rolling.append([Float](repeating: 0, count: 16_000), at: Double(index))
        }
        XCTAssertEqual(rolling.samples.count, 160_000)
        XCTAssertEqual(rolling.start, 90)
        XCTAssertNil(rolling.window(sessionID: "s", recordingID: "r", generation: 1, trackID: "mic", interval: 2))
        rolling.append([Float](repeating: 0.1, count: 8_000), at: 100)
        XCTAssertNotNil(rolling.window(sessionID: "s", recordingID: "r", generation: 1, trackID: "mic", interval: 2))
    }
    func testLatestPendingPerTrackAndFairnessWithOneInference() async {
        let engine = ControlledMeetingEngine(), events = MeetingPreviewEvents()
        let scheduler = MeetingPreviewScheduler(sessionID: "session", recordingID: "recording", generation: 1,
            tracks: ["mic", "remote"], engine: engine, ids: SequentialIDGenerator()) { await events.add($0) }
        await scheduler.submit(request())
        await engine.waitForCalls(1)
        for index in 1...20 { await scheduler.submit(request(start: Double(index))) }
        await scheduler.submit(request("remote", start: 5))
        let pending = await scheduler.pendingCount, maximum = await scheduler.maximumPendingCount
        XCTAssertEqual(pending, 2); XCTAssertEqual(maximum, 2)
        await engine.release()
        await engine.waitForCalls(2)
        let calls = await engine.calls
        XCTAssertEqual(calls.map(\.trackID), ["mic", "remote"])
        await engine.release()
        await engine.waitForCalls(3)
        let latest = await engine.calls.last?.windowStart
        XCTAssertEqual(latest, 20)
        await engine.release()
        await scheduler.finish()
        let peak = await engine.peakActive, gaps = await events.gaps
        XCTAssertEqual(peak, 1); XCTAssertEqual(gaps.count, 19)
    }
    func testStopTimeoutIsBoundedAndLateCancelledGenerationCannotPublish() async {
        let engine = ControlledMeetingEngine(), events = MeetingPreviewEvents()
        let scheduler = MeetingPreviewScheduler(sessionID: "session", recordingID: "recording", generation: 1,
            tracks: ["mic"], engine: engine, ids: SequentialIDGenerator()) { await events.add($0) }
        await scheduler.submit(request(generation: 2))
        let ignored = await scheduler.pendingCount
        XCTAssertEqual(ignored, 0)
        await scheduler.submit(request(final: true))
        await engine.waitForCalls(1)
        await scheduler.expireFinish()
        await scheduler.finish()
        await scheduler.cancel(); await scheduler.cancel()
        await engine.release()
        await scheduler.waitUntilIdle()
        let visible = await events.visible, gaps = await events.gaps
        XCTAssertTrue(visible.isEmpty)
        XCTAssertEqual(gaps.first?.reason, "finish-timeout")
        let failures = await events.failures, successfulTracks = await events.successfulTracks
        XCTAssertTrue(failures.isEmpty)
        XCTAssertTrue(successfulTracks.isEmpty)
    }
    func testPreviewFailureIsReportedAndNextTrackStillRuns() async {
        let engine = ControlledMeetingEngine(), events = MeetingPreviewEvents()
        let scheduler = MeetingPreviewScheduler(sessionID: "session", recordingID: "recording", generation: 1,
            tracks: ["mic", "remote"], engine: engine, ids: SequentialIDGenerator()) { await events.add($0) }
        await scheduler.submit(request())
        await engine.waitForCalls(1)
        await scheduler.submit(request("remote"))
        let failure = MeetingOperationFailure(phase: .tokenizer, reason: .tokenizerInvalid,
                                              errorDomain: .cocoa, errorCode: 3840)
        await engine.release(error: failure)
        await engine.waitForCalls(2)
        await engine.release()
        await events.waitForLoads(2)
        await scheduler.finish()
        let failures = await events.failures, gaps = await events.gaps, order = await events.order
        XCTAssertEqual(failures.map(\.trackID), ["mic"])
        XCTAssertEqual(failures.map(\.failure), [failure])
        XCTAssertEqual(gaps.first?.reason, "preview-error")
        XCTAssertEqual(Array(order.prefix(3)), ["failed:mic", "skipped", "load"])
        let successfulTracks = await events.successfulTracks
        XCTAssertEqual(successfulTracks, ["remote"], "Other-track success and finish must not imply mic recovery")
    }
    func testUnknownFailureDropsPrivateMetadataAndFinishIsNotRecovery() async {
        let engine = ControlledMeetingEngine(), events = MeetingPreviewEvents()
        let scheduler = MeetingPreviewScheduler(sessionID: "session", recordingID: "recording", generation: 1,
            tracks: ["mic"], engine: engine, ids: SequentialIDGenerator()) { await events.add($0) }
        await scheduler.submit(request())
        await engine.waitForCalls(1)
        await engine.release(error: NSError(domain: "private-path-and-token", code: 493,
            userInfo: [NSLocalizedDescriptionKey: "private meeting transcript", NSFilePathErrorKey: "/private/audio.wav"]))
        await events.waitForLoads(1)
        await scheduler.finish()
        let failures = await events.failures, successfulTracks = await events.successfulTracks
        XCTAssertEqual(failures.map(\.failure), [.init(phase: .preview, reason: .failed, errorDomain: .other)])
        XCTAssertNil(failures.first?.failure.errorCode)
        XCTAssertTrue(successfulTracks.isEmpty)
        XCTAssertFalse(String(describing: failures).contains("private"))
    }
    func testSuccessfulEmptyDecodeExplicitlyRecoversOnlyItsTrack() async {
        let engine = ControlledMeetingEngine(), events = MeetingPreviewEvents()
        let scheduler = MeetingPreviewScheduler(sessionID: "session", recordingID: "recording", generation: 1,
            tracks: ["mic", "remote"], engine: engine, ids: SequentialIDGenerator()) { await events.add($0) }
        await scheduler.submit(request())
        await engine.waitForCalls(1)
        await engine.release(error: NSError(domain: NSCocoaErrorDomain, code: 260))
        await events.waitForLoads(1)
        await scheduler.submit(request("remote"))
        await engine.waitForCalls(2)
        await engine.release()
        await events.waitForLoads(2)
        await scheduler.submit(request(start: 10))
        await engine.waitForCalls(3)
        await engine.release(spans: [])
        await events.waitForLoads(3)
        await scheduler.finish()
        let successfulTracks = await events.successfulTracks, failures = await events.failures
        XCTAssertEqual(successfulTracks, ["remote", "mic"])
        XCTAssertEqual(failures.first?.failure, .init(phase: .preview, reason: .failed, errorDomain: .cocoa, errorCode: 260))
    }
    func testCancelledDecodeDoesNotBecomePreviewErrorAndNextTrackStillRuns() async {
        let cancellations: [Error] = [CancellationError(), URLError(.cancelled),
            MeetingOperationFailure(phase: .modelLoading, reason: .cancelled)]
        for cancellation in cancellations {
            let engine = ControlledMeetingEngine(), events = MeetingPreviewEvents()
            let scheduler = MeetingPreviewScheduler(sessionID: "session", recordingID: "recording", generation: 1,
                tracks: ["mic", "remote"], engine: engine, ids: SequentialIDGenerator()) { await events.add($0) }
            await scheduler.submit(request())
            await engine.waitForCalls(1)
            await scheduler.submit(request("remote"))
            await engine.release(error: cancellation)
            await engine.waitForCalls(2)
            await engine.release()
            await events.waitForLoads(2)
            await scheduler.finish()
            let failures = await events.failures, gaps = await events.gaps, successfulTracks = await events.successfulTracks
            XCTAssertTrue(failures.isEmpty)
            XCTAssertTrue(gaps.isEmpty)
            XCTAssertEqual(successfulTracks, ["remote"])
        }
    }
}

private actor ControlledMeetingEngine: MeetingPreviewEngine {
    var calls: [MeetingPreviewRequest] = []
    var peakActive = 0
    private var active = 0
    private var continuations: [CheckedContinuation<[MeetingRecognizedSpan], Error>] = []
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func transcribe(_ request: MeetingPreviewRequest) async throws -> [MeetingRecognizedSpan] {
        calls.append(request); active += 1; peakActive = max(peakActive, active)
        defer { active -= 1 }
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
            let ready = callWaiters.filter { $0.0 <= calls.count }
            callWaiters.removeAll { $0.0 <= calls.count }; ready.forEach { $0.1.resume() }
        }
    }
    func waitForCalls(_ count: Int) async {
        if calls.count >= count { return }
        await withCheckedContinuation { callWaiters.append((count, $0)) }
    }
    func release(error: Error? = nil, spans: [MeetingRecognizedSpan] = [.init(start: 0, end: 1, text: "synthetic")]) {
        guard !continuations.isEmpty else { return }
        let waiter = continuations.removeFirst()
        if let error { waiter.resume(throwing: error) }
        else { waiter.resume(returning: spans) }
    }
}
private actor MeetingPreviewEvents {
    var visible: [MeetingPreviewSegment] = []
    var gaps: [MeetingPreviewGap] = []
    var failures: [(trackID: String, failure: MeetingOperationFailure)] = []
    var successfulTracks: [String] = []
    var order: [String] = []
    private var loads = 0
    private var loadWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func add(_ event: MeetingPreviewEvent) {
        switch event {
        case .updated(let segments, _): visible = segments; order.append("updated")
        case .succeeded(let trackID): successfulTracks.append(trackID); order.append("succeeded:\(trackID)")
        case .skipped(let gap): gaps.append(gap); order.append("skipped")
        case .failed(let trackID, let failure): failures.append((trackID, failure)); order.append("failed:\(trackID)")
        case .load:
            loads += 1; order.append("load")
            let ready = loadWaiters.filter { $0.0 <= loads }
            loadWaiters.removeAll { $0.0 <= loads }; ready.forEach { $0.1.resume() }
        }
    }
    func waitForLoads(_ count: Int) async {
        if loads >= count { return }
        await withCheckedContinuation { loadWaiters.append((count, $0)) }
    }
}
