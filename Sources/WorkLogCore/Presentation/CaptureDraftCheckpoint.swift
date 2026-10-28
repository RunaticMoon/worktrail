import Foundation

/// Only the two ordinary capture drafts can be represented. No Secret type or payload is accepted.
public struct CaptureDraftCheckpoint: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var text: String
    public var workDate: WorkDate
    public var dueOn: WorkDate?
    public var dueReminderDaysBefore: Int?
    public var targetTaskId: String?
    public var initialStatus: TaskStatus
    public var projectTrackingMode: ProjectTrackingMode
    public var taskQuery: String
    public var existingTaskId: String?
    public var changesStatus: Bool
    public var statusTarget: TaskStatus?
    public var relatedRecords: [RelatedRecordCandidate]
    public var selectedProjectIds: [String]
    public var selectedTagIds: [String]
}

public final class CaptureDraftStore {
    private let directory: URL
    private let ids: IDGenerator
    public init(directory: URL, ids: IDGenerator = UUIDGenerator()) { self.directory = directory; self.ids = ids }

    private func file(_ kind: RecordCaptureKind) throws -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw WorkLogError.storage("일반 초안 저장 폴더를 사용할 수 없습니다.")
        }
        guard kind == .memo || kind == .task else { throw WorkLogError.validation("일반 초안 유형을 확인하세요.") }
        return directory.appendingPathComponent("\(kind.rawValue).json")
    }
    public func load(_ kind: RecordCaptureKind) throws -> CaptureDraftCheckpoint? {
        let url = try file(kind)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try StableJSON.decode(CaptureDraftCheckpoint.self, from: Data(contentsOf: url))
        guard value.schemaVersion == 1 else { throw WorkLogError.storage("지원하지 않는 초안 형식입니다.") }
        return value
    }
    public func save(_ checkpoint: CaptureDraftCheckpoint?, kind: RecordCaptureKind) throws {
        let url = try file(kind)
        let fm = FileManager.default
        guard let checkpoint else {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            return
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".\(kind.rawValue)-\(ids.make()).tmp")
        let data = try StableJSON.encode(checkpoint)
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw WorkLogError.storage("초안 임시 파일을 만들지 못했습니다.")
        }
        defer { try? fm.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize(); try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw WorkLogError.storage("초안을 교체하지 못했습니다.") }
    }
}
