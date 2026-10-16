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

## macOS UI/UX
- 최소 지원 버전은 **macOS 26.0**. Swift 6.3 도구체인과 macOS 26 이상 SDK를 사용한다. Package.swift, 앱 번들, Sparkle 피드의 최소 버전을 일치시킨다.
- Apple [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines)와 [Liquid Glass 적용 지침](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)을 따른다. 탐색은 `NavigationSplitView`·사이드바 `List`·`toolbar`, 입력은 `Picker`·`DatePicker`·`Toggle`·`Form`, 펼침은 `DisclosureGroup`, 그룹은 기본 `GroupBox`를 우선 사용한다.
- Liquid Glass는 탐색·조작 계층에만 사용한다. 시스템 사이드바·툴바·시트 위에 불투명 배경이나 별도 glass를 겹치지 않는다. 메모·보고서·목록·Secret 표 등 본문에는 가독성 높은 시스템 의미 색/표준 소재를 사용한다.
- 일반 버튼은 시스템 스타일을 사용하고 직접 그린 공통 버튼 스타일로 덮어쓰지 않는다. 사용자 지정 floating control에만 필요한 범위로 `.glass`/`.glassProminent`/`glassEffect`를 적용한다. 색·투명도·모션·키보드 포커스·VoiceOver는 시스템 접근성 설정을 존중한다.
- 날짜 선택기는 `WorkCalendar`의 calendar/timeZone을 명시한다. UI 변경으로 IME, 단축키, 초안 보존, Secret 격리, 보고서 구분을 바꾸지 않는다.
- Linux 빌드는 SwiftUI 타입 검사나 화면 검증을 대신하지 않는다. UI 변경은 macOS SDK 빌드와 가짜 fixture 화면·키보드 검증 결과를 구분해 기록한다.
