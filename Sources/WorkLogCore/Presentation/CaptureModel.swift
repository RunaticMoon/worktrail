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

/// Ordinary record draft only. No Secret, network or AI path.
@Observable @MainActor public final class CaptureModel {
    public var text = ""
    public var kind: RecordCaptureKind = .memo
    public var workDate: WorkDate
    public var targetTaskId: String?
    public var initialStatus: TaskStatus = .planned
    public var projectTrackingMode: ProjectTrackingMode = .shared
    public private(set) var projects: [Project] = []
    public private(set) var tags: [Tag] = []
    public private(set) var tasks: [WorkTask] = []
    public private(set) var selectedProjectIds: [String] = []
    public private(set) var selectedTagIds: [String] = []
    public private(set) var errorMessage: String?
    public private(set) var isSubmitting = false
    public private(set) var lastSavedId: String?
    @ObservationIgnored private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
        workDate = environment.calendar.workDate(of: environment.options.clock.now())
        resetDefaults()
        reloadCandidates()
    }

    /// Applied only to a fresh draft; opening an existing draft preserves it.
    public func resetDefaults() {
        kind = environment.settings.defaultCaptureKind == .task ? .task : .memo
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
        guard let marker = text.lastIndex(where: { $0 == "@" || $0 == "#" }) else { return nil }
        if marker != text.startIndex && !text[text.index(before: marker)].isWhitespace { return nil }
        let suffix = String(text[text.index(after: marker)...])
        guard !suffix.contains(where: \.isNewline) else { return nil }
        return (text[marker] == "@" ? .project : .tag, marker..<text.endIndex, suffix)
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
        var matches = Array(all.filter { token.query.isEmpty || $0.name.localizedCaseInsensitiveContains(token.query) }.prefix(8))
        let name = token.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let exists = token.kind == .project ? projects.contains { $0.name == name } : tags.contains { $0.name == name }
        if !name.isEmpty && !exists && kind != .activity {
            matches.append(CaptureCandidate(id: "new:\(token.kind):\(name)", name: name, kind: token.kind, isNew: true))
        }
        return matches
    }

    /// Selection is stored by ID; the query token becomes a metadata chip.
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
        text.removeSubrange(token.range)
        reloadCandidates()
    }

    public func removeProject(_ id: String) { selectedProjectIds.removeAll { $0 == id } }
    public func removeTag(_ id: String) { selectedTagIds.removeAll { $0 == id } }

    @discardableResult public func submit() -> Bool {
        guard !isSubmitting else { return false }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "저장할 내용을 입력하세요."; return false
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            // Resolve current names from stable IDs so a rename never creates a second project.
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
            switch kind {
            case .memo:
                lastSavedId = try environment.tasks.captureMemo(body: text, workDate: workDate,
                    projectNames: names, tagNames: tagNames).id
            case .task:
                let lines = text.components(separatedBy: "\n")
                lastSavedId = try environment.tasks.createTask(title: lines[0], initialStatus: initialStatus,
                    workDate: workDate, projectNames: names, trackingMode: projectTrackingMode, tagNames: tagNames,
                    note: lines.dropFirst().joined(separator: "\n")).id
            case .activity:
                guard let targetTaskId else { throw WorkLogError.validation("진행 기록의 대상 업무를 선택하세요.") }
                let linkedIds = try environment.repo.taskProjects(taskId: targetTaskId).map(\.projectId)
                guard selectedProjectIds.allSatisfy({ linkedIds.contains($0) }) else {
                    throw WorkLogError.validation("대상 업무에 연결된 프로젝트를 선택하세요.")
                }
                lastSavedId = try environment.tasks.addActivity(taskId: targetTaskId, body: text,
                    workDate: workDate, projectIds: selectedProjectIds).id
            }
            text = ""; selectedProjectIds = []; selectedTagIds = []; targetTaskId = nil
            errorMessage = nil
            initialStatus = .planned
            projectTrackingMode = .shared
            resetDefaults()
            reloadCandidates()
            return true
        } catch {
            errorMessage = "저장하지 못했습니다. 대상 업무·프로젝트와 입력 내용을 확인하세요."
            return false
        }
    }
}
