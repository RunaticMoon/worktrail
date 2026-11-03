import Foundation

// MARK: - 예약 리포트 재평가 조정자
//
// 앱 시작 시의 catch-up과, 활동 가져오기(imports) 이후의 기간 재평가를 직렬화한다.
// - catch-up이 아직 시작되지 않았으면 가져오기 구간을 보류해 두었다가 catch-up이 끝난 뒤 한 번 재평가한다.
//   catch-up이 이미 성공한 기간은 다시 실행하지 않으므로, 시작 직전에 도착한 가져오기를 버리면
//   그 기간의 새 근거가 영영 반영되지 않는다.
// - catch-up이 실행 중이면 재평가 요청을 하나의 합집합 구간으로 모아 두었다가 끝난 뒤 한 번만 실행한다.
// - catch-up이 끝난 뒤에는 가져오기마다 즉시 재평가한다. 재평가 중에 들어온 요청은 모아서 이어서 실행한다.
// - 재평가 오류는 lastError에 보관하고 onError로 알리며 다음 가져오기에서 자연히 재시도한다
//   (앱을 중단시키지 않는다). 취소는 오류가 아니므로 남은 재평가를 시작하지 않고 멈춘다.

@MainActor
public final class ScheduledReportCoordinator {

    public enum Phase: Equatable, Sendable {
        case notStarted, running, finished
    }

    public private(set) var phase: Phase = .notStarted
    /// 가장 최근 재평가 오류. 다음 재평가가 성공하면 nil로 돌아간다.
    public private(set) var lastError: Error?

    private let catchUp: @MainActor () async throws -> Void
    private let reevaluate: @MainActor (DateRange) async throws -> Void
    /// 재평가 실패를 화면·진단 계층에 알린다(선택). nil이면 lastError만 남긴다.
    private let onError: (@MainActor (Error) -> Void)?
    private var pendingRange: DateRange?
    private var catchUpTask: Task<Void, Error>?
    private var isReevaluating = false

    public init(catchUp: @escaping @MainActor () async throws -> Void,
                reevaluate: @escaping @MainActor (DateRange) async throws -> Void,
                onError: (@MainActor (Error) -> Void)? = nil) {
        self.catchUp = catchUp
        self.reevaluate = reevaluate
        self.onError = onError
    }

    /// 시작 시 catch-up을 한 번 실행하고, 그동안 모인 가져오기 구간을 이어서 재평가한다.
    public func runCatchUp() async throws {
        switch phase {
        case .finished:
            return
        case .running:
            // 이미 실행 중이면 같은 catch-up 결과를 기다린다(중복 실행 금지).
            if let task = catchUpTask { try await task.value }
            return
        case .notStarted:
            phase = .running
            let task = Task { @MainActor [catchUp] in try await catchUp() }
            catchUpTask = task
            do {
                try await task.value
            } catch {
                catchUpTask = nil
                phase = .finished
                await drainPending()
                throw error
            }
            catchUpTask = nil
            phase = .finished
            await drainPending()
        }
    }

    /// 활동 가져오기가 끝난 뒤 호출한다. 가져온 활동이 영향을 주는 업무일 구간을 넘긴다.
    public func importsLanded(_ range: DateRange) async {
        switch phase {
        case .notStarted:
            // 아직 catch-up 전이면 버리지 않고 보류한다. runCatchUp이 끝난 뒤 drainPending이 실행한다.
            // (성공한 기간은 catch-up이 다시 실행하지 않으므로 여기서 버리면 새 근거가 유실된다.)
            merge(range)
        case .running:
            merge(range)
        case .finished:
            guard !isReevaluating else { merge(range); return }
            // 취소된 작업은 새 재평가를 시작하지 않는다. 구간은 보류해 다음 가져오기가 이어받는다.
            guard !Task.isCancelled else { merge(range); return }
            isReevaluating = true
            await reevaluateSafely(range)
            await drainPending()
            isReevaluating = false
        }
    }

    // MARK: - 내부

    private func drainPending() async {
        isReevaluating = true
        defer { isReevaluating = false }
        // 취소되면 남은 재평가를 시작하지 않는다. pendingRange는 다음 가져오기를 위해 남겨 둔다.
        while !Task.isCancelled, let range = pendingRange {
            pendingRange = nil
            await reevaluateSafely(range)
        }
    }

    private func reevaluateSafely(_ range: DateRange) async {
        do {
            try await reevaluate(range)
            lastError = nil
        } catch is CancellationError {
            // 사용자가 앱을 닫거나 작업을 취소한 경우다. 오류로 기록하지 않고 멈춘다.
        } catch {
            lastError = error
            onError?(error)
        }
    }

    private func merge(_ range: DateRange) {
        guard let pending = pendingRange else { pendingRange = range; return }
        pendingRange = union(pending, range)
    }

    /// 두 구간을 모두 덮는 최소 구간 [min(start), max(endExclusive)).
    private func union(_ lhs: DateRange, _ rhs: DateRange) -> DateRange {
        DateRange(start: min(lhs.start, rhs.start),
                  endExclusive: max(lhs.endExclusive, rhs.endExclusive))
    }
}
