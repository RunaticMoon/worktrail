# WorkLog 개발 지침 (에이전트·개발자 공통)

제품 요구사항 원본: `docs/mac_worklog_ai_handoff/02_PRODUCT_SPEC.md` (확정) → `06_DECISIONS_AND_SOURCES.md` → `03_TECHNICAL_DESIGN.md` → `04_IMPLEMENTATION_PLAN_AND_TESTS.md`.
구현 계획: `docs/plan.md`, 기술 결정: `docs/decisions.md`.

## 구조
- `Sources/WorkLogCore` — 도메인·저장·검색·Secret·백업·보고·AI 어댑터·스케줄러. **Linux/macOS 공통**으로 빌드·테스트되어야 한다. SwiftUI/AppKit/Security 프레임워크를 import 하지 않는다(필요하면 `#if canImport(...)`).
- `Sources/WorkLogApp` — macOS 전용 SwiftUI/AppKit 앱. 모든 코드는 `#if os(macOS)` 안에 둔다.
- `Sources/worklog` — 개발·검증용 CLI.
- `Tests/WorkLogCoreTests` — XCTest. 픽스처: `Tests/WorkLogCoreTests/Fixtures/example_data.json` (`Bundle.module.url(forResource: "Fixtures/example_data", withExtension: "json")`).

## 규칙
- 빌드: `swift build --build-tests`, 테스트: `swift test` 또는 `swift test --filter <TestClass>`. Swift 6.3 툴체인, Swift 5 언어 모드.
- 시간: `Date()` 직접 호출 금지 → `Clock` 주입. 업무일은 `WorkDate`, 기간은 `DateRange` [start, endExclusive), 시간대는 `WorkCalendar`(기본 Asia/Seoul).
- ID: `IDGenerator` 주입. 테스트는 `SequentialIDGenerator`.
- SQL: 항상 `?` 바인딩. 문자열 결합으로 값 넣기 금지. 스키마는 `Storage/WorkSchema.swift`, `Secret/VaultSchema.swift`가 원본이며 바꾸려면 새 Migration 버전을 추가한다(기존 버전 SQL 수정 금지).
- Secret 타입(`SecretRow`, `SecretPayload`, `SecretMetadata`, vault DB)은 AI 입력·일반 검색 인덱스·로그·work.sqlite에 절대 들어가지 않는다. Secret 경로에서 네트워크·AI 호출 없음.
- 제출용 주간보고(`ReportFamily.submission`)와 성과 리포트(`.performance`)는 서로 다른 Report/템플릿/본문이다.
- 상태·날짜·집계·확정은 결정적 로직이 정한다. AI 출력은 검증 후 초안으로만 저장.
- 자기 작업 범위 밖 파일은 수정하지 않는다. 공용 계약(Models.swift 등) 변경이 필요하면 수정하지 말고 보고한다.
- 실제 회사 자격증명·Keychain·Codex 토큰을 읽거나 출력하지 않는다. 테스트 데이터는 가짜 값만.
