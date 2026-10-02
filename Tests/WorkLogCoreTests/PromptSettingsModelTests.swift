import XCTest
@testable import WorkLogCore

/// V: 작업별 프롬프트 편집 Presentation 모델 검증.
/// 모델은 설정 JSON·skillBindings와 독립적으로 work.sqlite의 template_version만 사용한다.
final class PromptSettingsModelTests: XCTestCase {

    private var repo: WorkRepository!

    private func makeStore(seed: Bool = false) throws -> TemplateStore {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_790_000_000))
        let repo = try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator(prefix: "t"))
        self.repo = repo
        let store = TemplateStore(repo: repo)
        if seed { try store.seedDefaults() }
        return store
    }

    private let submissionId = "submission.weekly.default.v1"

    // MARK: 1 — load: 활성 값·내장 기본값 표시

    @MainActor
    func testLoadShowsActiveAndBuiltInValues() async throws {
        // 시드하지 않아도 load가 기본값을 시드해 템플릿을 찾아야 한다.
        let store = try makeStore()
        let model = PromptSettingsModel(templates: store)

        model.load(purpose: .submissionWeekly)

        let builtIn = DefaultPrompts.template(for: .submissionWeekly)
        XCTAssertEqual(model.purpose, .submissionWeekly)
        XCTAssertEqual(model.builtInInstructions, builtIn.instructions)
        XCTAssertEqual(model.builtInOutputExample, builtIn.outputExample)
        XCTAssertEqual(model.activeVersionNumber, 1)
        XCTAssertEqual(model.savedInstructions, builtIn.instructions)
        XCTAssertEqual(model.savedOutputExample, builtIn.outputExample)
        XCTAssertEqual(model.instructions, builtIn.instructions)
        XCTAssertEqual(model.outputExample, builtIn.outputExample)
        XCTAssertFalse(model.hasChanges)
        XCTAssertTrue(model.isBuiltInActive)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.protectedPreamble, DefaultPrompts.commonInstructions)
    }

    // MARK: 2 — 수정 저장 → 새 버전·활성화, 새 인스턴스(재시작)에서 유지

    @MainActor
    func testSaveCreatesNewVersionAndPersistsAcrossModelInstances() async throws {
        let store = try makeStore(seed: true)
        let model = PromptSettingsModel(templates: store)
        model.load(purpose: .submissionWeekly)

        model.instructions = "팀 전용 문체 지침"
        model.outputExample = "팀 전용 출력 예시"
        XCTAssertTrue(model.hasChanges)
        XCTAssertTrue(model.save())

        XCTAssertEqual(model.activeVersionNumber, 2)
        XCTAssertEqual(model.savedInstructions, "팀 전용 문체 지침")
        XCTAssertEqual(model.savedOutputExample, "팀 전용 출력 예시")
        XCTAssertFalse(model.hasChanges)
        XCTAssertFalse(model.isBuiltInActive)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try store.versions(templateId: submissionId).count, 2)

        // 재시작 시뮬레이션: 같은 저장소로 새 모델 인스턴스를 만든다.
        let restarted = PromptSettingsModel(templates: store)
        restarted.load(purpose: .submissionWeekly)
        XCTAssertEqual(restarted.savedInstructions, "팀 전용 문체 지침")
        XCTAssertEqual(restarted.savedOutputExample, "팀 전용 출력 예시")
        XCTAssertEqual(restarted.activeVersionNumber, 2)
        XCTAssertFalse(restarted.hasChanges)
        XCTAssertFalse(restarted.isBuiltInActive)
    }

    // MARK: 3 — 동일 내용 저장은 no-op (버전 수 불변)

    @MainActor
    func testSaveUnchangedIsNoOp() async throws {
        let store = try makeStore(seed: true)
        let model = PromptSettingsModel(templates: store)
        model.load(purpose: .submissionWeekly)

        XCTAssertFalse(model.hasChanges)
        XCTAssertTrue(model.save())
        XCTAssertEqual(try store.versions(templateId: submissionId).count, 1)
        XCTAssertEqual(model.activeVersionNumber, 1)
    }

    // MARK: 4 — 빈 지침 거절, 오류 문구에 경로·SQL 노출 없음

    @MainActor
    func testSaveRejectsEmptyInstructionsWithoutLeakingDetails() async throws {
        let store = try makeStore(seed: true)
        let model = PromptSettingsModel(templates: store)
        model.load(purpose: .submissionWeekly)

        model.instructions = "   \n  "
        XCTAssertFalse(model.save())

        let error = try XCTUnwrap(model.errorMessage)
        XCTAssertFalse(error.contains("SELECT"))
        XCTAssertFalse(error.contains("sqlite"))
        XCTAssertFalse(error.contains("template_version"))
        XCTAssertEqual(try store.versions(templateId: submissionId).count, 1)
        XCTAssertEqual(model.savedInstructions, DefaultPrompts.template(for: .submissionWeekly).instructions)
    }

    // MARK: 5 — 기본값 복원은 새 버전을 만들고 과거 버전을 보존

    @MainActor
    func testRestoreBuiltInCreatesNewVersionAndPreservesHistory() async throws {
        let store = try makeStore(seed: true)
        let model = PromptSettingsModel(templates: store)
        model.load(purpose: .submissionWeekly)

        // 먼저 사용자 수정(v2).
        model.instructions = "사용자 수정 지침"
        model.outputExample = ""
        XCTAssertTrue(model.save())
        XCTAssertEqual(model.activeVersionNumber, 2)

        // 기본값 복원(v3).
        XCTAssertTrue(model.restoreBuiltInDefault())
        let builtIn = DefaultPrompts.template(for: .submissionWeekly)
        XCTAssertEqual(model.activeVersionNumber, 3)
        XCTAssertEqual(model.savedInstructions, builtIn.instructions)
        XCTAssertEqual(model.savedOutputExample, builtIn.outputExample)
        XCTAssertTrue(model.isBuiltInActive)
        XCTAssertFalse(model.hasChanges)

        let versions = try store.versions(templateId: submissionId)
        XCTAssertEqual(versions.count, 3)
        XCTAssertEqual(versions[1].instructions, "사용자 수정 지침")
        XCTAssertEqual(versions[1].version, 2)
        XCTAssertEqual(versions[2].instructions, builtIn.instructions)

        // 이미 기본값이면 새 버전을 만들지 않는다.
        XCTAssertTrue(model.restoreBuiltInDefault())
        XCTAssertEqual(try store.versions(templateId: submissionId).count, 3)
        XCTAssertEqual(model.activeVersionNumber, 3)
    }

    // MARK: 6 — discardChanges

    @MainActor
    func testDiscardChangesResetsDrafts() async throws {
        let store = try makeStore(seed: true)
        let model = PromptSettingsModel(templates: store)
        model.load(purpose: .submissionWeekly)
        let saved = model.savedInstructions

        model.instructions = "버릴 초안"
        model.outputExample = "버릴 예시"
        XCTAssertTrue(model.hasChanges)

        model.discardChanges()
        XCTAssertEqual(model.instructions, saved)
        XCTAssertEqual(model.outputExample, model.savedOutputExample)
        XCTAssertFalse(model.hasChanges)
    }

    // MARK: 7 — Daily / Periodic purpose 독립

    @MainActor
    func testDailyAndPeriodicAreIndependent() async throws {
        let store = try makeStore(seed: true)
        let model = PromptSettingsModel(templates: store)

        model.load(purpose: .performanceDaily)
        let dailyBuiltIn = DefaultPrompts.template(for: .performanceDaily).instructions
        XCTAssertEqual(model.savedInstructions, dailyBuiltIn)
        model.instructions = "일일 전용 지침"
        XCTAssertTrue(model.save())
        XCTAssertEqual(model.activeVersionNumber, 2)

        // 같은 모델로 Periodic을 로드하면 Daily 활성값이 아니라 Periodic 내장값이 보인다.
        model.load(purpose: .performancePeriodic)
        let periodicBuiltIn = DefaultPrompts.template(for: .performancePeriodic).instructions
        XCTAssertEqual(model.savedInstructions, periodicBuiltIn)
        XCTAssertTrue(model.isBuiltInActive)
        model.instructions = "주월분기연간 전용 지침"
        XCTAssertTrue(model.save())
        XCTAssertEqual(model.activeVersionNumber, 2)

        // 서로의 버전에 영향을 주지 않는다.
        XCTAssertEqual(try store.versions(templateId: "performance.daily.default.v1").count, 2)
        XCTAssertEqual(try store.versions(templateId: "performance.periodic.default.v1").count, 2)
        XCTAssertEqual(try store.activeVersion(templateId: "performance.daily.default.v1")?.instructions,
                       "일일 전용 지침")
        XCTAssertEqual(try store.activeVersion(templateId: "performance.periodic.default.v1")?.instructions,
                       "주월분기연간 전용 지침")

        // 재로드해도 각각 유지된다.
        let daily = PromptSettingsModel(templates: store)
        daily.load(purpose: .performanceDaily)
        XCTAssertEqual(daily.savedInstructions, "일일 전용 지침")
        let periodic = PromptSettingsModel(templates: store)
        periodic.load(purpose: .performancePeriodic)
        XCTAssertEqual(periodic.savedInstructions, "주월분기연간 전용 지침")
    }

    // MARK: 8 — detach 후 저장은 실패하되 크래시 없음

    @MainActor
    func testDetachPreventsFurtherSave() async throws {
        let store = try makeStore(seed: true)
        let model = PromptSettingsModel(templates: store)
        model.load(purpose: .submissionWeekly)
        model.instructions = "수정"

        model.detach()
        XCTAssertFalse(model.save())
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try store.versions(templateId: submissionId).count, 1)
    }
}
