import XCTest
@testable import WorkLogCore

final class ChatGPTSkillInstructionsTests: XCTestCase {
    func testExplicitSkillIsAppendedAfterProtectedInstructions() throws {
        try fixture { root, file in
            try Data("짧은 문장으로 작성합니다.".utf8).write(to: file)
            let skill = try XCTUnwrap(SkillBindingResolver.resolve(file.path))
            let result = try ChatGPTSkillInstructions.appending(skill, to: "공통 지침", blockedPathPrefixes: [])
            XCTAssertTrue(result.hasPrefix("공통 지침\n")); XCTAssertTrue(result.contains("짧은 문장"))
        }
    }
    func testNamedSkillMissingPathIsRejectedRatherThanIgnored() {
        XCTAssertThrowsError(try ChatGPTSkillInstructions.appending(SkillRef(name: "legacy"), to: "common", blockedPathPrefixes: []))
    }
    func testChangedProtectedOversizeAndSensitiveSkillsAreRejected() throws {
        try fixture { root, file in
            try Data("original fake instructions".utf8).write(to: file)
            let skill = try XCTUnwrap(SkillBindingResolver.resolve(file.path))
            XCTAssertThrowsError(try ChatGPTSkillInstructions.appending(skill, to: "common", blockedPathPrefixes: [root.path]))
            try Data("modified fake instructions".utf8).write(to: file)
            XCTAssertThrowsError(try ChatGPTSkillInstructions.appending(skill, to: "common", blockedPathPrefixes: []))
            for text in [String(repeating: "x", count: 65_537), "fake access_token marker"] {
                try Data(text.utf8).write(to: file)
                let current = try XCTUnwrap(SkillBindingResolver.resolve(file.path))
                XCTAssertThrowsError(try ChatGPTSkillInstructions.appending(current, to: "common", blockedPathPrefixes: []))
            }
        }
    }
    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("worklog-skill-" + UUIDGenerator().make())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, root.appendingPathComponent("SKILL.md"))
    }
}
