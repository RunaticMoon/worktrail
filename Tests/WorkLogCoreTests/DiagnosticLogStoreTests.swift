import Foundation
import XCTest
@testable import WorkLogCore

final class DiagnosticLogStoreTests: XCTestCase {
    private var root: URL!
    private var clock: FixedClock!
    private let initial = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("diagnostics-test-" + UUIDGenerator().make())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clock = FixedClock(initial)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private var directory: URL { root.appendingPathComponent("Diagnostics") }
    private var metadata: DiagnosticReportMetadata {
        DiagnosticReportMetadata(appVersion: "1.2.3", appBuild: "123",
                                 operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 1))
    }

    private func report(_ store: DiagnosticLogStore) throws -> DiagnosticReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DiagnosticReport.self, from: store.exportReport(metadata: metadata))
    }

    private func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("events-") }.sorted { $0.path < $1.path }
    }

    func testRoundTripTypedOperationalFieldsAndPrivatePermissions() throws {
        let store = DiagnosticLogStore(directory: directory, clock: clock)
        XCTAssertTrue(store.record(.operationFailed, category: .keychain, level: .warning,
                                   fields: [.osStatus: .integer(-25308), .reason: .state(.denied)]))
        XCTAssertTrue(store.record(.audioConfigurationIgnored, category: .recording,
                                   fields: [.inputSampleRate: .decimal(48_000), .engineRunning: .flag(true)]))
        let exported = try report(store)
        XCTAssertEqual(exported.events.count, 2)
        XCTAssertEqual(exported.events[0].fields["osStatus"], .integer(-25308))
        XCTAssertEqual(exported.metadata.appVersion, "1.2.3")
        XCTAssertEqual(store.status().eventCount, 2)
        XCTAssertTrue(store.status().storageAvailable)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
        for file in try files() {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testRetentionRemovesOnlyExpiredRowsInsideSameFileOnExportAndLaunch() throws {
        let store = DiagnosticLogStore(directory: directory, clock: clock)
        store.record(.appStarted, category: .application)
        clock.advance(by: 86_400)
        store.record(.recordingStarted, category: .recording)
        XCTAssertEqual(try files().count, 1)
        clock.advance(by: 6 * 86_400)
        XCTAssertEqual(try report(store).events.map(\.event), [.recordingStarted])
        let raw = try String(contentsOf: XCTUnwrap(files().first), encoding: .utf8)
        XCTAssertFalse(raw.contains("appStarted"), "Expired rows must also be removed from disk")
        clock.advance(by: 86_400)
        let reopened = DiagnosticLogStore(directory: directory, clock: clock)
        XCTAssertEqual(reopened.status().fileCount, 0)
        XCTAssertEqual(try report(reopened).events.count, 0)
    }

    func testMaintenanceAndWritesExpireOldDataWithoutExport() throws {
        let store = DiagnosticLogStore(directory: directory, clock: clock)
        store.record(.appStarted, category: .application)
        clock.advance(by: 8 * 86_400)
        XCTAssertTrue(store.maintenance())
        XCTAssertTrue(try files().isEmpty)
        store.record(.appReady, category: .application)
        clock.advance(by: 8 * 86_400)
        store.record(.operationFailed, category: .storage)
        XCTAssertEqual(try report(store).events.map(\.event), [.operationFailed])
    }

    func testRolloverEnforcesPerFileAndTotalBytesKeepingRecentEvents() throws {
        let policy = DiagnosticRetentionPolicy(maximumFileBytes: 400, maximumTotalBytes: 800)
        let store = DiagnosticLogStore(directory: directory, clock: clock, policy: policy)
        for attempt in 0..<30 {
            XCTAssertTrue(store.record(.operationStarted, category: .recording,
                                       fields: [.attempt: .integer(attempt)]))
            clock.advance(by: 1)
        }
        let status = store.status()
        XCTAssertLessThanOrEqual(status.byteCount, 800)
        XCTAssertGreaterThan(status.fileCount, 1)
        XCTAssertLessThan(status.eventCount, 30)
        for file in try files() {
            let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
            XCTAssertLessThanOrEqual(try XCTUnwrap(size).intValue, 400)
        }
        XCTAssertEqual(try report(store).events.last?.fields["attempt"], .integer(29))
    }

    func testExportRedecodesAllowlistRejectingUnreviewedFieldsAndFreeText() throws {
        let store = DiagnosticLogStore(directory: directory, clock: clock)
        store.record(.appStarted, category: .application)
        let file = try XCTUnwrap(files().first)
        let original = try Data(contentsOf: file)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["arbitraryMessage"] = "FAKE_PRIVATE_NOTE"
        let harmlessUnknownTopLevel = try JSONSerialization.data(withJSONObject: object)
        object["fields"] = ["reason": "FAKE_SECRET_TOKEN"]
        let invalidValue = try JSONSerialization.data(withJSONObject: object)
        object["fields"] = ["privateFilePath": "/fake/private/path"]
        let invalidField = try JSONSerialization.data(withJSONObject: object)
        var combined = original
        for data in [harmlessUnknownTopLevel, invalidValue, invalidField] { combined.append(data); combined.append(0x0A) }
        combined.append(Data("{truncated-invalid-json\n".utf8))
        try combined.write(to: file)
        let exported = try store.exportReport(metadata: DiagnosticReportMetadata(
            appVersion: "FAKE_SECRET_TOKEN", appBuild: "/fake/private/path",
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)))
        let text = try XCTUnwrap(String(data: exported, encoding: .utf8))
        XCTAssertFalse(text.contains("FAKE_"))
        XCTAssertFalse(text.contains("private"))
        XCTAssertFalse(text.contains("truncated"))
        XCTAssertTrue(text.contains("unknown"))
        XCTAssertEqual(try report(store).events.count, 2)
    }

    func testSymlinksHardlinksUnrelatedFilesAndDirectoriesAreNeverCollectedOrDeleted() throws {
        let store = DiagnosticLogStore(directory: directory, clock: clock)
        store.record(.appStarted, category: .application)
        let existing = try XCTUnwrap(files().first)
        let outside = root.appendingPathComponent("private.txt")
        try Data("FAKE_EXTERNAL_SECRET".utf8).write(to: outside)
        let prefix = "events-00000001800000000000-"
        let symlink = directory.appendingPathComponent(prefix + "000010.jsonl")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        let hardlink = directory.appendingPathComponent(prefix + "000011.jsonl")
        try FileManager.default.linkItem(at: outside, to: hardlink)
        let subdirectory = directory.appendingPathComponent(prefix + "000012.jsonl")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: false)
        let unrelated = directory.appendingPathComponent("private.jsonl")
        try Data("FAKE_UNRELATED_SECRET".utf8).write(to: unrelated)
        XCTAssertEqual(try report(store).events.count, 1)
        let exported = try store.exportReport(metadata: metadata)
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains("FAKE_"))
        try store.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: existing.path))
        for preserved in [outside, symlink, hardlink, subdirectory, unrelated] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path))
        }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "FAKE_EXTERNAL_SECRET")
    }

    func testSymlinkDirectoryAndUnavailableStorageFailWithoutThrowingFromRecording() throws {
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
        let store = DiagnosticLogStore(directory: directory, clock: clock)
        XCTAssertFalse(store.record(.appStarted, category: .application))
        XCTAssertFalse(store.status().storageAvailable)
        XCTAssertEqual(store.status().droppedEventCount, 1)
        XCTAssertThrowsError(try store.exportReport(metadata: metadata))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testConcurrentRecordAndExportProduceWholeValidRows() throws {
        let store = DiagnosticLogStore(directory: directory, clock: clock)
        DispatchQueue.concurrentPerform(iterations: 100) { attempt in
            XCTAssertTrue(store.record(.operationStarted, category: .recording,
                                       fields: [.attempt: .integer(attempt)]))
            if attempt.isMultiple(of: 10) {
                do { _ = try store.exportReport(metadata: metadata) }
                catch { XCTFail("Concurrent export failed") }
            }
        }
        let exported = try report(store)
        XCTAssertEqual(exported.events.count, 100)
        let attempts = exported.events.compactMap { event -> Int? in
            if case .integer(let value) = event.fields["attempt"] { return value }
            return nil
        }
        XCTAssertEqual(Set(attempts), Set(0..<100))
        XCTAssertEqual(store.status().droppedEventCount, 0)
    }

    func testNonFiniteValuesAreDroppedAndOversizedOwnedFilesPruned() throws {
        let store = DiagnosticLogStore(directory: directory, clock: clock,
                                       policy: DiagnosticRetentionPolicy(maximumFileBytes: 300, maximumTotalBytes: 600))
        XCTAssertFalse(store.record(.operationFailed, category: .recording,
                                    fields: [.sampleRate: .decimal(.infinity)]))
        XCTAssertEqual(store.status().droppedEventCount, 1)
        XCTAssertTrue(store.record(.appStarted, category: .application))
        let file = try XCTUnwrap(files().first)
        try Data(repeating: 0x41, count: 301).write(to: file)
        XCTAssertTrue(store.maintenance())
        XCTAssertTrue(try files().isEmpty)
    }

    func testDeleteAllClearsCountsAndRecordingCanResume() throws {
        let store = DiagnosticLogStore(directory: directory, clock: clock)
        store.record(.appStarted, category: .application)
        try store.deleteAll()
        XCTAssertEqual(store.status().eventCount, 0)
        XCTAssertEqual(store.status().fileCount, 0)
        XCTAssertTrue(store.record(.appReady, category: .application))
        XCTAssertEqual(try report(store).events.map(\.event), [.appReady])
    }

    func testInterruptedLastRowDoesNotConsumeTheNextEvent() throws {
        let store = DiagnosticLogStore(directory: directory, clock: clock)
        store.record(.appStarted, category: .application)
        let file = try XCTUnwrap(files().first)
        var data = try Data(contentsOf: file)
        data.append(Data("{\"timestamp\":\"interrupted".utf8))
        try data.write(to: file)
        XCTAssertTrue(store.record(.appReady, category: .application))
        XCTAssertEqual(try report(store).events.map(\.event), [.appStarted, .appReady])
    }
}
