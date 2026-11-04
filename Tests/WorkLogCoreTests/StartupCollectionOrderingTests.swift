import XCTest
@testable import WorkLogCore

/// #61/#62: 앱이 시작하면 먼저 활동을 수집하고, 리포트 catch-up은 그 수집이 끝난 뒤에 읽는다.
/// 수집 중이거나 끝난 뒤에 도착한 가져오기는 조정자를 통해 한 번만 재평가된다.
///
/// AppController의 실행 게이트는 macOS 앱 타깃(WorkLogApp)에 있어 이 테스트 타깃에서 직접
/// 구동할 수 없다. 대신 앱이 실제로 쓰는 것과 같은 조정자(`ScheduledReportCoordinator`)와
/// 환경(`runStartupCatchUp`/`reevaluateScheduledReports`) 조합으로 순서 계약을 결정적으로
/// 검증한다:
/// 1. 수집이 끝난 뒤 catch-up을 돌리면 새 데이터를 포함한 초안 하나만 만든다.
/// 2. catch-up이 진행 중일 때 도착한 가져오기는 catch-up을 막지 않고, 끝난 뒤 합집합으로
///    한 번만 재평가한다. 원본이 이미 반영됐다면 새 버전을 만들지 않는다.
/// 3. catch-up이 끝난 뒤 도착한 가져오기는 즉시 재평가해 새 버전을 만든다.
/// 4. catch-up 전에 도착한 가져오기는 버리지 않고 보류했다가, 이전 세션에서 성공한 기간까지
///    catch-up 뒤 한 번 재평가한다.
final class StartupCollectionOrderingTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    // MARK: - 1. 수집 완료 → catch-up이 새 데이터를 포함한다

    @MainActor
    func testImportBeforeCatchUpIsIncludedInOneDraft() async throws {
        let now = kst(2026, 10, 21, 10)
        let env = try makeEnv(now: now)
        let today = env.calendar.workDate(of: now)
        let dayBefore = env.calendar.adding(days: -1, to: today)
        _ = try env.tasks.captureMemo(body: "어제 기록", workDate: dayBefore)

        // 앱은 첫 수집(sync)이 끝난 뒤에야 catch-up을 시작한다. 그 시점에는 이미 저장돼 있다.
        XCTAssertEqual(try env.repo.importActivities(
            [event(occurredAt: kst(2026, 10, 20, 12))], connection: connection()), 1)

        let coordinator = makeCoordinator(env)
        try await coordinator.runCatchUp()

        let report = try XCTUnwrap(dailyReport(env, on: dayBefore))
        let all = try versions(env, reportId: report.id)
        XCTAssertEqual(all.count, 1, "수집이 먼저 끝났으므로 초안은 하나만 만든다")

        let version = try XCTUnwrap(all.first)
        let imported = try facts(env, snapshotId: version.sourceSnapshotId)
            .sources.filter { $0.kind == .github }
        XCTAssertEqual(imported.count, 1, "catch-up이 이미 저장된 활동을 읽는다")
        XCTAssertTrue(imported[0].text.contains("PR #12"))

        // 앱은 수집 직후 같은 구간을 조정자에 넘긴다. 원본이 그대로면 새 버전이 없다.
        await coordinator.importsLanded(DateRange(start: dayBefore, endExclusive: today))
        XCTAssertEqual(try versions(env, reportId: report.id).count, 1,
                       "같은 원본의 재평가는 새 버전을 만들지 않는다")
        XCTAssertNil(coordinator.lastError)
    }

    // MARK: - 2. catch-up 중 도착한 가져오기는 막지 않고 끝난 뒤 합쳐서 재평가한다

    @MainActor
    func testImportDuringCatchUpDoesNotBlockAndMergesIntoOneReevaluation() async throws {
        let now = kst(2026, 10, 21, 10)
        let env = try makeEnv(now: now)
        let today = env.calendar.workDate(of: now)
        let dayBefore = env.calendar.adding(days: -1, to: today)
        _ = try env.tasks.captureMemo(body: "어제 기록", workDate: dayBefore)

        let gate = CatchUpGate()
        let coordinator = ScheduledReportCoordinator(
            catchUp: {
                await gate.wait()
                _ = try await env.runStartupCatchUp()
            },
            reevaluate: { _ = try await env.reevaluateScheduledReports(affecting: $0) })

        let catchUp = Task { try await coordinator.runCatchUp() }
        await gate.waitUntilStarted()
        XCTAssertEqual(coordinator.phase, .running)

        // 수집이 늦게 끝나 가져오기가 catch-up 도중에 도착하는 경우.
        XCTAssertEqual(try env.repo.importActivities(
            [event(occurredAt: kst(2026, 10, 20, 12))], connection: connection()), 1)
        let range = DateRange(start: dayBefore, endExclusive: today)
        await coordinator.importsLanded(range)

        // 넘겨받기는 즉시 돌아오고, catch-up은 여전히 게이트에 매달려 있다.
        XCTAssertEqual(coordinator.phase, .running)
        XCTAssertNil(try dailyReport(env, on: dayBefore), "재평가는 catch-up이 끝난 뒤에만 실행된다")

        await gate.open()
        try await catchUp.value
        XCTAssertEqual(coordinator.phase, .finished)

        let report = try XCTUnwrap(dailyReport(env, on: dayBefore))
        let all = try versions(env, reportId: report.id)
        XCTAssertEqual(all.count, 1, "catch-up이 가져온 활동을 포함했으므로 재평가는 새 버전을 만들지 않는다")
        let version = try XCTUnwrap(all.first)
        XCTAssertTrue(try facts(env, snapshotId: version.sourceSnapshotId)
            .sources.contains { $0.kind == .github })
        XCTAssertNil(coordinator.lastError)
    }

    // MARK: - 3. catch-up 이후 도착한 가져오기는 즉시 재평가한다

    @MainActor
    func testImportAfterCatchUpReevaluatesImmediately() async throws {
        let now = kst(2026, 10, 21, 10)
        let env = try makeEnv(now: now)
        let today = env.calendar.workDate(of: now)
        let dayBefore = env.calendar.adding(days: -1, to: today)
        _ = try env.tasks.captureMemo(body: "어제 기록", workDate: dayBefore)

        let coordinator = makeCoordinator(env)
        try await coordinator.runCatchUp()

        let report = try XCTUnwrap(dailyReport(env, on: dayBefore))
        let before = try XCTUnwrap(try versions(env, reportId: report.id).last)
        XCTAssertFalse(try facts(env, snapshotId: before.sourceSnapshotId)
            .sources.contains { $0.kind == .github })

        XCTAssertEqual(try env.repo.importActivities(
            [event(occurredAt: kst(2026, 10, 20, 12))], connection: connection()), 1)
        await coordinator.importsLanded(DateRange(start: dayBefore, endExclusive: today))

        let all = try versions(env, reportId: report.id)
        XCTAssertEqual(all.count, 2, "끝난 뒤 도착한 가져오기는 즉시 새 버전을 만든다")
        let after = try XCTUnwrap(all.last)
        XCTAssertTrue(try facts(env, snapshotId: after.sourceSnapshotId)
            .sources.contains { $0.kind == .github })
        let job = try XCTUnwrap(env.repo.scheduledJob(type: .dailyClose, periodKey: dayBefore.iso))
        XCTAssertEqual(job.state, .succeeded, "재평가는 예약 작업을 실패로 만들지 않는다")
    }

    // MARK: - 4. 시작 직전 가져오기는 성공한 기간도 다시 평가한다

    /// 앱 재시작 뒤에는 이전 세션이 성공시킨 업무일의 작업이 `succeeded`로 남아 있다. catch-up은
    /// 성공한 기간을 다시 실행하지 않으므로, 시작 직전 가져오기를 버리면 그 근거가 영영 사라진다.
    /// 조정자는 구간을 보류했다가 catch-up이 끝난 뒤 정확히 한 번 재평가해야 한다.
    @MainActor
    func testImportBeforeCatchUpReevaluatesSucceededPeriodFromPreviousSession() async throws {
        let now = kst(2026, 10, 21, 10)
        let env = try makeEnv(now: now)
        let today = env.calendar.workDate(of: now)
        let dayBefore = env.calendar.adding(days: -1, to: today)
        _ = try env.tasks.captureMemo(body: "어제 기록", workDate: dayBefore)

        // 이전 세션: catch-up이 D-1 리포트를 성공 상태로 만든다(아직 가져온 활동 없음).
        _ = try await env.runStartupCatchUp()
        let report = try XCTUnwrap(dailyReport(env, on: dayBefore))
        let first = try XCTUnwrap(try versions(env, reportId: report.id).last)
        XCTAssertFalse(try facts(env, snapshotId: first.sourceSnapshotId)
            .sources.contains { $0.kind == .github })

        // 새 세션: 가져오기가 catch-up보다 먼저 도착한다.
        let coordinator = makeCoordinator(env)
        XCTAssertEqual(try env.repo.importActivities(
            [event(occurredAt: kst(2026, 10, 20, 12))], connection: connection()), 1)
        await coordinator.importsLanded(DateRange(start: dayBefore, endExclusive: today))
        XCTAssertEqual(try versions(env, reportId: report.id).count, 1,
                       "재평가는 catch-up이 끝난 뒤에만 실행된다")

        try await coordinator.runCatchUp()

        let all = try versions(env, reportId: report.id)
        XCTAssertEqual(all.count, 2, "보류한 구간을 catch-up 뒤 한 번 재평가해 새 버전을 만든다")
        let after = try XCTUnwrap(all.last)
        let imported = try facts(env, snapshotId: after.sourceSnapshotId)
            .sources.filter { $0.kind == .github }
        XCTAssertEqual(imported.count, 1)
        XCTAssertTrue(imported[0].text.contains("PR #12"))

        let job = try XCTUnwrap(env.repo.scheduledJob(type: .dailyClose, periodKey: dayBefore.iso))
        XCTAssertEqual(job.state, .succeeded, "재평가는 예약 작업을 실패로 만들지 않는다")
        XCTAssertEqual(job.attempts, 1, "catch-up은 이미 성공한 작업을 다시 실행하지 않는다")
        XCTAssertNil(coordinator.lastError)
    }

    // MARK: - Helpers

    /// 앱의 AppController가 만드는 것과 같은 조정자(수집 완료 → catch-up → 가져오기 재평가).
    @MainActor
    private func makeCoordinator(_ env: AppEnvironment) -> ScheduledReportCoordinator {
        ScheduledReportCoordinator(
            catchUp: { _ = try await env.runStartupCatchUp() },
            reevaluate: { _ = try await env.reevaluateScheduledReports(affecting: $0) })
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StartupCollectionOrderingTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func makeEnv(now: Date) throws -> AppEnvironment {
        let root = try makeTempDir()
        let options = AppEnvironmentOptions(
            paths: AppPaths(dataRoot: root.appendingPathComponent("data", isDirectory: true),
                            backupRoot: root.appendingPathComponent("backups", isDirectory: true)),
            keyStore: InMemoryVaultKeyStore(),
            authenticator: MockDeviceAuthenticator(),
            pasteboard: InMemoryPasteboard(),
            clock: FixedClock(now),
            ids: SequentialIDGenerator())
        return try AppEnvironment.open(options)
    }

    /// KST 기준 시각. 업무일 경계가 한국 시간대임을 명시한다.
    private func kst(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour))!
    }

    private func connection() -> ActivityConnection {
        var connection = ActivityConnection(source: .github)
        connection.enabled = true
        connection.baseURL = "https://api.github.com"
        connection.account = "sample-user"
        return connection
    }

    private func event(id: String = "gh-1", occurredAt: Date,
                       title: String = "PR #12 병합") -> ImportedActivity {
        ImportedActivity(id: id, occurredAt: occurredAt, title: title,
                         detail: "가져온 활동 본문", url: "https://example.test/pr/12")
    }

    private func dailyReport(_ env: AppEnvironment, on date: WorkDate) throws -> Report? {
        try env.repo.report(family: .performance, periodType: .daily, periodKey: date.iso)
    }

    private func versions(_ env: AppEnvironment, reportId: String) throws -> [ReportVersion] {
        try env.repo.reportVersions(reportId: reportId)
    }

    private func facts(_ env: AppEnvironment, snapshotId: String) throws -> ReportFacts {
        let snapshot = try XCTUnwrap(env.repo.sourceSnapshot(id: snapshotId))
        return try StableJSON.decode(ReportFacts.self, from: Data(snapshot.frozenFactsJSON.utf8))
    }

    /// catch-up이 시작되었음을 알리고, open() 전까지 매달리는 게이트.
    private actor CatchUpGate {
        private var opened = false
        private var started = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var openContinuation: CheckedContinuation<Void, Never>?

        func wait() async {
            started = true
            let waiters = startWaiters
            startWaiters = []
            for waiter in waiters { waiter.resume() }
            if opened { return }
            await withCheckedContinuation { openContinuation = $0 }
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func open() {
            opened = true
            openContinuation?.resume()
            openContinuation = nil
        }
    }
}
