import Foundation
import Crypto

// 영속 AI 작업 실행기.
// - ai_job 테이블에 작업 상태를 남기고, idempotency key로 중복 실행·저장을 막는다.
// - 실제 AI 동시성은 1(FIFO 비동기 잠금). 호출 전 payloadGuard로 금지 문자열을 차단한다.
// - Secret 타입은 이 경로의 어떤 입력에도 넣지 않는다.
// - print/로그 출력 금지. provider 오류는 throw하지 않고 상태로 환원한다.

/// AI 작업 실행 요청. 자동 작업은 regenerationNonce를 nil로 둔다.
public struct AIJobRequest: Sendable, Hashable {
    public var jobType: AIJobType
    public var periodStart: WorkDate?
    public var periodEndExclusive: WorkDate?
    public var instructions: String
    public var payloadJSON: String
    public var templateVersionId: String?
    public var skill: SkillRef?
    /// 사용자의 의도적 재생성일 때만 값 지정(자동 작업은 nil)
    public var regenerationNonce: String?

    public init(jobType: AIJobType, periodStart: WorkDate? = nil, periodEndExclusive: WorkDate? = nil,
                instructions: String, payloadJSON: String, templateVersionId: String? = nil,
                skill: SkillRef? = nil, regenerationNonce: String? = nil) {
        self.jobType = jobType
        self.periodStart = periodStart
        self.periodEndExclusive = periodEndExclusive
        self.instructions = instructions
        self.payloadJSON = payloadJSON
        self.templateVersionId = templateVersionId
        self.skill = skill
        self.regenerationNonce = regenerationNonce
    }
}

public struct AIJobResult: Sendable {
    public var job: AIJob
    /// succeeded일 때만 채워진다.
    public var output: AIJobOutput?
    /// 같은 key의 성공 결과를 재사용했는지.
    public var reusedExisting: Bool

    public init(job: AIJob, output: AIJobOutput?, reusedExisting: Bool) {
        self.job = job
        self.output = output
        self.reusedExisting = reusedExisting
    }
}

/// provider 호출 전 입력 검사. 금지 문자열이 instructions·payload에 있으면 차단한다.
/// 빈 문자열 규칙은 무시한다. 차단 메시지에 차단 문자열 자체를 넣지 않는다.
public struct AIPayloadGuard: Sendable {
    public var blockedSubstrings: [String]

    public init(blockedSubstrings: [String] = []) {
        self.blockedSubstrings = blockedSubstrings
    }

    public func check(_ request: AIJobRequest) throws {
        let rules = blockedSubstrings.filter { !$0.isEmpty }
        guard !rules.isEmpty else { return }
        let fields = [request.instructions, request.payloadJSON]
        for (index, rule) in rules.enumerated() {
            if fields.contains(where: { $0.contains(rule) }) {
                throw WorkLogError.policyBlocked("AI 입력이 차단 규칙 \(index)에 해당합니다.")
            }
        }
    }
}

/// FIFO 비동기 상호 배제 잠금. actor 재진입에 의존하지 않는다.
private final class AsyncFIFOLock: @unchecked Sendable {
    private let lock = NSLock()
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // 동기 헬퍼 안에서만 잠금을 다뤄 async 컨텍스트 경고를 피한다.
            if acquireOrEnqueue(continuation) { continuation.resume() }
        }
    }

    /// 즉시 획득하면 true, 아니면 대기열에 넣고 false.
    private func acquireOrEnqueue(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !isLocked {
            isLocked = true
            return true
        }
        waiters.append(continuation)
        return false
    }

    func release() {
        let next: CheckedContinuation<Void, Never>? = releaseOrNext()
        next?.resume()
    }

    /// 다음 대기자가 있으면 반환(호출자가 resume), 없으면 잠금 해제 후 nil.
    private func releaseOrNext() -> CheckedContinuation<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        if waiters.isEmpty {
            isLocked = false
            return nil
        }
        return waiters.removeFirst()
    }
}

public final class AIJobRunner: @unchecked Sendable {
    public let repo: WorkRepository
    public let provider: AIProvider
    public let stagingRoot: URL
    public let payloadGuard: AIPayloadGuard
    public let maxAttempts: Int

    private let executionLock = AsyncFIFOLock()

    public init(repo: WorkRepository, provider: AIProvider, stagingRoot: URL,
                guard payloadGuard: AIPayloadGuard = AIPayloadGuard(), maxAttempts: Int = 3) {
        self.repo = repo
        self.provider = provider
        self.stagingRoot = stagingRoot
        self.payloadGuard = payloadGuard
        self.maxAttempts = maxAttempts
    }

    // MARK: - Key·Digest

    public static func inputDigest(_ request: AIJobRequest) -> String {
        let canonical = request.instructions + "\u{0}" + request.payloadJSON
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func idempotencyKey(_ request: AIJobRequest) -> String {
        let skillPart = request.skill.map { "\($0.name)@\($0.contentHash ?? "-")" } ?? "-"
        return [
            request.jobType.rawValue,
            request.periodStart?.iso ?? "-",
            request.periodEndExclusive?.iso ?? "-",
            inputDigest(request),
            request.templateVersionId ?? "-",
            skillPart,
            request.regenerationNonce ?? "-",
        ].joined(separator: "|")
    }

    // MARK: - 실행

    /// 1회 실행. provider 오류는 throw하지 않고 상태로 저장해 결과로 돌려준다.
    /// 저장소 오류만 throw한다.
    public func submit(_ request: AIJobRequest) async throws -> AIJobResult {
        // 1) 호출 전 차단. 차단 시 ai_job 행도 만들지 않고 provider도 부르지 않는다.
        try payloadGuard.check(request)

        let key = Self.idempotencyKey(request)
        let digest = Self.inputDigest(request)

        // 2)/3) 잠금 밖 빠른 경로: 이미 성공/실행중인 같은 key를 즉시 처리한다.
        if let existing = try repo.aiJob(idempotencyKey: key) {
            switch existing.status {
            case .succeeded:
                return AIJobResult(job: existing, output: Self.decodeOutput(existing.resultJSON),
                                   reusedExisting: true)
            case .running:
                throw WorkLogError.conflict("같은 AI 작업이 이미 실행 중입니다.")
            default:
                break
            }
        }

        // 6) 동시성 1: 앞선 submit이 끝날 때까지 FIFO로 대기한다.
        await executionLock.acquire()
        defer { executionLock.release() }

        // 잠금 획득 후 재확인(그 사이 다른 호출이 같은 key를 완료했을 수 있다).
        let job: AIJob
        if let existing = try repo.aiJob(idempotencyKey: key) {
            switch existing.status {
            case .succeeded:
                return AIJobResult(job: existing, output: Self.decodeOutput(existing.resultJSON),
                                   reusedExisting: true)
            case .running:
                throw WorkLogError.conflict("같은 AI 작업이 이미 실행 중입니다.")
            case .failed, .blockedAuth, .blockedPolicy, .cancelled, .queued:
                // 4) 실패·차단·취소·대기 행은 새로 만들지 않고 재사용한다.
                job = existing
            }
        } else {
            // 5) 없으면 queued 행 생성.
            let now = repo.clock.now()
            let created = AIJob(id: repo.ids.make(), type: request.jobType.rawValue,
                                idempotencyKey: key, inputDigest: digest, status: .queued,
                                attempts: 0, lastErrorClass: nil, resultJSON: nil,
                                createdAt: now, updatedAt: now)
            try repo.insertAIJob(created)
            job = created
        }

        // 4) 재시도 한도 도달 시 provider를 부르지 않고 현재 작업을 돌려준다.
        if job.attempts >= maxAttempts {
            return AIJobResult(job: job, output: nil, reusedExisting: true)
        }

        var running = job
        running.status = .running
        running.attempts += 1
        running.updatedAt = repo.clock.now()
        try repo.updateAIJob(running)   // 7)

        let input = AIJobInput(jobId: running.id, jobType: request.jobType,
                               instructions: request.instructions, payloadJSON: request.payloadJSON,
                               skill: request.skill)
        do {
            let output = try await provider.run(input)
            running.status = .succeeded
            running.resultJSON = try StableJSON.string(output)
            running.lastErrorClass = nil
            running.updatedAt = repo.clock.now()
            try repo.updateAIJob(running)   // 8)
            Self.cleanupStaging(stagingRoot: stagingRoot, jobId: running.id)   // 9)
            return AIJobResult(job: running, output: output, reusedExisting: false)
        } catch {
            // provider 오류는 원문을 저장하지 않고 분류만 남긴다.
            running.status = Self.status(for: error)
            running.lastErrorClass = Self.errorClass(for: error)
            running.resultJSON = nil
            running.updatedAt = repo.clock.now()
            try repo.updateAIJob(running)
            Self.cleanupStaging(stagingRoot: stagingRoot, jobId: running.id)
            return AIJobResult(job: running, output: nil, reusedExisting: false)
        }
    }

    /// provider.cancel 위임.
    public func cancel(jobId: String) async {
        await provider.cancel(jobId: jobId)
    }

    /// 앱 시작 시: 프로세스가 죽어 남은 running 행을 queued로 되돌리고 개수를 반환한다.
    @discardableResult
    public func recoverInterrupted() throws -> Int {
        let running = try repo.aiJobs(status: .running)
        for var job in running {
            job.status = .queued
            job.updatedAt = repo.clock.now()
            try repo.updateAIJob(job)
        }
        return running.count
    }

    // MARK: - 내부

    private static func decodeOutput(_ json: String?) -> AIJobOutput? {
        guard let json, !json.isEmpty else { return nil }
        return try? StableJSON.decode(AIJobOutput.self, from: json)
    }

    /// AIProviderError 분류 → 상태. 그 밖의 Error는 failed.
    static func status(for error: Error) -> AIJobStatus {
        guard let providerError = error as? AIProviderError else { return .failed }
        switch providerError.errorClass {
        case .notLoggedIn, .authExpired: return .blockedAuth
        case .policyRestricted: return .blockedPolicy
        case .cancelled: return .cancelled
        default: return .failed
        }
    }

    /// AIProviderError 분류 → AIErrorClass. 그 밖의 Error는 unknown.
    static func errorClass(for error: Error) -> AIErrorClass {
        (error as? AIProviderError)?.errorClass ?? .unknown
    }

    private static func cleanupStaging(stagingRoot: URL, jobId: String) {
        let dir = stagingRoot.appendingPathComponent(jobId, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}
