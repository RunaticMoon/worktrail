import CryptoKit
import Foundation
import WorkLogCore

private enum FixtureError: Error { case interrupted }
private actor FakeDownloader: MeetingModelDownloading {
    let directory: URL
    let data: Data
    var calls = 0
    var failSecond = false
    var hold = false
    init(directory: URL, data: Data) { self.directory = directory; self.data = data }
    func configure(failSecond: Bool = false, hold: Bool = false) { self.failSecond = failSecond; self.hold = hold }
    func count() -> Int { calls }
    func download(_ file: MeetingModelFile, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        calls += 1
        if hold { try await Task.sleep(nanoseconds: 30_000_000_000) }
        if failSecond && file.localPath.hasSuffix("second.bin") { failSecond = false; throw FixtureError.interrupted }
        let temporary = directory.appendingPathComponent("download-\(calls)")
        try data.write(to: temporary)
        progress(Int64(data.count))
        return temporary
    }
}

@main struct ModelChecks {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "ModelChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
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
        let download = FakeDownloader(directory: root, data: data)
        let storeRoot = root.appendingPathComponent("models")
        let store = MeetingLocalModelStore(root: storeRoot, downloader: download,
                                          clock: FixedClock(Date(timeIntervalSince1970: 0)),
                                          descriptors: [descriptor([file("first.bin"), file("second.bin", git: true)])])
        try require(!FileManager.default.fileExists(atPath: storeRoot.path), "initialization wrote files")
        try require(await store.isInstalled(.live) == false, "missing model marked ready")
        do { _ = try await store.verifiedDirectory(for: .live); throw FixtureError.interrupted }
        catch is MeetingLocalModelError {}
        try require(await download.count() == 0, "inference availability downloaded")
        print("PASS initialization and missing-model verification are offline")

        await download.configure(failSecond: true)
        do { try await store.prepare(.live) { _ in }; throw FixtureError.interrupted }
        catch FixtureError.interrupted {}
        try require(await store.isInstalled(.live) == false, "partial install marked ready")
        try require(await download.count() == 2, "expected interrupted second file")
        try await store.prepare(.live) { _ in }
        try require(await download.count() == 3, "retry redownloaded verified first file")
        let installed = try await store.verifiedDirectory(for: .live)
        try require(await store.isInstalled(.live), "completed install missing")
        let receipt = try JSONDecoder().decode(MeetingLocalModelStore.Receipt.self,
                                               from: Data(contentsOf: installed.appendingPathComponent("installation.json")))
        try require(receipt.files.count == 2 && receipt.files.allSatisfy { $0.sha256 == sha }, "receipt hashes not recorded")
        try require(receipt.installedAt == Date(timeIntervalSince1970: 0), "clock injection ignored")
        print("PASS interrupted install, resume, SHA256/Git-blob integrity and provenance receipt")

        try await store.prepare(.live) { _ in }
        try require(await download.count() == 3, "prepared model downloaded again")
        var changed = data; changed[0] ^= 1
        try changed.write(to: installed.appendingPathComponent("model/first.bin"))
        do { _ = try await store.verifiedDirectory(for: .live); throw FixtureError.interrupted }
        catch is MeetingLocalModelError {}
        try require(await download.count() == 3, "corrupt inference verification downloaded")
        print("PASS prepared model reuse and corrupt model fail closed without network")

        let cancelDownload = FakeDownloader(directory: root, data: data)
        await cancelDownload.configure(hold: true)
        let cancelStore = MeetingLocalModelStore(root: root.appendingPathComponent("cancel"), downloader: cancelDownload,
                                                descriptors: [descriptor([file("first.bin")])])
        let operation = Task { try await cancelStore.prepare(.live) { _ in } }
        while await cancelDownload.count() == 0 { await Task.yield() }
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
