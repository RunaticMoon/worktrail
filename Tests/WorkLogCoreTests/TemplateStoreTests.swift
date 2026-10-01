import XCTest
@testable import WorkLogCore

final class TemplateStoreTests: XCTestCase {

    private var repo: WorkRepository!

    private func makeStore() throws -> TemplateStore {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_790_000_000))
        let repo = try WorkRepository.inMemory(clock: clock, ids: SequentialIDGenerator(prefix: "t"))
        self.repo = repo
        return TemplateStore(repo: repo)
    }

    private let submissionId = "submission.weekly.default.v1"
    private let dailyId = "performance.daily.default.v1"
    private let periodicId = "performance.periodic.default.v1"

    // MARK: 1 — seedDefaults

    func testSeedDefaultsInsertsSevenOnce() throws {
        let store = try makeStore()

        XCTAssertEqual(try store.seedDefaults(), 7)
        let templates = try store.templates()
        XCTAssertEqual(templates.count, 7)

        for template in templates {
            let active = try XCTUnwrap(try store.activeVersion(templateId: template.id))
            XCTAssertEqual(active.version, 1)
            XCTAssertEqual(active.id, template.activeVersionId)
            XCTAssertEqual(try store.versions(templateId: template.id).count, 1)
        }

        // 두 번째 호출은 아무것도 삽입하지 않는다.
        XCTAssertEqual(try store.seedDefaults(), 0)
        XCTAssertEqual(try store.templates().count, 7)
    }

    // MARK: 2 — DefaultPrompts 내용 (REP-T03)

    func testDefaultPromptContentsAndSeparation() throws {
        XCTAssertEqual(DefaultPrompts.all.count, 7)
        XCTAssertEqual(Set(DefaultPrompts.all.map(\.purpose)), Set(TemplatePurpose.allCases))

        XCTAssertTrue(DefaultPrompts.commonInstructions
            .hasPrefix("너는 개인의 업무 기록을 정리하는 보조자다."))

        let submission = DefaultPrompts.template(for: .submissionWeekly)
        XCTAssertTrue(submission.instructions.contains("상세 성과용 Weekly 리포트가 아니다"))
        XCTAssertTrue(submission.outputExample.contains("기타"))

        let periodic = DefaultPrompts.template(for: .performancePeriodic)
        XCTAssertTrue(periodic.instructions.contains("제출용 주간보고 형식으로 축약하지 않는다"))

        // 제출용(P-01)과 상세 리포트(P-03)는 다른 템플릿 ID·purpose다.
        XCTAssertNotEqual(submission.id, periodic.id)
        XCTAssertNotEqual(submission.purpose, periodic.purpose)

        // P-02~P-07의 outputExample은 비어 있다.
        for purpose in [TemplatePurpose.performanceDaily, .performancePeriodic, .evidenceQuiz,
                        .memoTaskLinks, .queryPlan, .groundedAnswer] {
            XCTAssertEqual(DefaultPrompts.template(for: purpose).outputExample, "")
        }
    }

    // MARK: 3 — Secret 프롬프트 없음

    func testNoSecretPurposeOrId() throws {
        for template in DefaultPrompts.all {
            XCTAssertFalse(template.id.lowercased().contains("secret"),
                           "Secret id가 있으면 안 된다: \(template.id)")
        }
        for purpose in TemplatePurpose.allCases {
            XCTAssertFalse(purpose.rawValue.lowercased().contains("secret"))
        }
    }

    // MARK: 4 — saveNewVersion

    func testSaveNewVersionPreservesOldAndSkipsIdentical() throws {
        let store = try makeStore()
        try store.seedDefaults()
        let v1 = try XCTUnwrap(try store.activeVersion(templateId: submissionId))

        let v2 = try store.saveNewVersion(templateId: submissionId, instructions: "팀 문체 지침",
                                          outputExample: "예시 출력", skillRef: "skill-1")
        XCTAssertEqual(v2.version, 2)
        XCTAssertEqual(try store.activeVersion(templateId: submissionId)?.id, v2.id)

        let versions = try store.versions(templateId: submissionId)
        XCTAssertEqual(versions.count, 2)
        XCTAssertEqual(versions[0].version, 1)
        XCTAssertEqual(versions[0].instructions, v1.instructions)
        XCTAssertEqual(versions[0].outputExample, v1.outputExample)

        // 동일 내용 재저장은 새 버전을 만들지 않는다.
        let again = try store.saveNewVersion(templateId: submissionId, instructions: "팀 문체 지침",
                                             outputExample: "예시 출력", skillRef: "skill-1")
        XCTAssertEqual(again.id, v2.id)
        XCTAssertEqual(try store.versions(templateId: submissionId).count, 2)

        // 빈 지침은 validation 오류.
        XCTAssertThrowsError(try store.saveNewVersion(templateId: submissionId, instructions: "   ",
                                                      outputExample: "", skillRef: nil)) { error in
            guard case WorkLogError.validation = error else {
                return XCTFail("validation을 기대했으나 \(error)")
            }
        }
    }

    // MARK: 5 — setActiveVersion

    func testSetActiveVersionRevertsAndRejectsForeignVersion() throws {
        let store = try makeStore()
        try store.seedDefaults()
        let v1 = try XCTUnwrap(try store.activeVersion(templateId: submissionId))
        _ = try store.saveNewVersion(templateId: submissionId, instructions: "새 지침",
                                     outputExample: "", skillRef: nil)

        try store.setActiveVersion(templateId: submissionId, versionId: v1.id)
        XCTAssertEqual(try store.activeVersion(templateId: submissionId)?.id, v1.id)
        XCTAssertEqual(try store.versions(templateId: submissionId).count, 2, "되돌리기는 새 버전을 만들지 않는다")

        // 다른 템플릿의 버전 지정은 오류.
        let dailyV1 = try XCTUnwrap(try store.activeVersion(templateId: dailyId))
        XCTAssertThrowsError(try store.setActiveVersion(templateId: submissionId, versionId: dailyV1.id)) { error in
            guard case WorkLogError.validation = error else {
                return XCTFail("validation을 기대했으나 \(error)")
            }
        }
    }

    // MARK: 6 — clone (REP-T17)

    func testCloneIsIndependentFromSource() throws {
        let store = try makeStore()
        try store.seedDefaults()
        let sourceActive = try XCTUnwrap(try store.activeVersion(templateId: submissionId))

        let cloned = try store.clone(templateId: submissionId, newName: "팀 A 주간보고")
        XCTAssertNotEqual(cloned.id, submissionId)
        XCTAssertEqual(cloned.name, "팀 A 주간보고")
        XCTAssertEqual(cloned.purpose, .submissionWeekly)

        let clonedVersions = try store.versions(templateId: cloned.id)
        XCTAssertEqual(clonedVersions.count, 1)
        XCTAssertEqual(clonedVersions[0].version, 1)
        XCTAssertEqual(clonedVersions[0].instructions, sourceActive.instructions)
        XCTAssertEqual(clonedVersions[0].outputExample, sourceActive.outputExample)

        // 복제 수정은 원본에 영향을 주지 않는다.
        _ = try store.saveNewVersion(templateId: cloned.id, instructions: "복제팀 전용 지침",
                                     outputExample: "", skillRef: nil)
        XCTAssertEqual(try store.activeVersion(templateId: submissionId)?.instructions,
                       sourceActive.instructions)
        XCTAssertEqual(try store.versions(templateId: submissionId).count, 1)
    }

    // MARK: 7 — 사용자 수정 보존

    func testSeedDefaultsPreservesUserEdits() throws {
        let store = try makeStore()
        try store.seedDefaults()
        let edited = try store.saveNewVersion(templateId: submissionId, instructions: "사용자 수정 지침",
                                              outputExample: "", skillRef: nil)
        XCTAssertEqual(edited.version, 2)

        XCTAssertEqual(try store.seedDefaults(), 0)
        XCTAssertEqual(try store.activeVersion(templateId: submissionId)?.id, edited.id)
        XCTAssertEqual(try store.versions(templateId: submissionId).count, 2)
    }

    // MARK: 8 — archive / preferredTemplate

    func testArchiveAndPreferredTemplate() throws {
        let store = try makeStore()
        try store.seedDefaults()
        let team = try store.clone(templateId: submissionId, newName: "팀 B 주간보고")

        try store.archive(templateId: submissionId)
        XCTAssertFalse(try store.templates(purpose: .submissionWeekly).contains { $0.id == submissionId })
        XCTAssertTrue(try store.templates(purpose: .submissionWeekly, includeArchived: true)
            .contains { $0.id == submissionId })

        // 기본 id가 보관되면 보관되지 않은 다음 후보를 고른다.
        XCTAssertEqual(try store.preferredTemplate(for: .submissionWeekly)?.id, team.id)

        // 보관되지 않은 기본 템플릿이 있으면 기본 id를 우선한다.
        XCTAssertEqual(try store.preferredTemplate(for: .performanceDaily)?.id, dailyId)
        XCTAssertEqual(try store.preferredTemplate(for: .performancePeriodic)?.id, periodicId)
    }

    // MARK: 9 — composeInstructions

    func testComposeInstructionsPrependsGuardAndExample() throws {
        let store = try makeStore()
        try store.seedDefaults()

        let submission = try XCTUnwrap(try store.activeVersion(templateId: submissionId))
        let composed = try store.composeInstructions(versionId: submission.id)
        XCTAssertTrue(composed.hasPrefix(DefaultPrompts.commonInstructions + "\n\n"))
        XCTAssertTrue(composed.contains(submission.instructions))
        XCTAssertTrue(composed.contains("\n\n출력 예시:\n" + submission.outputExample))

        // outputExample이 비어 있으면 출력 예시 섹션이 없다.
        let daily = try XCTUnwrap(try store.activeVersion(templateId: dailyId))
        let dailyComposed = try store.composeInstructions(versionId: daily.id)
        XCTAssertFalse(dailyComposed.contains("출력 예시:"))
        XCTAssertTrue(dailyComposed.hasPrefix("너는 개인의 업무 기록을 정리하는 보조자다."))
    }

    // MARK: 10 — v3 트리거 (template_version 불변)

    func testTemplateVersionImmutableTriggers() throws {
        let store = try makeStore()
        try store.seedDefaults()
        let v1 = try XCTUnwrap(try store.activeVersion(templateId: submissionId))

        XCTAssertThrowsError(try repo.db.run(
            "UPDATE template_version SET instructions = ? WHERE id = ?", ["변경 시도", v1.id]))
        XCTAssertThrowsError(try repo.db.run(
            "DELETE FROM template_version WHERE id = ?", [v1.id]))

        let reloaded = try XCTUnwrap(try store.version(id: v1.id))
        XCTAssertEqual(reloaded.instructions, v1.instructions)
    }
}
