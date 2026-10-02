import Foundation
import XCTest
@testable import WorkLogCore

/// WTUX-F946 T: 핫키 적용·복구·녹화 수명주기 조정기 검증.
/// OS 코드 대신 fake registrar로 등록·해제 호출과 실패 주입을 검증한다.
final class HotkeySettingsCoordinatorTests: XCTestCase {

    // MARK: - Fake

    private struct StubError: Error {}

    /// 등록 상태를 기록하는 fake. 실제 OS처럼 이미 등록된 조합의 중복 등록을 거절한다.
    @MainActor
    private final class FakeRegistrar: HotkeyRegistrar {
        private(set) var registered: [HotkeyAction: HotkeyBinding] = [:]
        var registerCalls = 0
        var unregisterCalls = 0
        /// 이 action의 등록은 항상 실패한다(복구 등록 포함).
        var failingActions: Set<HotkeyAction> = []
        /// 이 조합의 등록은 항상 실패한다(OS가 다른 앱 점유로 거절하는 상황).
        var failingBindings: Set<HotkeyBinding> = []

        func register(_ binding: HotkeyBinding, for action: HotkeyAction) throws {
            registerCalls += 1
            if failingActions.contains(action) || failingBindings.contains(binding) { throw StubError() }
            if registered.contains(where: { $0.key != action && $0.value == binding }) { throw StubError() }
            registered[action] = binding
        }

        func unregister(_ action: HotkeyAction) {
            unregisterCalls += 1
            registered[action] = nil
        }
    }

    private let captureText = "ctrl+opt+space"
    private let searchText = "ctrl+opt+d"

    @MainActor
    private func makeStarted() -> (HotkeySettingsCoordinator, FakeRegistrar) {
        let registrar = FakeRegistrar()
        let coordinator = HotkeySettingsCoordinator(registrar: registrar)
        let messages = coordinator.start(capture: captureText, search: searchText)
        XCTAssertEqual(messages, [])
        return (coordinator, registrar)
    }

    private func binding(_ text: String) throws -> HotkeyBinding {
        try HotkeyBinding(parsing: text)
    }

    // MARK: - 최초 등록

    @MainActor
    func testStartRegistersBothActions() async throws {
        let registrar = FakeRegistrar()
        let coordinator = HotkeySettingsCoordinator(registrar: registrar)

        let messages = coordinator.start(capture: captureText, search: searchText)

        XCTAssertEqual(messages, [])
        XCTAssertEqual(registrar.registered[.capture], try binding(captureText))
        XCTAssertEqual(registrar.registered[.search], try binding(searchText))
        XCTAssertEqual(coordinator.active[.capture], try binding(captureText))
        XCTAssertEqual(coordinator.active[.search], try binding(searchText))
        XCTAssertFalse(coordinator.isRecording)
    }

    @MainActor
    func testStartPartialFailureKeepsOtherAction() async throws {
        let registrar = FakeRegistrar()
        registrar.failingActions = [.search]
        let coordinator = HotkeySettingsCoordinator(registrar: registrar)

        let messages = coordinator.start(capture: captureText, search: searchText)

        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("검색"))
        XCTAssertEqual(registrar.registered[.capture], try binding(captureText))
        XCTAssertNil(registrar.registered[.search])
        XCTAssertNil(coordinator.active[.search])
    }

    @MainActor
    func testStartReportsInvalidFormatWithoutRegistering() async {
        let registrar = FakeRegistrar()
        let coordinator = HotkeySettingsCoordinator(registrar: registrar)

        let messages = coordinator.start(capture: "super+space", search: searchText)

        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("입력"))
        XCTAssertNil(registrar.registered[.capture])
        XCTAssertNotNil(registrar.registered[.search])
    }

    @MainActor
    func testStartReportsDuplicateCombination() async throws {
        let registrar = FakeRegistrar()
        let coordinator = HotkeySettingsCoordinator(registrar: registrar)

        let messages = coordinator.start(capture: captureText, search: " ⌃⌥Space ")

        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("검색"))
        XCTAssertEqual(registrar.registered.count, 1)
        XCTAssertEqual(registrar.registered[.capture], try binding(captureText))
    }

    @MainActor
    func testStartTwiceLeavesNoStaleRegistrations() async throws {
        let registrar = FakeRegistrar()
        let coordinator = HotkeySettingsCoordinator(registrar: registrar)
        _ = coordinator.start(capture: captureText, search: searchText)

        let messages = coordinator.start(capture: "ctrl+opt+n", search: "cmd+shift+k")

        XCTAssertEqual(messages, [])
        XCTAssertEqual(registrar.registered.count, 2)
        XCTAssertEqual(registrar.registered[.capture], try? binding("ctrl+opt+n"))
        XCTAssertEqual(registrar.registered[.search], try? binding("cmd+shift+k"))
    }

    // MARK: - 적용

    @MainActor
    func testApplyChangesOnlyChangedAction() async throws {
        let (coordinator, registrar) = makeStarted()
        let beforeRegisters = registrar.registerCalls

        try coordinator.apply(capture: captureText, search: "cmd+shift+k") {}

        XCTAssertEqual(registrar.registered.count, 2)
        XCTAssertEqual(registrar.registered[.search], try binding("cmd+shift+k"))
        XCTAssertEqual(registrar.registered[.capture], try binding(captureText))
        XCTAssertEqual(registrar.registerCalls - beforeRegisters, 1, "변경된 action만 재등록해야 합니다.")
    }

    @MainActor
    func testRepeatedApplyDoesNotAccumulate() async throws {
        let (coordinator, registrar) = makeStarted()

        try coordinator.apply(capture: "ctrl+opt+n", search: searchText) {}
        try coordinator.apply(capture: "cmd+opt+m", search: searchText) {}
        try coordinator.apply(capture: captureText, search: "ctrl+shift+s") {}

        XCTAssertEqual(registrar.registered.count, 2, "반복 적용 후에도 action당 하나씩만 등록돼야 합니다.")
        XCTAssertEqual(registrar.registered[.capture], try binding(captureText))
        XCTAssertEqual(registrar.registered[.search], try binding("ctrl+shift+s"))
    }

    @MainActor
    func testKeySwapSucceeds() async throws {
        let (coordinator, registrar) = makeStarted()

        try coordinator.apply(capture: searchText, search: captureText) {}

        XCTAssertEqual(registrar.registered[.capture], try binding(searchText))
        XCTAssertEqual(registrar.registered[.search], try binding(captureText))
        XCTAssertEqual(coordinator.active[.capture], try binding(searchText))
    }

    @MainActor
    func testDuplicateCombinationRejectedWithoutTouchingRegistrations() async {
        let (coordinator, registrar) = makeStarted()
        let registerCalls = registrar.registerCalls
        let unregisterCalls = registrar.unregisterCalls

        XCTAssertThrowsError(try coordinator.apply(capture: "ctrl+opt+d", search: "⌃⌥D") {}) { error in
            XCTAssertEqual(error as? HotkeyApplyError, .duplicate)
        }
        XCTAssertEqual(registrar.registerCalls, registerCalls)
        XCTAssertEqual(registrar.unregisterCalls, unregisterCalls)
        XCTAssertEqual(registrar.registered.count, 2)
    }

    @MainActor
    func testInvalidFormatRejectedWithoutTouchingRegistrations() async {
        let (coordinator, registrar) = makeStarted()
        let registerCalls = registrar.registerCalls
        let unregisterCalls = registrar.unregisterCalls

        XCTAssertThrowsError(try coordinator.apply(capture: "ctrl+opt+tab", search: searchText) {}) { error in
            guard case .invalid(let action, let detail)? = error as? HotkeyApplyError else {
                return XCTFail("invalid 오류를 기대했습니다: \(error)")
            }
            XCTAssertEqual(action, .capture)
            XCTAssertFalse(detail.isEmpty)
        }
        XCTAssertEqual(registrar.registerCalls, registerCalls)
        XCTAssertEqual(registrar.unregisterCalls, unregisterCalls)
        XCTAssertEqual(registrar.registered.count, 2)
    }

    @MainActor
    func testUnchangedApplyOnlyPersists() async throws {
        let (coordinator, registrar) = makeStarted()
        let registerCalls = registrar.registerCalls
        let unregisterCalls = registrar.unregisterCalls
        var persisted = 0

        try coordinator.apply(capture: captureText, search: searchText) { persisted += 1 }

        XCTAssertEqual(persisted, 1)
        XCTAssertEqual(registrar.registerCalls, registerCalls)
        XCTAssertEqual(registrar.unregisterCalls, unregisterCalls)
    }

    @MainActor
    func testRegistrationFailureRestoresPreviousBindings() async throws {
        let (coordinator, registrar) = makeStarted()
        registrar.failingBindings = [try binding("cmd+shift+k")]

        XCTAssertThrowsError(try coordinator.apply(capture: captureText, search: "cmd+shift+k") {}) { error in
            XCTAssertEqual(error as? HotkeyApplyError, .registrationFailed(.search))
        }
        XCTAssertEqual(registrar.registered[.capture], try binding(captureText))
        XCTAssertEqual(registrar.registered[.search], try binding(searchText), "기존 조합이 복구돼야 합니다.")
        XCTAssertEqual(coordinator.active[.search], try binding(searchText))
    }

    @MainActor
    func testPersistFailureRestoresPreviousBindings() async throws {
        let (coordinator, registrar) = makeStarted()
        struct PersistError: Error {}

        XCTAssertThrowsError(
            try coordinator.apply(capture: captureText, search: "cmd+shift+k") { throw PersistError() }
        ) { error in
            XCTAssertEqual(error as? HotkeyApplyError, .persistFailed)
        }
        XCTAssertEqual(registrar.registered[.capture], try binding(captureText))
        XCTAssertEqual(registrar.registered[.search], try binding(searchText), "저장 실패 시 기존 조합이 복구돼야 합니다.")
        XCTAssertEqual(coordinator.active[.search], try binding(searchText))
    }

    @MainActor
    func testRestoreFailureThrowsRestoreFailed() async {
        let (coordinator, registrar) = makeStarted()
        registrar.failingActions = [.search]

        XCTAssertThrowsError(try coordinator.apply(capture: captureText, search: "cmd+shift+k") {}) { error in
            XCTAssertEqual(error as? HotkeyApplyError, .restoreFailed)
        }
        XCTAssertNil(registrar.registered[.search])
        XCTAssertNotNil(registrar.registered[.capture])
    }

    // MARK: - 녹화

    @MainActor
    func testBeginRecordingSuspendsAllRegistrations() async {
        let (coordinator, registrar) = makeStarted()

        coordinator.beginRecording()

        XCTAssertTrue(coordinator.isRecording)
        XCTAssertTrue(registrar.registered.isEmpty, "녹화 중에는 현재 조합도 해제돼 다시 녹화할 수 있어야 합니다.")
    }

    @MainActor
    func testEndRecordingRestoresRegistrations() async throws {
        let (coordinator, registrar) = makeStarted()
        coordinator.beginRecording()

        let messages = coordinator.endRecording()

        XCTAssertEqual(messages, [])
        XCTAssertFalse(coordinator.isRecording)
        XCTAssertEqual(registrar.registered[.capture], try binding(captureText))
        XCTAssertEqual(registrar.registered[.search], try binding(searchText))
    }

    @MainActor
    func testBeginRecordingTwiceIsIgnored() async {
        let (coordinator, registrar) = makeStarted()
        coordinator.beginRecording()
        let unregisterCalls = registrar.unregisterCalls

        coordinator.beginRecording()

        XCTAssertEqual(registrar.unregisterCalls, unregisterCalls, "중복 begin은 추가 해제를 하면 안 됩니다.")
        XCTAssertTrue(coordinator.isRecording)
    }

    @MainActor
    func testEndRecordingWithoutBeginIsNoOp() async {
        let (coordinator, registrar) = makeStarted()
        let registerCalls = registrar.registerCalls

        let messages = coordinator.endRecording()

        XCTAssertEqual(messages, [])
        XCTAssertEqual(registrar.registerCalls, registerCalls)
    }

    @MainActor
    func testEndRecordingReportsRestoreFailure() async throws {
        let (coordinator, registrar) = makeStarted()
        coordinator.beginRecording()
        registrar.failingActions = [.search]

        let messages = coordinator.endRecording()

        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("검색"))
        XCTAssertFalse(coordinator.isRecording)
        XCTAssertEqual(registrar.registered[.capture], try binding(captureText))
        XCTAssertNil(registrar.registered[.search])
    }

    @MainActor
    func testApplyDuringRecordingEndsRecordingAndApplies() async throws {
        let (coordinator, registrar) = makeStarted()
        coordinator.beginRecording()
        var persisted = false

        try coordinator.apply(capture: "ctrl+opt+n", search: searchText) { persisted = true }

        XCTAssertFalse(coordinator.isRecording)
        XCTAssertTrue(persisted)
        XCTAssertEqual(registrar.registered[.capture], try binding("ctrl+opt+n"))
        XCTAssertEqual(registrar.registered[.search], try binding(searchText))
    }

    @MainActor
    func testApplyDuringRecordingWithInvalidInputRestoresPrevious() async throws {
        let (coordinator, registrar) = makeStarted()
        coordinator.beginRecording()

        XCTAssertThrowsError(try coordinator.apply(capture: "tab", search: "cmd+shift+k") {}) { error in
            guard case .invalid(let action, _)? = error as? HotkeyApplyError else {
                return XCTFail("invalid 오류를 기대했습니다: \(error)")
            }
            XCTAssertEqual(action, .capture)
        }
        XCTAssertFalse(coordinator.isRecording)
        XCTAssertEqual(registrar.registered[.capture], try binding(captureText), "녹화 종료로 처리됐으므로 기존 조합이 복원돼야 합니다.")
        XCTAssertEqual(registrar.registered[.search], try binding(searchText))
    }

    // MARK: - 종료

    @MainActor
    func testShutdownClearsAllRegistrations() async {
        let (coordinator, registrar) = makeStarted()

        coordinator.shutdown()

        XCTAssertTrue(registrar.registered.isEmpty)
        XCTAssertTrue(coordinator.active.isEmpty)
        XCTAssertFalse(coordinator.isRecording)
    }

    @MainActor
    func testShutdownDuringRecordingStaysCleared() async {
        let (coordinator, registrar) = makeStarted()
        coordinator.beginRecording()

        coordinator.shutdown()

        XCTAssertTrue(registrar.registered.isEmpty)
        XCTAssertTrue(coordinator.active.isEmpty)
        XCTAssertFalse(coordinator.isRecording)
    }

    // MARK: - 오류 메시지

    func testErrorDescriptionsAreKoreanAndSafe() async {
        let errors: [HotkeyApplyError] = [
            .invalid(.capture, "지원하지 않는 키입니다: tab"),
            .duplicate,
            .registrationFailed(.search),
            .persistFailed,
            .restoreFailed,
        ]
        for error in errors {
            let description = error.errorDescription ?? ""
            XCTAssertFalse(description.isEmpty, "\(error)의 설명이 비어 있습니다.")
            XCTAssertFalse(description.contains("/"), "경로 노출 금지: \(description)")
            XCTAssertTrue(description.range(of: "[가-힣]", options: .regularExpression) != nil,
                          "한국어 메시지여야 합니다: \(description)")
        }
        XCTAssertFalse(HotkeyApplyError.restoreFailed.errorDescription?.contains("유지됩니다") ?? true,
                       "복구 실패는 기존 조합 유지를 주장하면 안 됩니다.")
    }
}
