import Foundation
import XCTest
@testable import WorkLogCore

/// WLOG-45A3 AF: 설정의 작업별 스킬 바인딩을 AI 작업 요청·리포트 버전에 연결하는지 검증한다.
/// 실제 ~/.codex·사용자 스킬 디렉터리는 읽지 않는다(모두 임시 디렉터리). 스킬 파일은 수정하지 않는다.
final class SkillBindingTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillBindingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func fixtureNow() -> Date {
        (try? FixtureLoader.load()).flatMap { $0.clock?.now }.flatMap(FixtureLoader.date)
            ?? Date(timeIntervalSince1970: 1_790_000_000)
    }

    private func makeRepo(now: Date) throws -> WorkRepository {
        let repo = try WorkRepository.inMemory(clock: FixedClock(now), ids: SequentialIDGenerator())
        try FixtureSeeder.seed(repo, fixture: try FixtureLoader.load())
        return repo
    }

    // MARK: - 1. 이름만/빈 값 바인딩

    func testNameOnlyAndEmptyBindings() {
        let resolver = SkillBindingResolver(bindings: [
            AIJobType.submissionWeekly.rawValue: "team-weekly",
            AIJobType.performanceReport.rawValue: "   ",
        ])

        XCTAssertEqual(resolver.skill(for: .submissionWeekly),
                       SkillRef(name: "team-weekly", path: nil, contentHash: nil))
        XCTAssertNil(resolver.skill(for: .performanceReport), "공백뿐인 값은 nil")
        XCTAssertNil(resolver.skill(for: .evidenceQuiz), "바인딩 없는 jobType은 nil")
    }

    func testUpdateReplacesBindings() {
        let resolver = SkillBindingResolver(bindings: [:])
        XCTAssertNil(resolver.skill(for: .groundedAnswer))

        resolver.update(bindings: [AIJobType.groundedAnswer.rawValue: "answer-skill"])
        XCTAssertEqual(resolver.skill(for: .groundedAnswer)?.name, "answer-skill")
    }

    // MARK: - 2. SKILL.md 경로 바인딩 → 이름·해시, 파일은 수정하지 않음

    func testSkillFileBindingComputesNameAndHash() throws {
        let dir = try makeTempDir()
        let skillDir = dir.appendingPathComponent("my-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let skillFile = skillDir.appendingPathComponent("SKILL.md")
        try "hello".write(to: skillFile, atomically: true, encoding: .utf8)

        let resolver = SkillBindingResolver(bindings: [
            AIJobType.submissionWeekly.rawValue: skillFile.path,
        ])

        let first = try XCTUnwrap(resolver.skill(for: .submissionWeekly))
        XCTAssertEqual(first.name, "my-skill", "SKILL.md면 상위 디렉터리 이름")
        XCTAssertEqual(first.path, skillFile.path)
        XCTAssertEqual(first.contentHash,
                       "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
                       "파일 SHA256과 같아야 함")

        // 파일 내용 변경 → 해시 변경.
        try "hello world".write(to: skillFile, atomically: true, encoding: .utf8)
        let second = try XCTUnwrap(resolver.skill(for: .submissionWeekly))
        XCTAssertNotEqual(second.contentHash, first.contentHash)
        XCTAssertEqual(second.contentHash,
                       "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")

        // 리졸버는 스킬 파일을 수정하지 않는다.
        XCTAssertEqual(try String(contentsOf: skillFile, encoding: .utf8), "hello world")
    }

    func testNonSkillFileBindingUsesFileNameWithoutExtension() throws {
        let dir = try makeTempDir()
        let file = dir.appendingPathComponent("weekly-style.md")
        try "content".write(to: file, atomically: true, encoding: .utf8)

        let resolver = SkillBindingResolver(bindings: [
            AIJobType.performanceReport.rawValue: file.path,
        ])
        let ref = try XCTUnwrap(resolver.skill(for: .performanceReport))
        XCTAssertEqual(ref.name, "weekly-style")
        XCTAssertEqual(ref.path, file.path)
        XCTAssertNotNil(ref.contentHash)
    }

    // MARK: - 3. 존재하지 않는 경로 → 크래시 없이 이름만

    func testMissingPathResolvesWithoutCrash() throws {
        let dir = try makeTempDir()
        let missing = dir.appendingPathComponent("ghost-skill").appendingPathComponent("SKILL.md")

        let resolver = SkillBindingResolver(bindings: [
            AIJobType.submissionWeekly.rawValue: missing.path,
        ])
        let ref = try XCTUnwrap(resolver.skill(for: .submissionWeekly))
        XCTAssertEqual(ref.name, "ghost-skill")
        XCTAssertNil(ref.contentHash)
    }

    // MARK: - 4. 보호 경로는 읽지 않고 nil (결함 5)

    func testBlockedPathPrefixReturnsNilWithoutReading() throws {
        let dir = try makeTempDir()
        let blockedDir = dir.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: blockedDir, withIntermediateDirectories: true)
        let blockedSkill = blockedDir.appendingPathComponent("SKILL.md")
        try "blocked-content".write(to: blockedSkill, atomically: true, encoding: .utf8)

        // 정상 스킬(차단 prefix 밖).
        let okDir = dir.appendingPathComponent("ok-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: okDir, withIntermediateDirectories: true)
        let okSkill = okDir.appendingPathComponent("SKILL.md")
        try "ok-content".write(to: okSkill, atomically: true, encoding: .utf8)

        // 디렉터리 경계: prefix와 이름이 비슷할 뿐 하위가 아닌 경로는 차단하지 않는다.
        let siblingDir = dir.appendingPathComponent("blocked-extra", isDirectory: true)
        try FileManager.default.createDirectory(at: siblingDir, withIntermediateDirectories: true)
        let siblingSkill = siblingDir.appendingPathComponent("SKILL.md")
        try "sibling-content".write(to: siblingSkill, atomically: true, encoding: .utf8)

        let resolver = SkillBindingResolver(
            bindings: [
                AIJobType.submissionWeekly.rawValue: blockedSkill.path,
                AIJobType.performanceReport.rawValue: okSkill.path,
                AIJobType.groundedAnswer.rawValue: siblingSkill.path,
            ],
            blockedPathPrefixes: [blockedDir.path])

        XCTAssertNil(resolver.skill(for: .submissionWeekly), "차단 prefix 하위는 읽지 않고 nil")
        XCTAssertNotNil(resolver.skill(for: .performanceReport)?.contentHash, "prefix 밖 정상 스킬은 해시")
        XCTAssertNotNil(resolver.skill(for: .groundedAnswer)?.contentHash,
                        "prefix 경계 밖(blocked-extra)은 차단하지 않는다")
    }

    func testCodexAuthAndSQLitePathsReturnNilWithoutReading() throws {
        let dir = try makeTempDir()

        let codexDir = dir.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let authFile = codexDir.appendingPathComponent("auth.json")
        try #"{"token":"secret"}"#.write(to: authFile, atomically: true, encoding: .utf8)

        let outsideAuthDir = dir.appendingPathComponent("auth-outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideAuthDir, withIntermediateDirectories: true)
        let outsideAuth = outsideAuthDir.appendingPathComponent("auth.json")
        try #"{"other":1}"#.write(to: outsideAuth, atomically: true, encoding: .utf8)

        let sqliteFile = dir.appendingPathComponent("x.sqlite")
        try "SQLite format 3\u{0}".write(to: sqliteFile, atomically: true, encoding: .utf8)
        let walFile = dir.appendingPathComponent("x.sqlite-wal")
        try "wal".write(to: walFile, atomically: true, encoding: .utf8)

        let resolver = SkillBindingResolver(bindings: [
            AIJobType.submissionWeekly.rawValue: authFile.path,
            AIJobType.performanceReport.rawValue: outsideAuth.path,
            AIJobType.groundedAnswer.rawValue: sqliteFile.path,
            AIJobType.evidenceQuiz.rawValue: walFile.path,
        ])

        XCTAssertNil(resolver.skill(for: .submissionWeekly), "`.codex` 구성요소는 차단")
        XCTAssertNil(resolver.skill(for: .performanceReport), "파일명 auth.json은 위치와 무관하게 차단")
        XCTAssertNil(resolver.skill(for: .groundedAnswer), "sqlite 확장자는 차단")
        XCTAssertNil(resolver.skill(for: .evidenceQuiz), "sqlite-wal 확장자는 차단")
    }

    func testSymlinkToBlockedPathReturnsNil() throws {
        let dir = try makeTempDir()
        let codexDir = dir.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let authFile = codexDir.appendingPathComponent("auth.json")
        try "secret".write(to: authFile, atomically: true, encoding: .utf8)

        let linkDir = dir.appendingPathComponent("link-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: linkDir, withIntermediateDirectories: true)
        let link = linkDir.appendingPathComponent("SKILL.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: authFile)

        let resolver = SkillBindingResolver(bindings: [
            AIJobType.submissionWeekly.rawValue: link.path,
        ])
        XCTAssertNil(resolver.skill(for: .submissionWeekly),
                     "차단 경로를 가리키는 심볼릭 링크는 해석 후에도 nil")
    }

    // MARK: - 5. AIJobRunner: 바인딩 해석·재사용·해시 변경 시 새 실행

    func testRunnerUsesResolvedSkillAndReusesUntilHashChanges() async throws {
        let dir = try makeTempDir()
        let skillDir = dir.appendingPathComponent("my-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let skillFile = skillDir.appendingPathComponent("SKILL.md")
        try "hello".write(to: skillFile, atomically: true, encoding: .utf8)

        let repo = try WorkRepository.inMemory(clock: FixedClock(fixtureNow()), ids: SequentialIDGenerator())
        let mock = MockAIProvider(responses: [.groundedAnswer: #"{"answer":"ok"}"#])
        let resolver = SkillBindingResolver(bindings: [AIJobType.groundedAnswer.rawValue: skillFile.path])
        let runner = AIJobRunner(repo: repo, provider: mock, stagingRoot: dir, skillResolver: resolver)

        let request = AIJobRequest(jobType: .groundedAnswer, instructions: "지침",
                                   payloadJSON: #"{"query":"오늘 한 일"}"#)

        let first = try await runner.submit(request)
        XCTAssertFalse(first.reusedExisting)
        XCTAssertEqual(mock.runCount, 1)
        XCTAssertEqual(mock.receivedInputs.last?.skill?.name, "my-skill")
        XCTAssertEqual(first.skill?.name, "my-skill", "실행 결과에도 사용 스킬 기록")
        XCTAssertNotNil(first.skill?.contentHash)

        // 같은 스킬·같은 입력 → 재사용(호출 증가 없음).
        let second = try await runner.submit(request)
        XCTAssertTrue(second.reusedExisting)
        XCTAssertEqual(mock.runCount, 1)

        // 스킬 파일 해시가 바뀌면 새 key → 새 실행.
        try "hello world".write(to: skillFile, atomically: true, encoding: .utf8)
        let third = try await runner.submit(request)
        XCTAssertFalse(third.reusedExisting)
        XCTAssertEqual(mock.runCount, 2)
        XCTAssertNotEqual(third.skill?.contentHash, first.skill?.contentHash)
    }

    func testRunnerLeavesSkillNilWhenUnbound() async throws {
        let dir = try makeTempDir()
        let repo = try WorkRepository.inMemory(clock: FixedClock(fixtureNow()), ids: SequentialIDGenerator())
        let mock = MockAIProvider(responses: [.groundedAnswer: #"{"answer":"ok"}"#])
        let runner = AIJobRunner(repo: repo, provider: mock, stagingRoot: dir,
                                 skillResolver: SkillBindingResolver(bindings: [:]))

        let result = try await runner.submit(AIJobRequest(jobType: .groundedAnswer, instructions: "지침",
                                                          payloadJSON: "{}"))
        XCTAssertNil(mock.receivedInputs.last?.skill)
        XCTAssertNil(result.skill)
    }

    // MARK: - 6. AppEnvironment: updateSettings 반영

    func testEnvironmentResolverReflectsUpdatedBindings() throws {
        let root = try makeTempDir()
        let paths = AppPaths(dataRoot: root.appendingPathComponent("data", isDirectory: true),
                             backupRoot: root.appendingPathComponent("backups", isDirectory: true))
        let env = try AppEnvironment.open(AppEnvironmentOptions(
            paths: paths, keyStore: InMemoryVaultKeyStore(), authenticator: MockDeviceAuthenticator(),
            pasteboard: InMemoryPasteboard(), aiProvider: nil,
            clock: FixedClock(fixtureNow()), ids: SequentialIDGenerator()))

        XCTAssertNil(env.skillResolver.skill(for: .submissionWeekly))

        var changed = env.settings
        changed.skillBindings = [AIJobType.submissionWeekly.rawValue: "new-skill"]
        try env.updateSettings(changed)

        XCTAssertEqual(env.skillResolver.skill(for: .submissionWeekly)?.name, "new-skill")
    }

    // MARK: - 7. ReportService: 버전 skillRef 기록

    func testReportVersionRecordsResolvedSkillOnAISuccess() async throws {
        let probeRepo = try makeRepo(now: fixtureNow())
        let periods = Periods()
        let probeBuilder = ReportFactsBuilder(repo: probeRepo, periods: periods,
                                              planService: WeekPlanService(repo: probeRepo, periods: periods))
        let facts = try probeBuilder.submissionFacts(reportDate: WorkDate("2026-10-05")!,
                                                     knownAt: probeRepo.clock.now())
        let json = try StableJSON.string(SubmissionComposer.compose(facts))

        let repo = try makeRepo(now: fixtureNow())
        let builder = ReportFactsBuilder(repo: repo, periods: periods,
                                         planService: WeekPlanService(repo: repo, periods: periods))
        let store = ReportStore(repo: repo)
        let templates = TemplateStore(repo: repo)
        let provider = MockAIProvider(responses: [.submissionWeekly: json])
        let resolver = SkillBindingResolver(bindings: [AIJobType.submissionWeekly.rawValue: "team-weekly"])
        let runner = AIJobRunner(repo: repo, provider: provider,
                                 stagingRoot: try makeTempDir(), skillResolver: resolver)
        let service = ReportService(repo: repo, periods: periods, factsBuilder: builder,
                                    store: store, templates: templates, runner: runner,
                                    evaluationPeriods: EvaluationPeriodService(repo: repo))

        let result = try await service.generateSubmission(reportDate: WorkDate("2026-10-05")!,
                                                          mode: .userRequested, useAI: true)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.aiJobStatus, .succeeded)
        guard case .created(let version) = result.outcome else {
            return XCTFail("created를 기대: \(result.outcome)")
        }
        XCTAssertEqual(version.generator, "codex")
        XCTAssertEqual(version.skillRef, "team-weekly@-", "이름@해시 형식(이름만 바인딩은 해시 -)")
    }

    func testReportVersionSkillRefNilWithoutAI() async throws {
        let repo = try makeRepo(now: fixtureNow())
        let periods = Periods()
        let builder = ReportFactsBuilder(repo: repo, periods: periods,
                                         planService: WeekPlanService(repo: repo, periods: periods))
        let service = ReportService(repo: repo, periods: periods, factsBuilder: builder,
                                    store: ReportStore(repo: repo), templates: TemplateStore(repo: repo),
                                    runner: nil, evaluationPeriods: EvaluationPeriodService(repo: repo))

        let result = try await service.generateSubmission(reportDate: WorkDate("2026-10-05")!,
                                                          mode: .userRequested, useAI: false)
        guard case .created(let version) = result.outcome else {
            return XCTFail("created를 기대: \(result.outcome)")
        }
        XCTAssertNil(version.skillRef, "AI를 쓰지 않은 결정적 초안은 스킬을 기록하지 않는다")
    }

    func testReportVersionSkillRefNilOnFallback() async throws {
        // 검증 실패를 유도하는 잘못된 AI 출력 → 결정적 초안 대체 → skillRef nil.
        let bad = SubmissionDraft(groups: [
            SubmissionGroup(heading: "공통 업무", items: [
                SubmissionItem(itemId: "line-1", category: .inProgress, text: "검증 실패",
                               taskIds: ["ghost-task"], projectIds: [])
            ])
        ])
        let json = try StableJSON.string(bad)

        let repo = try makeRepo(now: fixtureNow())
        let periods = Periods()
        let builder = ReportFactsBuilder(repo: repo, periods: periods,
                                         planService: WeekPlanService(repo: repo, periods: periods))
        let provider = MockAIProvider(responses: [.submissionWeekly: json])
        let resolver = SkillBindingResolver(bindings: [AIJobType.submissionWeekly.rawValue: "team-weekly"])
        let runner = AIJobRunner(repo: repo, provider: provider,
                                 stagingRoot: try makeTempDir(), skillResolver: resolver)
        let service = ReportService(repo: repo, periods: periods, factsBuilder: builder,
                                    store: ReportStore(repo: repo), templates: TemplateStore(repo: repo),
                                    runner: runner, evaluationPeriods: EvaluationPeriodService(repo: repo))

        let result = try await service.generateSubmission(reportDate: WorkDate("2026-10-05")!,
                                                          mode: .userRequested, useAI: true)
        XCTAssertTrue(result.usedFallback)
        guard case .created(let version) = result.outcome else {
            return XCTFail("created를 기대: \(result.outcome)")
        }
        XCTAssertNil(version.skillRef, "대체 초안은 '기존 스킬로 실행함'을 기록하지 않는다")
    }
}
