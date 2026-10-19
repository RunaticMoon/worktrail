// 제출용 주간보고의 AI 출력 형식. SubmissionDraft의 필수 Codable 필드와 일치해야 한다.
// 형태를 고정한 뒤에도 Task·상태·계획·근거의 사실 검증은 SubmissionValidator가 수행한다.
enum SubmissionOutputSchema {
    static let schema: JSONValue = object([
        "schemaVersion": .object(["type": .string("integer"), "enum": .array([.number(1)])]),
        "jobType": .object(["type": .string("string"), "enum": .array([.string("submission_weekly")])]),
        "groups": array(of: object([
            "heading": string,
            "items": array(of: object([
                "itemId": string,
                "category": .object([
                    "type": .string("string"),
                    "enum": .array(SubmissionCategory.allCases.map { .string($0.rawValue) }),
                ]),
                "text": string,
                "taskIds": array(of: string),
                "projectIds": array(of: string),
                "planItemIds": array(of: string),
                "evidenceIds": array(of: string),
            ])),
        ])),
        "reviewNotes": array(of: string),
        "warnings": array(of: string),
    ])

    private static let string: JSONValue = .object(["type": .string("string")])

    private static func array(of item: JSONValue) -> JSONValue {
        .object(["type": .string("array"), "items": item])
    }

    private static func object(_ properties: [String: JSONValue]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(properties.keys.sorted().map { .string($0) }),
            "additionalProperties": .bool(false),
        ])
    }
}
