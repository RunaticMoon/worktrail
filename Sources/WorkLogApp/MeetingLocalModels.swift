#if os(macOS)
import CryptoKit
import Foundation
import Observation
import WorkLogCore

enum MeetingModelRole: String, CaseIterable, Codable, Sendable, Identifiable {
    case live, final, diarization
    var id: String { rawValue }
    var label: String {
        switch self {
        case .live: return "실시간 전사 · Whisper large-v3-turbo"
        case .final: return "최종 전사 · Whisper large-v3"
        case .diarization: return "화자 구분 · SpeakerKit"
        }
    }
}

struct MeetingModelFile: Codable, Sendable {
    let repository: String
    let revision: String
    let remotePath: String
    let localPath: String
    let bytes: Int64
    /// Hugging Face LFS objects use SHA256. Small Git blobs use Git's blob SHA1.
    let digest: String
    let digestKind: String
    var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(remotePath)")!
    }
}

struct MeetingModelDescriptor: Sendable {
    let role: MeetingModelRole
    let modelID: String
    let revision: String
    let license: String
    let attribution: String
    let files: [MeetingModelFile]
    var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    var directoryName: String { "\(role.rawValue)-\(revision)" }
}

struct MeetingModelProgress: Sendable {
    var completedBytes: Int64
    var totalBytes: Int64
    var message: String
    var bytesPerSecond: Double? = nil
    var fraction: Double { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0 }
}

enum MeetingLocalModelError: LocalizedError {
    case missing(MeetingModelRole), invalidFile(String), busy, invalidAudio, downloadFailed(Int), invalidTokenizer
    var errorDescription: String? {
        switch self {
        case .missing(let role): return "‘\(role.label)’ 모델 준비를 먼저 실행해 주세요. 추론 중에는 다운로드하지 않습니다."
        case .invalidFile(let path): return "로컬 모델 파일의 무결성을 확인하지 못했습니다: \(path). 모델 준비를 다시 실행해 주세요."
        case .busy: return "진행 중인 모델 작업을 마치거나 취소해 주세요."
        case .invalidAudio: return "16kHz 모노 음성 구간이 필요합니다. 전사 최대 30초, 화자 구분 최대 120초입니다."
        case .downloadFailed(let code): return "모델 다운로드에 실패했습니다(HTTP \(code)). 다시 준비를 실행하면 검증된 파일부터 이어갑니다."
        case .invalidTokenizer: return "로컬 다국어 토크나이저가 없거나 손상되었습니다. 모델 준비를 다시 실행해 주세요."
        }
    }
}

protocol MeetingModelDownloading: Sendable {
    /// Writes the public file into `partial`, resuming from its current size when possible.
    /// On return `partial` holds the whole file (caller verifies size+digest). `progress` reports cumulative bytes in `partial`.
    func download(_ file: MeetingModelFile, to partial: URL, progress: @escaping @Sendable (Int64) -> Void) async throws
}

private func fileSize(at url: URL) -> Int64 {
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
          values.isRegularFile == true else { return 0 }
    return Int64(values.fileSize ?? 0)
}

/// One shared ephemeral session for every model file: connection reuse and HTTP/2 multiplexing,
/// with a session-level delegate streaming into the caller's partial file so interrupted
/// downloads resume through Range requests. Plain data tasks, since the async download API
/// never reports write progress.
final class MeetingModelHTTPDownloader: MeetingModelDownloading, @unchecked Sendable {
    private let session: URLSession
    private let delegate: SessionDelegate

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3_600
        let queue = OperationQueue()
        queue.name = "WorkLog.MeetingModelDownloader"
        queue.maxConcurrentOperationCount = 1
        let delegate = SessionDelegate()
        self.delegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    }

    deinit { session.finishTasksAndInvalidate() }

    func download(_ file: MeetingModelFile, to partial: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try Task.checkCancellation()
        let existing = fileSize(at: partial)
        let offset = existing > 0 && existing < file.bytes ? existing : 0
        var request = URLRequest(url: file.downloadURL)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: request)
        delegate.register(expectedBytes: file.bytes, offset: offset, localPath: file.localPath,
                          partial: partial, progress: progress, for: task.taskIdentifier)
        defer { delegate.removeState(for: task.taskIdentifier) }
        do {
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if delegate.install(continuation, for: task.taskIdentifier) { task.resume() }
                }
            }, onCancel: { task.cancel() })
        } catch {
            if Task.isCancelled, error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }
        try Task.checkCancellation()
    }

    private final class SessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        static let flushThreshold = 4 * 1_048_576

        private final class TaskState {
            let expectedBytes: Int64
            let localPath: String
            let partial: URL
            let progress: @Sendable (Int64) -> Void
            var written: Int64
            var handle: FileHandle?
            var buffer = Data()
            var continuation: CheckedContinuation<Void, Error>?
            var finished = false
            /// Outcome recorded when the task ends before its continuation is installed (e.g. early cancel).
            var outcome: Result<Void, Error>?
            init(expectedBytes: Int64, offset: Int64, localPath: String, partial: URL,
                 progress: @escaping @Sendable (Int64) -> Void) {
                self.expectedBytes = expectedBytes
                self.written = offset
                self.localPath = localPath
                self.partial = partial
                self.progress = progress
            }
        }

        private let lock = NSLock()
        private var states: [Int: TaskState] = [:]

        func register(expectedBytes: Int64, offset: Int64, localPath: String, partial: URL,
                      progress: @escaping @Sendable (Int64) -> Void, for identifier: Int) {
            lock.lock(); defer { lock.unlock() }
            states[identifier] = TaskState(expectedBytes: expectedBytes, offset: offset, localPath: localPath,
                                           partial: partial, progress: progress)
        }

        func removeState(for identifier: Int) {
            lock.lock(); defer { lock.unlock() }
            states[identifier] = nil
        }

        /// Returns false when the task already ended; the continuation is then resumed with that outcome.
        func install(_ continuation: CheckedContinuation<Void, Error>, for identifier: Int) -> Bool {
            lock.lock()
            guard let state = states[identifier], !state.finished else {
                let outcome = states[identifier]?.outcome ?? .failure(CancellationError())
                lock.unlock()
                continuation.resume(with: outcome)
                return false
            }
            state.continuation = continuation
            lock.unlock()
            return true
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard request.url?.scheme == "https" else {
                complete(task.taskIdentifier, error: MeetingLocalModelError.downloadFailed(response.statusCode))
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var failure: Error?
            var allow = false
            var reported: (bytes: Int64, progress: @Sendable (Int64) -> Void)?
            lock.lock()
            if let state = states[dataTask.taskIdentifier], !state.finished {
                do {
                    switch status {
                    case 206 where state.written > 0:
                        // Append only when the server resumes exactly where the partial file ends.
                        let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") ?? ""
                        guard range.hasPrefix("bytes \(state.written)-") else {
                            FileManager.default.createFile(atPath: state.partial.path, contents: Data())
                            state.written = 0
                            throw MeetingLocalModelError.downloadFailed(206)
                        }
                        let handle = try FileHandle(forWritingTo: state.partial)
                        handle.seekToEndOfFile()
                        state.handle = handle
                    case 200, 206:
                        FileManager.default.createFile(atPath: state.partial.path, contents: Data())
                        state.written = 0
                        state.handle = try FileHandle(forWritingTo: state.partial)
                    case 416:
                        FileManager.default.createFile(atPath: state.partial.path, contents: Data())
                        state.written = 0
                        throw MeetingLocalModelError.downloadFailed(416)
                    default:
                        throw MeetingLocalModelError.downloadFailed(status)
                    }
                    reported = (state.written, state.progress)
                    allow = true
                } catch {
                    failure = error
                }
            }
            lock.unlock()
            if let reported { reported.progress(reported.bytes) }
            if let failure {
                complete(dataTask.taskIdentifier, error: failure)
                completionHandler(.cancel)
            } else {
                completionHandler(allow ? .allow : .cancel)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            var failure: Error?
            var reported: (bytes: Int64, progress: @Sendable (Int64) -> Void)?
            lock.lock()
            if let state = states[dataTask.taskIdentifier], !state.finished {
                state.buffer.append(data)
                state.written += Int64(data.count)
                if state.written > state.expectedBytes {
                    failure = MeetingLocalModelError.invalidFile(state.localPath)
                } else {
                    if state.buffer.count >= Self.flushThreshold {
                        do { try flush(state) } catch { failure = error }
                    }
                    if failure == nil { reported = (state.written, state.progress) }
                }
            }
            lock.unlock()
            if let failure {
                complete(dataTask.taskIdentifier, error: failure)
                dataTask.cancel()
            } else if let reported {
                reported.progress(reported.bytes)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            complete(task.taskIdentifier, error: error)
        }

        private func flush(_ state: TaskState) throws {
            guard let handle = state.handle, !state.buffer.isEmpty else { return }
            try handle.write(contentsOf: state.buffer)
            state.buffer.removeAll(keepingCapacity: false)
        }

        /// Terminal path for every exit: flush and close under the lock, then resume the continuation exactly once.
        private func complete(_ identifier: Int, error: Error?) {
            var continuation: CheckedContinuation<Void, Error>?
            var outcome: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
            lock.lock()
            if let state = states[identifier], !state.finished {
                state.finished = true
                // A failed final write must surface instead of looking like a corrupt download.
                do { try flush(state) } catch { if case .success = outcome { outcome = .failure(error) } }
                if let handle = state.handle {
                    try? handle.synchronize()
                    try? handle.close()
                    state.handle = nil
                }
                continuation = state.continuation
                state.continuation = nil
                if continuation == nil { state.outcome = outcome }
            }
            lock.unlock()
            continuation?.resume(with: outcome)
        }
    }
}

/// All network access is confined to explicit prepare(). Inference only calls verifiedDirectory().
/// Files are immutable by revision; partial downloads never receive an installation receipt.
actor MeetingLocalModelStore {
    private static let maxConcurrentDownloads = 4
    private let root: URL
    private let downloader: any MeetingModelDownloading
    private let clock: any WorkLogCore.Clock
    private let monotonic: any MeetingMonotonicClock
    private let descriptors: [MeetingModelDescriptor]
    private var preparing = false

    struct InstalledFile: Codable { var path: String; var sha256: String; var bytes: Int64 }
    struct Receipt: Codable {
        var modelID: String; var revision: String; var sdkVersion: String; var installedAt: Date
        var license: String; var attribution: String; var sources: [MeetingModelFile]; var files: [InstalledFile]
    }

    init(root: URL, downloader: any MeetingModelDownloading = MeetingModelHTTPDownloader(),
         clock: any WorkLogCore.Clock = SystemClock(), descriptors: [MeetingModelDescriptor] = MeetingModelRegistry.models,
         monotonic: any MeetingMonotonicClock = SystemMeetingMonotonicClock()) {
        self.root = root; self.downloader = downloader; self.clock = clock; self.descriptors = descriptors
        self.monotonic = monotonic
    }

    func descriptor(for role: MeetingModelRole) throws -> MeetingModelDescriptor {
        guard let descriptor = descriptors.first(where: { $0.role == role }) else { throw MeetingLocalModelError.missing(role) }
        return descriptor
    }

    /// Cheap local status inspection. Full pinned digest verification happens before model loading.
    func isInstalled(_ role: MeetingModelRole) -> Bool {
        guard let descriptor = try? descriptor(for: role) else { return false }
        let directory = root.appendingPathComponent(descriptor.directoryName, isDirectory: true)
        guard let receipt = try? readReceipt(in: directory), receipt.modelID == descriptor.modelID,
              receipt.revision == descriptor.revision, receipt.files.count == descriptor.files.count else { return false }
        return descriptor.files.allSatisfy { file in
            guard let url = try? safeFile(file.localPath, in: directory),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true && Int64(values.fileSize ?? -1) == file.bytes
        }
    }

    func verifiedDirectory(for role: MeetingModelRole) throws -> URL {
        let descriptor = try descriptor(for: role)
        let directory = root.appendingPathComponent(descriptor.directoryName, isDirectory: true)
        guard isInstalled(role) else { throw MeetingLocalModelError.missing(role) }
        let receipt = try readReceipt(in: directory)
        for file in descriptor.files {
            try Task.checkCancellation()
            let sha256 = try verify(file, in: directory)
            guard receipt.files.contains(where: { $0.path == file.localPath && $0.sha256 == sha256 && $0.bytes == file.bytes }) else {
                throw MeetingLocalModelError.invalidFile(file.localPath)
            }
        }
        return directory
    }

    /// This is the only entry point permitted to fetch model/tokenizer files.
    func prepare(_ role: MeetingModelRole, progress: @escaping @Sendable (MeetingModelProgress) -> Void) async throws {
        guard !preparing else { throw MeetingLocalModelError.busy }
        preparing = true
        defer { preparing = false }
        let descriptor = try descriptor(for: role)
        if (try? verifiedDirectory(for: role)) != nil {
            progress(.init(completedBytes: descriptor.bytes, totalBytes: descriptor.bytes, message: "모델 준비됨"))
            return
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".partial-\(descriptor.directoryName)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let aggregator = PrepareProgressAggregator(files: descriptor.files, monotonic: monotonic, progress: progress)
        // Largest first: the biggest files dominate the critical path; up to four run in parallel.
        var items: [(index: Int, file: MeetingModelFile)] = []
        for (offset, modelFile) in descriptor.files.enumerated() { items.append((offset, modelFile)) }
        items.sort { lhs, rhs in
            if lhs.file.bytes != rhs.file.bytes { return lhs.file.bytes > rhs.file.bytes }
            return lhs.index < rhs.index
        }
        let install: @Sendable (Int, MeetingModelFile) async throws -> (Int, InstalledFile) = { index, file in
            (index, try await self.installFile(file, index: index, staging: staging, downloader: self.downloader, aggregator: aggregator))
        }
        var installedFiles = [InstalledFile?](repeating: nil, count: descriptor.files.count)
        var failure: Error?
        await withThrowingTaskGroup(of: (Int, InstalledFile).self) { group in
            var next = min(Self.maxConcurrentDownloads, items.count)
            for item in items.prefix(Self.maxConcurrentDownloads) {
                group.addTask { try await install(item.index, item.file) }
            }
            do {
                while let (index, installed) = try await group.next() {
                    installedFiles[index] = installed
                    if next < items.count, !Task.isCancelled {
                        let item = items[next]
                        next += 1
                        group.addTask { try await install(item.index, item.file) }
                    }
                }
            } catch {
                // Do not cancel in-flight children: their finished files stay verified for the next retry.
                failure = error
            }
        }
        if let failure { throw failure }
        try Task.checkCancellation()
        for file in descriptor.files {
            if let partial = try? safeFile(file.localPath + ".part", in: staging) {
                try? FileManager.default.removeItem(at: partial)
            }
        }
        let verifiedFiles = installedFiles.compactMap { $0 }
        guard verifiedFiles.count == descriptor.files.count else { throw MeetingLocalModelError.missing(role) }
        let receipt = Receipt(modelID: descriptor.modelID, revision: descriptor.revision, sdkVersion: "1.1.1",
                              installedAt: clock.now(), license: descriptor.license, attribution: descriptor.attribution,
                              sources: descriptor.files, files: verifiedFiles)
        try JSONEncoder().encode(receipt).write(to: staging.appendingPathComponent("installation.json"), options: .atomic)
        let destination = root.appendingPathComponent(descriptor.directoryName, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: staging, to: destination)
        progress(.init(completedBytes: descriptor.bytes, totalBytes: descriptor.bytes, message: "모델 준비됨 · 음성은 이 Mac에서 처리됩니다."))
    }

    /// Runs entirely off the actor: hashing and downloads happen in the caller's child task.
    private nonisolated func installFile(_ file: MeetingModelFile, index: Int, staging: URL,
                                         downloader: any MeetingModelDownloading,
                                         aggregator: PrepareProgressAggregator) async throws -> InstalledFile {
        let destination = try safeFile(file.localPath, in: staging)
        if let checksum = try? verify(file, in: staging) {
            aggregator.fileCompleted(index)
            return InstalledFile(path: file.localPath, sha256: checksum, bytes: file.bytes)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = try safeFile(file.localPath + ".part", in: staging)
        var resumed = fileSize(at: partial)
        if resumed > file.bytes {
            try? FileManager.default.removeItem(at: partial)
            resumed = 0
        }
        aggregator.startDownload(index, resumedBytes: min(resumed, file.bytes))
        // A partial that already holds every byte (interrupted just before the move) goes straight to verification.
        if resumed < file.bytes {
            try await downloader.download(file, to: partial) { [aggregator] bytes in
                aggregator.update(index, bytes: bytes)
            }
        }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: partial, to: destination)
        do {
            let checksum = try verify(file, in: staging)
            aggregator.fileCompleted(index)
            return InstalledFile(path: file.localPath, sha256: checksum, bytes: file.bytes)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            aggregator.reset(index)
            throw error
        }
    }

    /// Lock-protected aggregate progress across parallel downloads; calls `progress` on the
    /// emitting thread (the MeetingLocalModels callback performs the MainActor hop).
    private final class PrepareProgressAggregator: @unchecked Sendable {
        private let lock = NSLock()
        private let files: [MeetingModelFile]
        private let monotonic: any MeetingMonotonicClock
        private let progress: @Sendable (MeetingModelProgress) -> Void
        private var current: [Int64]
        private var reported: [Int64]
        private var downloadedSinceSample: Int64 = 0
        private var lastSampleAt: Double?
        private var rateAverage: Double?
        private var lastEmitAt = -Double.greatestFiniteMagnitude

        init(files: [MeetingModelFile], monotonic: any MeetingMonotonicClock,
             progress: @escaping @Sendable (MeetingModelProgress) -> Void) {
            self.files = files
            self.monotonic = monotonic
            self.progress = progress
            self.current = Array(repeating: 0, count: files.count)
            self.reported = Array(repeating: 0, count: files.count)
        }

        func startDownload(_ index: Int, resumedBytes: Int64) {
            lock.lock(); defer { lock.unlock() }
            current[index] = resumedBytes
            reported[index] = resumedBytes
        }

        func update(_ index: Int, bytes: Int64) {
            lock.lock(); defer { lock.unlock() }
            if bytes > reported[index] { downloadedSinceSample += bytes - reported[index] }
            reported[index] = bytes
            current[index] = min(bytes, files[index].bytes)
            let now = monotonic.seconds()
            sample(at: now)
            emit(message: "모델 다운로드 중…", force: false, at: now)
        }

        func fileCompleted(_ index: Int) {
            lock.lock(); defer { lock.unlock() }
            current[index] = files[index].bytes
            reported[index] = files[index].bytes
            let now = monotonic.seconds()
            sample(at: now)
            emit(message: "다운로드 및 무결성 확인 중…", force: true, at: now)
        }

        func reset(_ index: Int) {
            lock.lock(); defer { lock.unlock() }
            current[index] = 0
            reported[index] = 0
        }

        /// One rate sample at most every 0.5 s, exponential moving average with alpha 0.3,
        /// counting only newly downloaded bytes (resumed bytes never enter the delta).
        private func sample(at now: Double) {
            guard let last = lastSampleAt else {
                lastSampleAt = now
                downloadedSinceSample = 0
                return
            }
            let elapsed = now - last
            guard elapsed >= 0.5 else { return }
            if downloadedSinceSample > 0 {
                let rate = Double(downloadedSinceSample) / elapsed
                rateAverage = rateAverage.map { $0 + 0.3 * (rate - $0) } ?? rate
            }
            lastSampleAt = now
            downloadedSinceSample = 0
        }

        private func emit(message: String, force: Bool, at now: Double) {
            guard force || now - lastEmitAt >= 0.15 else { return }
            lastEmitAt = now
            progress(MeetingModelProgress(completedBytes: current.reduce(0, +), totalBytes: files.reduce(0) { $0 + $1.bytes },
                                          message: message, bytesPerSecond: rateAverage))
        }
    }

    private nonisolated func readReceipt(in directory: URL) throws -> Receipt {
        let url = try safeFile("installation.json", in: directory)
        return try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url))
    }

    private nonisolated func safeFile(_ path: String, in directory: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw MeetingLocalModelError.invalidFile(path)
        }
        let url = directory.appendingPathComponent(path)
        let base = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base) else {
            throw MeetingLocalModelError.invalidFile(path)
        }
        return url
    }

    private nonisolated func verify(_ file: MeetingModelFile, in directory: URL) throws -> String {
        let url = try safeFile(file.localPath, in: directory)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == file.bytes else {
            throw MeetingLocalModelError.invalidFile(file.localPath)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha256 = SHA256()
        var gitSHA1 = Insecure.SHA1()
        gitSHA1.update(data: Data("blob \(file.bytes)\0".utf8))
        var count: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            count += Int64(data.count)
            guard count <= file.bytes else { throw MeetingLocalModelError.invalidFile(file.localPath) }
            sha256.update(data: data)
            if file.digestKind == "git-blob-sha1" { gitSHA1.update(data: data) }
        }
        let hex = sha256.finalize().map { String(format: "%02x", $0) }.joined()
        let expected = file.digestKind == "sha256" ? hex : gitSHA1.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == file.bytes, expected == file.digest else { throw MeetingLocalModelError.invalidFile(file.localPath) }
        return hex
    }
}

@Observable @MainActor final class MeetingLocalModels {
    let store: MeetingLocalModelStore
    private(set) var readyRoles: Set<MeetingModelRole> = []
    private(set) var preparingRole: MeetingModelRole?
    private(set) var progress: MeetingModelProgress?
    private(set) var message: String?
    @ObservationIgnored private var task: Task<Void, Error>?
    @ObservationIgnored private var generation = 0
    var isPreparing: Bool { preparingRole != nil }
    init(store: MeetingLocalModelStore) { self.store = store }

    func refreshAvailability() async {
        guard !isPreparing else { return }
        var ready: Set<MeetingModelRole> = []
        for role in MeetingModelRole.allCases where await store.isInstalled(role) { ready.insert(role) }
        guard !isPreparing else { return }
        readyRoles = ready
    }

    func prepare(_ role: MeetingModelRole) async throws {
        AppDiagnostics.shared.record(.operationStarted, category: .transcription)
        guard !isPreparing else { throw MeetingLocalModelError.busy }
        generation += 1
        let expectedGeneration = generation
        preparingRole = role
        message = "모델 준비 중…"
        let modelStore = store
        let operation = Task { [weak self] in
            try await modelStore.prepare(role) { [weak self] value in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == expectedGeneration, self.preparingRole == role else { return }
                    self.progress = value; self.message = value.message
                }
            }
        }
        task = operation
        defer { generation += 1; preparingRole = nil; progress = nil; task = nil }
        do {
            try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
            try Task.checkCancellation()
            readyRoles.insert(role)
            AppDiagnostics.shared.record(.operationSucceeded, category: .transcription)
            message = "\(role.label) 준비됨 · 음성은 이 Mac에서 처리됩니다."
        } catch {
            AppDiagnostics.shared.recordFailure(error, category: .transcription)
            message = error is CancellationError ? "모델 준비를 취소했습니다. 검증된 파일은 재시도에 사용합니다." : error.localizedDescription
            throw error
        }
    }

    func cancel() { task?.cancel() }
}
#endif
