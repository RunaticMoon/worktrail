import Foundation
import Observation

/// 프로젝트 목록 한 행. 진행 중 업무 수와 전체 업무 수를 함께 보여준다.
public struct ProjectSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let openTaskCount: Int
    public let totalTaskCount: Int

    public init(id: String, name: String, openTaskCount: Int, totalTaskCount: Int) {
        self.id = id
        self.name = name
        self.openTaskCount = openTaskCount
        self.totalTaskCount = totalTaskCount
    }
}

/// 선택한 프로젝트에 연결된 업무 한 행. 전체 상태와 프로젝트 기준 상태를 별도로 싣는다.
public struct ProjectTaskRow: Identifiable, Equatable, Sendable {
    /// taskId
    public let id: String
    public let title: String
    public let overallStatus: TaskStatus?
    public let projectStatus: TaskStatus?
    public let tracksProjectStatus: Bool
    public let dueOn: WorkDate?

    public init(id: String, title: String, overallStatus: TaskStatus?, projectStatus: TaskStatus?,
                tracksProjectStatus: Bool, dueOn: WorkDate?) {
        self.id = id
        self.title = title
        self.overallStatus = overallStatus
        self.projectStatus = projectStatus
        self.tracksProjectStatus = tracksProjectStatus
        self.dueOn = dueOn
    }
}

/// 프로젝트 화면 모델. 프로젝트별 상태는 `TaskService.detail`의 기존 재생 결과를 그대로 쓴다.
@Observable @MainActor public final class ProjectsModel {
    public private(set) var projects: [ProjectSummary] = []
    public private(set) var selectedProjectId: String?
    public private(set) var tasks: [ProjectTaskRow] = []
    public private(set) var errorMessage: String?
    @ObservationIgnored private let environment: AppEnvironment

    public init(environment: AppEnvironment) { self.environment = environment }

    public func load() {
        do {
            var summaries: [ProjectSummary] = []
            for project in try environment.repo.projects() {
                let projectRows = try rows(forProject: project.id)
                let open = projectRows.filter { row in
                    let status = row.tracksProjectStatus ? row.projectStatus : row.overallStatus
                    switch status {
                    case .completed, .cancelled: return false
                    default: return true
                    }
                }.count
                summaries.append(ProjectSummary(id: project.id, name: project.name,
                                                openTaskCount: open,
                                                totalTaskCount: projectRows.count))
            }
            projects = summaries
            // 선택한 프로젝트가 아직 있으면 유지한다.
            if let selected = selectedProjectId, !summaries.contains(where: { $0.id == selected }) {
                selectedProjectId = nil
            }
            tasks = try selectedProjectId.map { try rows(forProject: $0) } ?? []
            errorMessage = nil
        } catch {
            projects = []
            tasks = []
            errorMessage = "프로젝트를 불러오지 못했습니다. 다시 시도하세요."
        }
    }

    /// nil이면 선택 해제. 선택한 프로젝트의 업무를 다시 읽는다.
    public func select(_ projectId: String?) {
        selectedProjectId = projectId
        do {
            tasks = try projectId.map { try rows(forProject: $0) } ?? []
            errorMessage = nil
        } catch {
            tasks = []
            errorMessage = "프로젝트 업무를 불러오지 못했습니다. 다시 시도하세요."
        }
    }

    // MARK: - 내부

    private func rows(forProject projectId: String) throws -> [ProjectTaskRow] {
        var entries: [(row: ProjectTaskRow, createdAt: Date)] = []
        for link in try environment.repo.taskProjects(projectId: projectId) {
            guard let task = try environment.repo.task(id: link.taskId) else { continue }
            let detail = try environment.tasks.detail(taskId: task.id)
            let projectStatus: TaskStatus? = link.trackingEnabled
                ? (detail.projects.first { $0.project.id == projectId }?.status ?? .planned)
                : nil
            let row = ProjectTaskRow(id: task.id, title: task.title, overallStatus: detail.status,
                                     projectStatus: projectStatus,
                                     tracksProjectStatus: link.trackingEnabled, dueOn: task.dueOn)
            entries.append((row, task.createdAt))
        }
        entries.sort { a, b in
            let au = Self.isUnfinished(a.row.overallStatus), bu = Self.isUnfinished(b.row.overallStatus)
            if au != bu { return au }
            switch (a.row.dueOn, b.row.dueOn) {
            case let (x?, y?): if x != y { return x < y }
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return a.row.id < b.row.id
        }
        return entries.map { $0.row }
    }

    private static func isUnfinished(_ status: TaskStatus?) -> Bool {
        switch status {
        case .completed, .cancelled: return false
        default: return true
        }
    }
}
