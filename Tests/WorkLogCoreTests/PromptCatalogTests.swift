import XCTest
@testable import WorkLogCore

final class PromptCatalogTests: XCTestCase {

    func testEveryJobAndPurposeRoundTripsExactlyOnce() {
        for job in AIJobType.allCases {
            XCTAssertFalse(PromptCatalog.purposes(for: job).isEmpty,
                           "purpose가 없는 AI 작업: \(job)")
        }

        let mappedPurposes = AIJobType.allCases.flatMap { PromptCatalog.purposes(for: $0) }
        for purpose in TemplatePurpose.allCases {
            XCTAssertEqual(mappedPurposes.filter { $0 == purpose }.count, 1,
                           "정확히 한 작업에 대응해야 하는 purpose: \(purpose)")
            XCTAssertTrue(PromptCatalog.purposes(for: PromptCatalog.job(for: purpose))
                .contains(purpose), "왕복 매핑 실패: \(purpose)")
        }
    }

    func testBuiltInDefaultsMatchDefaultPromptsExactly() {
        XCTAssertEqual(TemplatePurpose.allCases.count, 7)

        for purpose in TemplatePurpose.allCases {
            XCTAssertEqual(PromptCatalog.builtInDefault(for: purpose),
                           DefaultPrompts.template(for: purpose),
                           "내장 기본 템플릿 원문 불일치: \(purpose)")
        }
    }

    func testTitlesUsageNotesAndProtectedPreamble() {
        XCTAssertEqual(PromptCatalog.title(for: .performanceDaily), "성과 리포트 · 일일")
        XCTAssertEqual(PromptCatalog.title(for: .performancePeriodic), "성과 리포트 · 주·월·분기·연간")
        XCTAssertEqual(PromptCatalog.usageNote(for: .queryPlan), "현재 검색 경로에서 사용되지 않습니다.")

        for job in AIJobType.allCases where job != .queryPlan {
            XCTAssertNil(PromptCatalog.usageNote(for: job))
        }

        XCTAssertEqual(PromptCatalog.protectedPreamble, DefaultPrompts.commonInstructions)
    }
}
