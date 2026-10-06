#if os(macOS)
import Carbon
import Foundation
import SwiftUI
import Observation
import WorkLogCore

enum GlobalHotkeyError: Error {
    case handlerInstallFailed(OSStatus)
    case registrationFailed(OSStatus)
}

/// Session-only diagnostics. No query, title, key or value is stored or logged.
struct HotkeyDiagnostic: Equatable, Sendable {
    var registrationText = "등록되지 않음"
    var recentPressText: String?
    var lastFailure: String?
}

private struct HotkeyDiagnosticsKey: EnvironmentKey {
    static let defaultValue: [HotkeyAction: HotkeyDiagnostic] = [:]
}

extension EnvironmentValues {
    var hotkeyDiagnostics: [HotkeyAction: HotkeyDiagnostic] {
        get { self[HotkeyDiagnosticsKey.self] }
        set { self[HotkeyDiagnosticsKey.self] = newValue }
    }
}

/// Carbon refs are stored in a nonisolated box so `deinit` can release them
/// even when it runs outside the main actor (Swift 6 deinit isolation).
private final class CarbonHotkeyState: @unchecked Sendable {
    var handler: EventHandlerRef?
    var registrations: [HotkeyAction: EventHotKeyRef] = [:]
}

/// Carbon registration avoids event-monitor/accessibility permissions. Unknown combinations fail visibly.
/// The event handler is installed lazily once per instance and removed by `shutdown`/`deinit`,
/// so repeated binding swaps never accumulate handlers.
@Observable @MainActor final class GlobalHotkeys: HotkeyRegistrar {
    private static let signature: OSType = 0x574C4F47 // 'WLOG'

    @ObservationIgnored private let handlers: [HotkeyAction: () -> Void]
    @ObservationIgnored private let state = CarbonHotkeyState()
    @ObservationIgnored private let clock: any WorkLogCore.Clock
    @ObservationIgnored private let timeZone: TimeZone
    private(set) var diagnostics: [HotkeyAction: HotkeyDiagnostic] = [:]

    init(clock: any WorkLogCore.Clock, timeZone: TimeZone, handlers: [HotkeyAction: () -> Void]) {
        self.clock = clock
        self.timeZone = timeZone
        self.handlers = handlers
    }

    /// Replaces the existing registration for `action`: it is removed first, and a failed
    /// call leaves nothing registered for that action.
    func register(_ binding: HotkeyBinding, for action: HotkeyAction) throws {
        unregister(action)
        do {
            try installHandlerIfNeeded()
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(binding.key.macVirtualKeyCode),
                Self.carbonModifiers(binding.modifiers),
                EventHotKeyID(signature: Self.signature, id: action.hotKeyID),
                GetApplicationEventTarget(), 0, &ref)
            guard status == noErr, let ref else { throw GlobalHotkeyError.registrationFailed(status) }
            state.registrations[action] = ref
            var diagnostic = diagnostics[action] ?? HotkeyDiagnostic()
            diagnostic.registrationText = "등록됨"
            diagnostics[action] = diagnostic
        } catch {
            let code: OSStatus
            switch error {
            case GlobalHotkeyError.handlerInstallFailed(let status): code = status
            case GlobalHotkeyError.registrationFailed(let status): code = status
            default: code = OSStatus(paramErr)
            }
            var diagnostic = diagnostics[action] ?? HotkeyDiagnostic()
            diagnostic.registrationText = "등록 실패: 다른 앱이 사용 중일 수 있음 (OSStatus \(code))"
            diagnostic.lastFailure = diagnostic.registrationText
            diagnostics[action] = diagnostic
            throw error
        }
    }

    func unregister(_ action: HotkeyAction) {
        if let ref = state.registrations.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
            var diagnostic = diagnostics[action] ?? HotkeyDiagnostic()
            diagnostic.registrationText = "등록되지 않음 · 단축키 녹화 또는 변경 중"
            diagnostics[action] = diagnostic
        }
    }

    /// Releases every registered hotkey and removes the event handler.
    /// A later `register` call installs the handler again.
    func shutdown() {
        for ref in state.registrations.values { UnregisterEventHotKey(ref) }
        state.registrations.removeAll()
        diagnostics = [:]
        if let handler = state.handler {
            RemoveEventHandler(handler)
            state.handler = nil
        }
    }

    deinit {
        for ref in state.registrations.values { UnregisterEventHotKey(ref) }
        if let handler = state.handler { RemoveEventHandler(handler) }
    }

    private func installHandlerIfNeeded() throws {
        guard state.handler == nil else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var handler: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil,
                numericCast(MemoryLayout<EventHotKeyID>.size), nil, &hotKeyID)
            guard read == noErr else { return read }
            guard hotKeyID.signature == GlobalHotkeys.signature else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                let owner = Unmanaged<GlobalHotkeys>.fromOpaque(context).takeUnretainedValue()
                owner.dispatch(hotKeyID.id)
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr, let handler else {
            throw GlobalHotkeyError.handlerInstallFailed(status)
        }
        state.handler = handler
    }

    private func dispatch(_ id: UInt32) {
        guard let action = HotkeyAction.allCases.first(where: { $0.hotKeyID == id }) else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        var diagnostic = diagnostics[action] ?? HotkeyDiagnostic()
        diagnostic.recentPressText = "최근 눌림: \(formatter.string(from: clock.now()))"
        diagnostics[action] = diagnostic
        handlers[action]?()
    }

    private static func carbonModifiers(_ modifiers: Set<HotkeyModifier>) -> UInt32 {
        var result: UInt32 = 0
        for modifier in modifiers {
            switch modifier {
            case .control: result |= UInt32(controlKey)
            case .option: result |= UInt32(optionKey)
            case .shift: result |= UInt32(shiftKey)
            case .command: result |= UInt32(cmdKey)
            }
        }
        return result
    }
}

private extension HotkeyAction {
    /// Fixed Carbon EventHotKeyID per action.
    var hotKeyID: UInt32 {
        switch self {
        case .capture: return 1
        case .search: return 2
        }
    }
}
#endif
