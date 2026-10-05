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
    public var text = "" { didSet { selectionRange = nil; highlightOverride = nil; dismissedTokenKey = nil } }
    /// UTF-16 selection from the native editor; nil uses existing-name prefix matching.
    public var selectionRange: NSRange?
    public var kind: RecordCaptureKind = .memo
    public var workDate: WorkDate
    public var targetTaskId: String?
    public var initialStatus: TaskStatus = .planned
    public var projectTrackingMode: ProjectTrackingMode = .shared

    /// `initialStatus`를 완료로 등록할지 여부. 새 업무 저장 시 완료 상태로 만든다.
    public var registersAsCompleted: Bool {
        get { initialStatus == .completed }
        set { initialStatus = newValue ? .completed : .planned }
    }

    /// 사용자가 ↑↓로 옮긴 강조. `text`가 바뀌면 초기화되어 기본 규칙(첫 기존 후보)으로 돌아간다.
    private var highlightOverride: CaptureCandidate?
    /// `dismissCandidates()`로 숨긴 토큰 식별자. 같은 토큰이면 후보를 숨기고, 토큰이 바뀌면 다시 보인다.
    private var dismissedTokenKey: String?

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
    public var requiresSecretEditor: Bool { environment?.settings.defaultCaptureKind == .secret }
    @ObservationIgnored private var environment: AppEnvironment?
    @ObservationIgnored private var linkedCapture: LinkedCaptureService?
    @ObservationIgnored private var linkStore: RecordLinkStore?
    /// 완료 확인 재시도 대상 업무 id. `pendingCompletion`과 함께만 유효하다.
    @ObservationIgnored private var pendingCompletionTaskId: String?

    /// 진행 기록 입력 맥락인지. 진행 기록 탭이거나, 업무 탭에서 기존 업무에 진행 기록을 추가하는 상태.
    /// 이 맥락에서는 프로젝트는 대상 업무 연결 프로젝트만, 태그·새 생성은 쓰지 않는다.
    private var isActivityContext: Bool {
        if kind == .activity { return true }
        if case .existing = taskSelection, taskAction == .addActivity { return true }
        return false
    }

    /// 진행 기록이 향하는 대상 업무 id. 진행 기록 탭이면 `targetTaskId`,
    /// 업무 탭에서 기존 업무+진행 기록이면 그 업무 id, 그 외에는 nil.
    public var activityTargetTaskId: String? {
        if kind == .activity { return targetTaskId }
        if case let .existing(id) = taskSelection, taskAction == .addActivity { return id }
        return nil
    }

    /// 진행 기록 맥락에서 대상 업무에 연결된 프로젝트 id. 맥락이 아니면 nil(제한 없음).
    /// 맥락인데 대상 업무가 없으면 빈 배열(모든 프로젝트 제외).
    private var activityLinkedProjectIds: [String]? {
        guard isActivityContext else { return nil }
        return activityTargetTaskId.flatMap { id in
            environment.flatMap { try? $0.repo.taskProjects(taskId: id).map(\.projectId) }
        } ?? []
    }

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
        guard let environment else { return }
        if !requiresSecretEditor {
            kind = environment.settings.defaultCaptureKind == .task ? .task : .memo
        }
        workDate = environment.calendar.workDate(of: environment.options.clock.now())
        highlightOverride = nil
        dismissedTokenKey = nil
    }

    /// 저장소 참조를 놓는다. 백업 복원 등에서 DB를 붙잡지 않게 한다. 이후 호출은 무해하다.
    public func detach() {
        environment = nil
        linkedCapture = nil
        linkStore = nil
    }

    public func reloadCandidates() {
        guard let environment else { return }
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

    /// 현재 토큰(종류·마커 위치·query)을 식별하는 키. 후보 숨김 비교에 쓴다.
    private var tokenKey: String? {
        guard let token else { return nil }
        let location = NSRange(token.range, in: text).location
        return "\(token.kind)#\(location)#\(token.query)"
    }

    public var candidates: [CaptureCandidate] {
        guard let token else { return [] }
        if let dismissedTokenKey, dismissedTokenKey == tokenKey { return [] }
        let all: [CaptureCandidate]
        switch token.kind {
        case .project:
            let linkedIds = activityLinkedProjectIds
            all = projects.filter { !selectedProjectIds.contains($0.id) && (linkedIds?.contains($0.id) ?? true) }
                .map { CaptureCandidate(id: $0.id, name: $0.name, kind: .project) }
        case .tag:
            guard !isActivityContext else { return [] }
            all = tags.filter { !selectedTagIds.contains($0.id) }
                .map { CaptureCandidate(id: $0.id, name: $0.name, kind: .tag) }
        }
        var matches = Array(all.filter { $0.name.lowercased().hasPrefix(token.query.lowercased()) }.prefix(8))
        let name = token.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let exists = token.kind == .project ? projects.contains { $0.name == name } : tags.contains { $0.name == name }
        let hasExistingPrefix = (token.kind == .project ? projects.map(\.name) : tags.map(\.name))
            .contains { $0.lowercased().hasPrefix(name.lowercased()) }
        if !name.isEmpty && !exists && !hasExistingPrefix && !isActivityContext {
            matches.append(CaptureCandidate(id: "new:\(token.kind):\(name)", name: name, kind: token.kind, isNew: true))
        }
        return matches
    }

    /// 후보를 숨긴다. 같은 토큰이면 `candidates`가 빈 배열을 반환하고, 토큰 문자열이 바뀌면 다시 보인다.
    public func dismissCandidates() {
        guard let key = tokenKey else { return }
        dismissedTokenKey = key
        highlightOverride = nil
    }

    public var isShowingCandidates: Bool { !candidates.isEmpty }

    /// 기본 강조는 `candidates` 중 첫 번째 기존 항목(`isNew == false`). 새로 만들기 후보만 있으면 nil.
    /// 사용자가 ↑↓로 옮긴 강조가 후보 목록에 남아 있으면 그것을 우선한다.
    public var highlightedCandidate: CaptureCandidate? {
        let list = candidates
        if let override = highlightOverride, list.contains(override) { return override }
        return list.first { !$0.isNew }
    }

    /// 후보 목록(새로 만들기 포함) 안에서 강조를 이동한다. 양 끝에서 멈춘다.
    /// 강조가 nil이면 delta > 0은 첫 후보, delta < 0은 마지막 후보.
    public func moveCandidateHighlight(by delta: Int) {
        guard delta != 0 else { return }
        let list = candidates
        guard !list.isEmpty else { return }
        if let current = highlightedCandidate, let index = list.firstIndex(of: current) {
            let next = min(max(index + delta, 0), list.count - 1)
            highlightOverride = list[next]
        } else {
            highlightOverride = delta > 0 ? list.first : list.last
        }
    }

    /// 강조 후보가 있으면 선택하고 true. 없으면 false(호출자는 Return을 줄바꿈으로 넘긴다).
    @discardableResult
    public func acceptHighlightedCandidate() -> Bool {
        guard let candidate = highlightedCandidate else { return false }
        select(candidate)
        return true
    }

    /// Selection is stored by ID; replace only the query and preserve surrounding prose.
    public func select(_ candidate: CaptureCandidate) {
        guard candidates.contains(candidate), let token, let environment else { return }
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

    // MARK: - 버튼 경로(문법 없이 선택)
    //
    // `@`/`#` 문법을 몰라도 같은 후보를 고를 수 있게 한다. 본문 `text`는 건드리지 않는다.

    /// 이미 선택된 것을 제외한 프로젝트 후보. 대소문자 무시 포함 검색, 빈 query면 전체, 최대 50.
    /// 진행 기록 맥락이면 대상 업무에 연결된 프로젝트만 보여준다.
    public func projectOptions(matching query: String) -> [Project] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let linkedIds = activityLinkedProjectIds
        return projects
            .filter { !selectedProjectIds.contains($0.id) && (linkedIds?.contains($0.id) ?? true) }
            .filter { trimmed.isEmpty || $0.name.lowercased().contains(trimmed) }
            .prefix(50)
            .map { $0 }
    }

    /// 이미 선택된 것을 제외한 태그 후보. 대소문자 무시 포함 검색, 빈 query면 전체, 최대 50.
    /// 진행 기록 맥락에서는 태그를 쓰지 않으므로 빈 배열.
    public func tagOptions(matching query: String) -> [Tag] {
        guard !isActivityContext else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return tags
            .filter { !selectedTagIds.contains($0.id) }
            .filter { trimmed.isEmpty || $0.name.lowercased().contains(trimmed) }
            .prefix(50)
            .map { $0 }
    }

    /// 존재하는 프로젝트 id를 선택에 추가한다. 없는 id·중복은 무시한다.
    /// 진행 기록 맥락에서는 대상 업무에 연결되지 않은 프로젝트를 무시한다.
    public func addProject(id: String) {
        guard projects.contains(where: { $0.id == id }), !selectedProjectIds.contains(id) else { return }
        if let linkedIds = activityLinkedProjectIds, !linkedIds.contains(id) { return }
        selectedProjectIds.append(id)
    }

    /// 존재하는 태그 id를 선택에 추가한다. 없는 id·중복은 무시한다.
    /// 진행 기록 맥락에서는 태그를 쓰지 않으므로 무시한다.
    public func addTag(id: String) {
        guard !isActivityContext else { return }
        guard tags.contains(where: { $0.id == id }), !selectedTagIds.contains(id) else { return }
        selectedTagIds.append(id)
    }

    /// 이름으로 프로젝트를 찾거나 만들고 선택에 추가한다. trim 후 빈 값은 무시한다.
    /// 진행 기록 맥락에서는 새 프로젝트를 만들지 않는다.
    public func addNewProject(name: String) {
        guard !isActivityContext, let environment else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let project = try environment.repo.findOrCreateProject(name: trimmed)
            if !selectedProjectIds.contains(project.id) { selectedProjectIds.append(project.id) }
            errorMessage = nil
            reloadCandidates()
        } catch {
            errorMessage = "프로젝트를 추가하지 못했습니다. 다시 시도하세요."
        }
    }

    /// 이름으로 태그를 찾거나 만들고 선택에 추가한다. trim 후 빈 값은 무시한다.
    /// 진행 기록 맥락에서는 새 태그를 만들지 않는다.
    public func addNewTag(name: String) {
        guard !isActivityContext, let environment else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let tag = try environment.repo.findOrCreateTag(name: trimmed)
            if !selectedTagIds.contains(tag.id) { selectedTagIds.append(tag.id) }
            errorMessage = nil
            reloadCandidates()
        } catch {
            errorMessage = "태그를 추가하지 못했습니다. 다시 시도하세요."
        }
    }

    // MARK: - 업무일

    /// 주입된 `environment.clock` 기준 오늘.
    private var today: WorkDate? {
        environment.map { $0.calendar.workDate(of: $0.options.clock.now()) }
    }

    public var isPastWorkDate: Bool {
        guard let today else { return false }
        return workDate < today
    }

    public var isFutureWorkDate: Bool {
        guard let today else { return false }
        return workDate > today
    }

    /// 업무일을 오늘로 되돌린다.
    public func resetWorkDateToToday() {
        guard let today else { return }
        workDate = today
    }

    /// 업무일 표시. 오늘/과거/미래를 라벨로 구분하고 요일은 `WorkCalendar` 시간대 기준 한국어 한 글자.
    public var workDateLabel: String {
        guard let today, let environment else { return "" }
        let weekday = Self.koreanWeekday(environment.calendar.isoWeekday(workDate))
        let date = "\(workDate.month)월 \(workDate.day)일(\(weekday))"
        if workDate == today { return "오늘 · \(date)" }
        if workDate < today { return "과거 날짜 · \(date)" }
        return "미래 날짜 · \(date)"
    }

    /// ISO 요일(월=1…일=7) → 한국어 한 글자.
    static func koreanWeekday(_ isoWeekday: Int) -> String {
        let names = ["월", "화", "수", "목", "금", "토", "일"]
        guard (1...names.count).contains(isoWeekday) else { return "" }
        return names[isoWeekday - 1]
    }

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
              let current = environment.flatMap({ try? $0.tasks.currentStatus(taskId: id) }) else { return [] }
        return TaskStatus.allCases.filter { target in
            target != current && Self.transitionKind(from: current, to: target) != nil
        }
    }

    /// 수동 관련 링크 후보를 검색한다. 이미 선택한 후보와 현재 대상 업무는 제외한다.
    public func searchRelated(_ query: String) throws -> [RelatedRecordCandidate] {
        guard let linkStore else { return [] }
        var excluding = Set(relatedRecords.map(\.reference))
        if case let .existing(id) = taskSelection {
            excluding.insert(RecordReference(kind: .task, id: id))
        }
        return try linkStore.candidates(query: query, excluding: excluding, limit: 20)
    }

    /// 완료 확인이 필요한 경우 `confirmRemaining: true`로 재시도한다. 성공하면 true.
    @discardableResult public func confirmCompletion() -> Bool {
        guard let taskId = pendingCompletionTaskId, pendingCompletion != nil else { return false }
        guard !isSubmitting, let environment else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            _ = try environment.tasks.completeTask(taskId: taskId, workDate: workDate, confirmRemaining: true)
            pendingCompletion = nil
            pendingCompletionTaskId = nil
            taskSelection = .newTask
            statusTarget = nil
            relatedRecords = []
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
        guard !isSubmitting, let environment, let linkedCapture else { return false }
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
                    let (title, body) = Self.splitTaskText(text)
                    let reference = try linkedCapture.create(
                        .task(title: title, body: body,
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
        guard let environment, let linkedCapture else { return false }
        guard hasBody else { errorMessage = "진행 기록 내용을 입력하세요."; return false }
        let linkedIds = try environment.repo.taskProjects(taskId: taskId).map(\.projectId)
        // 진입 경로상 남아 있을 수 있는 연결 밖 선택(예: 새 업무 모드에서 고른 뒤 전환)은
        // 저장 시 연결 프로젝트만 남긴다.
        let projectIds = selectedProjectIds.filter { linkedIds.contains($0) }
        let reference = try linkedCapture.create(
            .activity(taskId: taskId, body: text, workDate: workDate, effectiveTime: nil,
                      projectIds: projectIds, checklistItemIds: [], kind: .progress, links: []),
            related: relatedRecords.map(\.reference))
        lastSavedId = reference.id
        finishOrdinarySubmit()
        return true
    }

    /// 상태만 변경한다. 본문은 사용·삭제하지 않고 보존한다. 완료 계열은 확인 절차를 거친다.
    private func submitStatusChange(taskId: String) throws -> Bool {
        guard let environment else { return false }
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
        relatedRecords = []
        errorMessage = nil
        // 상태 변경도 일반 저장 성공과 같이 업무일을 오늘로 되돌린다(과거 날짜가 몰래 유지되지 않게).
        workDate = environment.calendar.workDate(of: environment.options.clock.now())
        reloadCandidates()
        return true
    }

    private var hasBody: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// 새 업무 초안을 업무명과 본문으로 나눈다.
    ///
    /// 기존 규칙은 첫 줄을 업무명, 나머지를 본문으로 한다. 첫 줄이 공백뿐이면
    /// 첫 번째 비어 있지 않은 줄을 업무명으로 쓰고, 그 이후 줄만 본문으로 남긴다.
    /// CRLF 입력을 고려해 빈 줄 판정과 업무명 trim에 개행 문자를 포함한다.
    static func splitTaskText(_ text: String) -> (title: String, body: String) {
        // Swift에서 "\r\n"은 하나의 Character라 "\n"으로 바로 나뉘지 않으므로 먼저 LF로 정규화한다.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        if let first = lines.first, !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (first.trimmingCharacters(in: .whitespacesAndNewlines),
                    lines.dropFirst().joined(separator: "\n"))
        }
        guard let index = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return (text, "")
        }
        return (lines[index].trimmingCharacters(in: .whitespacesAndNewlines),
                lines.dropFirst(index + 1).joined(separator: "\n"))
    }

    /// 이름이 바뀌어도 두 번째 프로젝트가 생기지 않도록 안정 ID에서 현재 이름을 확인한다.
    private func resolveProjectAndTagNames() throws -> (projects: [String], tags: [String]) {
        guard let environment else {
            throw WorkLogError.validation("저장소 연결이 닫혔습니다.")
        }
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
