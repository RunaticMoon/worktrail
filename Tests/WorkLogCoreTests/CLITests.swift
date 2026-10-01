import XCTest
@testable import WorkLogCore

/// WLOG-45A3 AC: 개발용 worklog CLI.
///
/// 모든 테스트는 임시 데이터 디렉터리를 쓰고 종료 시 삭제한다.
/// 실제 사용자 홈의 앱 데이터·Keychain·AI에는 접근하지 않는다.
final class CLITests: XCTestCase {

    private var tempDirs: [URL] = []

    /// 2026-10-05(월) 10:00 KST = 01:00 UTC. 월요일 제출용·주간 성과 기준 시각.
    private let fixedNow = ISO8601DateFormatter().date(from: "2026-10-05T01:00:00Z")!

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeDataDir() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir.path
    }

    private func run(_ args: [String], dataDir: String? = nil) async -> CLIResult {
        var environment: [String: String] = [:]
        if let dataDir { environment["WORKLOG_DATA_DIR"] = dataDir }
        return await WorkLogCLI.run(args, environment: environment, now: fixedNow)
    }

    private func lastToken(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").last.map(String.init) ?? ""
    }

    private func firstLine(_ text: String) -> String {
        text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
    }

    // MARK: - 1. data-dir 없으면 exit 2

    func testMissingDataDirExitsTwo() async {
        let result = await WorkLogCLI.run(["memo", "테스트 메모"], environment: [:], now: fixedNow)
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertFalse(result.stderr.isEmpty)
        XCTAssertTrue(result.stderr.contains("--data-dir") || result.stderr.contains("WORKLOG_DATA_DIR"))
    }

    func testHelpExitsZero() async {
        let result = await WorkLogCLI.run(["help"], environment: [:], now: fixedNow)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Secret 명령 없음"))
    }

    // MARK: - 2. memo → search hit

    func testMemoThenSearchFindsMemo() async throws {
        let dir = try makeDataDir()

        let memo = await run(["memo", "아키텍처 정리 회의 공유"], dataDir: dir)
        XCTAssertEqual(memo.exitCode, 0, memo.stderr)
        XCTAssertTrue(memo.stdout.hasPrefix("memo "))

        let search = await run(["search", "아키텍처"], dataDir: dir)
        XCTAssertEqual(search.exitCode, 0, search.stderr)
        XCTAssertTrue(search.stdout.contains("memo"))
        XCTAssertTrue(search.stdout.contains("아키텍처 정리 회의 공유"))
    }

    // MARK: - 3. task add → activity → done → show

    func testTaskLifecycleShowsCompleted() async throws {
        let dir = try makeDataDir()

        let add = await run(["task", "add", "배포", "자동화", "--project", "플랫폼", "--tag", "infra"],
                            dataDir: dir)
        XCTAssertEqual(add.exitCode, 0, add.stderr)
        let taskId = lastToken(add.stdout)
        XCTAssertFalse(taskId.isEmpty)

        let activity = await run(["activity", taskId, "파이프라인 구성"], dataDir: dir)
        XCTAssertEqual(activity.exitCode, 0, activity.stderr)
        XCTAssertTrue(activity.stdout.hasPrefix("activity "))

        let done = await run(["task", "done", taskId], dataDir: dir)
        XCTAssertEqual(done.exitCode, 0, done.stderr)
        XCTAssertTrue(done.stdout.contains("completed"))

        let show = await run(["task", "show", taskId], dataDir: dir)
        XCTAssertEqual(show.exitCode, 0, show.stderr)
        XCTAssertTrue(show.stdout.contains("status: completed"), show.stdout)
        XCTAssertTrue(show.stdout.contains("activities: 1"), show.stdout)
    }

    // MARK: - 4. 제출용·성과 리포트 분리

    func testSubmissionAndPerformanceAreSeparateReports() async throws {
        let dir = try makeDataDir()

        let submission = await run(["report", "submission", "2026-10-05"], dataDir: dir)
        XCTAssertEqual(submission.exitCode, 0, submission.stderr)
        XCTAssertTrue(submission.stdout.hasPrefix("[제출용 주간보고] 실적 기간 "), submission.stdout)

        let performance = await run(["report", "performance", "weekly", "2026-10-05"], dataDir: dir)
        XCTAssertEqual(performance.exitCode, 0, performance.stderr)
        XCTAssertTrue(performance.stdout.hasPrefix("[상세 성과 리포트] weekly 기간 "), performance.stdout)

        XCTAssertNotEqual(firstLine(submission.stdout), firstLine(performance.stdout))

        // env를 다시 열어 submission/performance report 행이 별개 id임을 확인한다.
        let root = URL(fileURLWithPath: dir, isDirectory: true)
        let paths = AppPaths(dataRoot: root.appendingPathComponent("data", isDirectory: true),
                             backupRoot: root.appendingPathComponent("backups", isDirectory: true))
        let env = try AppEnvironment.open(AppEnvironmentOptions(
            paths: paths, keyStore: InMemoryVaultKeyStore(),
            authenticator: MockDeviceAuthenticator(), pasteboard: InMemoryPasteboard(),
            aiProvider: nil, clock: FixedClock(fixedNow), ids: UUIDGenerator()))

        let subReport = try XCTUnwrap(try env.repo.reports(family: .submission)
            .first { $0.periodType == .weekly })
        let perfReport = try XCTUnwrap(try env.repo.reports(family: .performance)
            .first { $0.periodType == .weekly })
        XCTAssertNotEqual(subReport.id, perfReport.id)
        XCTAssertEqual(try env.repo.reports(family: .submission).count, 1)
        XCTAssertEqual(try env.repo.reports(family: .performance).count, 1)
    }

    // MARK: - 4b. 리포트 머리말은 포함 종료일을 쓴다

    func testReportHeadersUseInclusivePeriod() async throws {
        let dir = try makeDataDir()

        let submission = await run(["report", "submission", "2026-10-05"], dataDir: dir)
        XCTAssertEqual(submission.exitCode, 0, submission.stderr)
        XCTAssertEqual(firstLine(submission.stdout),
                       "[제출용 주간보고] 실적 기간 2026-09-28 ~ 2026-10-04"
                           + " · 계획 기간 2026-10-05 ~ 2026-10-11",
                       submission.stdout)

        let performance = await run(["report", "performance", "weekly", "2026-10-05"], dataDir: dir)
        XCTAssertEqual(performance.exitCode, 0, performance.stderr)
        XCTAssertEqual(firstLine(performance.stdout),
                       "[상세 성과 리포트] weekly 기간 2026-10-05 ~ 2026-10-11",
                       performance.stdout)
    }

    // MARK: - 5. backup create → list → verify

    func testBackupCreateListVerify() async throws {
        let dir = try makeDataDir()

        let create = await run(["backup", "create"], dataDir: dir)
        XCTAssertEqual(create.exitCode, 0, create.stderr)
        XCTAssertTrue(create.stdout.hasPrefix("backup "))
        let directoryName = lastToken(create.stdout)
        XCTAssertFalse(directoryName.isEmpty)

        let list = await run(["backup", "list"], dataDir: dir)
        XCTAssertEqual(list.exitCode, 0, list.stderr)
        XCTAssertTrue(list.stdout.contains(directoryName))

        let verify = await run(["backup", "verify", directoryName], dataDir: dir)
        XCTAssertEqual(verify.exitCode, 0, verify.stderr)
    }

    func testBackupVerifyDistinguishesCorruptManifest() async throws {
        let dir = try makeDataDir()

        let create = await run(["backup", "create"], dataDir: dir)
        XCTAssertEqual(create.exitCode, 0, create.stderr)
        let name = lastToken(create.stdout)
        XCTAssertFalse(name.isEmpty)

        // manifest.json을 깨뜨려도 디렉터리는 남는다. listBackups()는 건너뛰지만 verify는 손상을 알려야 한다.
        let manifest = URL(fileURLWithPath: dir, isDirectory: true)
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("manifest.json")
        try Data("{".utf8).write(to: manifest)

        let result = await run(["backup", "verify", name], dataDir: dir)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(result.stderr.contains("찾을 수 없습니다"), result.stderr)
        XCTAssertTrue(result.stderr.contains("manifest"), result.stderr)
    }

    func testBackupVerifyMissingNameNotFound() async throws {
        let dir = try makeDataDir()
        _ = await run(["backup", "create"], dataDir: dir)

        let result = await run(["backup", "verify", "no-such-backup"], dataDir: dir)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("찾을 수 없습니다"), result.stderr)
    }

    func testBackupVerifyPathTraversalNameNotFound() async throws {
        let dir = try makeDataDir()
        _ = await run(["backup", "create"], dataDir: dir)

        let result = await run(["backup", "verify", "../x"], dataDir: dir)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("찾을 수 없습니다"), result.stderr)
    }

    // MARK: - 6. 알 수 없는 명령 exit 2

    func testUnknownCommandExitsTwo() async throws {
        let dir = try makeDataDir()
        let result = await run(["frobnicate"], dataDir: dir)
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertFalse(result.stderr.isEmpty)
    }
}
