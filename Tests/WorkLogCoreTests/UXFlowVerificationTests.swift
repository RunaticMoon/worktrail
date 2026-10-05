import XCTest
@testable import WorkLogCore

/// UXFL-E55A P — 필수 검증 흐름 중 기존 테스트가 직접 덮지 않던 Core 경로를 흐름 단위로 확인한다.
///
/// - ① 한국어 메모 전체 보존(스칼라 단위)·두 번째 저장으로 중복이 생기지 않음.
/// - ② 어제 한 일을 오늘 입력 → 어제 업무일에 연결, 저장 후 업무일 오늘 복귀.
/// - ③ 기존 업무 선택 시 기본 동작이 진행 기록 추가, 상태·업무 수 불변.
/// - ⑤ 검색 → 원문 읽기 → 다른 화면 → 검색 상태 복원(새 결과가 생겨도 선택 유지).
/// - ⑨ SecretsModel 경로의 저장 시 trim·부분 수정·가림 문자 거부·이전 버전·휴지통 복원과 값 미노출 문구.
/// - ⑩ 긴 한국어 + AI 오프라인에서 로컬 저장·검색·보고 편집본 보존.
/// - 보안: Secret 제목·key·value가 work.sqlite·일반 검색·AI 입력에 들어가지 않음.
///
/// 가짜 데이터만 쓰며 실제 Keychain·자격증명·회사 기록을 읽지 않는다. 시계는 2026-10-05(월) 10:00 KST 고정.
final class UXFlowVerificationTests: XCTestCase {
    private let monday = WorkDate("2026-10-05")!
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func environment(provider: AIProvider? = nil, aiEnabled: Bool = false,
                             pasteboard: InMemoryPasteboard = InMemoryPasteboard()) throws -> (AppEnvironment, AppPaths) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UXFlowVerificationTests-\(UUID().uuidString)")
        roots.append(root)
        let paths = AppPaths(dataRoot: root.appendingPathComponent("data"),
                             backupRoot: root.appendingPathComponent("backups"))
        var settings = AppSettings()
        settings.aiEnabled = aiEnabled
        try SettingsStore(fileURL: paths.settingsFile).save(settings)
        let now = WorkCalendar().startOfDay(monday).addingTimeInterval(10 * 3600)
        let env = try AppEnvironment.open(AppEnvironmentOptions(
            paths: paths, keyStore: InMemoryVaultKeyStore(),
            authenticator: MockDeviceAuthenticator(), pasteboard: pasteboard,
            aiProvider: provider, clock: FixedClock(now), ids: SequentialIDGenerator()))
        return (env, paths)
    }

    private func today(_ env: AppEnvironment) -> WorkDate {
        env.calendar.workDate(of: env.options.clock.now())
    }

    private func fileBytes(_ url: URL) -> Data {
        var data = Data()
        for suffix in ["", "-wal", "-shm", "-journal"] {
            if let chunk = FileManager.default.contents(atPath: url.path + suffix) { data.append(chunk) }
        }
        return data
    }

    private func contains(_ needle: String, in data: Data) -> Bool {
        data.range(of: Data(needle.utf8)) != nil
    }

    // MARK: - ① 한국어 메모 전체 보존·중복 저장 없음

    @MainActor func testKoreanMemoKeepsEveryScalarAndSecondSubmitDoesNotDuplicate() async throws {
        let (env, _) = try environment()
        XCTAssertEqual(today(env), monday)
        // NFC 음절, NFD 자모(한), 이모지, 탭, CRLF, 앞뒤 공백, 받침으로 끝나는 마지막 글자를 함께 넣는다.
        let nfdHan = "\u{1112}\u{1161}\u{11AB}"
        let body = "  배포 점검 완료했음\t(⌘↩)\r\n\(nfdHan)글 조합 확인 🙂\n마지막 글자 받침 끝"
        let capture = CaptureModel(environment: env)
        XCTAssertEqual(capture.kind, .memo, "기본 입력 유형은 Memo")
        capture.text = body
        XCTAssertTrue(capture.submit())
        XCTAssertEqual(capture.text, "", "저장 성공 후 초안을 비운다")

        // 같은 입력창에서 다시 저장해도(⌘Return 연타) 새 메모가 생기지 않는다.
        XCTAssertFalse(capture.submit())
        XCTAssertEqual(capture.errorMessage, "저장할 내용을 입력하세요.")

        let memos = try env.repo.memos(on: monday)
        XCTAssertEqual(memos.count, 1)
        let stored = try XCTUnwrap(memos.first?.body)
        XCTAssertEqual(Array(stored.unicodeScalars), Array(body.unicodeScalars),
                       "정규화·trim 없이 스칼라 단위로 그대로 저장")
        XCTAssertEqual(stored.last, "끝", "마지막 한글 글자가 유실되지 않는다")

        let search = SearchModel(environment: env)
        search.text = "받침"; search.search()
        XCTAssertEqual(search.hits.map(\.sourceId), [try XCTUnwrap(capture.lastSavedId)])
    }

    // MARK: - ② 어제 한 일을 오늘 입력

    @MainActor func testYesterdayWorkEnteredTodayLinksToYesterdayAndNextEntryStartsToday() async throws {
        let (env, _) = try environment()
        let yesterday = env.calendar.adding(days: -1, to: monday)
        let capture = CaptureModel(environment: env)
        capture.kind = .task
        XCTAssertEqual(capture.taskSelection, .newTask)
        capture.registersAsCompleted = true
        capture.workDate = yesterday
        XCTAssertTrue(capture.isPastWorkDate)
        XCTAssertTrue(capture.workDateLabel.hasPrefix("과거 날짜 · 10월 4일(일)"))
        capture.text = "어제 끝낸 배포 점검\n로그 확인까지 마침"
        XCTAssertTrue(capture.submit())
        let taskId = try XCTUnwrap(capture.lastSavedId)

        XCTAssertEqual(capture.workDate, monday, "저장 후 다음 기록은 오늘로 시작")
        XCTAssertFalse(capture.isPastWorkDate)
        XCTAssertEqual(capture.workDateLabel, "오늘 · 10월 5일(월)")

        let detail = try env.tasks.detail(taskId: taskId)
        XCTAssertEqual(detail.task.title, "어제 끝낸 배포 점검")
        XCTAssertEqual(detail.status, .completed)
        XCTAssertEqual(detail.completionDates, [yesterday], "완료일은 입력한 어제 업무일")

        let yesterdayBox = try env.dayBox.dayBox(for: yesterday)
        XCTAssertTrue(yesterdayBox.isPast)
        XCTAssertEqual(yesterdayBox.tasks.first { $0.taskId == taskId }?.completedOnDay, true)
        let todayBox = try env.dayBox.dayBox(for: monday)
        XCTAssertNotEqual(todayBox.tasks.first { $0.taskId == taskId }?.completedOnDay, true,
                          "오늘 날짜에는 완료 사건이 붙지 않는다")

        // 이어서 쓰는 다음 메모는 과거 날짜가 몰래 유지되지 않고 오늘에 저장된다.
        capture.kind = .memo
        capture.text = "오늘 메모"
        XCTAssertTrue(capture.submit())
        XCTAssertEqual(try env.repo.memos(on: monday).map(\.body), ["오늘 메모"])
        XCTAssertTrue(try env.repo.memos(on: yesterday).isEmpty)
    }

    // MARK: - ③ 기존 업무에 진행 기록 추가

    @MainActor func testExistingTaskSelectionDefaultsToProgressRecordAndKeepsStatus() async throws {
        let (env, _) = try environment()
        let yesterday = env.calendar.adding(days: -1, to: monday)
        let task = try env.tasks.createTask(title: "결제 모듈 개선", initialStatus: .inProgress,
                                            workDate: env.calendar.adding(days: -3, to: monday),
                                            projectNames: ["G", "J"], trackingMode: .perProject)
        let gId = try XCTUnwrap(env.tasks.detail(taskId: task.id).projects.first { $0.project.name == "G" }?.project.id)
        let taskCount = try env.repo.tasks().count

        let capture = CaptureModel(environment: env)
        capture.kind = .task
        capture.taskQuery = "결제"
        XCTAssertEqual(capture.filteredTasks.map(\.id), [task.id])
        capture.taskSelection = .existing(task.id)
        XCTAssertEqual(capture.taskAction, .addActivity, "기존 업무 선택의 기본 동작은 진행 기록 추가")
        capture.workDate = yesterday
        capture.addProject(id: gId)
        capture.text = "G 환경 회귀 테스트 통과"
        XCTAssertTrue(capture.submit())

        let activities = try env.repo.activities(taskId: task.id)
        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(activities.first?.body, "G 환경 회귀 테스트 통과")
        XCTAssertEqual(activities.first?.workDate, yesterday)
        XCTAssertEqual(activities.first?.projectIds, [gId], "특정 프로젝트 기록으로 구분")
        XCTAssertEqual(try env.tasks.currentStatus(taskId: task.id), .inProgress, "진행 기록은 상태를 바꾸지 않는다")
        XCTAssertEqual(try env.repo.tasks().count, taskCount, "진행 기록이 업무를 복제하지 않는다")
        XCTAssertEqual(capture.workDate, monday)
        XCTAssertEqual(capture.taskSelection, .newTask)
    }

    // MARK: - ⑤ 검색 → 원문 → 검색 상태 복원

    @MainActor func testSearchOpenOriginalThenRestoreKeepsQueryFiltersAndSelection() async throws {
        let provider = MockAIProvider()
        let (env, _) = try environment(provider: provider, aiEnabled: true)
        let recordedAt = env.options.clock.now()
        let project = try env.repo.createProject(name: "원문프로젝트")
        let longBody = "원문복원 첫 줄\n" + String(repeating: "자세한 내용 ", count: 80) + "\n끝줄"
        try env.repo.insertMemo(Memo(id: "orig-1", body: "원문복원 알파", workDate: monday,
                                     recordedAt: recordedAt, projectIds: [project.id]))
        try env.repo.insertMemo(Memo(id: "orig-2", body: longBody, workDate: monday,
                                     recordedAt: recordedAt, projectIds: [project.id]))
        try env.repo.insertMemo(Memo(id: "orig-3", body: "원문복원 필터밖", workDate: monday, recordedAt: recordedAt))

        let search = SearchModel(environment: env)
        search.text = "원문복원"; search.projectIds = [project.id]
        search.search()
        XCTAssertEqual(Set(search.hits.map(\.sourceId)), ["orig-1", "orig-2"])
        let target = try XCTUnwrap(search.hits.first { $0.sourceId == "orig-2" })
        search.select(target)
        let saved = search.snapshot()

        // 원문 열기(SearchScreen.openSource와 같은 저장소 읽기)는 검색 상태를 바꾸지 않는다.
        XCTAssertEqual(try env.repo.memo(id: target.sourceId)?.body, longBody, "원문은 스니펫이 아닌 전체 본문")
        XCTAssertEqual(search.snapshot(), saved)

        // 다른 화면에서 새 기록이 생기고 검색 화면이 다른 상태로 바뀐 뒤 복원한다.
        try env.repo.insertMemo(Memo(id: "orig-0", body: "원문복원 새로생김", workDate: monday,
                                     recordedAt: recordedAt, projectIds: [project.id]))
        search.text = "다른 검색"; search.projectIds = []; search.search()
        search.restore(saved)
        XCTAssertEqual(search.text, "원문복원")
        XCTAssertEqual(search.projectIds, [project.id])
        XCTAssertEqual(Set(search.hits.map(\.sourceId)), ["orig-0", "orig-1", "orig-2"])
        XCTAssertEqual(search.selectedHit?.sourceId, "orig-2", "새 결과가 생겨도 선택이 몰래 바뀌지 않는다")
        XCTAssertEqual(provider.runCount, 0, "검색·원문·복원은 AI를 호출하지 않는다")
    }

    // MARK: - ⑧⑨ Secret 조회/편집·trim·부분 수정·이전 버전·휴지통

    @MainActor func testSecretFlowTrimOnSavePartialEditRevisionTrashAndConcealedFeedback() async throws {
        let board = InMemoryPasteboard()
        let (env, _) = try environment(pasteboard: board)
        let model = SecretsModel(environment: env)
        let valueA = "fake-Token Value\nsecond line"
        let valueB1 = "ap-Northeast-2"
        let valueB2 = "us-West-1"
        var messages: [String] = []
        func note() { if let message = model.message { messages.append(message) } }

        await model.unlock()
        model.beginNew()
        model.title = "가짜 배포 계정"
        model.addRow(); model.rows[0].key = "  API_TOKEN  "; model.rows[0].value = "  \(valueA)  \n"
        model.addRow(); model.rows[1].key = "Region"; model.rows[1].value = valueB1
        XCTAssertEqual(model.rows[0].key, "  API_TOKEN  ", "입력 중에는 trim하지 않는다")
        XCTAssertEqual(model.rows[0].value, "  \(valueA)  \n")
        XCTAssertTrue(model.save()); note()
        let id = try XCTUnwrap(model.selectedId)
        let saved = try env.vaultSession.currentRows(secretId: id)
        XCTAssertEqual(saved.map(\.key), ["API_TOKEN", "Region"])
        XCTAssertEqual(saved.map(\.value), [valueA, valueB1], "앞뒤만 trim, 내부 공백·개행·대소문자 보존")
        XCTAssertFalse(model.isEditing)

        // 조회 상태: ↑↓ 포커스는 복사하지 않고, 명시 실행만 복사한다.
        model.moveFocus(by: 1)
        XCTAssertNil(board.string)
        model.copyFocusedRow(); note()
        XCTAssertEqual(board.string, valueA)

        // 부분 수정: 다른 행은 id·값 유지, 저장 단위로 버전 증가.
        model.beginEditing()
        model.rows[1].value = valueB2
        XCTAssertTrue(model.save()); note()
        let afterEdit = try env.vaultSession.currentRows(secretId: id)
        XCTAssertEqual(afterEdit[0], saved[0], "수정하지 않은 행은 그대로")
        XCTAssertEqual(afterEdit[1].id, saved[1].id)
        XCTAssertEqual(afterEdit[1].value, valueB2)
        XCTAssertEqual(model.revisions.map(\.version), [1, 2])

        // 가림 문자만 입력된 값은 저장하지 않고 다른 행·입력을 보존한다.
        model.beginEditing()
        model.rows[0].value = "••••••"
        XCTAssertFalse(model.save()); note()
        XCTAssertEqual(model.maskedRowIds, [saved[0].id])
        XCTAssertEqual(model.rows[1].value, valueB2)
        XCTAssertEqual(try env.vaultSession.currentRows(secretId: id), afterEdit)
        model.cancelEditing()

        // 이전 버전을 새 버전으로 복원.
        model.selectRevision(try XCTUnwrap(model.revisions.first { $0.version == 1 }))
        model.restoreSelectedRevision(); note()
        XCTAssertEqual(try env.vaultSession.currentRows(secretId: id).map(\.value), [valueA, valueB1])
        XCTAssertEqual(model.revisions.map(\.version), [1, 2, 3])

        // 휴지통 이동 후 복원: 행과 버전 유지.
        model.moveToTrash(); note()
        XCTAssertTrue(model.titles.isEmpty)
        model.restoreTrash(id)
        model.open(try XCTUnwrap(model.titles.first { $0.id == id }))
        XCTAssertEqual(model.rows.map(\.value), [valueA, valueB1])
        XCTAssertEqual(model.revisions.count, 3)
        XCTAssertFalse(model.showsValues, "다시 열면 값은 기본 가림")

        XCTAssertFalse(messages.isEmpty)
        for message in messages {
            for secret in [valueA, "fake-Token", valueB1, valueB2] {
                XCTAssertFalse(message.contains(secret), "피드백 문구에 값이 없어야 한다: \(message)")
            }
        }
    }

    // MARK: - ⑦⑩ 긴 한국어·AI 오프라인

    @MainActor func testOfflineAIKeepsLocalCaptureSearchAndEditedReport() async throws {
        let provider = MockAIProvider()
        provider.failure = AIProviderError(.network, "offline")
        let (env, _) = try environment(provider: provider, aiEnabled: true)
        let prior = WorkDate("2026-09-30")!
        let task = try env.tasks.createTask(title: "오프라인 보고 대상", initialStatus: .inProgress, workDate: prior)
        _ = try env.tasks.addActivity(taskId: task.id, body: "지난주 수행 근거", workDate: prior)

        // 긴 한국어 메모: AI 실패와 무관하게 즉시 로컬 저장.
        let longKorean = (1...400).map { "\($0)번째 문단 한국어 업무 기록 검증 장문표식" }.joined(separator: "\n")
        let capture = CaptureModel(environment: env)
        capture.text = longKorean
        XCTAssertTrue(capture.submit())
        XCTAssertEqual(try env.repo.memos(on: monday).first?.body, longKorean)
        XCTAssertEqual(provider.runCount, 0, "저장은 AI를 기다리지 않는다")

        // 검색은 로컬 결과를 그대로 보여주고, 명시 실행한 AI 답변 실패는 결과를 지우지 않는다.
        let search = SearchModel(environment: env)
        search.text = "장문표식"; search.search()
        XCTAssertEqual(search.hits.count, 1)
        search.select(try XCTUnwrap(search.hits.first))
        XCTAssertEqual(provider.runCount, 0)
        await search.askAI()
        XCTAssertGreaterThan(provider.runCount, 0)
        XCTAssertEqual(search.aiMessage, "AI 답변을 만들지 못했습니다. 잠시 후 다시 요청하세요.")
        XCTAssertEqual(search.hits.count, 1)
        XCTAssertNotNil(search.selectedHit, "AI 실패 후에도 선택·결과 유지")
        XCTAssertNil(search.errorMessage)

        // 주간보고: 기록 기반 초안은 AI 없이, AI 재생성이 실패해도 수정본은 보존.
        let reports = ReportsModel(environment: env)
        XCTAssertTrue(reports.useAI)
        let runsBeforeReport = provider.runCount
        await reports.ensureDraftForCurrentPeriod()
        XCTAssertEqual(provider.runCount, runsBeforeReport, "자동 초안은 AI를 부르지 않는다")
        reports.content = "직접 고친 보고 본문"
        reports.saveEdits()
        let edited = try XCTUnwrap(reports.version)
        XCTAssertEqual(edited.state, .edited)

        await reports.generate()
        XCTAssertGreaterThan(provider.runCount, runsBeforeReport, "명시 재생성에서만 AI를 시도")
        XCTAssertEqual(reports.version?.id, edited.id, "AI 실패 재생성도 화면의 수정본을 바꾸지 않는다")
        XCTAssertEqual(reports.content, "직접 고친 보고 본문")
        XCTAssertEqual(try env.repo.reportVersion(id: edited.id)?.state, .edited)
        XCTAssertEqual(try env.repo.reportVersion(id: edited.id)?.content, "직접 고친 보고 본문")
        if let pending = reports.pendingRegeneration { XCTAssertNotEqual(pending.id, edited.id) }

        reports.markCopied()
        XCTAssertEqual(reports.statusMessage, "클립보드에 복사했습니다 · 제출 상태는 바뀌지 않습니다")
        XCTAssertEqual(try env.repo.reportVersion(id: edited.id)?.state, .edited, "복사만으로 확정되지 않는다")

        // 실패 문구 형식: 무엇이 실패 · 무엇은 보존 · 재시도 방법.
        XCTAssertEqual(RecoveryMessage.aiDraftFailed.text, "AI 초안을 만들지 못했습니다 · 기존 본문은 그대로입니다 · 다시 시도하세요")
    }

    @MainActor func testAIUnconnectedStillAllowsFirstMemoSearchAndDraft() async throws {
        let (env, _) = try environment(provider: nil, aiEnabled: false)
        let capture = CaptureModel(environment: env)
        capture.text = "AI 로그인 없이 첫 메모"
        XCTAssertTrue(capture.submit())
        let search = SearchModel(environment: env)
        XCTAssertFalse(search.isAIAvailable)
        search.text = "첫 메모"; search.search()
        XCTAssertEqual(search.hits.count, 1)
        await search.askAI()
        XCTAssertEqual(search.aiMessage, "AI가 비활성화되어 있습니다. 원문 검색은 사용할 수 있습니다.")
        XCTAssertEqual(search.hits.count, 1)
        let reports = ReportsModel(environment: env)
        await reports.ensureDraftForCurrentPeriod()
        XCTAssertEqual(reports.version?.generator, "deterministic")
        XCTAssertNil(reports.errorMessage)
    }

    // MARK: - 보안: Secret은 work.sqlite·일반 검색·AI 입력에 없음

    @MainActor func testSecretTitleKeyAndValueNeverReachWorkDatabaseSearchOrAIInput() async throws {
        let provider = MockAIProvider()
        let (env, paths) = try environment(provider: provider, aiEnabled: true)
        let title = "UXFLP제목카나리"
        let key = "UXFLP_KEY_CANARY"
        let value = "UXFLP-VALUE-CANARY-7731"
        let secrets = SecretsModel(environment: env)
        await secrets.unlock()
        secrets.beginNew()
        secrets.title = title
        secrets.addRow(); secrets.rows[0].key = key; secrets.rows[0].value = value
        XCTAssertTrue(secrets.save())
        secrets.moveFocus(by: 1); secrets.copyFocusedRow()
        XCTAssertFalse(secrets.message?.contains(value) ?? false)
        XCTAssertEqual(secrets.titles.map(\.title), [title], "Secret 제목 검색은 Secret 범위에서만")

        let capture = CaptureModel(environment: env)
        capture.text = "카나리 근처 일반 메모 UXFLP"
        XCTAssertTrue(capture.submit())

        let search = SearchModel(environment: env)
        for query in [title, key, value] {
            search.text = query; search.search()
            XCTAssertTrue(search.hits.isEmpty, "일반 검색에 Secret이 나오지 않는다: \(query)")
        }
        search.text = "UXFLP"; search.search()
        XCTAssertEqual(search.hits.count, 1)
        await search.askAI()
        XCTAssertGreaterThan(provider.runCount, 0)
        for input in provider.receivedInputs {
            for canary in [title, key, value] {
                XCTAssertFalse(input.instructions.contains(canary))
                XCTAssertFalse(input.payloadJSON.contains(canary))
            }
        }

        let workBytes = fileBytes(paths.workDatabase)
        XCTAssertFalse(workBytes.isEmpty)
        for canary in [title, key, value] {
            XCTAssertFalse(contains(canary, in: workBytes), "work.sqlite에 Secret이 남음: \(canary)")
        }
        XCTAssertFalse(contains(value, in: fileBytes(paths.vaultDatabase)), "vault에도 값 평문 없음")
    }
}
