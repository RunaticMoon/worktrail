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
    /// Downloads public model bytes only, into a temporary file owned by the caller.
    func download(_ file: MeetingModelFile, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL
}

final class MeetingModelHTTPDownloader: MeetingModelDownloading, @unchecked Sendable {
    func download(_ file: MeetingModelFile, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3_600
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let delegate = DownloadDelegate(expectedBytes: file.bytes, progress: progress)
        let url: URL
        let response: URLResponse
        do {
            (url, response) = try await session.download(from: file.downloadURL, delegate: delegate)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: url)
            throw MeetingLocalModelError.downloadFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        do { try Task.checkCancellation() } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let expectedBytes: Int64
        let progress: @Sendable (Int64) -> Void
        init(expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) {
            self.expectedBytes = expectedBytes; self.progress = progress
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesWritten > expectedBytes { downloadTask.cancel() }
            progress(min(expectedBytes, totalBytesWritten))
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url?.scheme == "https" ? request : nil)
        }
    }
}

/// All network access is confined to explicit prepare(). Inference only calls verifiedDirectory().
/// Files are immutable by revision; partial downloads never receive an installation receipt.
actor MeetingLocalModelStore {
    private let root: URL
    private let downloader: any MeetingModelDownloading
    private let clock: any WorkLogCore.Clock
    private let descriptors: [MeetingModelDescriptor]
    private var preparing = false

    struct InstalledFile: Codable { var path: String; var sha256: String; var bytes: Int64 }
    struct Receipt: Codable {
        var modelID: String; var revision: String; var sdkVersion: String; var installedAt: Date
        var license: String; var attribution: String; var sources: [MeetingModelFile]; var files: [InstalledFile]
    }

    init(root: URL, downloader: any MeetingModelDownloading = MeetingModelHTTPDownloader(),
         clock: any WorkLogCore.Clock = SystemClock(), descriptors: [MeetingModelDescriptor] = MeetingModelRegistry.models) {
        self.root = root; self.downloader = downloader; self.clock = clock; self.descriptors = descriptors
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
        var completed: Int64 = 0
        var installedFiles: [InstalledFile] = []
        for file in descriptor.files {
            try Task.checkCancellation()
            let destination = try safeFile(file.localPath, in: staging)
            if (try? verify(file, in: staging)) == nil {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let before = completed
                let temporary = try await downloader.download(file) { count in
                    progress(.init(completedBytes: before + count, totalBytes: descriptor.bytes, message: "모델 다운로드 중…"))
                }
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            let checksum = try verify(file, in: staging)
            installedFiles.append(.init(path: file.localPath, sha256: checksum, bytes: file.bytes))
            completed += file.bytes
            progress(.init(completedBytes: completed, totalBytes: descriptor.bytes, message: "다운로드 및 무결성 확인 중…"))
        }
        try Task.checkCancellation()
        let receipt = Receipt(modelID: descriptor.modelID, revision: descriptor.revision, sdkVersion: "1.1.1",
                              installedAt: clock.now(), license: descriptor.license, attribution: descriptor.attribution,
                              sources: descriptor.files, files: installedFiles)
        try JSONEncoder().encode(receipt).write(to: staging.appendingPathComponent("installation.json"), options: .atomic)
        let destination = root.appendingPathComponent(descriptor.directoryName, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: staging, to: destination)
        progress(.init(completedBytes: descriptor.bytes, totalBytes: descriptor.bytes, message: "모델 준비됨 · 음성은 이 Mac에서 처리됩니다."))
    }

    private func readReceipt(in directory: URL) throws -> Receipt {
        let url = try safeFile("installation.json", in: directory)
        return try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url))
    }

    private func safeFile(_ path: String, in directory: URL) throws -> URL {
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

    private func verify(_ file: MeetingModelFile, in directory: URL) throws -> String {
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
            message = "\(role.label) 준비됨 · 음성은 이 Mac에서 처리됩니다."
        } catch {
            message = error is CancellationError ? "모델 준비를 취소했습니다. 검증된 파일은 재시도에 사용합니다." : error.localizedDescription
            throw error
        }
    }

    func cancel() { task?.cancel() }
}
#endif
