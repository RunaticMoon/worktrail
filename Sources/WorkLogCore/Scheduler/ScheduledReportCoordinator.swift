import Foundation

/// Owns and serializes startup, deadline checks and imported-source reevaluation.
@MainActor
public final class ScheduledReportCoordinator {
    public enum Phase: Equatable, Sendable { case notStarted, running, finished }
    public private(set) var phase: Phase = .notStarted
    public private(set) var lastError: Error?
    private let catchUp: @MainActor () async throws -> Void
    private let reevaluate: @MainActor (DateRange) async throws -> Void
    private let onError: (@MainActor (Error) -> Void)?
    private var pendingRange: DateRange?
    private var operation: Task<Void, Error>?
    private var stopped = false

    public init(catchUp: @escaping @MainActor () async throws -> Void,
                reevaluate: @escaping @MainActor (DateRange) async throws -> Void,
                onError: (@MainActor (Error) -> Void)? = nil) {
        self.catchUp = catchUp; self.reevaluate = reevaluate; self.onError = onError
    }

    public func runCatchUp() async throws {
        guard !stopped else { throw CancellationError() }
        if let operation { try await operation.value; return }
        guard phase == .notStarted else { return }
        phase = .running
        let task = Task { @MainActor in
            do { try await self.catchUp() }
            catch {
                self.phase = .finished
                if !(error is CancellationError) { await self.drainPending() }
                throw error
            }
            self.phase = .finished
            await self.drainPending()
        }
        operation = task
        defer { operation = nil }
        try await withTaskCancellationHandler(operation: { try await task.value },
                                              onCancel: { task.cancel() })
    }

    /// Timer/wake checks also recover persisted failures when collection returns no new items.
    /// The scheduler bounds attempts/backoff and skips already successful periods.
    public func maintenance() async throws {
        guard !stopped, phase == .finished, operation == nil else { return }
        phase = .notStarted
        try await runCatchUp()
    }

    public func importsLanded(_ range: DateRange) async {
        guard !stopped else { return }
        merge(range)
        guard phase == .finished, operation == nil, !Task.isCancelled else { return }
        let task = Task<Void, Error> { @MainActor in await self.drainPending() }
        operation = task
        defer { operation = nil }
        await withTaskCancellationHandler(operation: { _ = try? await task.value },
                                          onCancel: { task.cancel() })
    }

    /// Stop admission synchronously, then await shutdown before releasing the environment.
    public func cancel() { stopped = true; operation?.cancel() }
    public func shutdown() async {
        cancel()
        _ = try? await operation?.value
        operation = nil
        pendingRange = nil
    }

    private func drainPending() async {
        while !stopped, !Task.isCancelled, let range = pendingRange {
            pendingRange = nil
            do {
                try await reevaluate(range)
                lastError = nil
            } catch {
                merge(range)
                if !(error is CancellationError) { lastError = error; onError?(error) }
                // Leave the failed range for the next external trigger, never a hot retry loop.
                break
            }
            if Task.isCancelled { merge(range); break }
        }
    }
    private func merge(_ range: DateRange) {
        guard let pending = pendingRange else { pendingRange = range; return }
        pendingRange = DateRange(start: min(pending.start, range.start),
                                 endExclusive: max(pending.endExclusive, range.endExclusive))
    }
}
