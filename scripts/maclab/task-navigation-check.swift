// Compiles with the complete production AppController and app sources. Only the
// Carbon hotkey adapter is inert. No SwiftUI view is presented, and no real IME,
// OS notification response, or alert/sheet dismissal timing is simulated here.
import AppKit
import Foundation
import Observation
import SwiftUI
import WorkLogCore

struct HotkeyDiagnostic: Equatable, Sendable {
    var registrationText = "검증용 · OS 등록 없음"
    var recentPressText: String?
    var lastFailure: String?
}

private struct NavigationHotkeyDiagnosticsKey: EnvironmentKey {
    static let defaultValue: [HotkeyAction: HotkeyDiagnostic] = [:]
}

extension EnvironmentValues {
    var hotkeyDiagnostics: [HotkeyAction: HotkeyDiagnostic] {
        get { self[NavigationHotkeyDiagnosticsKey.self] }
        set { self[NavigationHotkeyDiagnosticsKey.self] = newValue }
    }
}

@Observable @MainActor final class GlobalHotkeys: HotkeyRegistrar {
    private(set) var diagnostics: [HotkeyAction: HotkeyDiagnostic] = [:]
    init(clock: any WorkLogCore.Clock, timeZone: TimeZone, handlers: [HotkeyAction: () -> Void]) {}
    func register(_ binding: HotkeyBinding, for action: HotkeyAction) throws {
        diagnostics[action] = HotkeyDiagnostic()
    }
    func unregister(_ action: HotkeyAction) { diagnostics.removeValue(forKey: action) }
    func shutdown() { diagnostics = [:] }
}

private struct TaskNavigationCheckError: Error {
    let message: String
}

@main struct TaskNavigationCheck {
    @MainActor static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw TaskNavigationCheckError(message: message) }
    }

    @MainActor static func main() async {
        do {
            try require(Array(CommandLine.arguments.dropFirst()) == ["--ui-test-fixture", "many"],
                        "The disposable many fixture is required; other launch arguments are forbidden")
            try require(ProcessInfo.processInfo.environment["WORKLOG_DIAGNOSTICS_DISABLED"] == "1",
                        "Diagnostics must be disabled before starting the controller")
            _ = NSApplication.shared
            let controller = AppController()
            await controller.start()
            try require(controller.startupError == nil, "Fixture AppController startup failed")
            guard let environment = controller.environment, let model = controller.taskDetail else {
                throw TaskNavigationCheckError(message: "Missing fixture environment or task detail")
            }
            let root = environment.options.paths.dataRoot.deletingLastPathComponent().standardizedFileURL
            try require(root.lastPathComponent.hasPrefix("WorkLog-UI-many-"), "Refusing a non-fixture data root")
            try require(root.deletingLastPathComponent().resolvingSymlinksInPath()
                        == FileManager.default.temporaryDirectory.resolvingSymlinksInPath(),
                        "Fixture data must stay under the temporary directory")
            defer {
                controller.closeTask()
                try? FileManager.default.removeItem(at: root)
            }
            try require(controller.taskNotifications == nil, "Headless checks must not install OS notification handling")
            try require(NSApp.windows.isEmpty, "Headless startup must not create windows")

            let a = try environment.tasks.createTask(title: "Navigation fixture A", projectNames: ["Navigation project A"], checklist: ["Existing A item"])
            let b = try environment.tasks.createTask(title: "Navigation fixture B")
            let c = try environment.tasks.createTask(title: "Navigation fixture C")
            controller.openTask(a.id)
            guard let projectId = model.detail?.projects.first?.project.id else {
                throw TaskNavigationCheckError(message: "Fixture project is missing")
            }
            let date = environment.calendar.adding(days: -1, to: model.today)
            model.activityText = "A activity draft"; model.checklistText = "A checklist draft"
            model.statusNote = "A reason draft"; model.workDate = date; model.activityProjectId = projectId
            controller.openTask(b.id)
            controller.openTask(c.id)
            try require(controller.pendingTaskNavigation?.id == b.id && controller.confirmsTaskNavigation,
                        "Repeated requests must retain the first pending target")
            try require(controller.selectedTaskId == a.id && model.detail?.task.id == a.id,
                        "A pending request must retain the current task")
            // SwiftUI owns this flag. Clearing it before the callback must not
            // remove the independently stored navigation request.
            controller.confirmsTaskNavigation = false
            controller.cancelTaskNavigation()
            try require(controller.pendingTaskNavigation == nil && controller.selectedTaskId == a.id,
                        "Cancelling must leave A selected and clear the pending request")
            try require(model.activityText == "A activity draft" && model.checklistText == "A checklist draft"
                        && model.statusNote == "A reason draft" && model.workDate == date
                        && model.activityProjectId == projectId && model.asOf == nil,
                        "Cancelling must preserve all input and its date/scope")
            model.addActivity(); model.addChecklistItem()
            try require(try environment.repo.activities(taskId: a.id).map(\.body) == ["A activity draft"],
                        "Activity after cancellation must be saved only to A")
            try require(try environment.repo.checklistItems(taskId: a.id).contains { $0.text == "A checklist draft" },
                        "Checklist after cancellation must be saved only to A")
            try require(try environment.repo.activities(taskId: b.id).isEmpty
                        && environment.repo.checklistItems(taskId: b.id).isEmpty,
                        "B must not receive A input")
            print("PASS: pending cancellation preserves all input and subsequent writes target only A")

            model.activityText = "Discarded activity"; model.checklistText = "Discarded checklist"
            controller.openTask(b.id)
            controller.confirmsTaskNavigation = false
            controller.discardInputAndNavigateTask()
            try require(controller.selectedTaskId == b.id && model.detail?.task.id == b.id
                        && controller.pendingTaskNavigation == nil && !controller.confirmsTaskNavigation,
                        "Discard must consume the pending request even when its presentation flag is already false")
            try require(!model.hasUnsavedInput && model.activityText.isEmpty && model.checklistText.isEmpty
                        && model.statusNote.isEmpty && model.activityProjectId == nil && model.workDate == model.today,
                        "Discarding and navigating must start B with clean task-specific state")
            print("PASS: explicit discard opens a clean B and clears the request")

            controller.openTask(a.id)
            model.complete()
            guard let completion = model.completionCheck else {
                throw TaskNavigationCheckError(message: "A must require completion confirmation")
            }
            controller.openTask(a.id)
            try require(model.completionCheck == completion && controller.pendingTaskNavigation == nil,
                        "A same-selection notification must not reset the active completion check")
            model.cancelCompletion()
            model.activityText = "Refresh draft"; model.workDate = date; model.activityProjectId = projectId
            controller.refresh()
            try require(model.activityText == "Refresh draft" && model.workDate == date && model.activityProjectId == projectId,
                        "An ordinary refresh must retain task input and its context")
            model.discardInput()
            print("PASS: same-selection notifications preserve completion and refresh preserves task input")

            guard var draft = model.propertiesDraft else {
                throw TaskNavigationCheckError(message: "Missing property editor draft")
            }
            draft.title = "Navigation fixture A edited"
            controller.setTaskEditorPresented(true)
            controller.openTask(b.id)
            controller.openTask(c.id)
            try require(controller.selectedTaskId == a.id && model.detail?.task.id == a.id
                        && controller.pendingTaskNavigation == nil && !controller.confirmsTaskNavigation,
                        "An open nested editor must defer selection without opening a competing alert")
            try require(model.saveProperties(draft), "The nested property draft should save to A")
            controller.setTaskEditorPresented(false)
            try require(try environment.repo.task(id: a.id)?.title == "Navigation fixture A edited"
                        && environment.repo.task(id: b.id)?.title == b.title,
                        "The captured A property draft must never rename B")
            try require(controller.selectedTaskId == b.id && model.detail?.task.id == b.id,
                        "Closing the nested editor must consume the first deferred request only")
            print("PASS: nested property editing saves to A, then opens the first deferred target B")

            controller.openTask(a.id)
            model.activityText = "Parent activity remains"
            controller.setTaskEditorPresented(true)
            controller.openTask(b.id)
            controller.setTaskEditorPresented(false)
            try require(controller.selectedTaskId == a.id && controller.pendingTaskNavigation?.id == b.id
                        && controller.confirmsTaskNavigation && model.activityText == "Parent activity remains",
                        "A parent draft must still require confirmation after the nested editor closes")
            controller.cancelTaskNavigation(); model.discardInput()
            print("PASS: deferred navigation rechecks the parent draft after nested editing")

            controller.setTaskEditorPresented(true)
            controller.openTask(b.id)
            controller.closeTask()
            controller.setTaskEditorPresented(false)
            try require(controller.selectedTaskId == nil && controller.pendingTaskNavigation == nil
                        && !controller.confirmsTaskNavigation, "Closing must not reopen a deferred task")
            controller.openTask(a.id)
            model.activityText = "Close pending draft"
            controller.openTask(b.id)
            controller.closeTask()
            try require(controller.selectedTaskId == nil && controller.pendingTaskNavigation == nil
                        && !controller.confirmsTaskNavigation, "Closing must clear pending confirmation state")
            model.discardInput()
            controller.openTask(c.id)
            try require(controller.selectedTaskId == c.id && model.detail?.task.id == c.id,
                        "Cleared queues must not block a later task request")
            print("PASS: close clears deferred and pending requests without reopening a stale task")

            let missingId = "navigation-fixture-late-task"
            controller.openTask(missingId)
            try require(controller.selectedTaskId == missingId && model.detail == nil && model.errorMessage != nil,
                        "An accepted load failure must not retain the previous task detail")
            var late = c
            late.id = missingId; late.title = "Late fixture task"
            try environment.repo.insertTask(late)
            controller.openTask(missingId)
            try require(model.detail?.task.id == missingId && model.errorMessage == nil,
                        "The same-selection shortcut must allow retry after a failed load")
            try require(NSApp.windows.isEmpty, "Headless checks must not create or activate windows")
            print("PASS: same-ID retry recovers from a missing-task load failure")
            print("7 task navigation controller suites passed; fake local data and inert hotkeys only. SwiftUI presentation, real notifications and IME are not tested.")
        } catch let error as TaskNavigationCheckError {
            print("FAIL: \(error.message)")
            exit(1)
        } catch {
            print("FAIL: fixture setup or persistence failed")
            exit(1)
        }
    }
}
