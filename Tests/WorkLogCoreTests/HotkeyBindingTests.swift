import Foundation
import XCTest
@testable import WorkLogCore

/// WTUX-F946 Q: 플랫폼 독립 단축키 표현·파서·정규화 검증.
/// Carbon/AppKit 없이 이름·수정자·정규화·오류만 검증한다.
final class HotkeyBindingTests: XCTestCase {

    // MARK: - 정상 파싱

    func testParsesCanonicalForm() throws {
        let binding = try HotkeyBinding(parsing: "ctrl+opt+d")
        XCTAssertEqual(binding.key, HotkeyKey.named("d"))
        XCTAssertEqual(binding.modifiers, [.control, .option])
        XCTAssertEqual(binding.canonicalString, "ctrl+opt+d")
    }

    func testParsesExistingSettingsValues() throws {
        XCTAssertEqual(try HotkeyBinding(parsing: "ctrl+opt+space").canonicalString, "ctrl+opt+space")
        XCTAssertEqual(try HotkeyBinding(parsing: "ctrl+opt+f").canonicalString, "ctrl+opt+f")
        XCTAssertEqual(try HotkeyBinding(parsing: "ctrl+opt+d").canonicalString, "ctrl+opt+d")
    }

    func testCaseInsensitive() throws {
        XCTAssertEqual(try HotkeyBinding(parsing: "CTRL+OPT+D"), try HotkeyBinding(parsing: "ctrl+opt+d"))
        XCTAssertEqual(try HotkeyBinding(parsing: "Ctrl+Opt+Space").canonicalString, "ctrl+opt+space")
    }

    func testTrimsWhitespaceAroundParts() throws {
        let binding = try HotkeyBinding(parsing: "  ctrl  +  opt +  d  ")
        XCTAssertEqual(binding.canonicalString, "ctrl+opt+d")
    }

    func testModifierAliases() throws {
        let aliased = try HotkeyBinding(parsing: "control+option+command+k")
        XCTAssertEqual(aliased.modifiers, [.control, .option, .command])
        XCTAssertEqual(aliased.canonicalString, "ctrl+opt+cmd+k")
        XCTAssertEqual(try HotkeyBinding(parsing: "alt+d"), try HotkeyBinding(parsing: "opt+d"))
    }

    func testSymbolAliases() throws {
        let symbol = try HotkeyBinding(parsing: "⌃⌥D")
        XCTAssertEqual(symbol, try HotkeyBinding(parsing: "ctrl+opt+d"))
        XCTAssertEqual(symbol.displayString, "⌃⌥D")
    }

    func testDuplicateModifiersAreNormalized() throws {
        let binding = try HotkeyBinding(parsing: "ctrl+ctrl+option+opt+d")
        XCTAssertEqual(binding.modifiers, [.control, .option])
        XCTAssertEqual(binding.canonicalString, "ctrl+opt+d")
        XCTAssertEqual(binding, try HotkeyBinding(parsing: "ctrl+opt+d"))
    }

    func testCanonicalModifierOrder() throws {
        XCTAssertEqual(try HotkeyBinding(parsing: "cmd+shift+opt+ctrl+a").canonicalString, "ctrl+opt+shift+cmd+a")
        XCTAssertEqual(try HotkeyBinding(parsing: "cmd+a").canonicalString, "cmd+a")
    }

    // MARK: - 정규화 동등성

    func testNormalizedEquality() throws {
        XCTAssertEqual(try HotkeyBinding(parsing: "opt+ctrl+D"), try HotkeyBinding(parsing: "ctrl+opt+d"))
        XCTAssertEqual(try HotkeyBinding(parsing: "⌘⇧K"), try HotkeyBinding(parsing: "shift+command+k"))
        XCTAssertNotEqual(try HotkeyBinding(parsing: "ctrl+opt+d"), try HotkeyBinding(parsing: "ctrl+opt+f"))
        XCTAssertNotEqual(try HotkeyBinding(parsing: "ctrl+opt+d"), try HotkeyBinding(parsing: "ctrl+d"))
    }

    func testHashableNormalization() throws {
        var set: Set<HotkeyBinding> = []
        set.insert(try HotkeyBinding(parsing: "opt+ctrl+D"))
        set.insert(try HotkeyBinding(parsing: "ctrl+opt+d"))
        XCTAssertEqual(set.count, 1)
    }

    // MARK: - 표시 문자열

    func testDisplayString() throws {
        XCTAssertEqual(try HotkeyBinding(parsing: "ctrl+opt+d").displayString, "⌃⌥D")
        XCTAssertEqual(try HotkeyBinding(parsing: "ctrl+opt+space").displayString, "⌃⌥Space")
        XCTAssertEqual(try HotkeyBinding(parsing: "ctrl+shift+return").displayString, "⌃⇧↩")
        XCTAssertEqual(try HotkeyBinding(parsing: "ctrl+f1").displayString, "⌃F1")
        XCTAssertEqual(try HotkeyBinding(parsing: "cmd+7").displayString, "⌘7")
        XCTAssertEqual(try HotkeyBinding(parsing: "⌥⇧⌘F12").displayString, "⌥⇧⌘F12")
    }

    // MARK: - 오류

    func testEmptyError() {
        assertThrows(try HotkeyBinding(parsing: ""), equals: .empty)
        assertThrows(try HotkeyBinding(parsing: "   "), equals: .empty)
        assertThrows(try HotkeyBinding(parsing: "+"), equals: .empty)
    }

    func testUnsupportedKeyError() {
        assertThrows(try HotkeyBinding(parsing: "ctrl+opt+tab"), equals: .unsupportedKey("tab"))
        assertThrows(try HotkeyBinding(parsing: "ctrl+opt+foo"), equals: .unsupportedKey("foo"))
        assertThrows(try HotkeyBinding(parsing: "ctrl+enter"), equals: .unsupportedKey("enter"))
    }

    func testUnsupportedModifierError() {
        assertThrows(try HotkeyBinding(parsing: "super+d"), equals: .unsupportedModifier("super"))
        assertThrows(try HotkeyBinding(parsing: "fn+ctrl+d"), equals: .unsupportedModifier("fn"))
    }

    func testMissingModifierError() {
        assertThrows(try HotkeyBinding(parsing: "d"), equals: .missingModifier)
        assertThrows(try HotkeyBinding(parsing: "space"), equals: .missingModifier)
        assertThrows(try HotkeyBinding(key: requireKey("a"), modifiers: []), equals: .missingModifier)
    }

    func testMissingKeyError() {
        assertThrows(try HotkeyBinding(parsing: "ctrl+opt"), equals: .missingKey)
        assertThrows(try HotkeyBinding(parsing: "cmd"), equals: .missingKey)
        assertThrows(try HotkeyBinding(parsing: "⌃⌥⇧"), equals: .missingKey)
    }

    func testErrorMessagesAreKorean() {
        XCTAssertEqual(HotkeyBindingError.empty.errorDescription, "단축키가 비어 있습니다.")
        XCTAssertEqual(HotkeyBindingError.missingModifier.errorDescription, "수정자를 하나 이상 포함해야 합니다.")
        XCTAssertEqual(HotkeyBindingError.missingKey.errorDescription, "키가 필요합니다. 수정자만으로는 단축키를 만들 수 없습니다.")
        XCTAssertEqual(HotkeyBindingError.unsupportedKey("tab").errorDescription, "지원하지 않는 키입니다: tab")
        XCTAssertEqual(HotkeyBindingError.unsupportedModifier("super").errorDescription, "지원하지 않는 수정자입니다: super")
    }

    // MARK: - 지원 키 목록 · 키코드 왕복

    func testAllKeysCountAndNames() {
        let names = HotkeyKey.all.map(\.name)
        XCTAssertEqual(HotkeyKey.all.count, 2 + 26 + 10 + 12)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(Array(names.prefix(2)), ["space", "return"])
        for letter in "abcdefghijklmnopqrstuvwxyz" { XCTAssertTrue(names.contains(String(letter))) }
        for digit in "0123456789" { XCTAssertTrue(names.contains(String(digit))) }
        for index in 1...12 { XCTAssertTrue(names.contains("f\(index)")) }
        XCTAssertFalse(names.contains("tab"))
    }

    func testMacVirtualKeyCodeRoundTrip() {
        for key in HotkeyKey.all {
            XCTAssertEqual(HotkeyKey.fromMacVirtualKeyCode(key.macVirtualKeyCode), key, "왕복 실패: \(key.name)")
        }
        let codes = HotkeyKey.all.map(\.macVirtualKeyCode)
        XCTAssertEqual(Set(codes).count, codes.count, "macOS 가상 키코드가 중복됩니다.")
        XCTAssertNil(HotkeyKey.fromMacVirtualKeyCode(0xFFFF))
    }

    func testKnownMacVirtualKeyCodes() {
        XCTAssertEqual(HotkeyKey.named("a")?.macVirtualKeyCode, 0x00)
        XCTAssertEqual(HotkeyKey.named("s")?.macVirtualKeyCode, 0x01)
        XCTAssertEqual(HotkeyKey.named("space")?.macVirtualKeyCode, 0x31)
        XCTAssertEqual(HotkeyKey.named("return")?.macVirtualKeyCode, 0x24)
        XCTAssertEqual(HotkeyKey.named("f12")?.macVirtualKeyCode, 0x6F)
        XCTAssertEqual(HotkeyKey.named("0")?.macVirtualKeyCode, 0x1D)
    }

    func testKeyLookupIsCaseInsensitive() {
        XCTAssertEqual(HotkeyKey.named("D"), HotkeyKey.named("d"))
        XCTAssertNil(HotkeyKey.named("tab"))
    }

    // MARK: - Helpers

    private func requireKey(_ name: String) -> HotkeyKey {
        guard let key = HotkeyKey.named(name) else {
            XCTFail("지원 키를 찾지 못했습니다: \(name)")
            return HotkeyKey.all[0]
        }
        return key
    }

    private func assertThrows<T>(_ expression: @autoclosure () throws -> T,
                                 equals expected: HotkeyBindingError,
                                 file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try expression()
            XCTFail("오류를 기대했습니다: \(expected)", file: file, line: line)
        } catch let error as HotkeyBindingError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("다른 오류가 발생했습니다: \(error)", file: file, line: line)
        }
    }
}
