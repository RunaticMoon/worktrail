#if os(macOS)
import Carbon
import Foundation
import WorkLogCore

enum GlobalHotkeyError: Error {
    case handlerInstallFailed(OSStatus)
    case registrationFailed(OSStatus)
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
@MainActor final class GlobalHotkeys: HotkeyRegistrar {
    private static let signature: OSType = 0x574C4F47 // 'WLOG'

    private let handlers: [HotkeyAction: () -> Void]
    private let state = CarbonHotkeyState()

    init(handlers: [HotkeyAction: () -> Void]) {
        self.handlers = handlers
    }

    /// Replaces the existing registration for `action`: it is removed first, and a failed
    /// call leaves nothing registered for that action.
    func register(_ binding: HotkeyBinding, for action: HotkeyAction) throws {
        unregister(action)
        try installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(binding.key.macVirtualKeyCode),
            Self.carbonModifiers(binding.modifiers),
            EventHotKeyID(signature: Self.signature, id: action.hotKeyID),
            GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            throw GlobalHotkeyError.registrationFailed(status)
        }
        state.registrations[action] = ref
    }

    func unregister(_ action: HotkeyAction) {
        if let ref = state.registrations.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
        }
    }

    /// Releases every registered hotkey and removes the event handler.
    /// A later `register` call installs the handler again.
    func shutdown() {
        for ref in state.registrations.values { UnregisterEventHotKey(ref) }
        state.registrations.removeAll()
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
