import Foundation
import Crypto

/// Only the two ordinary capture drafts can be represented. No Secret type or payload is accepted.
public struct CaptureDraftCheckpoint: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    /// Optional for checkpoints written before durable submission receipts existed.
    public var draftID: String? = nil
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

/// Receipts and their successor drafts contain ordinary capture values only.
/// The caller records the receipt in the same transaction as the captured record.
struct CaptureDraftReceipts {
    let repo: WorkRepository

    func identified(_ checkpoint: CaptureDraftCheckpoint, kind: RecordCaptureKind) throws -> CaptureDraftCheckpoint {
        guard checkpoint.schemaVersion == 1 else { throw WorkLogError.storage("지원하지 않는 초안 형식입니다.") }
        var value = checkpoint
        if value.draftID == nil {
            // A legacy file may survive a failed cleanup repeatedly. Its identity must
            // remain stable even when the upgraded checkpoint cannot be written back.
            let digest = SHA256.hash(data: try StableJSON.encode(value)).map { String(format: "%02x", $0) }.joined()
            value.draftID = "legacy-\(kind.rawValue)-\(digest)"
        }
        guard let id = value.draftID, !id.isEmpty else { throw WorkLogError.storage("초안 식별자가 올바르지 않습니다.") }
        return value
    }

    func contains(_ draftID: String) throws -> Bool {
        try repo.db.queryOne("SELECT draft_id FROM capture_draft_receipt WHERE draft_id=?", [draftID]) != nil
    }

    func record(_ draftID: String, remaining: CaptureDraftCheckpoint?) throws {
        let json = try remaining.map { String(decoding: try StableJSON.encode($0), as: UTF8.self) }
        try repo.db.run("INSERT INTO capture_draft_receipt(draft_id,saved_at,remaining_checkpoint_json) VALUES(?,?,?)",
                        [draftID, repo.clock.now(), json])
    }

    /// Follow submitted state changes to any unused text that still needs recovery.
    /// A corrupt cycle or excessive chain never replays a submitted action.
    func resolve(_ checkpoint: CaptureDraftCheckpoint, kind: RecordCaptureKind) throws -> CaptureDraftCheckpoint? {
        var value = checkpoint
        var visited: Set<String> = []
        for _ in 0..<128 {
            value = try identified(value, kind: kind)
            let id = value.draftID!
            guard visited.insert(id).inserted else { throw WorkLogError.storage("초안 복구 이력이 순환합니다.") }
            guard let receipt = try repo.db.queryOne("SELECT remaining_checkpoint_json FROM capture_draft_receipt WHERE draft_id=?", [id]) else { return value }
            if receipt["remaining_checkpoint_json"] == .null { return nil }
            guard let json = receipt.string("remaining_checkpoint_json") else {
                throw WorkLogError.storage("초안 복구 이력을 읽을 수 없습니다.")
            }
            value = try StableJSON.decode(CaptureDraftCheckpoint.self, from: Data(json.utf8))
        }
        throw WorkLogError.storage("초안 복구 이력이 너무 깁니다.")
    }
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
