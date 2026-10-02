import Foundation

/// 일반 기록(메모·새 업무·진행 기록) 생성과 수동 관련 링크(`record_link`)를
/// 하나의 DB 트랜잭션으로 저장하는 요청.
///
/// - 각 case는 기존 `TaskService`의 해당 메서드 인자를 빠짐없이 표현한다.
///   · `.memo`   → `TaskService.captureMemo(body:workDate:projectNames:tagNames:)`
///   · `.task`   → `TaskService.createTask(title:initialStatus:workDate:effectiveTime:dueOn:projectNames:trackingMode:tagNames:checklist:note:links:)`
///     여기서 `body`는 `createTask`의 `note`(제목 이후 본문)에 대응한다.
///   · `.activity` → `TaskService.addActivity(taskId:body:workDate:effectiveTime:projectIds:checklistItemIds:kind:links:)`
/// - Secret과 상태 변경(transition)·AI는 포함하지 않는다.
public enum OrdinaryCaptureRequest: Sendable {
    case memo(body: String,
              workDate: WorkDate?,
              projectNames: [String],
              tagNames: [String])

    case task(title: String,
              body: String?,
              initialStatus: TaskStatus,
              workDate: WorkDate?,
              effectiveTime: Date?,
              dueOn: WorkDate?,
              projectNames: [String],
              trackingMode: ProjectTrackingMode,
              tagNames: [String],
              checklist: [String],
              links: [String])

    case activity(taskId: String,
                  body: String,
                  workDate: WorkDate?,
                  effectiveTime: Date?,
                  projectIds: [String],
                  checklistItemIds: [String],
                  kind: ActivityKind,
                  links: [String])
}

/// 일반 기록 생성 + 수동 관련 링크 저장을 하나의 트랜잭션으로 묶는 서비스.
///
/// - 원본 생성은 `TaskService`에 위임한다. `TaskService`가 여는 트랜잭션은 이 서비스의
///   바깥 트랜잭션 안에서 SAVEPOINT로 중첩된다(`SQLiteDatabase.transaction`).
/// - `related`가 비어 있으면 원본만 저장한다.
/// - `related`에서 생성된 레코드 자신과 중복 참조는 제거한다.
/// - 링크 대상이 없으면 원본·FTS(`search_doc`)·링크가 모두 롤백된 뒤 throw한다(자기 참조는 위처럼 제거 후 저장).
/// - Secret(Vault) 데이터는 다루지 않으며 work.sqlite의 일반 기록만 저장한다.
public final class LinkedCaptureService: @unchecked Sendable {
    private let repo: WorkRepository
    private let tasks: TaskService
    private let linkStore: RecordLinkStore

    public init(repo: WorkRepository, tasks: TaskService) {
        self.repo = repo
        self.tasks = tasks
        self.linkStore = RecordLinkStore(repo: repo)
    }

    /// 원본을 만들고 수동 관련 링크를 같은 트랜잭션에 저장한다.
    ///
    /// - Returns: 생성된 원본의 `RecordReference`.
    /// - Throws: 원본 생성 검증 실패, 링크 대상 없음 등. 이때 원본·FTS·링크는 남지 않는다.
    @discardableResult
    public func create(_ request: OrdinaryCaptureRequest,
                       related: [RecordReference]) throws -> RecordReference {
        try repo.db.transaction {
            let reference: RecordReference
            switch request {
            case let .memo(body, workDate, projectNames, tagNames):
                let memo = try tasks.captureMemo(body: body, workDate: workDate,
                                                 projectNames: projectNames, tagNames: tagNames)
                reference = RecordReference(kind: .memo, id: memo.id)

            case let .task(title, body, initialStatus, workDate, effectiveTime, dueOn,
                           projectNames, trackingMode, tagNames, checklist, links):
                let task = try tasks.createTask(title: title, initialStatus: initialStatus,
                                                workDate: workDate, effectiveTime: effectiveTime,
                                                dueOn: dueOn, projectNames: projectNames,
                                                trackingMode: trackingMode, tagNames: tagNames,
                                                checklist: checklist, note: body, links: links)
                reference = RecordReference(kind: .task, id: task.id)

            case let .activity(taskId, body, workDate, effectiveTime, projectIds,
                               checklistItemIds, kind, links):
                let activity = try tasks.addActivity(taskId: taskId, body: body, workDate: workDate,
                                                     effectiveTime: effectiveTime,
                                                     projectIds: projectIds,
                                                     checklistItemIds: checklistItemIds,
                                                     kind: kind, links: links)
                reference = RecordReference(kind: .activity, id: activity.id)
            }

            let targets = normalizedTargets(related, excluding: reference)
            if !targets.isEmpty {
                _ = try linkStore.add(from: reference, to: targets)
            }
            return reference
        }
    }

    /// 자기 자신과 중복을 입력 순서를 보존하며 제거한다.
    private func normalizedTargets(_ related: [RecordReference],
                                   excluding reference: RecordReference) -> [RecordReference] {
        var seen = Set<RecordReference>()
        var result: [RecordReference] = []
        for target in related where target != reference && seen.insert(target).inserted {
            result.append(target)
        }
        return result
    }
}
