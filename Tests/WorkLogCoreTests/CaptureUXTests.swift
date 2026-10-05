import XCTest
@testable import WorkLogCore

/// UXFL: 빠른 입력 Core — 자동완성 강조·키보드, 버튼 선택 경로, 업무일 표시/리셋, 완료 업무 등록.
///
/// - 이메일은 후보를 열지 않는다.
/// - 후보가 없을 때 "새로 만들기"만 있으면 기본 강조가 없다(Return은 줄바꿈).
/// - 기존 후보 기본 강조·↑↓ 이동·선택, Esc 후보 숨김.
/// - 버튼 경로(add/새로 만들기)는 본문을 바꾸지 않는다.
/// - 업무일 라벨(오늘/과거/미래)과 저장·상태 변경 후 오늘 복귀.
/// - 등록 상태 완료.
/// - 세션 초안(업무일 포함) 유지와 저장 후 새 세션 오늘 시작.
final class CaptureUXTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func environment(defaultKind: CaptureKind = .memo) throws -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureUXTests-\(UUID().uuidString)")
        roots.append(root)
        let paths = AppPaths(dataRoot: root.appendingPathComponent("data"),
                             backupRoot: root.appendingPathComponent("backups"))
        var settings = AppSettings()
        settings.aiEnabled = false
        settings.defaultCaptureKind = defaultKind
        try SettingsStore(fileURL: paths.settingsFile).save(settings)
        return try AppEnvironment.open(AppEnvironmentOptions(
            paths: paths, keyStore: InMemoryVaultKeyStore(),
            authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(),
            aiProvider: nil,
            clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_000)),
            ids: SequentialIDGenerator()))
    }

    private func today(_ env: AppEnvironment) -> WorkDate {
        env.calendar.workDate(of: env.options.clock.now())
    }

    // MARK: - (a) 이메일은 후보를 열지 않는다

    @MainActor
    func testEmailDoesNotOpenCandidates() async throws {
        let env = try environment()
        let model = CaptureModel(environment: env)
        model.text = "a@b.com"
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertFalse(model.isShowingCandidates)
        XCTAssertNil(model.highlightedCandidate)
        XCTAssertFalse(model.acceptHighlightedCandidate())
        XCTAssertEqual(model.text, "a@b.com")
    }

    // MARK: - (b) 기존 항목이 없으면 새로 만들기만, 기본 강조 없음

    @MainActor
    func testOnlyNewCandidateHasNoDefaultHighlightAndReturnIsNewline() async throws {
        let env = try environment()
        let model = CaptureModel(environment: env)
        model.text = "코드 #include"

        XCTAssertEqual(model.candidates.count, 1)
        XCTAssertEqual(model.candidates.first?.isNew, true)
        XCTAssertNil(model.highlightedCandidate, "새로 만들기 후보는 기본 강조되지 않는다")
        XCTAssertFalse(model.acceptHighlightedCandidate(), "강조가 없으면 Return은 줄바꿈으로 넘긴다")
        XCTAssertEqual(model.text, "코드 #include", "본문을 바꾸지 않는다")
    }

    // MARK: - (c) 기존 프로젝트 기본 강조·선택

    @MainActor
    func testExistingProjectIsHighlightedAndAccepted() async throws {
        let env = try environment()
        let gamma = try env.repo.createProject(name: "Gamma")
        let model = CaptureModel(environment: env)
        model.text = "@Ga"

        XCTAssertEqual(model.highlightedCandidate?.name, "Gamma")
        XCTAssertTrue(model.acceptHighlightedCandidate())
        XCTAssertEqual(model.selectedProjectIds, [gamma.id])
        XCTAssertEqual(model.text, "Gamma ")
    }

    // MARK: - (d) ↑↓로 새로 만들기 후보 선택

    @MainActor
    func testMoveCandidateHighlightSelectsNewCandidate() async throws {
        let env = try environment()
        _ = try env.repo.createProject(name: "Gamma")
        let model = CaptureModel(environment: env)
        model.text = "@Gamz"

        XCTAssertEqual(model.candidates.count, 1)
        XCTAssertEqual(model.candidates.first?.isNew, true)
        XCTAssertNil(model.highlightedCandidate)

        model.moveCandidateHighlight(by: 1)
        XCTAssertEqual(model.highlightedCandidate?.name, "Gamz")

        XCTAssertTrue(model.acceptHighlightedCandidate())
        let id = try XCTUnwrap(model.selectedProjectIds.first)
        XCTAssertEqual(try env.repo.project(id: id)?.name, "Gamz")
    }

    // MARK: - (e) Esc 후보 숨김, 토큰이 바뀌면 다시 보임

    @MainActor
    func testDismissCandidatesHidesUntilTokenChanges() async throws {
        let env = try environment()
        _ = try env.repo.createProject(name: "Gamma")
        let model = CaptureModel(environment: env)
        model.text = "@Ga"
        XCTAssertFalse(model.candidates.isEmpty)

        model.dismissCandidates()
        XCTAssertTrue(model.candidates.isEmpty, "같은 토큰이면 후보를 숨긴다")
        XCTAssertFalse(model.isShowingCandidates)

        model.text += "m"
        XCTAssertFalse(model.candidates.isEmpty, "토큰 문자열이 바뀌면 다시 보인다")
    }

    // MARK: - (f) 버튼 경로는 본문을 바꾸지 않는다

    @MainActor
    func testButtonPathsDoNotChangeText() async throws {
        let env = try environment()
        let project = try env.repo.createProject(name: "플랫폼")
        let model = CaptureModel(environment: env)
        model.text = "본문 @플랫폼 #검증"

        model.addProject(id: project.id)
        XCTAssertEqual(model.selectedProjectIds, [project.id])
        model.addProject(id: project.id)
        XCTAssertEqual(model.selectedProjectIds, [project.id], "중복 추가는 무시한다")
        model.addProject(id: "없는-id")
        XCTAssertEqual(model.selectedProjectIds, [project.id], "없는 id는 무시한다")

        model.addNewTag(name: "  검증  ")
        XCTAssertEqual(model.selectedTagIds.count, 1)
        model.addNewTag(name: "검증")
        XCTAssertEqual(model.selectedTagIds.count, 1, "새 태그도 중복을 만들지 않는다")

        XCTAssertEqual(model.text, "본문 @플랫폼 #검증", "버튼 선택은 본문을 바꾸지 않는다")
        XCTAssertEqual(try env.repo.tags().map(\.name), ["검증"])
    }

    @MainActor
    func testProjectAndTagOptionsFilterAndExcludeSelected() async throws {
        let env = try environment()
        let alpha = try env.repo.createProject(name: "Alpha")
        _ = try env.repo.createProject(name: "Beta")
        _ = try env.repo.findOrCreateTag(name: "긴급")
        _ = try env.repo.findOrCreateTag(name: "검증")
        let model = CaptureModel(environment: env)

        XCTAssertEqual(model.projectOptions(matching: "").map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(model.projectOptions(matching: "alp").map(\.name), ["Alpha"],
                       "대소문자 무시 포함 검색")
        XCTAssertEqual(model.tagOptions(matching: "검").map(\.name), ["검증"])

        model.addProject(id: alpha.id)
        XCTAssertEqual(model.projectOptions(matching: "").map(\.name), ["Beta"],
                       "이미 선택한 프로젝트는 제외")

        model.kind = .activity
        XCTAssertTrue(model.tagOptions(matching: "").isEmpty, "진행 기록에서는 태그를 쓰지 않는다")
    }

    // MARK: - (g) 저장 성공 시 오늘 복귀, 실패 시 날짜 유지

    @MainActor
    func testMemoSubmitResetsWorkDateAndFailureKeepsIt() async throws {
        let env = try environment()
        let today = today(env)
        let yesterday = env.calendar.adding(days: -1, to: today)

        let model = CaptureModel(environment: env)
        model.workDate = yesterday
        model.text = "과거 날짜 메모"
        XCTAssertTrue(model.submit())
        XCTAssertEqual(model.workDate, today, "저장 성공 후 업무일이 오늘로 돌아온다")
        XCTAssertEqual(try env.repo.memos(on: yesterday).count, 1, "기록은 지정한 과거 날짜에 저장")

        let failing = CaptureModel(environment: env)
        failing.workDate = yesterday
        failing.text = "롤백 메모"
        failing.relatedRecords = [RelatedRecordCandidate(
            reference: RecordReference(kind: .task, id: "없는업무"), title: "없는 업무")]
        XCTAssertFalse(failing.submit())
        XCTAssertEqual(failing.workDate, yesterday, "실패 시 입력한 업무일을 유지한다")
        XCTAssertEqual(failing.text, "롤백 메모", "실패 시 본문을 유지한다")
    }

    // MARK: - (h) 상태 변경 성공 후 업무일 오늘 복귀

    @MainActor
    func testStatusChangeSuccessResetsWorkDateButKeepsText() async throws {
        let env = try environment()
        let today = today(env)
        let yesterday = env.calendar.adding(days: -1, to: today)
        let task = try env.tasks.createTask(title: "상태 업무", workDate: yesterday)

        let model = CaptureModel(environment: env)
        model.kind = .task
        model.taskSelection = .existing(task.id)
        model.taskAction = .changeStatus
        model.statusTarget = .inProgress
        model.workDate = yesterday
        model.text = "상태 변경 중에도 보존되는 본문"

        XCTAssertTrue(model.submit())
        XCTAssertEqual(model.workDate, today, "상태 변경 성공도 업무일을 오늘로 되돌린다")
        XCTAssertEqual(model.text, "상태 변경 중에도 보존되는 본문", "상태 변경은 본문을 지우지 않는다")
        XCTAssertEqual(try env.tasks.currentStatus(taskId: task.id), .inProgress)
    }

    // MARK: - (i) 업무일 라벨

    @MainActor
    func testWorkDateLabelForTodayPastAndFuture() async throws {
        let env = try environment()
        let today = today(env)
        let yesterday = env.calendar.adding(days: -1, to: today)
        let tomorrow = env.calendar.adding(days: 1, to: today)
        let model = CaptureModel(environment: env)
        let names = ["월", "화", "수", "목", "금", "토", "일"]

        model.workDate = today
        XCTAssertFalse(model.isPastWorkDate)
        XCTAssertFalse(model.isFutureWorkDate)
        XCTAssertEqual(model.workDateLabel,
                       "오늘 · \(today.month)월 \(today.day)일(\(names[env.calendar.isoWeekday(today) - 1]))")

        model.workDate = yesterday
        XCTAssertTrue(model.isPastWorkDate)
        XCTAssertEqual(model.workDateLabel,
                       "과거 날짜 · \(yesterday.month)월 \(yesterday.day)일(\(names[env.calendar.isoWeekday(yesterday) - 1]))")

        model.workDate = tomorrow
        XCTAssertTrue(model.isFutureWorkDate)
        XCTAssertEqual(model.workDateLabel,
                       "미래 날짜 · \(tomorrow.month)월 \(tomorrow.day)일(\(names[env.calendar.isoWeekday(tomorrow) - 1]))")

        model.resetWorkDateToToday()
        XCTAssertEqual(model.workDate, today)
    }

    // MARK: - (j) 완료 업무 처음부터 등록

    @MainActor
    func testRegistersAsCompletedSavesCompletedTask() async throws {
        let env = try environment()
        let model = CaptureModel(environment: env)
        model.kind = .task
        XCTAssertEqual(model.taskSelection, .newTask)
        XCTAssertFalse(model.registersAsCompleted)

        model.registersAsCompleted = true
        XCTAssertTrue(model.registersAsCompleted)
        model.text = "완료한 업무\n본문"
        XCTAssertTrue(model.submit())

        let taskId = try XCTUnwrap(model.lastSavedId)
        XCTAssertEqual(try env.tasks.currentStatus(taskId: taskId), .completed)
        XCTAssertFalse(model.registersAsCompleted, "저장 후 기본값(예정)으로 돌아간다")
    }

    // MARK: - (k) 세션 초안 유지·저장 후 오늘 시작

    @MainActor
    func testSessionPreservesPastDateAndStartsTodayAfterSave() async throws {
        let env = try environment(defaultKind: .memo)
        let today = today(env)
        let yesterday = env.calendar.adding(days: -1, to: today)
        let model = CaptureSessionModel(environment: env)
        model.beginSession()

        model.memoDraft.text = "보존할 초안"
        model.memoDraft.workDate = yesterday

        // Esc로 닫았다 다시 열어도 초안과 업무일이 유지된다.
        model.beginSession()
        XCTAssertEqual(model.memoDraft.text, "보존할 초안")
        XCTAssertEqual(model.memoDraft.workDate, yesterday)

        XCTAssertTrue(model.submitOrdinary())
        model.markSessionCompleted()
        model.beginSession()

        XCTAssertTrue(model.memoDraft.text.isEmpty)
        XCTAssertEqual(model.memoDraft.workDate, today, "저장 완료 후 새 세션은 오늘로 시작")
    }
}
