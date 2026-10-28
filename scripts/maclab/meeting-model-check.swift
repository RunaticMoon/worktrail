import CryptoKit
import Foundation
import WorkLogCore

private enum FixtureError: Error { case interrupted }

private final class ScriptedMonotonicClock: MeetingMonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    func seconds() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: Double) { lock.lock(); value += seconds; lock.unlock() }
}

private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MeetingModelProgress] = []
    func record(_ value: MeetingModelProgress) { lock.lock(); values.append(value); lock.unlock() }
    var all: [MeetingModelProgress] { lock.lock(); defer { lock.unlock() }; return values }
}

private actor FakeDownloader: MeetingModelDownloading {
    let data: Data
    var calls = 0
    var failSecond = false
    var holdNanos: UInt64 = 0
    var inFlight = 0
    var peakInFlight = 0
    var observedPartialBytes: [String: Int64] = [:]
    var clock: ScriptedMonotonicClock?
    init(data: Data) { self.data = data }
    func configure(failSecond: Bool = false, holdNanos: UInt64 = 0, clock: ScriptedMonotonicClock? = nil) {
        self.failSecond = failSecond; self.holdNanos = holdNanos; self.clock = clock
    }
    func count() -> Int { calls }
    func peakConcurrent() -> Int { peakInFlight }
    func observedBytes(for localPath: String) -> Int64? { observedPartialBytes[localPath] }
    func download(_ file: MeetingModelFile, to partial: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        calls += 1
        inFlight += 1
        if inFlight > peakInFlight { peakInFlight = inFlight }
        defer { inFlight -= 1 }
        if holdNanos > 0 { try await Task.sleep(nanoseconds: holdNanos) }
        if failSecond && file.localPath.hasSuffix("second.bin") { failSecond = false; throw FixtureError.interrupted }
        let existing = (try? FileManager.default.attributesOfItem(atPath: partial.path))?[.size] as? Int64 ?? 0
        observedPartialBytes[file.localPath] = existing
        progress(existing)
        clock?.advance(1.0)
        // Append only the missing tail, like a real Range resume, so a wrong offset breaks the digest.
        if existing > 0 && existing < Int64(data.count) {
            let handle = try FileHandle(forWritingTo: partial)
            try handle.seekToEnd()
            try handle.write(contentsOf: data.subdata(in: Int(existing)..<data.count))
            try handle.close()
        } else {
            try data.write(to: partial)
        }
        progress(Int64(data.count))
        clock?.advance(1.0)
    }
}

@main struct ModelChecks {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "ModelChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func containsPartFile(_ directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return false }
        return enumerator.allObjects.contains { ($0 as? URL)?.lastPathComponent.hasSuffix(".part") == true }
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = Data("fake public model bytes".utf8)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let gitData = Data("blob \(data.count)\0".utf8) + data
        let gitSHA = Insecure.SHA1.hash(data: gitData).map { String(format: "%02x", $0) }.joined()
        func file(_ path: String, git: Bool = false) -> MeetingModelFile {
            .init(repository: "fixture/public", revision: String(repeating: "a", count: 40), remotePath: path,
                  localPath: "model/\(path)", bytes: Int64(data.count), digest: git ? gitSHA : sha,
                  digestKind: git ? "git-blob-sha1" : "sha256")
        }
        func descriptor(_ files: [MeetingModelFile]) -> MeetingModelDescriptor {
            .init(role: .live, modelID: "fixture", revision: String(repeating: "a", count: 40),
                  license: "fixture", attribution: "fake data", files: files)
        }
        let clock = ScriptedMonotonicClock()
        let download = FakeDownloader(data: data)
        await download.configure(clock: clock)
        let collector = ProgressCollector()
        let storeRoot = root.appendingPathComponent("models")
        let store = MeetingLocalModelStore(root: storeRoot, downloader: download,
                                          clock: FixedClock(Date(timeIntervalSince1970: 0)),
                                          descriptors: [descriptor([file("first.bin"), file("second.bin", git: true)])],
                                          monotonic: clock)
        try require(!FileManager.default.fileExists(atPath: storeRoot.path), "initialization wrote files")
        try require(await store.isInstalled(.live) == false, "missing model marked ready")
        do { _ = try await store.verifiedDirectory(for: .live); throw FixtureError.interrupted }
        catch is MeetingLocalModelError {}
        try require(await download.count() == 0, "inference availability downloaded")
        print("PASS initialization and missing-model verification are offline")

        await download.configure(failSecond: true, clock: clock)
        do { try await store.prepare(.live) { _ in }; throw FixtureError.interrupted }
        catch FixtureError.interrupted {}
        try require(await store.isInstalled(.live) == false, "partial install marked ready")
        try require(await download.count() == 2, "expected interrupted second file")
        try await store.prepare(.live) { [collector] value in collector.record(value) }
        try require(await download.count() == 3, "retry redownloaded verified first file")
        let installed = try await store.verifiedDirectory(for: .live)
        try require(await store.isInstalled(.live), "completed install missing")
        let receipt = try JSONDecoder().decode(MeetingLocalModelStore.Receipt.self,
                                               from: Data(contentsOf: installed.appendingPathComponent("installation.json")))
        try require(receipt.files.count == 2 && receipt.files.allSatisfy { $0.sha256 == sha }, "receipt hashes not recorded")
        try require(receipt.installedAt == Date(timeIntervalSince1970: 0), "clock injection ignored")
        try require(receipt.files.map(\.path) == ["model/first.bin", "model/second.bin"], "receipt file order changed")
        let total = Int64(data.count) * 2
        let emitted = collector.all
        try require(emitted.last?.completedBytes == total, "final progress did not reach total bytes")
        try require(emitted.allSatisfy { $0.completedBytes <= total }, "progress exceeded total bytes")
        try require(emitted.contains { ($0.bytesPerSecond ?? 0) > 0 }, "no throughput progress emitted")
        print("PASS interrupted install, resume, aggregated progress with throughput, SHA256/Git-blob integrity and provenance receipt")

        let resumeDownload = FakeDownloader(data: data)
        let resumeDescriptor = descriptor([file("first.bin"), file("second.bin", git: true), file("third.bin")])
        let resumeRoot = root.appendingPathComponent("resume")
        let resumeStore = MeetingLocalModelStore(root: resumeRoot, downloader: resumeDownload, descriptors: [resumeDescriptor])
        let resumeStaging = resumeRoot.appendingPathComponent(".partial-\(resumeDescriptor.directoryName)", isDirectory: true)
        let resumeModelDirectory = resumeStaging.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: resumeModelDirectory, withIntermediateDirectories: true)
        let resumeBytes = Int64(data.count / 2)
        try data.subdata(in: 0..<Int(resumeBytes)).write(to: resumeModelDirectory.appendingPathComponent("first.bin.part"))
        try data.write(to: resumeModelDirectory.appendingPathComponent("second.bin"))
        try data.write(to: resumeModelDirectory.appendingPathComponent("second.bin.part"))
        // Fully written partial left by an interruption between the last write and the move.
        try data.write(to: resumeModelDirectory.appendingPathComponent("third.bin.part"))
        try await resumeStore.prepare(.live) { _ in }
        try require(await resumeDownload.count() == 1, "resume prepare downloaded the already-verified file")
        try require(await resumeDownload.observedBytes(for: "model/first.bin") == resumeBytes,
                    "resume did not start from the pre-created partial bytes")
        try require(await resumeDownload.observedBytes(for: "model/second.bin") == nil, "verified file was downloaded again")
        try require(await resumeDownload.observedBytes(for: "model/third.bin") == nil, "complete partial file was downloaded again")
        let resumeInstalled = try await resumeStore.verifiedDirectory(for: .live)
        try require(!containsPartFile(resumeInstalled), "stale .part file survived the final move")
        print("PASS partial-file resume appends from existing bytes, complete partials skip download, stale .part files are cleaned")

        let concurrentDownload = FakeDownloader(data: data)
        await concurrentDownload.configure(holdNanos: 50_000_000)
        let concurrentStore = MeetingLocalModelStore(root: root.appendingPathComponent("concurrent"), downloader: concurrentDownload,
                                                    descriptors: [descriptor([file("a.bin"), file("b.bin"), file("c.bin")])])
        try await concurrentStore.prepare(.live) { _ in }
        let peak = await concurrentDownload.peakConcurrent()
        try require(peak > 1, "downloads did not overlap (peak in flight \(peak))")
        _ = try await concurrentStore.verifiedDirectory(for: .live)
        print("PASS parallel prepare downloads overlap (peak in flight \(peak))")

        try await store.prepare(.live) { _ in }
        try require(await download.count() == 3, "prepared model downloaded again")
        var changed = data; changed[0] ^= 1
        try changed.write(to: installed.appendingPathComponent("model/first.bin"))
        do { _ = try await store.verifiedDirectory(for: .live); throw FixtureError.interrupted }
        catch is MeetingLocalModelError {}
        try require(await download.count() == 3, "corrupt inference verification downloaded")
        print("PASS prepared model reuse and corrupt model fail closed without network")

        let cancelDownload = FakeDownloader(data: data)
        await cancelDownload.configure(holdNanos: 30_000_000_000)
        let cancelStore = MeetingLocalModelStore(root: root.appendingPathComponent("cancel"), downloader: cancelDownload,
                                                descriptors: [descriptor([file("first.bin")])])
        let operation = Task { try await cancelStore.prepare(.live) { _ in } }
        var waited = 0
        while await cancelDownload.count() == 0 {
            waited += 1
            try require(waited < 5_000, "cancellable download never started")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        operation.cancel()
        do { try await operation.value; throw FixtureError.interrupted } catch is CancellationError {}
        try require(await cancelStore.isInstalled(.live) == false, "cancelled install marked ready")
        await cancelDownload.configure()
        try await cancelStore.prepare(.live) { _ in }
        _ = try await cancelStore.verifiedDirectory(for: .live)
        print("PASS cancellation and explicit retry")

        for model in MeetingModelRegistry.models {
            try require(!model.files.isEmpty && model.bytes > 0, "empty registry")
            try require(model.revision.count == 40, "mutable model revision")
            try require(Set(model.files.map(\.localPath)).count == model.files.count, "duplicate model path")
            for file in model.files {
                try require(file.revision.count == 40 && !file.localPath.contains(".."), "unpinned or unsafe registry path")
                try require(file.digest.count == (file.digestKind == "sha256" ? 64 : 40), "invalid registry digest")
                try require(file.downloadURL.scheme == "https", "non-HTTPS registry URL")
            }
        }
        print("PASS pinned public registry structure (no model asset downloads)")
    }
}
