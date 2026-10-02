import Foundation
import Observation

public enum RecordCaptureKind: String, CaseIterable, Sendable {
    case memo, task, activity
    public var label: String {
        switch self { case .memo: return "메모"; case .task: return "업무"; case .activity: return "진행 기록" }
    }
}

public struct CaptureCandidate: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case project, tag }
    public let id: String
    public let name: String
    public let kind: Kind
    public var isNew: Bool = false
}

/// 업무 탭에서 대상으로 삼을 업무: 새 업무 생성 또는 기존 업무.
public enum CaptureTaskSelection: Equatable, Sendable {
    case newTask
    case existing(String)
}

/// 기존 업무에 수행할 동작. 두 동작을 한 번에 수행하지 않는다.
public enum CaptureTaskAction: Equatable, Sendable {
    case addActivity
    case changeStatus
}

/// Ordinary record draft only. No Secret, network or AI path.
@Observable @MainActor public final class CaptureModel {
    public var text = "" { didSet { selectionRange = nil } }
    /// UTF-16 selection from the native editor; nil uses existing-name prefix matching.
    public var selectionRange: NSRange?
    public var kind: RecordCaptureKind = .memo
    public var workDate: WorkDate
    public var targetTaskId: String?
    public var initialStatus: TaskStatus = .planned
    public var projectTrackingMode: ProjectTrackingMode = .shared

    /// 업무 탭 검색어. 제목 부분 일치(대소문자 무시).
    public var taskQuery: String = ""
    /// 업무 탭 대상: 새 업무 또는 기존 업무 id.
    public var taskSelection: CaptureTaskSelection = .newTask
    /// 기존 업무에 수행할 동작: 진행기록 추가 또는 상태 변경.
    public var taskAction: CaptureTaskAction = .addActivity
    /// `taskAction == .changeStatus`일 때 목표 상태.
    public var statusTarget: TaskStatus?
    /// 완료 시 남은 체크리스트·프로젝트 확인이 필요하면 `completeTask`가 돌려준 값.
    public private(set) var pendingCompletion: CompletionCheck?
    /// 생성·진행기록과 함께 수동 관련 링크로 저장할 후보. 상태 변경에는 쓰지 않는다.
    public var relatedRecords: [RelatedRecordCandidate] = []

    public private(set) var projects: [Project] = []
    public private(set) var tags: [Tag] = []
    public private(set) var tasks: [WorkTask] = []
    public private(set) var selectedProjectIds: [String] = []
    public private(set) var selectedTagIds: [String] = []
    public private(set) var errorMessage: String?
    public private(set) var isSubmitting = false
    public private(set) var lastSavedId: String?
    /// Deprecated: 설정 기본값으로 일반 제출을 막던 정책은 제거됐다. 활성 탭 판단은 입력 세션이 담당한다.
    public var requiresSecretEditor: Bool { environment.settings.defaultCaptureKind == .secret }
    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private let linkedCapture: LinkedCaptureService
    @ObservationIgnored private let linkStore: RecordLinkStore
    /// 완료 확인 재시도 대상 업무 id. `pendingCompletion`과 함께만 유효하다.
    @ObservationIgnored private var pendingCompletionTaskId: String?

    public init(environment: AppEnvironment) {
        self.environment = environment
        linkedCapture = LinkedCaptureService(repo: environment.repo, tasks: environment.tasks)
        linkStore = RecordLinkStore(repo: environment.repo)
        workDate = environment.calendar.workDate(of: environment.options.clock.now())
        resetDefaults()
        reloadCandidates()
    }

    /// Applied only to a fresh draft; opening an existing draft preserves it.
    public func resetDefaults() {
        if !requiresSecretEditor {
            kind = environment.settings.defaultCaptureKind == .task ? .task : .memo
        }
        workDate = environment.calendar.workDate(of: environment.options.clock.now())
    }

    public func reloadCandidates() {
        do {
            projects = try environment.repo.projects()
            tags = try environment.repo.tags()
            tasks = try environment.repo.tasks()
            errorMessage = nil
        } catch { errorMessage = "입력 후보를 불러오지 못했습니다. 다시 열어 주세요." }
    }

    private var token: (kind: CaptureCandidate.Kind, range: Range<String.Index>, query: String)? {
        let cursor = selectionRange.flatMap { Range($0, in: text)?.lowerBound }
        let end = cursor ?? text.endIndex
        guard let marker = text[..<end].lastIndex(where: { $0 == "@" || $0 == "#" }) else { return nil }
        if marker != text.startIndex && !text[text.index(before: marker)].isWhitespace { return nil }
        let start = text.index(after: marker)
        let suffix = String(text[start..<end])
        guard !suffix.contains(where: \.isNewline) else { return nil }
        let tokenKind: CaptureCandidate.Kind = text[marker] == "@" ? .project : .tag
        let names = tokenKind == .project ? projects.map(\.name) : tags.map(\.name)
        var query = suffix
        if cursor == nil && !names.contains(where: { $0.lowercased().hasPrefix(suffix.lowercased()) }) {
            // Without a caret, stop at the longest prefix shared with an existing name.
            // This permits spaces in names without swallowing the following prose.
            let matched = names.filter { name in
                guard suffix.lowercased().hasPrefix(name.lowercased()) else { return false }
                let rest = suffix.dropFirst(name.count)
                return rest.isEmpty || rest.first?.isWhitespace == true
            }.max { $0.count < $1.count }
            if let matched { query = String(suffix.prefix(matched.count)) }
        }
        return (tokenKind, marker..<text.index(start, offsetBy: query.count), query)
    }

    public var candidates: [CaptureCandidate] {
        guard let token else { return [] }
        let all: [CaptureCandidate]
        switch token.kind {
        case .project:
            let linkedIds: [String]?
            if kind == .activity {
                linkedIds = targetTaskId.flatMap { try? environment.repo.taskProjects(taskId: $0).map(\.projectId) } ?? []
            } else { linkedIds = nil }
            all = projects.filter { !selectedProjectIds.contains($0.id) && (linkedIds?.contains($0.id) ?? true) }
                .map { CaptureCandidate(id: $0.id, name: $0.name, kind: .project) }
        case .tag:
            guard kind != .activity else { return [] }
            all = tags.filter { !selectedTagIds.contains($0.id) }
                .map { CaptureCandidate(id: $0.id, name: $0.name, kind: .tag) }
        }
        var matches = Array(all.filter { $0.name.lowercased().hasPrefix(token.query.lowercased()) }.prefix(8))
        let name = token.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let exists = token.kind == .project ? projects.contains { $0.name == name } : tags.contains { $0.name == name }
        let hasExistingPrefix = (token.kind == .project ? projects.map(\.name) : tags.map(\.name))
            .contains { $0.lowercased().hasPrefix(name.lowercased()) }
        if !name.isEmpty && !exists && !hasExistingPrefix && kind != .activity {
            matches.append(CaptureCandidate(id: "new:\(token.kind):\(name)", name: name, kind: token.kind, isNew: true))
        }
        return matches
    }

    /// Selection is stored by ID; replace only the query and preserve surrounding prose.
    public func select(_ candidate: CaptureCandidate) {
        guard candidates.contains(candidate), let token else { return }
        do {
            switch candidate.kind {
            case .project:
                let id = candidate.isNew ? try environment.repo.findOrCreateProject(name: candidate.name).id : candidate.id
                selectedProjectIds.append(id)
            case .tag:
                let id = candidate.isNew ? try environment.repo.findOrCreateTag(name: candidate.name).id : candidate.id
                selectedTagIds.append(id)
            }
        } catch {
            errorMessage = "프로젝트·태그를 선택하지 못했습니다. 다시 시도하세요."; return
        }
        let replacement = candidate.name + (token.range.upperBound == text.endIndex ? " " : "")
        let caret = NSRange(token.range, in: text).location + replacement.utf16.count
        text.replaceSubrange(token.range, with: replacement)
        selectionRange = NSRange(location: caret, length: 0)
        reloadCandidates()
    }

    public func removeProject(_ id: String) { selectedProjectIds.removeAll { $0 == id } }
    public func removeTag(_ id: String) { selectedTagIds.removeAll { $0 == id } }

    // MARK: - 업무 검색·선택

    /// 업무 탭 목록. 제목 대소문자 무시 포함 검색, 삭제 제외,
    /// 미완료(진행·계획·보류 등) 우선 → 최근 생성 순, 최대 50개.
    public var filteredTasks: [WorkTask] {
        let query = taskQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return tasks
            .filter { query.isEmpty || $0.title.lowercased().contains(query) }
            .sorted { lhs, rhs in
                let lhsUnfinished = Self.isUnfinished(lhs)
                let rhsUnfinished = Self.isUnfinished(rhs)
                if lhsUnfinished != rhsUnfinished { return lhsUnfinished }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id < rhs.id
            }
            .prefix(50)
            .map { $0 }
    }

    /// 선택된 기존 업무의 현재 상태에서 허용되는 전이 목표(현재 상태 제외). 선택이 없으면 빈 배열.
    public func availableStatusTargets() -> [TaskStatus] {
        guard case let .existing(id) = taskSelection,
              let current = try? environment.tasks.currentStatus(taskId: id) else { return [] }
        return TaskStatus.allCases.filter { target in
            target != current && Self.transitionKind(from: current, to: target) != nil
        }
    }

    /// 수동 관련 링크 후보를 검색한다. 이미 선택한 후보와 현재 대상 업무는 제외한다.
    public func searchRelated(_ query: String) throws -> [RelatedRecordCandidate] {
        var excluding = Set(relatedRecords.map(\.reference))
        if case let .existing(id) = taskSelection {
            excluding.insert(RecordReference(kind: .task, id: id))
        }
        return try linkStore.candidates(query: query, excluding: excluding, limit: 20)
    }

    /// 완료 확인이 필요한 경우 `confirmRemaining: true`로 재시도한다. 성공하면 true.
    @discardableResult public func confirmCompletion() -> Bool {
        guard let taskId = pendingCompletionTaskId, pendingCompletion != nil else { return false }
        guard !isSubmitting else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            _ = try environment.tasks.completeTask(taskId: taskId, workDate: workDate, confirmRemaining: true)
            pendingCompletion = nil
            pendingCompletionTaskId = nil
            taskSelection = .newTask
            statusTarget = nil
            errorMessage = nil
            reloadCandidates()
            return true
        } catch {
            errorMessage = "업무를 완료하지 못했습니다. 대상 업무를 확인하세요."
            return false
        }
    }

    /// 완료 확인을 취소한다. 초안·선택은 지우지 않는다.
    public func cancelCompletion() {
        pendingCompletion = nil
        pendingCompletionTaskId = nil
    }

    // MARK: - 저장

    @discardableResult public func submit() -> Bool {
        guard !isSubmitting else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            switch kind {
            case .memo:
                guard hasBody else { errorMessage = "저장할 내용을 입력하세요."; return false }
                let (names, tagNames) = try resolveProjectAndTagNames()
                let reference = try linkedCapture.create(
                    .memo(body: text, workDate: workDate, projectNames: names, tagNames: tagNames),
                    related: relatedRecords.map(\.reference))
                lastSavedId = reference.id
                finishOrdinarySubmit()
                return true

            case .task:
                switch taskSelection {
                case .newTask:
                    guard hasBody else { errorMessage = "업무명을 입력하세요."; return false }
                    let (names, tagNames) = try resolveProjectAndTagNames()
                    let lines = text.components(separatedBy: "\n")
                    let reference = try linkedCapture.create(
                        .task(title: lines[0], body: lines.dropFirst().joined(separator: "\n"),
                              initialStatus: initialStatus, workDate: workDate, effectiveTime: nil,
                              dueOn: nil, projectNames: names, trackingMode: projectTrackingMode,
                              tagNames: tagNames, checklist: [], links: []),
                        related: relatedRecords.map(\.reference))
                    lastSavedId = reference.id
                    finishOrdinarySubmit()
                    return true

                case .existing(let taskId):
                    switch taskAction {
                    case .addActivity:
                        return try submitActivityToExisting(taskId: taskId)
                    case .changeStatus:
                        return try submitStatusChange(taskId: taskId)
                    }
                }

            case .activity:
                // 내부 호환 경로. 탭에서는 노출하지 않는다.
                guard hasBody else { errorMessage = "진행 기록 내용을 입력하세요."; return false }
                guard let targetTaskId else {
                    errorMessage = "진행 기록의 대상 업무를 선택하세요."; return false
                }
                let linkedIds = try environment.repo.taskProjects(taskId: targetTaskId).map(\.projectId)
                guard selectedProjectIds.allSatisfy({ linkedIds.contains($0) }) else {
                    errorMessage = "대상 업무에 연결된 프로젝트를 선택하세요."; return false
                }
                lastSavedId = try environment.tasks.addActivity(taskId: targetTaskId, body: text,
                    workDate: workDate, projectIds: selectedProjectIds).id
                finishOrdinarySubmit()
                return true
            }
        } catch {
            errorMessage = "저장하지 못했습니다. 대상 업무·프로젝트와 입력 내용을 확인하세요."
            return false
        }
    }

    // MARK: - 저장 내부

    /// 기존 업무에 진행 기록을 추가하고 관련 링크를 함께 저장한다.
    private func submitActivityToExisting(taskId: String) throws -> Bool {
        guard hasBody else { errorMessage = "진행 기록 내용을 입력하세요."; return false }
        let linkedIds = try environment.repo.taskProjects(taskId: taskId).map(\.projectId)
        guard selectedProjectIds.allSatisfy({ linkedIds.contains($0) }) else {
            errorMessage = "대상 업무에 연결된 프로젝트를 선택하세요."; return false
        }
        let reference = try linkedCapture.create(
            .activity(taskId: taskId, body: text, workDate: workDate, effectiveTime: nil,
                      projectIds: selectedProjectIds, checklistItemIds: [], kind: .progress, links: []),
            related: relatedRecords.map(\.reference))
        lastSavedId = reference.id
        finishOrdinarySubmit()
        return true
    }

    /// 상태만 변경한다. 본문은 사용·삭제하지 않고 보존한다. 완료 계열은 확인 절차를 거친다.
    private func submitStatusChange(taskId: String) throws -> Bool {
        guard let target = statusTarget else {
            errorMessage = "변경할 상태를 선택하세요."; return false
        }
        guard let current = try environment.tasks.currentStatus(taskId: taskId) else {
            errorMessage = "대상 업무의 상태를 확인하지 못했습니다."; return false
        }
        guard current != target else {
            errorMessage = "이미 같은 상태입니다."; return false
        }
        if target == .completed {
            let check = try environment.tasks.completeTask(taskId: taskId, workDate: workDate,
                                                           confirmRemaining: false)
            guard check.completed else {
                // 남은 체크리스트·프로젝트 확인이 필요하다. 초안·선택을 보존한다.
                pendingCompletion = check
                pendingCompletionTaskId = taskId
                errorMessage = nil
                return false
            }
        } else {
            guard let eventKind = Self.transitionKind(from: current, to: target) else {
                errorMessage = "현재 상태에서 선택한 상태로 변경할 수 없습니다."; return false
            }
            try environment.tasks.changeTaskStatus(taskId: taskId, kind: eventKind, workDate: workDate)
        }
        taskSelection = .newTask
        statusTarget = nil
        pendingCompletion = nil
        pendingCompletionTaskId = nil
        errorMessage = nil
        reloadCandidates()
        return true
    }

    private var hasBody: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// 이름이 바뀌어도 두 번째 프로젝트가 생기지 않도록 안정 ID에서 현재 이름을 확인한다.
    private func resolveProjectAndTagNames() throws -> (projects: [String], tags: [String]) {
        let names = try selectedProjectIds.map { id -> String in
            guard let project = try environment.repo.project(id: id) else {
                throw WorkLogError.validation("선택한 프로젝트를 찾을 수 없습니다.")
            }
            return project.name
        }
        let currentTags = try environment.repo.tags()
        let tagNames = try selectedTagIds.map { id -> String in
            guard let tag = currentTags.first(where: { $0.id == id }) else {
                throw WorkLogError.validation("선택한 태그를 찾을 수 없습니다.")
            }
            return tag.name
        }
        return (names, tagNames)
    }

    /// 일반 초안·선택을 성공 후 비운다. 상태 변경 경로는 이 메서드를 쓰지 않는다.
    private func finishOrdinarySubmit() {
        text = ""; selectedProjectIds = []; selectedTagIds = []; targetTaskId = nil
        relatedRecords = []
        taskSelection = .newTask
        statusTarget = nil
        pendingCompletion = nil
        pendingCompletionTaskId = nil
        errorMessage = nil
        initialStatus = .planned
        projectTrackingMode = .shared
        resetDefaults()
        reloadCandidates()
    }

    /// 진행·계획이 아닌 완료·취소가 아니면 미완료로 본다.
    private static func isUnfinished(_ task: WorkTask) -> Bool {
        switch task.cachedStatus {
        case .completed, .cancelled: return false
        default: return true
        }
    }

    /// `from`에서 `to`로 가는 상태 사건 종류. `StatusRules`로 검증한다.
    static func transitionKind(from current: TaskStatus, to target: TaskStatus) -> DomainEventKind? {
        let candidates: [DomainEventKind] = [.started, .resumed, .reopened,
                                             .paused, .completed, .cancelled, .replanned]
        for kind in candidates {
            if case let .success(result) = StatusRules.apply(scopeType: .task, from: current,
                                                             kind: kind, toStatus: target),
               result == target {
                return kind
            }
        }
        return nil
    }
}
