import Foundation

/// Local evidence decisions are available without an AI provider or network.
public final class MemoEvidenceLinkService {
    private let repo: WorkRepository
    public init(repo: WorkRepository) { self.repo = repo }

    @discardableResult public func connect(memoId: String, taskId: String) throws -> MemoTaskLink {
        try repo.db.transaction {
            guard let memo = try repo.memo(id: memoId), try repo.task(id: taskId) != nil else {
                throw WorkLogError.notFound("메모 또는 업무")
            }
            if let existing = try repo.memoTaskLinks(memoId: memoId).first(where: { $0.taskId == taskId }) {
                return try decide(linkId: existing.id, status: .accepted)
            }
            let link = MemoTaskLink(id: repo.ids.make(), memoId: memoId, taskId: taskId,
                status: .accepted, reason: "사용자가 보고서 근거로 연결", sourceRevision: memo.revision,
                createdAt: repo.clock.now(), decidedAt: repo.clock.now())
            try repo.upsertMemoTaskLink(link)
            return link
        }
    }

    @discardableResult public func decide(linkId: String, status: MemoTaskLinkStatus) throws -> MemoTaskLink {
        guard status != .proposed else { throw WorkLogError.validation("제안 상태로 되돌릴 수 없습니다.") }
        return try repo.db.transaction {
            guard let row = try repo.db.queryOneV("SELECT memo_id FROM memo_task_link WHERE id = ?", linkId),
                  let memoId = row.string("memo_id"), let memo = try repo.memo(id: memoId),
                  var link = try repo.memoTaskLinks(memoId: memoId).first(where: { $0.id == linkId }) else {
                throw WorkLogError.notFound("근거 연결")
            }
            if status == .accepted {
                guard try repo.task(id: link.taskId) != nil else { throw WorkLogError.notFound("업무") }
                link.sourceRevision = memo.revision
            }
            link.status = status
            link.decidedAt = repo.clock.now()
            try repo.upsertMemoTaskLink(link)
            return link
        }
    }
}
