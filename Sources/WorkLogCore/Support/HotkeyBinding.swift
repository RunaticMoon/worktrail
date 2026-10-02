import Foundation

/// 단축키 수정자. `ctrl < opt < shift < cmd` 순서로 비교·정렬한다.
/// Carbon/AppKit 키 마스크는 만들지 않는다(플랫폼 코드는 App 계층이 담당).
public enum HotkeyModifier: String, CaseIterable, Comparable, Sendable {
    case control = "ctrl"
    case option = "opt"
    case shift = "shift"
    case command = "cmd"

    public static func < (lhs: HotkeyModifier, rhs: HotkeyModifier) -> Bool {
        let order = HotkeyModifier.allCases
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }

    /// 표시용 기호. 순서는 `⌃⌥⇧⌘`.
    var symbol: String {
        switch self {
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        case .command: return "⌘"
        }
    }
}

/// 플랫폼 독립 단축키 키. 정규 이름과 macOS 가상 키코드(Carbon kVK 상수값)를 함께 둔다.
/// 지원 키: space, return, a-z, 0-9, f1-f12. (`tab`은 지원하지 않는다.)
public struct HotkeyKey: Hashable, Sendable {
    public let name: String
    public let macVirtualKeyCode: UInt16

    private init(name: String, macVirtualKeyCode: UInt16) {
        self.name = name
        self.macVirtualKeyCode = macVirtualKeyCode
    }

    /// 지원 키 전체. 이름 순서는 space, return, a-z, 0-9, f1-f12.
    public static let all: [HotkeyKey] = [
        HotkeyKey(name: "space", macVirtualKeyCode: 0x31),
        HotkeyKey(name: "return", macVirtualKeyCode: 0x24),
        HotkeyKey(name: "a", macVirtualKeyCode: 0x00),
        HotkeyKey(name: "b", macVirtualKeyCode: 0x0B),
        HotkeyKey(name: "c", macVirtualKeyCode: 0x08),
        HotkeyKey(name: "d", macVirtualKeyCode: 0x02),
        HotkeyKey(name: "e", macVirtualKeyCode: 0x0E),
        HotkeyKey(name: "f", macVirtualKeyCode: 0x03),
        HotkeyKey(name: "g", macVirtualKeyCode: 0x05),
        HotkeyKey(name: "h", macVirtualKeyCode: 0x04),
        HotkeyKey(name: "i", macVirtualKeyCode: 0x22),
        HotkeyKey(name: "j", macVirtualKeyCode: 0x26),
        HotkeyKey(name: "k", macVirtualKeyCode: 0x28),
        HotkeyKey(name: "l", macVirtualKeyCode: 0x25),
        HotkeyKey(name: "m", macVirtualKeyCode: 0x2E),
        HotkeyKey(name: "n", macVirtualKeyCode: 0x2D),
        HotkeyKey(name: "o", macVirtualKeyCode: 0x1F),
        HotkeyKey(name: "p", macVirtualKeyCode: 0x23),
        HotkeyKey(name: "q", macVirtualKeyCode: 0x0C),
        HotkeyKey(name: "r", macVirtualKeyCode: 0x0F),
        HotkeyKey(name: "s", macVirtualKeyCode: 0x01),
        HotkeyKey(name: "t", macVirtualKeyCode: 0x11),
        HotkeyKey(name: "u", macVirtualKeyCode: 0x20),
        HotkeyKey(name: "v", macVirtualKeyCode: 0x09),
        HotkeyKey(name: "w", macVirtualKeyCode: 0x0D),
        HotkeyKey(name: "x", macVirtualKeyCode: 0x07),
        HotkeyKey(name: "y", macVirtualKeyCode: 0x10),
        HotkeyKey(name: "z", macVirtualKeyCode: 0x06),
        HotkeyKey(name: "0", macVirtualKeyCode: 0x1D),
        HotkeyKey(name: "1", macVirtualKeyCode: 0x12),
        HotkeyKey(name: "2", macVirtualKeyCode: 0x13),
        HotkeyKey(name: "3", macVirtualKeyCode: 0x14),
        HotkeyKey(name: "4", macVirtualKeyCode: 0x15),
        HotkeyKey(name: "5", macVirtualKeyCode: 0x17),
        HotkeyKey(name: "6", macVirtualKeyCode: 0x16),
        HotkeyKey(name: "7", macVirtualKeyCode: 0x1A),
        HotkeyKey(name: "8", macVirtualKeyCode: 0x1C),
        HotkeyKey(name: "9", macVirtualKeyCode: 0x19),
        HotkeyKey(name: "f1", macVirtualKeyCode: 0x7A),
        HotkeyKey(name: "f2", macVirtualKeyCode: 0x78),
        HotkeyKey(name: "f3", macVirtualKeyCode: 0x63),
        HotkeyKey(name: "f4", macVirtualKeyCode: 0x76),
        HotkeyKey(name: "f5", macVirtualKeyCode: 0x60),
        HotkeyKey(name: "f6", macVirtualKeyCode: 0x61),
        HotkeyKey(name: "f7", macVirtualKeyCode: 0x62),
        HotkeyKey(name: "f8", macVirtualKeyCode: 0x64),
        HotkeyKey(name: "f9", macVirtualKeyCode: 0x65),
        HotkeyKey(name: "f10", macVirtualKeyCode: 0x6D),
        HotkeyKey(name: "f11", macVirtualKeyCode: 0x67),
        HotkeyKey(name: "f12", macVirtualKeyCode: 0x6F),
    ]

    private static let byName: [String: HotkeyKey] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
    private static let byCode: [UInt16: HotkeyKey] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.macVirtualKeyCode, $0) })

    /// 정규 이름(대소문자 무시)으로 키를 찾는다.
    public static func named(_ name: String) -> HotkeyKey? {
        byName[name.lowercased()]
    }

    /// macOS 가상 키코드로 키를 찾는다(역매핑).
    public static func fromMacVirtualKeyCode(_ code: UInt16) -> HotkeyKey? {
        byCode[code]
    }

    /// 표시용 이름. space→"Space", return→"↩", 그 외는 대문자.
    var displayName: String {
        switch name {
        case "space": return "Space"
        case "return": return "↩"
        default: return name.uppercased()
        }
    }
}

/// 단축키 문자열 파싱·정규화 오류.
public enum HotkeyBindingError: Error, Equatable, LocalizedError {
    case empty
    case unsupportedKey(String)
    case unsupportedModifier(String)
    case missingModifier
    case missingKey

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "단축키가 비어 있습니다."
        case .unsupportedKey(let key):
            return "지원하지 않는 키입니다: \(key)"
        case .unsupportedModifier(let modifier):
            return "지원하지 않는 수정자입니다: \(modifier)"
        case .missingModifier:
            return "수정자를 하나 이상 포함해야 합니다."
        case .missingKey:
            return "키가 필요합니다. 수정자만으로는 단축키를 만들 수 없습니다."
        }
    }
}

/// 플랫폼 독립 단축키 표현. 파싱·정규화·표시 문자열을 제공한다.
public struct HotkeyBinding: Equatable, Hashable, Sendable {
    public let key: HotkeyKey
    public let modifiers: Set<HotkeyModifier>

    public init(key: HotkeyKey, modifiers: Set<HotkeyModifier>) throws {
        guard !modifiers.isEmpty else { throw HotkeyBindingError.missingModifier }
        self.key = key
        self.modifiers = modifiers
    }

    /// 대소문자 무시, 공백 trim, `+` 구분, 별칭(control/option/alt/command 및 ⌃⌥⇧⌘ 기호)을 허용한다.
    /// 수정자 중복은 허용하되 정규화한다.
    public init(parsing text: String) throws {
        let tokens = Self.tokenize(text)
        guard !tokens.isEmpty else { throw HotkeyBindingError.empty }
        if tokens.allSatisfy({ Self.modifierAliases[$0] != nil }) {
            throw HotkeyBindingError.missingKey
        }
        guard let keyToken = tokens.last else { throw HotkeyBindingError.empty }

        var mods: Set<HotkeyModifier> = []
        for token in tokens.dropLast() {
            guard let modifier = Self.modifierAliases[token] else {
                throw HotkeyBindingError.unsupportedModifier(token)
            }
            mods.insert(modifier)
        }
        guard let key = HotkeyKey.named(keyToken) else {
            throw HotkeyBindingError.unsupportedKey(keyToken)
        }
        guard !mods.isEmpty else { throw HotkeyBindingError.missingModifier }
        self.key = key
        self.modifiers = mods
    }

    /// 정렬된 수정자 + 키. 예: `"ctrl+opt+d"`.
    public var canonicalString: String {
        modifiers.sorted().map(\.rawValue).joined(separator: "+") + "+" + key.name
    }

    /// 표시 문자열. 예: `"⌃⌥D"`, `"⌃⌥Space"`, `"⌃⇧↩"`.
    public var displayString: String {
        modifiers.sorted().map(\.symbol).joined() + key.displayName
    }

    private static let modifierAliases: [String: HotkeyModifier] = [
        "ctrl": .control, "control": .control,
        "opt": .option, "option": .option, "alt": .option,
        "shift": .shift,
        "cmd": .command, "command": .command,
    ]

    private static let symbolModifiers: [Character: HotkeyModifier] = [
        "⌃": .control, "⌥": .option, "⇧": .shift, "⌘": .command,
    ]

    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { tokens.append(trimmed) }
            current = ""
        }
        for character in text.lowercased() {
            if character == "+" {
                flush()
            } else if let modifier = symbolModifiers[character] {
                flush()
                tokens.append(modifier.rawValue)
            } else {
                current.append(character)
            }
        }
        flush()
        return tokens
    }
}
