import XCTest
@testable import WorkLogCore

final class SecretNormalizerTests: XCTestCase {

    // MARK: - Fixture

    private func loadFixture() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/example_data", withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func string(_ dict: [String: Any], _ key: String) throws -> String {
        try XCTUnwrap(dict[key] as? String)
    }

    private func row(_ dict: [String: Any], order: Int) throws -> SecretRow {
        SecretRow(id: try string(dict, "id"), key: try string(dict, "key"),
                  value: try string(dict, "value"), order: order)
    }

    // MARK: - SEC-T03~T05: trim

    func testSecretTrimCasesFromFixture() throws {
        let fixture = try loadFixture()
        let cases = try XCTUnwrap(fixture["secretTrimCases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 6)

        for item in cases {
            let id = try string(item, "id")
            let input = try XCTUnwrap(item["input"] as? [String: Any])
            let expected = try XCTUnwrap(item["expected"] as? [String: Any])

            let result = SecretNormalizer.apply(
                existing: [],
                changes: SecretChangeSet(upserts: [
                    SecretRowInput(key: try string(input, "key"), value: try string(input, "value"))
                ]),
                ids: SequentialIDGenerator())

            XCTAssertTrue(result.issues.isEmpty, "\(id): unexpected issues \(result.issues)")
            XCTAssertEqual(result.rows.count, 1, id)
            XCTAssertEqual(result.rows[0].key, try string(expected, "key"), "\(id) key")
            XCTAssertEqual(result.rows[0].value, try string(expected, "value"), "\(id) value")
            XCTAssertTrue(result.changed, "\(id) changed")
        }
    }

    func testTrimOnlyStripsLeadingAndTrailing() {
        XCTAssertEqual(SecretNormalizer.trim("  abc  123  "), "abc  123")
        XCTAssertEqual(SecretNormalizer.trim("\n line1\nline  2\t"), "line1\nline  2")
        XCTAssertEqual(SecretNormalizer.trim("한 글  은"), "한 글  은")
        XCTAssertEqual(SecretNormalizer.trim(""), "")
        XCTAssertEqual(SecretNormalizer.trim("   "), "")
    }

    // MARK: - SEC-T02: 값은 항상 문자열 그대로

    func testValuesAreKeptAsStrings() {
        for raw in ["00123", "true", "{x:1}", "\"\"", "  lead"] {
            let result = SecretNormalizer.apply(
                existing: [],
                changes: SecretChangeSet(upserts: [SecretRowInput(key: "K", value: raw)]),
                ids: SequentialIDGenerator())
            XCTAssertEqual(result.rows.count, 1)
            XCTAssertEqual(result.rows[0].value, SecretNormalizer.trim(raw), raw)
        }
    }

    // MARK: - SEC-T06: 자동 key

    func testAutoKeyAvoidsExistingKey1() throws {
        let fixture = try loadFixture()
        let autoCase = try XCTUnwrap(fixture["secretAutoKeyCase"] as? [String: Any])
        let existingKeys = try XCTUnwrap(autoCase["existingKeys"] as? [String])
        let inputs = try XCTUnwrap(autoCase["input"] as? [[String: Any]])
        let expected = try XCTUnwrap(autoCase["expected"] as? [[String: Any]])

        let existingRows = existingKeys.enumerated().map {
            SecretRow(id: "existing-\($0.offset)", key: $0.element, value: "unused", order: $0.offset)
        }
        let upserts = try inputs.map {
            SecretRowInput(key: try string($0, "key"), value: try string($0, "value"))
        }

        let result = SecretNormalizer.apply(
            existing: existingRows,
            changes: SecretChangeSet(upserts: upserts),
            ids: SequentialIDGenerator())

        XCTAssertTrue(result.issues.isEmpty)
        let newRows = Array(result.rows.suffix(inputs.count))
        for (index, row) in newRows.enumerated() {
            XCTAssertEqual(row.key, try string(expected[index], "key"))
            XCTAssertEqual(row.value, try string(expected[index], "value"))
        }
        XCTAssertEqual(newRows.first?.key, "key2")
    }

    func testTwoBlankKeysGetSequentialAutoKeys() {
        let existing = [SecretRow(id: "r1", key: "key1", value: "v", order: 0)]
        let result = SecretNormalizer.apply(
            existing: existing,
            changes: SecretChangeSet(upserts: [
                SecretRowInput(key: "", value: "first"),
                SecretRowInput(key: "   ", value: "second"),
            ]),
            ids: SequentialIDGenerator())

        XCTAssertEqual(result.rows.count, 3)
        XCTAssertEqual(result.rows[0].key, "key1")
        XCTAssertEqual(result.rows[1].key, "key2")
        XCTAssertEqual(result.rows[2].key, "key3")
    }

    // MARK: - SEC-T07: 중복 key

    func testDuplicateKeyKeepsBothValues() {
        let existing = [
            SecretRow(id: "r1", key: "API_KEY", value: "first", order: 0),
            SecretRow(id: "r2", key: "API_KEY", value: "second", order: 1),
        ]
        let result = SecretNormalizer.apply(
            existing: existing,
            changes: SecretChangeSet(),
            ids: SequentialIDGenerator())

        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows.map { $0.value }, ["first", "second"])
        let expected = SecretValidationIssue.duplicateKey(key: "API_KEY", rowIds: ["r1", "r2"])
        XCTAssertTrue(result.issues.contains(expected), "\(result.issues)")
    }

    func testDuplicateKeyIsCaseSensitive() {
        let existing = [
            SecretRow(id: "r1", key: "Key", value: "a", order: 0),
            SecretRow(id: "r2", key: "key", value: "b", order: 1),
        ]
        let result = SecretNormalizer.apply(
            existing: existing, changes: SecretChangeSet(), ids: SequentialIDGenerator())
        XCTAssertTrue(result.issues.isEmpty)
    }

    // MARK: - SEC-T08: 완전히 빈 새 행 무시

    func testBlankNewRowsAreIgnored() {
        let existing = [SecretRow(id: "r1", key: "HOST", value: "h", order: 0)]
        let result = SecretNormalizer.apply(
            existing: existing,
            changes: SecretChangeSet(upserts: [
                SecretRowInput(key: "", value: ""),
                SecretRowInput(key: "   ", value: "\t\n"),
            ]),
            ids: SequentialIDGenerator())

        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0].id, "r1")
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertFalse(result.changed)
    }

    // MARK: - SEC-T09: 빈 값 수정은 허용, 행 삭제와 다름

    func testUpdatingValueToEmptyIsKept() {
        let existing = [SecretRow(id: "r1", key: "API_KEY", value: "secret", order: 0)]
        let result = SecretNormalizer.apply(
            existing: existing,
            changes: SecretChangeSet(upserts: [SecretRowInput(id: "r1", key: "API_KEY", value: "")]),
            ids: SequentialIDGenerator())

        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0].value, "")
        XCTAssertTrue(result.changed)
    }

    // MARK: - SEC-T12 / SEC-T15: 부분 수정, 같은 row ID

    func testSecretPartialUpdateFromFixture() throws {
        let fixture = try loadFixture()
        let partial = try XCTUnwrap(fixture["secretPartialUpdateCase"] as? [String: Any])
        let initialDicts = try XCTUnwrap(partial["initialRows"] as? [[String: Any]])
        let patch = try XCTUnwrap(partial["patch"] as? [String: Any])
        let expectedDicts = try XCTUnwrap(partial["expectedRows"] as? [[String: Any]])

        let initial = try initialDicts.enumerated().map { try row($0.element, order: $0.offset) }
        let changes = SecretChangeSet(upserts: [
            SecretRowInput(id: try string(patch, "id"),
                           key: try string(patch, "key"),
                           value: try string(patch, "value"))
        ])

        let result = SecretNormalizer.apply(existing: initial, changes: changes, ids: SequentialIDGenerator())
        XCTAssertTrue(result.issues.isEmpty)

        let expected = try expectedDicts.enumerated().map { try row($0.element, order: $0.offset) }
        XCTAssertEqual(result.rows, expected)
        XCTAssertTrue(result.changed)

        // row-key 수정했지만 같은 row ID 유지.
        XCTAssertEqual(result.rows[1].id, "row-key")
        // 건드리지 않은 row-host 보존.
        XCTAssertEqual(result.rows[0], initial[0])
    }

    func testRenamingKeyKeepsRowId() {
        let existing = [SecretRow(id: "row-1", key: "OLD", value: "v", order: 0)]
        let result = SecretNormalizer.apply(
            existing: existing,
            changes: SecretChangeSet(upserts: [SecretRowInput(id: "row-1", key: "NEW", value: "v")]),
            ids: SequentialIDGenerator())
        XCTAssertEqual(result.rows[0].id, "row-1")
        XCTAssertEqual(result.rows[0].key, "NEW")
        XCTAssertTrue(result.changed)
    }

    // MARK: - SEC-T14: trim 후 변경 없으면 changed=false

    func testWhitespaceOnlyChangeIsNotChanged() {
        let existing = [SecretRow(id: "r1", key: "API_KEY", value: "abc", order: 0)]
        let result = SecretNormalizer.apply(
            existing: existing,
            changes: SecretChangeSet(upserts: [SecretRowInput(id: "r1", key: "  API_KEY  ", value: "  abc  ")]),
            ids: SequentialIDGenerator())

        XCTAssertEqual(result.rows[0].key, "API_KEY")
        XCTAssertEqual(result.rows[0].value, "abc")
        XCTAssertFalse(result.changed)
    }

    // MARK: - 삭제 / unknown id

    func testDeletionRemovesRowsAndUnknownIdReportsIssue() {
        let existing = [
            SecretRow(id: "r1", key: "A", value: "1", order: 0),
            SecretRow(id: "r2", key: "B", value: "2", order: 1),
        ]
        let result = SecretNormalizer.apply(
            existing: existing,
            changes: SecretChangeSet(deletedRowIds: ["r2", "missing"]),
            ids: SequentialIDGenerator())

        XCTAssertEqual(result.rows.map { $0.id }, ["r1"])
        XCTAssertEqual(result.rows[0].order, 0)
        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.issues.contains(.unknownRowId("missing")))
    }

    func testUnknownUpsertIdReportsIssue() {
        let result = SecretNormalizer.apply(
            existing: [],
            changes: SecretChangeSet(upserts: [SecretRowInput(id: "nope", key: "A", value: "1")]),
            ids: SequentialIDGenerator())

        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertEqual(result.issues, [.unknownRowId("nope")])
        XCTAssertFalse(result.changed)
    }

    func testNewRowAppendedAndRenumbered() {
        let existing = [SecretRow(id: "r1", key: "A", value: "1", order: 5)]
        let result = SecretNormalizer.apply(
            existing: existing,
            changes: SecretChangeSet(upserts: [SecretRowInput(key: "B", value: "2")]),
            ids: SequentialIDGenerator())

        XCTAssertEqual(result.rows.map { $0.key }, ["A", "B"])
        XCTAssertEqual(result.rows.map { $0.order }, [0, 1])
        XCTAssertTrue(result.changed)
    }

    // MARK: - SEC-T10, SEC-T11: 붙여넣기

    func testPasteExamplesFromFixture() throws {
        let fixture = try loadFixture()
        let examples = try XCTUnwrap(fixture["pasteExamples"] as? [[String: Any]])
        XCTAssertEqual(examples.count, 3)

        for example in examples {
            let parsed = SecretPasteParser.parse(try string(example, "input"))
            XCTAssertEqual(parsed.count, 1, "\(example)")
            XCTAssertFalse(parsed[0].ambiguous, "\(example)")

            let result = SecretNormalizer.apply(
                existing: [],
                changes: SecretChangeSet(upserts: parsed.map { $0.input }),
                ids: SequentialIDGenerator())
            XCTAssertEqual(result.rows.count, 1)
            XCTAssertEqual(result.rows[0].key, try string(example, "expectedKey"))
            XCTAssertEqual(result.rows[0].value, try string(example, "expectedValue"))
        }
    }

    func testPasteKeepsTrailingSeparatorsInValue() {
        let rows = SecretPasteParser.parse("A=B=C")
        XCTAssertEqual(rows[0].input.key, "A")
        XCTAssertEqual(rows[0].input.value, "B=C")

        let colon = SecretPasteParser.parse("A : B:C")
        XCTAssertEqual(colon[0].input.key, "A")
        XCTAssertEqual(colon[0].input.value, "B:C")
    }

    func testPasteUrlIsAmbiguousAndLossless() {
        let parsed = SecretPasteParser.parse("https://example.invalid/x")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertTrue(parsed[0].ambiguous)
        XCTAssertEqual(parsed[0].input.key, "")
        XCTAssertEqual(parsed[0].input.value, "https://example.invalid/x")

        let result = SecretNormalizer.apply(
            existing: [],
            changes: SecretChangeSet(upserts: parsed.map { $0.input }),
            ids: SequentialIDGenerator())
        XCTAssertEqual(result.rows[0].key, "key1")
        XCTAssertEqual(result.rows[0].value, "https://example.invalid/x")
    }

    func testPasteSkipsBlankLinesAndHandlesCRLF() {
        let rows = SecretPasteParser.parse("A=1\r\n\r\n   \r\nB : 2")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].input.key, "A")
        XCTAssertEqual(rows[0].input.value, "1")
        XCTAssertEqual(rows[1].input.key, "B")
        XCTAssertEqual(rows[1].input.value, "2")
    }

    func testPasteAmbiguousEmptyKeyKeepsWholeLine() {
        let rows = SecretPasteParser.parse("=B")
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].ambiguous)
        XCTAssertEqual(rows[0].input.key, "")
        XCTAssertEqual(rows[0].input.value, "=B")
    }

    func testPasteOverlongKeyIsAmbiguous() {
        let longKey = String(repeating: "K", count: 65)
        let rows = SecretPasteParser.parse("\(longKey)=v")
        XCTAssertTrue(rows[0].ambiguous)
        XCTAssertEqual(rows[0].input.value, "\(longKey)=v")
    }

    func testPasteNoSeparatorIsNotAmbiguous() {
        let rows = SecretPasteParser.parse("only-fake-value")
        XCTAssertFalse(rows[0].ambiguous)
        XCTAssertEqual(rows[0].input.key, "")
        XCTAssertEqual(rows[0].input.value, "only-fake-value")
    }
}
