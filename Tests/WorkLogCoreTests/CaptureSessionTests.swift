import XCTest
@testable import WorkLogCore

/// O: 빠른 입력 패널의 세 탭(메모/업무/시크릿) 상태와 탭별 일반 초안을 관리하는 세션 모델.
///
/// - 탭 순환·역순·select, 탭 전환이 설정을 바꾸지 않음.
/// - 새 세션 기본 탭(설정 memo/task/secret 각각).
/// - Esc로 닫고 다시 열면 탭·초안 유지, 저장 성공 후 새 세션 기본값 복귀.
/// - 두 일반 초안 독립성, 고정 kind.
/// - Secret 탭 `submitOrdinary`가 false이고 DB 변화가 없음.
/// - 설정 기본값이 Secret이어도 메모 탭 저장 가능.
final class CaptureSessionTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func environment(defaultKind: CaptureKind = .memo) throws -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureSessionTests-\(UUID().uuidString)")
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

    private func memoCount(_ env: AppEnvironment) throws -> Int {
        let today = env.calendar.workDate(of: env.options.clock.now())
        return try env.repo.memos(on: today).count
    }

    // MARK: - 탭 순환·select

    @MainActor
    func testTabOrderAndCycling() async throws {
        XCTAssertEqual(CaptureSessionModel.tabOrder, [.memo, .task, .secret])

        let model = CaptureSessionModel(environment: try environment())
        model.beginSession()
        XCTAssertEqual(model.tab, .memo)

        model.cycleTab(backwards: false)
        XCTAssertEqual(model.tab, .task)
        model.cycleTab(backwards: false)
        XCTAssertEqual(model.tab, .secret)
        model.cycleTab(backwards: false)
        XCTAssertEqual(model.tab, .memo, "정방향 순환은 memo로 돌아온다")

        model.cycleTab(backwards: true)
        XCTAssertEqual(model.tab, .secret)
        model.cycleTab(backwards: true)
        XCTAssertEqual(model.tab, .task)
        model.cycleTab(backwards: true)
        XCTAssertEqual(model.tab, .memo, "역순 순환은 memo로 돌아온다")

        model.select(.secret)
        XCTAssertTrue(model.isSecretTab)
        XCTAssertNil(model.activeDraft)
        model.select(.task)
        XCTAssertFalse(model.isSecretTab)
        XCTAssertTrue(model.activeDraft === model.taskDraft)
    }

    @MainActor
    func testTabSwitchDoesNotChangeSettings() async throws {
        let env = try environment(defaultKind: .memo)
        let model = CaptureSessionModel(environment: env)
        model.beginSession()

        model.select(.task)
        model.cycleTab(backwards: false)   // secret
        model.cycleTab(backwards: true)    // task
        model.select(.memo)

        XCTAssertEqual(env.settings.defaultCaptureKind, .memo, "탭 전환은 설정을 바꾸지 않는다")
    }

    // MARK: - 새 세션 기본 탭

    @MainActor
    func testBeginSessionUsesDefaultTabForEachSetting() async throws {
        for kind in CaptureKind.allCases {
            let env = try environment(defaultKind: kind)
            let model = CaptureSessionModel(environment: env)
            model.beginSession()
            XCTAssertEqual(model.tab, kind, "새 세션 기본 탭 = 설정 \(kind)")
            XCTAssertEqual(model.isSecretTab, kind == .secret)
            XCTAssertEqual(model.activeDraft != nil, kind != .secret)
        }
    }

    @MainActor
    func testDraftKindsAreFixedRegardlessOfDefault() async throws {
        for kind in CaptureKind.allCases {
            let env = try environment(defaultKind: kind)
            let model = CaptureSessionModel(environment: env)
            model.beginSession()
            XCTAssertEqual(model.memoDraft.kind, .memo, "설정 \(kind)에서도 메모 초안 kind 고정")
            XCTAssertEqual(model.taskDraft.kind, .task, "설정 \(kind)에서도 업무 초안 kind 고정")
        }
    }

    // MARK: - Esc 재열기 보존 / 저장 후 초기화

    @MainActor
    func testReopenAfterEscPreservesTabAndDrafts() async throws {
        let env = try environment(defaultKind: .memo)
        let model = CaptureSessionModel(environment: env)
        model.beginSession()

        model.select(.task)
        model.memoDraft.text = "메모 초안"
        model.taskDraft.text = "업무 초안\n둘째 줄"

        // Esc 닫기: 별도 정리 호출 없이 패널을 다시 연다.
        model.beginSession()

        XCTAssertEqual(model.tab, .task, "Esc로 닫은 뒤 현재 탭 유지")
        XCTAssertEqual(model.memoDraft.text, "메모 초안")
        XCTAssertEqual(model.taskDraft.text, "업무 초안\n둘째 줄")
    }

    @MainActor
    func testSaveCompletionReturnsToDefaultSession() async throws {
        let env = try environment(defaultKind: .memo)
        let model = CaptureSessionModel(environment: env)
        model.beginSession()
        model.select(.task)
        model.taskDraft.text = "저장할 업무"

        XCTAssertTrue(model.submitOrdinary())
        model.markSessionCompleted()
        model.beginSession()

        XCTAssertEqual(model.tab, .memo, "저장 성공 후 새 세션은 기본 탭으로 복귀")
        XCTAssertTrue(model.memoDraft.text.isEmpty)
        XCTAssertTrue(model.taskDraft.text.isEmpty)
        XCTAssertEqual(model.memoDraft.kind, .memo)
        XCTAssertEqual(model.taskDraft.kind, .task, "제출 후에도 업무 초안 kind 고정")
    }

    @MainActor
    func testSaveCompletionWithTaskDefaultReturnsToTaskSession() async throws {
        let env = try environment(defaultKind: .task)
        let model = CaptureSessionModel(environment: env)
        model.beginSession()
        model.select(.memo)
        model.memoDraft.text = "저장할 메모"

        XCTAssertTrue(model.submitOrdinary())
        model.markSessionCompleted()
        model.beginSession()

        XCTAssertEqual(model.tab, .task, "기본값이 task면 새 세션 탭도 task")
        XCTAssertTrue(model.memoDraft.text.isEmpty)
    }

    // MARK: - 초안 독립성

    @MainActor
    func testDraftsAreIndependent() async throws {
        let env = try environment(defaultKind: .memo)
        let model = CaptureSessionModel(environment: env)
        model.beginSession()

        model.memoDraft.text = "메모 본문"
        model.taskDraft.text = "업무 본문"
        XCTAssertEqual(model.memoDraft.text, "메모 본문")
        XCTAssertEqual(model.taskDraft.text, "업무 본문")

        model.select(.memo)
        XCTAssertTrue(model.submitOrdinary())
        XCTAssertTrue(model.memoDraft.text.isEmpty, "메모 제출 후 메모 초안만 비운다")
        XCTAssertEqual(model.taskDraft.text, "업무 본문", "업무 초안은 영향받지 않는다")
        XCTAssertEqual(model.taskDraft.kind, .task)
    }

    // MARK: - Secret 탭 디스패치

    @MainActor
    func testSecretTabSubmitIsNoOpAndWritesNothing() async throws {
        let env = try environment(defaultKind: .memo)
        let model = CaptureSessionModel(environment: env)
        model.beginSession()
        model.memoDraft.text = "저장하면 안 되는 메모"
        model.taskDraft.text = "저장하면 안 되는 업무"

        model.select(.secret)
        let memosBefore = try memoCount(env)
        let tasksBefore = try env.repo.tasks().count

        XCTAssertFalse(model.submitOrdinary(), "Secret 탭에서는 일반 제출을 실행하지 않는다")
        XCTAssertNil(model.activeDraft)
        XCTAssertTrue(model.isSecretTab)
        XCTAssertEqual(model.memoDraft.text, "저장하면 안 되는 메모")
        XCTAssertEqual(model.taskDraft.text, "저장하면 안 되는 업무")
        XCTAssertNil(model.memoDraft.lastSavedId)
        XCTAssertNil(model.taskDraft.lastSavedId)
        XCTAssertEqual(try memoCount(env), memosBefore, "DB에 메모가 추가되지 않는다")
        XCTAssertEqual(try env.repo.tasks().count, tasksBefore, "DB에 업무가 추가되지 않는다")
    }

    @MainActor
    func testSecretDefaultStillAllowsMemoTabSubmit() async throws {
        let env = try environment(defaultKind: .secret)
        let model = CaptureSessionModel(environment: env)
        model.beginSession()
        XCTAssertEqual(model.tab, .secret)
        XCTAssertTrue(model.isSecretTab)

        model.select(.memo)
        model.memoDraft.text = "시크릿 기본값에서 저장한 메모"
        XCTAssertTrue(model.submitOrdinary())

        let id = try XCTUnwrap(model.memoDraft.lastSavedId)
        XCTAssertEqual(try env.repo.memo(id: id)?.body, "시크릿 기본값에서 저장한 메모")
        XCTAssertEqual(try env.repo.tasks().count, 0)
    }

    @MainActor
    func testMemoTabSubmitSavesMemoWhenDefaultIsTask() async throws {
        let env = try environment(defaultKind: .task)
        let model = CaptureSessionModel(environment: env)
        model.beginSession()
        model.select(.memo)
        model.memoDraft.text = "task 기본값에서도 메모"

        XCTAssertTrue(model.submitOrdinary())
        let id = try XCTUnwrap(model.memoDraft.lastSavedId)
        XCTAssertEqual(try env.repo.memo(id: id)?.body, "task 기본값에서도 메모")
        XCTAssertEqual(try env.repo.tasks().count, 0, "메모 탭 제출이 업무를 만들지 않는다")
    }

    // MARK: - detach

    @MainActor
    func testDetachReleasesEnvironmentAndLaterCallsAreHarmless() async throws {
        var env: AppEnvironment? = try environment()
        weak var weakEnvironment: AppEnvironment?
        weakEnvironment = env
        let model = CaptureSessionModel(environment: try XCTUnwrap(env))
        model.beginSession()
        model.memoDraft.text = "초안"

        model.detach()
        env = nil
        XCTAssertNil(weakEnvironment, "detach가 environment 참조를 놓는다")

        // 이후 호출은 무해해야 한다.
        model.beginSession()
        model.select(.task)
        XCTAssertEqual(model.tab, .task)
        model.memoDraft.text = "detach 후 초안"
        XCTAssertFalse(model.submitOrdinary(), "저장소가 없으면 일반 제출은 무해하게 실패한다")
        model.memoDraft.resetDefaults()
        model.memoDraft.reloadCandidates()
        XCTAssertNil(model.memoDraft.errorMessage)
    }
}
