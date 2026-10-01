#if os(macOS)
import Carbon
import Foundation

/// Carbon registration avoids event-monitor/accessibility permissions. Unknown combinations fail visibly.
@MainActor final class GlobalHotkeys {
    private var handler: EventHandlerRef?
    private var registrations: [EventHotKeyRef] = []
    private var callbacks: [UInt32: () -> Void] = [:]

    func register(capture: String, search: String, onCapture: @escaping () -> Void,
                  onSearch: @escaping () -> Void) -> [String] {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil, numericCast(MemoryLayout<EventHotKeyID>.size), nil, &id)
            guard status == noErr else { return status }
            MainActor.assumeIsolated {
                let owner = Unmanaged<GlobalHotkeys>.fromOpaque(context).takeUnretainedValue()
                owner.callbacks[id.id]?()
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return ["전역 단축키 처리기를 설치하지 못했습니다. 메뉴에서 입력·검색을 열어 주세요."] }
        var errors: [String] = []
        for (id, title, binding, action) in [(UInt32(1), "입력", capture, onCapture), (UInt32(2), "검색", search, onSearch)] {
            guard let key = Self.parse(binding) else {
                errors.append("\(title) 단축키 형식을 지원하지 않습니다: \(binding)"); continue
            }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(key.code, key.modifiers,
                EventHotKeyID(signature: 0x574C4F47, id: id), GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { registrations.append(ref); callbacks[id] = action }
            else { errors.append("\(title) 단축키를 등록하지 못했습니다(\(status)). 다른 조합으로 설정하세요.") }
        }
        return errors
    }
    private static func parse(_ binding: String) -> (code: UInt32, modifiers: UInt32)? {
        let parts = binding.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last else { return nil }
        let codes: [String: Int] = ["space": kVK_Space, "return": kVK_Return, "f": kVK_ANSI_F,
            "n": kVK_ANSI_N, "k": kVK_ANSI_K, "s": kVK_ANSI_S, "d": kVK_ANSI_D,
            "a": kVK_ANSI_A, "q": kVK_ANSI_Q, "w": kVK_ANSI_W, "e": kVK_ANSI_E,
            "r": kVK_ANSI_R, "t": kVK_ANSI_T, "g": kVK_ANSI_G, "b": kVK_ANSI_B,
            "c": kVK_ANSI_C, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
            "l": kVK_ANSI_L, "m": kVK_ANSI_M, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9, "f1": kVK_F1, "f2": kVK_F2,
            "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
            "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10,
            "f11": kVK_F11, "f12": kVK_F12]
        guard let code = codes[key] else { return nil }
        var modifiers: UInt32 = 0
        for part in parts.dropLast() {
            switch part {
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "opt", "option", "alt": modifiers |= UInt32(optionKey)
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            case "shift": modifiers |= UInt32(shiftKey)
            default: return nil
            }
        }
        guard modifiers != 0 else { return nil }
        return (UInt32(code), modifiers)
    }
    deinit {
        for ref in registrations { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
#endif
