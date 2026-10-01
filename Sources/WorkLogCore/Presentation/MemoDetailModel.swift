import Foundation
import Observation

/// User-triggered Memo/Task proposals, separate from record capture and day loading.
@Observable @MainActor public final class MemoDetailModel {
    public private(set) var memo: Memo?
    public private(set) var links: [MemoTaskLink] = []
    public private(set) var tasks: [WorkTask] = []
    public private(set) var isSuggesting = false
    public private(set) var message: String?
    public var isAIAvailable: Bool { environment.memoLinks != nil }
    @ObservationIgnored private let environment: AppEnvironment
    public init(environment: AppEnvironment) { self.environment = environment }
    public func load(id: String) {
        do {
            memo = try environment.repo.memo(id: id)
            links = try environment.repo.memoTaskLinks(memoId: id)
            tasks = try environment.repo.tasks()
            message = memo == nil ? "메모를 찾을 수 없습니다." : nil
        } catch { memo = nil; links = []; message = "메모를 불러오지 못했습니다." }
    }
    public func suggest() async {
        guard !isSuggesting, let id = memo?.id else { return }
        guard let service = environment.memoLinks else { message = "AI 연결 제안이 비활성화되어 있습니다."; return }
        isSuggesting = true; message = nil
        defer { isSuggesting = false }
        do {
            let result = try await service.suggest(memoId: id)
            guard memo?.id == id else { return }
            load(id: id)
            switch result.jobStatus {
            case .blockedAuth: message = "AI 인증을 확인한 뒤 연결 제안을 다시 요청하세요."
            case .blockedPolicy: message = "회사 정책에 따라 연결 제안 요청이 차단되었습니다."
            case .cancelled: message = "연결 제안 요청이 취소되었습니다."
            case .succeeded:
                if !result.warnings.isEmpty { message = result.warnings.joined(separator: "\n") }
                else if result.links.isEmpty { message = "새로운 연결 제안이 없습니다." }
            default: message = "연결 제안을 만들지 못했습니다. AI 연결 상태를 확인하세요."
            }
        } catch { if memo?.id == id { message = "연결 제안을 불러오지 못했습니다. 다시 요청하세요." } }
    }
    public func decide(linkId: String, status: MemoTaskLinkStatus) {
        guard let service = environment.memoLinks, let id = memo?.id else { return }
        do { _ = try service.decide(linkId: linkId, status: status); load(id: id) }
        catch { message = "연결 결정을 저장하지 못했습니다. 다시 시도하세요." }
    }
}
