#if os(macOS) && DEBUG
import Foundation
import WorkLogCore

/// Explicit debug launches use a fresh disposable workspace and fake authentication.
/// This branch must run before opening standard paths, Keychain, or an AI provider.
@MainActor
enum UITestFixture: String {
    case empty, few, many

    static func requested(arguments: [String] = ProcessInfo.processInfo.arguments) throws -> UITestFixture? {
        guard let index = arguments.firstIndex(of: "--ui-test-fixture") else { return nil }
        guard arguments.indices.contains(index + 1), let fixture = UITestFixture(rawValue: arguments[index + 1]) else {
            throw WorkLogError.validation("UI 테스트 데이터는 empty, few, many 중에서 선택하세요.")
        }
        return fixture
    }

    func makeEnvironment() async throws -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkLog-UI-\(rawValue)-\(UUIDGenerator().make())", isDirectory: true)
        let paths = AppPaths(dataRoot: root.appendingPathComponent("data", isDirectory: true),
                             backupRoot: root.appendingPathComponent("backups", isDirectory: true))
        var settings = AppSettings()
        settings.aiEnabled = false
        try SettingsStore(fileURL: paths.settingsFile).save(settings)
        let today = WorkDate("2026-10-10")!
        let clock = FixedClock(WorkCalendar().startOfDay(today).addingTimeInterval(10 * 60 * 60))
        let environment = try AppEnvironment.open(AppEnvironmentOptions(
            paths: paths, keyStore: InMemoryVaultKeyStore(), authenticator: MockDeviceAuthenticator(),
            pasteboard: SystemPasteboard(), aiProvider: nil, clock: clock,
            ids: SequentialIDGenerator(prefix: "ui-fixture")))
        _ = try environment.templates.seedDefaults()
        if self != .empty {
            try seedRecords(in: environment, today: today)
            try await seedVault(in: environment)
            try await seedReports(in: environment, today: today)
        }
        return environment
    }

    private func seedRecords(in environment: AppEnvironment, today: WorkDate) throws {
        let prior = WorkDate("2026-09-30")!
        let week = environment.periods.weekStart(containing: today)
        let names = ["공통 플랫폼", "고객 경험 개선", "대중교통 길찾기", "운영 도구"]
        let titles = [
            "여러 프로젝트에 함께 적용하는 배포 파이프라인 개선과 긴 한국어 업무명 표시·줄바꿈 검증",
            "검색 결과에서 원문을 확인하고 입력하던 검색 조건으로 돌아오는 흐름 점검",
            "배포 전 회귀 테스트와 운영 문서 정리",
            "팀 검토 의견을 반영한 오류 안내 문구 개선",
            "다음 분기 운영 도구 접근성 검토"
        ]
        let statuses: [TaskStatus] = [.inProgress, .planned, .completed, .onHold, .cancelled]
        let taskCount = self == .many ? 32 : 3
        for index in 0..<taskCount {
            let isShared = index % 4 == 0
            let task = try environment.tasks.createTask(
                title: titles[index % titles.count] + (index >= titles.count ? " · 검토 \(index + 1)" : ""),
                initialStatus: statuses[index % statuses.count], workDate: prior,
                dueOn: index % 2 == 0 ? environment.calendar.adding(days: index % 4, to: today) : nil,
                projectNames: isShared ? names : [names[index % names.count]],
                trackingMode: isShared ? .perProject : .shared,
                tagNames: index % 2 == 0 ? ["검증", "업무흐름"] : ["문서"],
                checklist: index == 0 ? ["작은 창에서 긴 업무명 확인", "프로젝트별 적용 확인", "운영 문서에 결과 기록"] : [],
                note: "지난주 검토한 가짜 업무 기록입니다. 원문과 상태를 구분해 확인합니다.",
                links: index == 0 ? ["https://example.invalid/worklog/ui-fixture"] : [])
            _ = try environment.tasks.addActivity(taskId: task.id,
                body: "지난주 진행 기록 \(index + 1): 문제를 재현하고 변경 내용을 검토했습니다.", workDate: prior)
            _ = try environment.tasks.addActivity(taskId: task.id,
                body: "오늘 진행 기록 \(index + 1): 긴 한국어 본문에서도 작업 결과와 다음 확인 항목을 읽을 수 있는지 확인합니다.\n추가 확인: 작은 창의 버튼과 줄바꿈.",
                workDate: today)
            if index == 0 {
                if let item = try environment.repo.checklistItems(taskId: task.id).first {
                    try environment.tasks.setChecklistItem(itemId: item.id, done: true, workDate: today)
                }
                if let project = try environment.repo.taskProjects(taskId: task.id).first {
                    try environment.tasks.changeProjectStatus(taskId: task.id, projectId: project.projectId,
                                                               kind: .completed, workDate: today)
                }
            }
        }
        let memoCount = self == .many ? 36 : 2
        for index in 0..<memoCount {
            _ = try environment.tasks.captureMemo(
                body: "검증 메모 \(index + 1) · 업무 도중 빠르게 기록한 내용\n첫 번째 관찰: 검색 결과와 원문을 바로 연결할 수 있어야 합니다.\n두 번째 관찰: 화면 크기가 달라도 긴 한국어 문장이 잘리지 않아야 합니다.",
                workDate: today, projectNames: [names[index % names.count]], tagNames: ["검증"])
        }
        _ = try environment.tasks.captureMemo(body: "지난주 회의 메모\n실제로 수행한 내용과 다음 주 계획은 따로 표시하기로 했습니다.",
                                              workDate: prior, projectNames: [names[0]], tagNames: ["회의"])
        let candidates = try environment.plans.generateCandidates(weekStart: week)
        let selected = candidates.filter { $0.scopeType == .wholeTask }.prefix(2).map(\.id)
        _ = try environment.plans.confirm(weekStart: week, itemIds: selected)
    }

    private func seedVault(in environment: AppEnvironment) async throws {
        try await environment.vaultSession.unlock(reason: "가짜 UI 테스트 데이터 준비")
        defer { environment.vaultSession.lock(.manual) }
        let rowCount = self == .many ? 25 : 4
        let rows = (1...rowCount).map { index in
            SecretRowInput(key: "  DEMO_SETTING_\(index)  ", value: "  fake-ui-only-value-\(index)  ")
        }
        let metadata = try environment.vaultSession.create(title: "가짜 개발 환경 설정", groupName: "UI 검증 전용", rows: rows)
        if let first = try environment.vaultSession.currentRows(secretId: metadata.id).first {
            _ = try environment.vaultSession.save(secretId: metadata.id, changes: SecretChangeSet(upserts: [
                SecretRowInput(id: first.id, key: first.key, value: "fake-ui-only-updated")
            ]))
        }
        if self == .many {
            for index in 1...7 {
                _ = try environment.vaultSession.create(title: "가짜 서비스 설정 \(index)", groupName: "UI 검증 전용",
                    rows: [SecretRowInput(key: "DEMO_ENDPOINT", value: "https://example.invalid/service/\(index)")])
            }
        }
        let trashed = try environment.vaultSession.create(title: "가짜 휴지통 항목", groupName: "UI 검증 전용",
            rows: [SecretRowInput(key: "DEMO_REMOVED", value: "fake-ui-only-removed")])
        try environment.vaultSession.moveToTrash(secretId: trashed.id)
    }

    private func seedReports(in environment: AppEnvironment, today: WorkDate) async throws {
        _ = try await environment.reports.generateSubmission(
            reportDate: environment.periods.weekStart(containing: today), mode: .userRequested, useAI: false)
        for type in [PeriodType.daily, .weekly, .monthly, .quarterly] {
            _ = try await environment.reports.generatePerformance(periodType: type, containing: today,
                                                                  mode: .userRequested, useAI: false)
        }
        let (period, _) = try environment.evaluationPeriods.create(start: WorkDate("2026-09-01")!, endInclusive: today)
        _ = try await environment.reports.generateEvaluation(periodId: period.id, mode: .userRequested, useAI: false)
    }
}
#endif
