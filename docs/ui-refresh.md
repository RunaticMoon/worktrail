# 플로팅 패널과 워크스페이스 UI

## Liquid Glass UI/UX 감사·개선 (LGUX-90DF · A, 2026-10-16 KST)

Method: design review only (detector not applicable, native platform). 기준 커밋 `6ea225b`, 브랜치 `feat/lgux-90df-liquid-glass-polish`. Linux에서 SwiftUI/AppKit 소스를 감사하고 안전한 범위의 polish를 적용했다. 현재 화면을 실행하거나 캡처하지 못했으며, 과거 Maclab 화면 링크의 이미지도 이 worktree에는 없다. 아래 배치·대비 위험은 코드 근거이며 실제 잘림이나 대비 비율을 측정한 결과가 아니다. 렌더링·성능·VoiceOver를 포함한 종합 점수는 산정하지 않았다.

### 감사 결과와 조치

높음 수준의 기능 차단 결함은 이번 정적 감사에서 확인하지 못했다. 중간 6건, 낮음 2건 중 7건을 수정하고 1건은 제안으로 남겼다. 파일과 줄은 이번 수정 후 기준이며 `Sources/WorkLogApp/` 아래다.

| 항목 | 화면 / 파일:줄 | 심각도 | 근거 | 조치 |
|---|---|---|---|---|
| 앱 사이드바와 설정 내부 목차가 동시에 폭을 차지한다. 내부 목차는 최소 188pt여서 좁은 본문의 양식·한국어 설명을 압박한다. | 설정 · `SettingsScreen.swift:45` | 중간 | Impeccable native audit/Adaptivity, polish/Layout; HIG macOS 창 적응 | **수정함.** 실제 설정 콘텐츠 폭 680pt 미만에서는 검색 + 표준 menu `Picker`를 위에 두고 `Form`에 전체 폭을 배분한다. 넓은 폭의 목차 목록, 선택·검색·저장 바인딩은 유지한다. |
| 버전/동작의 세로 대체 배치에서도 동작 5개가 한 `HStack`에 남아 있다. | 주간보고·성과자료 · `ReportsScreen.swift:324` | 중간 | Impeccable polish/flow·layout; HIG Liquid Glass/컨트롤 밀집 방지 | **수정함.** 복사·편집과 저장·되돌리기·확정을 두 그룹으로 구성하고 `ViewThatFits`의 두 줄 대안을 제공한다. 기존 실행·단축키·비활성 조건은 유지한다. |
| 업무 행의 기본 버튼 동작은 선택인데 안내는 상세 열기를 말한다. 일반 Return/더블클릭·하단 열기 버튼은 있지만 행 자체의 VoiceOver 상세 액션이 없다. | 프로젝트 업무 · `ProjectsScreen.swift:238` | 중간 | Impeccable native audit/Accessibility; HIG 접근성의 대체 조작 | **수정함.** 기존 업무 목록의 패턴을 재사용해 이름 있는 ‘업무 상세 열기’ 접근성 액션을 추가했다. 해당 행을 선택한 뒤 상세를 열어 복귀 대상도 맞춘다. |
| 검색 패널의 사용자 지정 외곽선은 대비 증가에서도 separator 1pt로 고정돼 빠른 입력 패널과 다르다. | 검색 패널 · `SearchPanel.swift:160` | 중간 | Impeccable polish/system drift; HIG Accessibility·Materials | **수정함.** `WorkLogTheme.outlineColor/outlineWidth`를 재사용해 대비 증가에서 label 색 2pt를 적용한다. glass 헤더와 표준 본문 소재는 유지한다. |
| 시각적으로는 ‘저장 중…’인데 명시적 접근성 이름은 계속 ‘저장하고 이전 앱으로 돌아가기’다. | 빠른 입력 · `CapturePanel.swift:790` | 중간 | Impeccable native audit/상태 의미; HIG Accessibility | **수정함.** 두 기존 저장 중 상태를 같은 조건으로 읽어 버튼 이름도 ‘저장 중’으로 맞춘다. 자동 음성 알림을 추가한 것은 아니며 실제 발화는 미검증이다. |
| 업무 상태 문구 전체가 녹색·주황색 등 상태 색을 사용해 공통 배지의 읽기 규칙과 다르다. | 오늘 → 업무 상태 · `DayScreen.swift:219` | 중간 | Impeccable native audit/Theming; HIG Accessibility·Color; `ux-components.md` 의미 색 원칙 | **수정함.** 문구는 시스템 label 색, 기호만 상태 색을 사용한다. 대비 증가에서는 기호도 label 색이며 문구와 기호의 형태로 상태를 구분한다. 새 배지 배경은 추가하지 않았다. |
| 장식용 Esc 키캡이 접근성 트리에 별도 텍스트로 남는다. | 검색 패널 헤더 · `SearchPanel.swift:132` | 낮음 | Impeccable polish/중복 정보; Taste의 장식 배제 원칙 | **수정함.** 키캡은 접근성에서 숨기고 닫기 버튼의 이름과 Esc 도움말은 유지한다. |
| 결과 수·필터·초기화·미리보기·AI 질문이 한 행에 모이고 별도 좁은 폭 대안이 없다. | 메인 검색·검색 패널 · `SearchScreen.swift:579` | 낮음 | Impeccable polish/Layout; Taste의 의도적인 정보 위계 | **제안만.** 필터·미리보기·AI가 함께 보이는 경우를 실제 Mac에서 먼저 재현하고 필요 시 결과/필터와 보조 동작을 두 줄로 나눈다. 가짜 fixture는 AI를 비활성화하므로 이 조합의 표시 검증은 별도 대역이 필요하다. |

유지한 장점: `AppRootView`는 표준 `NavigationSplitView`·사이드바 `List`·`toolbar`를 사용한다. `Components.swift`의 `StateView`·`RecoveryNotice`는 복구 동작과 보존 설명을 제공하며, `AppTheme.swift`는 의미 색·대비 경계를 이미 정의한다. 오늘·업무·프로젝트는 제목 우선의 행과 명시적 빈 상태를 사용하고, 보고서 두 목적은 별도 진입점·모델을 유지한다. Secret/휴지통은 잠금·편집 소유권·가림 상태와 파괴 동작 확인을 코드에서 확인했다. 이 경로들과 공용 컴포넌트의 API는 수정하지 않았다.

glass 사용처는 두 floating 패널의 조작 헤더뿐이다. 시스템 사이드바·툴바·시트의 배경을 덮거나 본문에 glass를 추가한 코드는 발견하지 못했다. 본문의 표준 소재, 시스템 버튼, 시스템 글꼴과 4/8/12/16pt 간격을 유지한다. 이 판단은 [Apple Materials HIG](https://developer.apple.com/design/human-interface-guidelines/materials), [Liquid Glass 적용](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass), [Accessibility HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility), [macOS 디자인](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)을 기준으로 한다.

### 스킬·문서 적용 범위와 제약

- **Impeccable:** `SKILL.md`를 먼저 읽고 worktree에서 `sh /home/ubuntu/paseo/personas/uiux/skills/impeccable/scripts/impeccable context --target Sources/WorkLogApp/AppRootView.swift`를 1회 실행했다. exit 127: engine 0.1.15 미설치이고 `/home/ubuntu/.impeccable/bin/0.1.15` 캐시 생성 권한이 없어 context는 로드되지 않았다. 안내된 수동 대안으로 기존 `AGENTS.md`, UI 문서와 실제 구현을 읽었다. 이 저장소에는 `PRODUCT.md`/`DESIGN.md`가 없다. `audit.native.md`, `critique.md`, `polish.md`, `operate.md` 및 UI 편집 직전 `craft-floor.md`를 읽고 Operate 모드의 일관성·상태·위계·절제 지침을 적용했다. 설치본에는 macOS 전용 native-platform 문서가 없고 `ios.md`만 있어, 공통 의미 색·시스템 컨트롤·접근성 원칙만 참고하고 macOS 규칙은 프로젝트와 Apple HIG를 우선했다. iOS 탭바·44pt 터치 크기·시뮬레이터 절차는 적용하지 않았다. native 대상에 웹 detector·overlay·브라우저 평점은 적용하지 않았고 하위 에이전트도 생성하지 않았다.
- **Taste:** `SKILL.md`를 읽고 결정 없는 기본값 제거, 장식 배제, 위계·여백·타이포의 의도적인 선택만 감사에 적용했다. 이 앱은 마케팅 웹페이지가 아니므로 방향 추첨, `draw.mjs`, `assets.mjs`, `lint.mjs`, `inspect.mjs`, 이미지/모션 할당량, 웹 글꼴·색상 팔레트·‘No glass’ 규칙은 적용하지 않았다. 네이티브 시스템 글꼴·구분선·키캡·Liquid Glass 사용 규칙을 우선한다.
- **보조:** frontend-design의 기존 시각 언어 보존, ui-ux-pro-max의 SwiftUI 레이블·의미·동작 줄이기 검색 결과, web-accessibility/web-design-guidelines의 이름·포커스·상태·긴 콘텐츠 원칙을 참고했다. HTML/ARIA·DOM·CSS·axe/Playwright 검사를 SwiftUI 검증으로 대체하지 않았다.
- **Context7:** `/websites/developer_apple_swiftui` ID를 확인한 뒤 `ViewThatFits`, 접근성 요소/이름, `colorSchemeContrast` 문서를 실제 조회했다. 설치 기준은 Swift 6.3.3 / macOS 26.0이며 SwiftUI는 SDK 프레임워크다. 조회는 최신 비고정 문서이므로 macOS 27 전용 항목은 제외하고 기존 앱에서 쓰는 macOS 26 이하 API만 재사용했다. Apple 웹 문서는 Markdown 본문 열기가 도구의 content-type 제한으로 실패해 공식 검색 결과와 Context7 조회를 보완 근거로 사용했다.

### 변경 범위와 검증

앱 변경은 `SettingsScreen.swift`(좁은 목차), `ReportsScreen.swift`(동작 그룹), `ProjectsScreen.swift`(접근성 액션), `SearchPanel.swift`(대비/키캡), `CapturePanel.swift`(저장 상태 이름), `DayScreen.swift`(상태 문구 색) 6개 파일이다. 이 절을 `docs/ui-refresh.md`에 추가했다. Core·스키마·Package.swift·배포·버전 파일은 변경하지 않았다. IME 처리·일반 단축키·저장/초안·Secret 경로·날짜 변환·보고서 목적 구분의 로직도 변경하지 않았다.

| 실행 명령 | 실제 결과 | 범위 |
|---|---|---|
| `swift build --build-tests` | exit **0**, Build complete (223.84초) | Linux aarch64 / Swift 6.3.3, Core·CLI와 테스트 빌드. SwiftUI 타입 검사를 뜻하지 않는다. |
| `swift test` | exit **0**, **807개 XCTest·실패 0**, 50.387초 | 전체 기존 회귀 테스트. 별도 Swift Testing 러너의 0개는 XCTest 807개와 구분한다. |
| 아래 macOS 26 대상 구문 파싱 루프 | exit **0**, 앱 Swift 파일 **36개**, FAIL 출력 없음 | 최종 UI 소스의 구문만 검사. macOS SDK 타입 검사·링크·실행은 미검증이다. |
| `git diff --check` | exit **0** | 공백 오류 없음. |

```bash
for f in Sources/WorkLogApp/*.swift; do swiftc -frontend -parse -target arm64-apple-macos26 "$f" || echo FAIL "$f"; done
```

첫 `swift build --build-tests`는 `github.com` DNS 오류로 의존성을 받지 못해 exit 1이었다. 기존 로컬 캐시의 깨끗한 체크아웃이 `Package.resolved`의 swift-crypto 4.5.2 / swift-asn1 1.7.3 리비전과 일치함을 확인하고, 이 worktree의 무시되는 `.build`에만 복사한 뒤 같은 빌드가 통과했다. 원본 캐시와 의존성 선언·잠금 파일은 수정하지 않았다. 최종 빌드/테스트 로그는 `/tmp/lgux-90df-build.log`, `/tmp/lgux-90df-test.log`다.

Questions skipped: 사용자 요청에서 감사 후 안전한 수정·검증·커밋 범위가 이미 확정되어 추가 디자인 질문은 생략했다. critique 저장소·브라우저 overlay·임시 서버는 생성하지 않았다.

### 독립 검토 후속 수정 (LGUX-90DF · A-1, 2026-10-16 KST)

기준 커밋 `cbbad91`에 대한 검토 지적 3건만 수정했다. 새 감사나 추가 개선은 수행하지 않았다. 변경 범위는 `Sources/WorkLogApp/SettingsScreen.swift`, `Sources/WorkLogApp/ReportsScreen.swift`와 이 절이다.

1. `SettingsScreen.swift:45`: `GeometryReader`와 콘텐츠 폭 680pt 기준을 유지하고, `AnyLayout`으로 `VStackLayout`/`HStackLayout`만 전환한다. `navigationColumn(isCompact:)` 안에서만 목차 내용을 분기하여 `ScrollViewReader` + `Form`인 `detail`은 항상 같은 자식 위치에 둔다. 폭 전환으로 인한 상세 편집 상태 재생성 위험을 제거하는 구조다. footer는 기존 바깥 `VStack`의 `Divider` 바로 아래에 유지하며 footer 내부 배치·padding과 높이 관련 코드는 변경하지 않았다.
2. `SettingsScreen.swift:127`: compact menu `Picker`에 `.accessibilityLabel("설정 목차")`와 `.accessibilityHint(destination.subtitle)`를 추가해 목차의 의미와 현재 항목 설명을 제공한다.
3. `ReportsScreen.swift:326`: 넓은 동작 행의 `HStack` 간격을 기존 **12pt**로 복원했다. 좁은 두 줄 배치는 유지한다.

기존 앱의 `AnyLayout` 사용례는 검색 결과 없었다. Context7에서 `/websites/developer_apple_swiftui`를 확인한 뒤 Apple의 `AnyLayout`·`VStackLayout`·`HStackLayout` 문서를 실제 조회했다. 자식 상태를 유지하는 축 전환 예제와 macOS 13+ API를 사용하므로 프로젝트 최소 버전 macOS 26 범위에 해당한다. 설치 도구체인은 Swift 6.3.3 / Linux이며 이 조회가 macOS SDK 타입 검사를 대신하지는 않는다. Impeccable context는 engine 0.1.15 미설치와 캐시 디렉터리 쓰기 제한으로 exit 127이었고, 기존 프로젝트 문서를 직접 확인해 진행했다.

Mac 실기 재현 필요: macOS 26 이상 SDK 빌드 후 가짜 fixture로 설정의 텍스트 입력 중 창 크기 조절 및 사이드바 접기(⌃⌘S)로 콘텐츠 폭 680pt 경계를 왕복한다. TextField 포커스·커서·한글 IME 조합·미저장 값·Form 스크롤 위치, footer의 하단 위치·높이·잘림을 확인한다. VoiceOver로 좁은 Picker의 이름·선택값·현재 항목 설명을 확인하고, 보고서의 넓은 12pt 행과 좁은 두 줄 배치를 확인한다. 이번 Linux 실행에서는 이러한 화면·키보드·VoiceOver 동작을 검증하지 않았다.

후속 수정의 직접 실행 검증:

| 실행 명령 | 실제 결과 |
|---|---|
| `swift build --build-tests` | exit **0**, Build complete (4.72초). Linux 빌드이며 SwiftUI 타입 검사는 아니다. |
| `swift test` | exit **0**, **807개 XCTest·실패 0**, 55.742초. 별도 Swift Testing 러너의 0개와 구분한다. |
| 위 macOS 26 대상 구문 파싱 루프 | exit **0**, 앱 Swift 파일 **36개**, FAIL 출력 없음. SDK 타입 검사·링크·실행은 미검증이다. |
| `git diff --check` | exit **0**, 공백 오류 없음. |

빌드/테스트 로그: `/tmp/lgux-90df-a1-build.log`, `/tmp/lgux-90df-a1-test.log`.

- A-2 (2026-10-16 KST): 설정 목차와 Form 사이 구분선을 compact에서는 `VStack(spacing: 0)`(가로선), regular에서는 `HStack(spacing: 0)`(세로선)으로 감싸 `AnyLayout`의 축 위임 여부와 무관하게 방향을 확정하며, 목차와 `detail`의 자식 위치·구조는 유지한다.

### Impeccable 엔진 재감사 (LGUX-90DF · F, 2026-10-16 감사 후속)

실행일 **2026-10-17 KST**. 기준 `bff0965`, 브랜치 `feat/lgux-90df-liquid-glass-polish`. 기존 A·A-1·A-2 감사 표와 대조한 **신규 항목만** 아래에 기록한다. 이번에도 Linux 소스 감사이며 macOS 화면·VoiceOver·실측 대비·렌더링 성능을 확인한 것은 아니다. native 방식의 Assessment A를 이 세션에서 수행했으며 웹 Assessment B/overlay와 하위 에이전트는 사용하지 않았다. 화면 증거가 없어 휴리스틱/건강 종합 점수는 산정하지 않았다.

#### 엔진 실행과 지침 적용

모든 명령은 이 worktree를 cwd로 실행했다. 설치 파일·스킬 폴더는 수정하지 않았다.

| 실제 명령 | exit / 실제 핵심 출력 | 해석·적용 |
|---|---|---|
| `/home/ubuntu/paseo/personas/uiux/skills/impeccable/scripts/impeccable context --target Sources/WorkLogApp/ContentView.swift` | **126**, `Permission denied` | 최초 직접 호출은 런처 실행 비트 때문에 실행되지 않았다. context 로드 실패를 알리고 `sh` 호출로 전환했다. 이 최초 대상명은 존재하지 않는 파일이므로 실제 문맥 로드에는 아래의 실존 대상을 사용했다. |
| `sh /home/ubuntu/paseo/personas/uiux/skills/impeccable/scripts/impeccable context --target Sources/WorkLogApp/AppRootView.swift` | **0**. `NO_PRODUCT_MD`, `PRODUCT_INIT_REQUIRED`, `MANUAL_DETECTOR_REQUIRED`, `AUTONOMY_DIRECTIVE_CHECK`, `SUBAGENT_AUTHORIZATION`. `targetExists: true`, `hasVisualImplementation: false`, `platform: null` | 엔진은 실제 실행됐지만 SwiftUI/macOS를 자동 인식하거나 native-platform 지침을 로드하지 않았다. scoped fix는 기존 코드 문맥으로 진행하라는 지시를 적용했다. |
| `sh /home/ubuntu/paseo/personas/uiux/skills/impeccable/scripts/impeccable engine-probe` | **0**, `impeccable-engine 0.1.15` | 등록 확인과 달리 실제 엔진 실행 성공이다. |
| `sh /home/ubuntu/paseo/personas/uiux/skills/impeccable/scripts/impeccable detect --json Sources/WorkLogApp/AppTheme.swift Sources/WorkLogApp/CapturePanel.swift Sources/WorkLogApp/SearchScreen.swift Sources/WorkLogApp/SettingsScreen.swift Sources/WorkLogApp/ProjectCreationSheet.swift Sources/WorkLogApp/ReportsScreen.swift` | **0**, 출력 전체 `[]` | 변경된 Swift 파일에 실제 시도했다. 미지원 경고·스캔 파일 수는 출력되지 않았다. `audit.native.md`·`critique.md`는 detector가 웹 마크업 전용이며 native에는 적용되지 않는다고 명시하므로, 빈 배열은 SwiftUI 검증 통과 근거가 아니다. 추가 스캔은 하지 않았다. |

`PRODUCT.md`·`DESIGN.md`는 사용자 범위 지시에 따라 생성하지 않았다. `AGENTS.md`, 기존 `docs/ui-refresh.md`·`ux-components.md`·`ux-flows.md` 및 실제 구현을 제품 맥락과 시각 규칙으로 대체했다. `AUTONOMY_DIRECTIVE_CHECK`에는 이 세션의 비동기 구조화 질문 도구로 우선 화면을 한 번 물었다(도구 accepted). 응답에 의존하지 않는 전체 감사는 이미 명시된 브리프대로 진행했다. 질문 도구가 없었다고 보고하지 않는다.

읽고 적용한 지침은 `audit.native.md`(접근성·테마·플랫폼·적응성), `critique.md`의 native Assessment A(흐름·일관성·인지 부하), `polish.md`(기존 동작 보존과 가장 좁은 수정), `operate.md`이며, 편집 직전에 `reference/craft-floor.md`를 읽었다. 설치본에는 macOS 전용 문서가 없고 `ios.md`만 있어 공통 시스템 의미 색·컨트롤·접근성 원칙만 참고했다. macOS 구조·버튼·소재는 프로젝트 지침과 [Apple 접근성 HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility), [Focus and selection](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection/), [Liquid Glass 적용](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)을 우선했다. iOS 터치 크기·탭바·시뮬레이터 규칙은 적용하지 않았다.

frontend-design은 기존 시각 언어 보존, ui-ux-pro-max는 `focus visible contrast --domain ux`의 모든 플랫폼 포커스 가시성 지침을 적용했다. 웹 전용 WCAG AAA 면적/비율은 네이티브 AA 요구로 간주하지 않았다. `contrast focus indicator --stack swiftui`의 @FocusState·로딩 검색 결과도 확인했고 기존 AppKit 키 루프는 변경하지 않았다. web-accessibility/web-design-guidelines는 읽었으나 웹 전용 검사 절차는 실행하지 않았다. Taste는 1차와 동일하게 장식 배제·일관된 위계·의도적인 타이포/여백 원칙만 사용했다. 웹 draw/assets/lint/inspect·팔레트·No glass·이미지/모션 할당량은 적용하지 않았다.

Context7에서 `/websites/developer_apple_swiftui` ID를 확인한 뒤 `colorSchemeContrast`와 사용자 지정 경계 관련 문서를 실제 조회했다. SDK 의존 SwiftUI이며 저장소 최소 macOS 26.0 / 설치 Swift 6.3.3과 대조했다. 최신 문서에 섞인 macOS 27 `accessibilityShowBorders`는 사용하지 않고, 기존 `colorSchemeContrast` 및 AppKit `keyboardFocusIndicatorColor`만 재사용했다.

#### 신규 감사 표

위치는 수정 후 기준이며 파일은 `Sources/WorkLogApp/` 아래다. P2는 native playbook의 Minor(우회 가능), P3는 Polish다. 대비 문제는 실측 실패 판정이 아니라 구현의 설정 미반영·공통 규칙 이탈이다.

| 항목 | 파일:줄 | 심각도 | 근거·사용자 영향 | 조치 |
|---|---|---|---|---|
| F1. 빠른 입력의 사용자 지정 컨트롤 포커스가 시스템 효과를 끈 뒤 강조색 1.5pt에 고정되고, 본문 포커스도 대비 증가 시 label 색으로 전환되지 않는다. | `CapturePanel.swift:72`, `CapturePanel.swift:1155`, `AppTheme.swift:32` | P2 | native Accessibility/Theming, HIG Focus; 사용자 강조색에 따라 포커스 구별이 약해질 위험 | **수정.** 공통 `focusColor(for:)`는 대비 설정과 무관하게 시스템 `keyboardFocusIndicatorColor`를 사용한다. 컨트롤·본문 포커스 링은 대비 높이기에서 3pt, 비포커스 outline은 2pt다. 본문 장식 경계는 hit testing에서 제외했다. 포커스 상태·등록·키 처리·순서는 그대로다. |
| F2. 검색어 필드가 패널 외곽선과 달리 대비 증가를 읽지 않고 포커스 강조색도 60%·1pt에 고정된다. | `SearchScreen.swift:576` | P2 | native Accessibility/Theming; 입력 위치 식별 규칙이 공통 테마와 다름 | **수정.** 공통 outline/focus 색을 적용한다. 포커스는 대비 설정과 무관하게 시스템 `keyboardFocusIndicatorColor`이며, 대비 높이기에서는 포커스 3pt·비포커스 outline 2pt로 구별한다. 장식 경계를 hit testing에서 제외했다. 메인 검색과 패널이 함께 적용된다. |
| F3. 보고서 본문 편집 경계가 separator 색 1pt로 고정된다. | `ReportsScreen.swift:284` | P2 | native Theming, polish/system drift; 다른 편집 영역과 달리 대비 증가 미반영 | **수정.** 기존 outlineColor/outlineWidth를 재사용했다. 주간보고·성과자료 각 모델·편집·확정 로직과 시스템 포커스 효과는 그대로다. |
| F4. 설정 검증·단축키 등록 실패, 프로젝트 생성 오류, 평가 기간 오류 문구 전체가 주황/빨강이다. | `SettingsScreen.swift:186`, `SettingsScreen.swift:318`, `ProjectCreationSheet.swift:30`, `ReportsScreen.swift:527` | P2 | native Theming; `ux-components.md`의 상태 문구는 시스템 label 색으로 읽는 원칙 이탈 | **수정.** 오류/복구 문구와 경고 기호·설정의 옅은 경고 배경은 유지하고 본문 전경을 label 색으로 통일했다. 새 레이블이나 컨트롤은 만들지 않았다. |
| F5. Secret 상세 편집이 콘텐츠 폭 700pt에서 VStack/HSplitView 분기로 재생성될 수 있다. | `SecretsScreen.swift:55`, `SecretsScreen.swift:65`, `SecretEditorView.swift:21/22` | P2 | native Adaptivity; 편집기의 로컬 FocusState·붙여넣기 펼침 상태가 폭 전환에서 유지되는지 불명확. 모델 초안 손실이 확인된 것은 아니다. | **제안.** Mac에서 한글 조합·셀 편집·붙여넣기 미리보기 중 경계를 왕복해 먼저 확인한다. 필요 시 편집 뷰 정체성을 유지하는 구조로 별도 수정한다. Secret 편집·목록 전환 구조 변경은 이번 범위의 안전한 polish에서 제외했다. |
| F6. 그래프 Canvas의 연결선은 대비 증가와 무관하게 비강조 membership 25%·선택 이외 35% 농도를 사용한다. | `GraphScreen.swift:661` | P2 | native Accessibility/Theming; 옅은 선을 따라가기 어려울 위험. 연결 목록·선 종류/화살표 대안은 있음 | **제안.** 라이트/다크 × 대비 증가에서 실측 후 Canvas 농도/선 굵기를 함께 보정한다. 실제 렌더링 근거 없이 그래프의 시각적 중요도를 바꾸지 않았다. |
| F7. Secret 검색 key 행 경계가 선택 강조색/비선택 separator로 고정되어 대비 증가 규칙을 사용하지 않는다. | `SearchSecretScope.swift:61` | P3 | native Theming; 선택/비선택 경계의 읽기 차이를 Mac에서 확인할 필요 | **제안.** 가짜 Secret으로 시스템 포커스·선택 채움·경계의 구별을 먼저 확인한 뒤 별도 보정한다. 값·복사·인증·AX 계약은 수정하지 않았다. |

검토 범위는 메인 창의 오늘·업무·프로젝트·주간보고·성과자료·Secret·검색·그래프·휴지통·백업·설정과 연결된 메모/업무 상세·계획, CapturePanel·SearchPanel, Components/AppTheme다. 기존 검색 도구 행의 폭 문제(A 제안)는 중복이라 신규 표에서 제외했다. 시스템 NavigationSplitView/List/toolbar·Form/DisclosureGroup·시스템 버튼, 공통 상태/복구 컴포넌트, 의미 색·Reduce Motion 처리는 유지할 장점이다. Source의 glass는 두 floating 조작 헤더에만 있으며 본문 glass 추가·시스템 사이드바/시트 배경 중첩은 하지 않았다. 이번에는 폭 분기·AnyLayout·Divider·입력 뷰 구조를 바꾸지 않았다.

F-1 후속: 프로젝트 생성·평가 기간 오류에 경고 아이콘을 추가하고, 설정의 경고도 텍스트는 label 색·아이콘은 의미 색(대비 증가 시 label 색)으로 분리했다. 기존 문구는 유지한다.
입력 포커스는 항상 시스템 keyboardFocusIndicatorColor를 쓰며 대비 증가에서는 빠른 입력 컨트롤·본문·검색어 링을 3pt로 표시해 비포커스 2pt 경계와 구별한다. 위 F1·F2·F4의 조치는 이 후속 수정으로 보완된다.

#### 변경·검증·Mac 인계

앱 변경 6개: `AppTheme.swift`, `CapturePanel.swift`, `SearchScreen.swift`, `SettingsScreen.swift`, `ProjectCreationSheet.swift`, `ReportsScreen.swift`. 공통 테마의 내부 색 helper 1개와 색/경계 표현만 변경했다. Core·Package·CI·.maclab·scripts·스킬 폴더는 수정하지 않았다. 접근성 레이블/식별자/힌트, keyboardShortcut/captureFocus 선언과 macOS guard는 HEAD 대비 소스 비교로 동일함을 확인했다. 이는 실제 AX 트리·한글 IME·키 조작 검증을 대신하지 않는다.

| 직접 실행 | 실제 결과 |
|---|---|
| `swift build --build-tests` | exit **0**, Build complete **4.98초**. SwiftPM manifest 캐시 열기/저장 경고는 있었지만 빌드는 완료됐다. Linux 빌드로 SwiftUI 타입 검사를 뜻하지 않는다. |
| `swift test` | exit **0**, **807개 XCTest / 실패 0**, **50.806초**. 별도 Swift Testing 러너의 0개와 구분한다. |
| `for f in Sources/WorkLogApp/*.swift; do swiftc -frontend -parse -target arm64-apple-macos26 "$f" || echo FAIL "$f"; done` | exit **0**, **36개** 파일, 출력 없음(FAIL 없음). macOS SDK 타입 검사·링크·실행은 미검증. |
| `git diff --check` | 문서를 포함한 최종 변경에서 exit **0**, 공백 오류 없음. |

로그: `/tmp/lgux-90df-f-build.log`, `/tmp/lgux-90df-f-test.log`. 엔진의 실제 출력은 위 표에 기록했다. 웹 자동화·가짜 스크린샷으로 네이티브 화면 확인을 대신하지 않았다.

Maclab 인계: 최종 커밋으로 macOS 26 이상 SDK 빌드 후 기존 `.maclab/tests/ui-flows.json`, `keyboard-ux.json`, `ui-edge-cases.json`, `ui-review.json`을 가짜 fixture로 실행한다. 추가 수동 확인은 (1) 메인 840×560·980pt·1280pt, 두 패널 최소 크기에서 기존 배치/스크롤·한글 IME·초안·단축키, (2) 밝은/어두운 강조색과 라이트/다크 × 대비 증가에서 빠른 입력 Tab 포커스·본문 캐럿·검색어 클릭/드래그·2pt 경계·보고서 편집, (3) 설정 오류/등록 실패·중복 프로젝트·잘못된 평가 기간 오류의 읽기와 VoiceOver, (4) 투명도 줄이기/동작 줄이기와 기존 glass 조작 영역, (5) F5–F7의 Secret 폭 경계·그래프 연결선·가짜 key 행 선택이다. 실계정·실제 Keychain·토큰을 사용하지 않는다.

Questions skipped: 우선 화면에 관한 비동기 질문은 실제 전송했으며, 추가 인터뷰·스킬 마무리 질문은 전체 감사·안전한 수정·검증·커밋 범위가 이미 확정된 사용자 브리프로 대체했다.

### Maclab 결함 분석·문서 정정 (LGUX-90DF · L, 2026-10-17 KST)

인계받은 Maclab 실기 결과는 `5a64fa4` 기준이다. 이 작업은 `cd6f2b3`에서 시작해 main `6ea225b..cd6f2b3`의 코드·스크립트·문서를 대조했다. 아래 실기 결과는 사용자 인계 내용이며 이번 Linux 세션에서 Maclab을 재실행한 결과가 아니다.

| 실기 항목 | 결과 | 범위·판정 | Maclab run (기준 `5a64fa4`) |
|---|---|---|---|
| 설정 → 검토 알림의 `HH:mm` 표시 | **실패** | 넓은 창·840pt 모두 `HH:m` / `m`으로 분리. 아래 코드 수정 후 Mac 재확인은 미실행. | 인계 화면 확인 (개별 run 귀속 미확인) |
| 빈 프로젝트 사이드바 → 콘텐츠 포커스 | **통과** | `keyboard-empty.js:247-256`의 빈 상태·포커스 확인까지 통과. Return 결과의 통과를 뜻하지 않는다. | keyboard-ux R2 `3d64d38f-7af9-4bf6-be22-d3e0e96dd8ec` |
| 빈 프로젝트 Return → 빠른 입력 | **실패** | `PROJECT_RETURN_DID_NOT_OPEN_CAPTURE`. 기존 앱 동작과 스크립트 기대 불일치이며 이번 브랜치 회귀가 아니다. | keyboard-ux R2 `3d64d38f-7af9-4bf6-be22-d3e0e96dd8ec` |
| `keyboard-safety.js --fixture many` | **실패** | `checklist_open`의 `TASK_LIST_MISSING`; 직후 업무 목록은 화면에 보였다는 인계. AX 역할/대기 조건 문제 가능성이 높고 후속 동선은 미실행. | keyboard-ux R2 `3d64d38f-7af9-4bf6-be22-d3e0e96dd8ec` |
| `capture-search-flow.js --action capture` | **실패** | `TextEdit becomes the previous app` timeout. 전역 핫키 전의 준비 단계 실패로 입력·저장·이전 앱 복귀는 미실행. | ui-flows R1 `4d979eb4-5d7b-422d-b728-0c1381250535` |
| 수정본의 macOS SDK 빌드·화면·키보드·VoiceOver | **미실행** | Linux 빌드·테스트·구문 파싱과 구별한다. `cd6f2b3`의 3pt 포커스 후속 변경도 이 `5a64fa4` 실기로 검증됐다고 간주하지 않는다. | — |

**L1 — 시간 형식 줄바꿈 수정.** `SettingsScreen.swift:536`의 `field()`는 `LabeledContent`로 제목을 제공하지만, 기존 `reminderSection`은 다시 `TextField("HH:mm")`를 넣었다. macOS `Form`은 이 문자열을 입력칸 앞의 레이블로 표시한다([Apple TextField](https://developer.apple.com/documentation/swiftui/textfield)). 따라서 고정 100pt가 편집기와 중복 레이블에 함께 배분되어 형식 문구를 압박한다. main에도 같은 헬퍼·중첩 레이블·100pt가 있으므로 기존 레이아웃 결함이다. 이번 diff는 바깥 탐색을 콘텐츠 680pt 기준 `AnyLayout`으로 바꿨으며 이 중첩 구조를 도입하지 않았다. 그 폭 전환이 실기에서 미친 영향은 별도 비교하지 않았다. `SettingsScreen.swift:513-520`에서 입력칸의 레이블만 `.labelsHidden()`으로 숨기고 `HH:mm`을 실제 prompt로 옮겼다. 입력값이 있어도 아래 설명에서 24시간제 시:분과 예시를 읽을 수 있다. 기존 접근성 라벨·바인딩·100pt 편집기와 전역 `field()`는 유지한다.

**L2 — 빈 프로젝트 Return은 기존 이슈.** `keyboard-empty.js:253`의 key 29는 ←가 아니라 물리 **0** 키다. ⌘⇧0은 `KeyboardNavigation.swift:89-94`의 콘텐츠 이동이며, key 36은 Return이다. 앱의 빈 상태는 `ProjectsScreen.swift:33-42`에서 `onCreateProject()`를 호출하고 `:168-170`에서 `showsProjectCreator = true`, `:83-88`에서 프로젝트 추가 시트를 연다. `keyboard-empty.js:259`는 별도 창 ‘빠른 입력’을 기다리므로 이 구현의 성공을 판정할 수 없다. 동작 변경은 main에 포함된 **`9b12e14`**에서 `onCapture()`를 프로젝트 추가로 대체한 것이며, 이번 브랜치의 ProjectsScreen diff는 데이터가 있는 업무 행의 named accessibility action 4줄(`:238-241`)뿐이다. 앱·스크립트는 수정하지 않았다. 프로젝트 시트가 실제로 열렸는지는 인계 결과만으로 확인할 수 없어 Mac에서 별도 확인한다.

과거 ‘키보드 탐색 개선’ 절에는 **2026-10-12 / `b5794a8` / run `27bbf0d4-bd8e-4ff7-8046-c304f9aee4bc`**의 `many`/`empty` 100개 assertion 및 ‘빈 프로젝트 Return 입력 열기’ 통과 기록이 있다. 이는 `9b12e14` 이전 동작의 기록으로 보존한다. `docs/ui-refresh.md`, `docs/ux-components.md`, `docs/ux-verification.md`, `docs/RELEASE.md`를 확인했지만 **0.9.0 / main `6ea225b`에서 keyboard-empty가 통과했다는 별도 기록은 찾지 못했다**. 저장소에 CHANGELOG 파일은 없다.

**L3 — 테스트 조건 문제로 판정, 변경 없음.** `keyboard-safety.js:61-69`는 8초간 0.12초 간격으로 재시도하지만 `:187`에서 ‘업무 목록’의 역할을 `AXScrollArea`로만 제한한다. 앱은 main과 동일한 `TaskListScreen.swift:40-66`의 표준 `List`다. 같은 저장소의 `keyboard-flow.js:120-126`은 `AXOutline`·`AXTable`·`AXList`·`AXScrollArea`를 허용하며, 아래 「macOS 26 · Liquid Glass와 표준 컴포넌트」(2026-10-15) 절의 Maclab 기록에도 목록이 `AXOutline`으로 노출된 선례가 있다. 이번 diff는 업무 목록·레이블·화면 이동·스크립트를 바꾸지 않았으므로 앱 회귀보다 **AX 역할 필터 또는 노출 타이밍** 가능성이 높다. 당시 AX 트리가 없어 정확한 역할/지연은 미확정이다. `capture-search-flow.js:242-244`는 TextEdit 활성화 후 전면 bundle ID 일치를 기다리고 나서야 핫키를 보낸다. `:49-57`의 기본 8초·0.15초 polling에서 실패했으므로 **테스트 환경의 앱 활성화/타이밍 문제**로 분류한다. 이번 diff에는 이 준비 단계나 앱 활성화 경로 변경이 없으며, 실제 입력·저장 회귀 여부는 이 실패로 판정할 수 없다. 두 스크립트와 앱 경로는 수정하지 않았다.

**L4 — 문서 P3 정정.** F1/F2 조치를 `cd6f2b3`의 대비 무관 시스템 `keyboardFocusIndicatorColor`, 대비 높이기 포커스 3pt·비포커스 outline 2pt와 일치시켰다. F4 단축키 실패 앵커는 실제 `SettingsScreen.swift:318`로 정정했다(L1 수정 후에도 동일).

L 검증: Linux aarch64 / Swift 6.3.3에서 `swift build --build-tests` exit **0**(4.11초), `swift test` exit **0**(**807개 XCTest / 실패 0**, 47.253초). `swiftc -frontend -parse -target arm64-apple-macos26 Sources/WorkLogApp/SettingsScreen.swift`와 `git diff --check`도 통과했다. 구문 파싱은 macOS SDK 타입 검사가 아니다. 로그는 `/tmp/lgux-90df-l-build.log`, `/tmp/lgux-90df-l-test.log`에 남겼다. 수정 파일은 `SettingsScreen.swift`와 이 문서뿐이다.

Mac 재현: 가짜 fixture에서 검토 알림을 넓은 창·840pt 및 설정 콘텐츠 680pt 경계 양쪽으로 전환하고, 값 있음/비어 있음·Tab 편집·저장·VoiceOver 라벨을 확인한다. 새 `empty` fixture의 프로젝트에서 ⌘0 → ⌘⇧0 → Return으로 ‘프로젝트 추가’ 시트가 열리고 Esc 후 포커스가 복귀하는지 확인한다. safety 실패는 당시 목록 AX 역할·부모 관계와 대기 시간을, capture 실패는 TextEdit 전면 활성화 성공 여부를 먼저 확인한다. 이 작업은 스크립트 수정·push·배포를 포함하지 않는다.

N 조치 (LGUX-90DF · N, 2026-10-17 KST): 설정 숫자 입력의 중복 레이블을 숨기고 제목과 단위가 포함된 범위를 읽는 기존 접근성 라벨을 유지했으며, Codex 경로·추가 스킬·프로젝트 이름은 의미 있는 제목과 별도 prompt로 정리했다. 포커스 색의 대비 무관·선 두께 대응 의도를 주석으로 명시하고 Maclab run ID와 2026-10-15 선례 참조를 보완했다. Linux Swift 6.3.3 빌드·전체 XCTest 807개(실패 0)·변경 Swift 3개 파일의 macOS 26 타깃 구문 파싱·`git diff --check`가 통과했다. macOS SDK 빌드·실제 화면·키보드·VoiceOver 재확인은 미실행이다.

### 실제 Mac 후속 확인 (이번 작업에서는 미실행)

macOS 26 이상 SDK로 앱을 빌드한 뒤 `--ui-test-fixture empty|few|many`를 각각 사용한다. 실제 회사 계정·Secret·Keychain·AI 토큰은 사용하지 않는다.

1. 메인 창 840×560·980pt·1280pt에서 사이드바를 펼치고 접는다. 설정의 목차/Picker 전환은 **창 폭이 아닌 콘텐츠 폭 680pt** 기준이다. 경계 양쪽에서 검색어·선택·미저장 양식 값이 유지되는지, 양식과 저장/되돌리기가 잘리지 않는지 확인한다. 설정 검색 0건·복구, 긴 한국어·단축키·숫자 양식과 스크롤도 확인한다.
2. 주간보고·성과자료 각각 저장된/빈/생성 중/오류/수정/확정 버전에서 버튼 배치·읽기 순서·본문 높이를 확인한다. 좁은 배치에서도 복사·편집·저장·되돌리기·확정이 보이고, ⌘E/⌘S/⇧⌘C가 한 번씩 실행돼야 한다. 복사는 확정을 바꾸지 않고 서로 다른 목적의 본문을 섞지 않아야 한다.
3. 키보드만으로 사이드바 → 설정 목차·검색·양식·저장, 프로젝트 → 업무 → 상세 → 복귀를 수행한다. VoiceOver 동작 메뉴에서 ‘업무 상세 열기’를 실행해 올바른 행과 선택으로 복귀하는지 확인한다. 빠른 입력의 저장 중 이름과 검색 헤더의 중복 Esc 발화 제거도 확인한다.
4. 라이트/다크 × 대비 증가·투명도 줄이기·동작 줄이기를 확인한다. 검색 패널 외곽선, 오늘의 보류/완료 상태 문구·기호, 상태 배지·포커스가 읽혀야 한다. 4.5:1 등 실제 대비 수치는 Accessibility Inspector와 렌더링으로 별도 측정한다. 검색 패널 580×480, 메모 패널 520×440, 업무 패널 800×440에서 glass 헤더·닫기·본문·저장 상태를 확인한다.
5. 메모·업무의 한글 조합 중 Return/Esc/⌘Return, 초안 탭 왕복·닫기/재열기·Undo, 설정 폭 전환 중 편집 상태를 확인한다. 가짜 Secret은 잠금·가림 값의 VoiceOver 비노출·방향키 비복사·명시적 복사·부분 수정·휴지통 복원을 회귀 확인한다. Linux 테스트와 파싱은 이 실제 동작의 통과 근거가 아니다.


## macOS 26 · Liquid Glass와 표준 컴포넌트 (2026-10-15)

사용자 요청으로 최소 지원 버전을 macOS 26.0으로 올렸다. Package.swift, 앱과 UI 리뷰 번들의 `LSMinimumSystemVersion`, Sparkle 피드의 `minimumSystemVersion`을 함께 변경하고 CI·릴리즈 러너는 `macos-26`을 사용한다. macOS 앱 빌드에는 macOS 26 이상 SDK가 필요하다. Core의 Linux 지원, Swift 5 언어 모드와 저장·Secret·AI 계약은 유지한다.

- 메인 창은 표준 제목 표시줄·`NavigationSplitView`·사이드바 `List`·`toolbar`를 사용한다. 시스템이 탐색 계층의 Liquid Glass를 관리하며 불투명 전체 배경과 자체 헤더는 제거했다. 사이드바 접기는 표준 열 숨기기로 동작한다. 빠른 입력·검색·새로고침·키보드 도움말은 메뉴에서도 접근한다.
- 시스템 버튼 스타일과 기본 `GroupBox`를 사용하고 자체 `WorkLogButtonStyle`/`WorkLogGroupBoxStyle`을 제거했다. 펼침 섹션은 `DisclosureGroup`, 날짜 입력은 표준 compact `DatePicker`다. 날짜 바인딩은 `WorkCalendar`의 달력·시간대·`WorkDate` 변환을 명시한다.
- 빠른 입력 유형은 표준 segmented `Picker`다. 빠른 입력·검색 패널의 조작 헤더에만 regular Liquid Glass를 적용하고 편집기·목록·보고서·Secret 표는 읽기 편한 콘텐츠 배경을 유지한다. 사용자 지정 모션은 동작 줄이기 설정을 따른다.
- 설정은 표준 선택 목록·grouped `Form`·`LabeledContent`, 단축키 기록은 네이티브 `NSButton` 외관을 사용한다. 업무 목록은 표준 `List`와 접힌 완료/취소 `DisclosureGroup`을 사용한다. 목록 선택 텍스트는 시스템 계층 색을 사용한다.
- 네이티브 사이드바 방향키 탐색 중 새 화면의 자동 포커스가 선택 목록을 방해하지 않도록 앱 내부 환경값으로 제어한다. 명시적인 본문 이동, 상세 닫기 후 복귀, 패널 입력 포커스는 유지한다. 업무 목록의 선택·Return·더블클릭과 날짜 선택은 시스템 표준 조작을 따른다.

기준: [Apple Materials HIG](https://developer.apple.com/design/human-interface-guidelines/materials), [Liquid Glass 적용](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass), [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons), [macOS 디자인](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos). 이후 작업에도 적용하도록 `AGENTS.md`에 UI/UX 규칙을 기록했다.

검증: Linux Swift 6.3.3 `swift build --build-tests`와 전체 테스트 807개(실패 0), 배포 도구 테스트 25개, macOS 26 타깃 Swift 구문 분석과 shell/JS 구문 검사 및 `git diff --check` 통과.

Maclab `fbb48f5e-2ff8-4435-83b3-46fabb106afd`에서 커밋 `8232854`의 앱을 macOS 26.6.2 / Xcode 27.0으로 빌드했다. 업로드 아카이브 SHA-256은 `80e1259872f9d7e21d06e6e2de7ffe9182aced39434dd1ee3bd6c23e3b2f9967`이다. `ui-flows`의 빌드, 앱 실행, 메모 저장·이전 앱 복귀, ⌘N 입력창, 창 유지 assertion은 모두 통과했다. 실제 회사 데이터·계정·Keychain을 사용하지 않는 DEBUG `many` fixture만 실행했다.

대화형 추가 검증에서 빠른 입력의 전역 진입, ⌘1·2·3 유형 전환 3회 반복, ⌃Tab 순환, Tab/Shift+Tab 포커스와 Esc 닫기가 통과했다. 메인 화면은 ⌘숫자 이동, ⌘0/⌘⇧0, 사이드바 ↑↓ 반복 이동 시 포커스 유지, 업무 Return 상세 열기·Esc 후 목록 복귀, 오늘 영역 순환을 통과했다. 다크 모드 검색은 전역 진입→결과→가짜 메모 편집/⌘S 저장→검색어·선택·포커스 복귀→Esc 닫기까지 통과했다.

첫 메인 키보드 helper는 목록을 `AXScrollArea`로 한정하여 실패했다. 실제 AX 조회에서 사이드바와 업무 목록이 `AXOutline`임을 확인하고, helper를 동일 레이블·역할·창과 실제 포커스 조상 관계로 판정하도록 수정했다. 수정 helper SHA-256 `15dc748b2e92d54ca630330458c4f2cbaf79f967a9f276b0d0795ad041c072e7`를 원격에 동기화하고 위 키보드 동선을 재실행해 통과했다. 앱 소스는 이 과정에서 변경하지 않았다.

실제 화면은 오늘 1280×800 (`fcec9b7b-8bbe-4a2b-826e-b4248e51c9da`), 메모 패널 (`fee92487-ed51-4861-b062-a2cb0290d2fc`), 설정 960×640 (`cbd7d598-c0b3-4c39-af85-a51790ccf9fe`), 다크 업무 목록 960×640 (`aa0d4fd4-ec82-4911-9dca-c84d82416dec`)에서 확인했다. 설정의 입력·저장 버튼과 선택 행의 제목·상태가 보이는 것을 확인했다. Xcode 27 빌드에는 기존 AppKit actor 격리/Sendable 및 weak 변수 경고가 남아 있으며 Swift 5 언어 모드에서 빌드는 통과했다. 전체 VoiceOver·한글 IME·투명도/대비/모션 설정 조합 및 배포용 DMG 재생성·업데이트 설치는 이번 Maclab 실행 범위에 포함하지 않았다.

추가 수동 확인 항목: 투명도 줄이기·대비 높이기·동작 줄이기, VoiceOver·한글 IME 전체 조합, 날짜 팝오버와 서울 시간대 경계, 미저장 초안/Undo/다중 창, 완료 목록 접기와 설정 저장의 전체 조합. 가짜 fixture만 사용한다.

## 빠른 입력에서 새로 작성 (2026-10-13)

- 메모·업무 입력의 날짜 행 오른쪽에 `새로 작성`을 표시한다. 남아 있는 초안은 `계속 작성` 또는 `버리고 새로 작성` 확인을 거치고, 빈 초안은 바로 오늘 날짜로 시작한다. Esc·닫기 후 재열기는 기존 초안을 유지한다.
- 현재 탭의 본문·프로젝트·태그·관련 기록·업무 검색어·대상·상태·추적 옵션을 초기화한다. 본문 없이 프로젝트나 태그만 연결했거나 업무 검색어만 입력한 경우도 초안으로 판단한다. 다른 탭의 초안과 기본 입력 유형은 유지한다.
- 저장·업무 완료 확인 중에는 새로 작성을 막고, 새 초안의 입력 위치와 편집기 상태를 초기화한다. Secret은 기존 암호화 초안 복구·폐기 흐름을 사용한다.

검증: Linux Swift 6.3.3에서 `swift build --build-tests`와 `swift test --filter 'Capture|QuickTask'` 통과(새 테스트 10개 포함 76개). macOS 대상 Swift 구문 검사와 `git diff --check`도 통과했다. 이번 변경의 macOS SDK 빌드·실제 UI 조작은 실행하지 않았다.

macOS 수동 확인: 본문·프로젝트만 있는 초안에서 확인 취소/폐기, 메모·업무 간 초안 독립성, 과거 날짜 초기화, 새 업무 선택 화면과 입력 포커스 복귀, 새 초안에서 Undo로 이전 본문이 돌아오지 않는지, 작은 창 배치와 한글 조합 중 조작.

## 프로젝트 추가·입력 표시 보완 (2026-10-13)

- ⌘N은 업무 화면에서 새 업무 입력, 프로젝트 화면에서 프로젝트 추가, 그 외 화면에서 빠른 입력을 연다. 프로젝트는 기록 없이 이름만으로 생성하며 빈 이름·중복 이름을 막고 생성 후 새 프로젝트를 선택한다. 추가 창은 호출한 메인 창에만 표시하며 닫으면 프로젝트 목록에 키보드 포커스를 돌려준다.
- 단축키 설정은 등록 영역을 최대 420pt, 레코더를 148×28pt로 제한하여 라벨과 입력이 과하게 벌어지지 않게 한다.
- 작업별 AI의 자동 항목은 실제 실행 프로필과 같은 로컬 Codex 모델 목록을 사용하여 모델 ID·사고 수준을 표시한다. AI가 활성화되어 있으면 해당 설정 진입 시 한 번 조회하고, 비활성 상태에서는 저장된 목록만 표시한다. 조회 정보가 없으면 `Codex 기본값 (미확인)`으로 표시한다.
- 빠른 입력 자동완성은 @/#를 본문에 남긴다. 연결된 이름은 본문과 연결 목록에서 둥근 배경으로 표시하되 저장·복사 시에는 일반 텍스트를 유지한다. 프로젝트별 상태 옵션은 체크박스와 설명을 직접 표시하며 전체 업무 상태와 독립적인 진행·완료 관리임을 설명한다.
- 접힌 사이드바는 표준 창 제어 버튼을 담는 80pt 폭을 확보하고 앱 아이콘과 화면 상단 바 높이를 44pt로 맞춘다.

Linux Swift 6.3.3에서 `swift build --build-tests`와 전체 테스트 796개가 통과했다. 이후 연결된 짧은 이름과 새 긴 이름의 자동완성이 겹치는 경우를 보완하고 CaptureUXTests 18개가 통과했다.

Maclab `dca79b8e-c81c-4a1f-9327-04b27e5f5605`에서 가짜 `many` fixture로 검증했다. 첫 자동 빌드는 프로젝트 상태의 optional 처리 오류로 실패했으며, `b3f676a`까지 수정한 세 파일을 원격에 동기화하고 SHA-256을 대조한 뒤 macOS 재빌드가 통과했다. 수정본에서 기본 창 경계, 전역 메모 입력·저장·이전 앱 복귀, 오늘 ⌘N 회귀를 다시 실행해 통과했다. 프로젝트 ⌘N의 이름 입력 포커스·생성·목록 선택·중복 이름 안내와 업무 ⌘N의 새 업무 진입, 직접 보이는 상태 옵션, 설정의 모델명과 단축키 크기를 실제 화면에서 확인했다.

메모의 @/# 토큰 배경은 텍스트 선택을 해제한 상태(`AXSelectedText` 길이 0)에서 확인했다. AI 화면은 `519aeac5-60e3-4a5c-b5ff-0a122fd26ba1`, 다크 단축키는 `93821f53-0c72-4569-b2ca-6c4f4739d52c`, 메모 토큰은 `c968f326-9536-4546-868f-c72e7e4c9789` screenshot 증거에 남겼다. 접힌 사이드바는 `6fc5c884-8fb1-462b-8424-d2dad940b287`에서 창 제어 버튼 세 개가 80pt 안에 들어가고 아이콘과 화면 제목의 높이가 일치하는 것을 확인했다. 실제 회사 계정·AI 추론·자격증명은 사용하지 않았으며, 한글 IME 전체 조합·다중 창·빈 fixture의 첫 생성 이후 키보드 동선은 이번 macOS 실행에서 별도 재현하지 않았다.

## 설정·버튼·종료 업무 정리 (2026-10-13)

- 설정은 검색 가능한 내부 목차와 선택한 항목의 상세 화면으로 구성한다. 일반·단축키·AI 연결·작업별 AI·백업·Secret 보호·검토 알림·업데이트를 직접 이동하며, 설명문과 입력 필드는 왼쪽 기준으로 정렬한다. 저장·되돌리기는 화면 아래에 유지한다.
- 단축키 등록 성공은 레코더 옆 작은 체크로 표시하고 별도 ‘등록됨’ 행은 없앤다. 등록 실패 안내와 녹화·취소·저장 동작은 유지한다.
- 일반 버튼은 평소 배경과 테두리를 없애고 hover/누름에 반응한다. 주요 동작에는 옅은 강조색을 쓴다. 행 포커스는 왼쪽 표시로, 버튼 포커스는 단일 테두리로 구분하고 펼침 영역은 헤더만 포커스를 받는다.
- 업무 목록은 현재 업무를 먼저 보여주며 완료·취소 업무는 기본으로 접는다. 이름 검색에서는 종료 업무도 표시한다. 방향키 선택은 실제 표시된 업무만 순회한다.
- 빠른 입력의 업무 후보에서 취소 업무를 제외한다. 패널을 다시 열 때 후보를 새로 조회하여 다른 화면에서 취소한 상태도 반영하되 작성 중인 초안과 명시적으로 선택한 업무는 보존한다.
- 작업별 모델·추론 강도는 `ai-task-profiles.json`에 별도로 저장한다. 일반 설정 저장·되돌리기에 포함하고 다음 AI 작업부터 적용한다. 기존 `AppSettings`·`AIJobInput`·DB 스키마는 변경하지 않는다.

모델 선택은 [공식 OpenAI 모델 안내](https://learn.chatgpt.com/docs/models)의 용도 구분을 참고한 앱 추천값이다. 메모 후보·검색 계획·질문 생성에는 사용 가능한 Luna, 주간보고·근거 답변·성과자료에는 사용 가능한 Sol을 우선한다. 추론 강도는 각각 빠른 추출/조건 정리에 low, 보고 문장/질문/근거 답변에 medium, 기간 성과 종합에 high를 권장한다. 실제 선택지는 [Codex app-server의 `model/list`](https://learn.chatgpt.com/docs/app-server)에서 반환한 계정별 모델과 지원 effort로 제한하며, 추천 모델이 없으면 계정 기본 모델을 쓴다.

Linux Swift 6.3.3에서 `swift build --build-tests`와 전체 `swift test` 786개가 통과했다. macOS 대상 구문 검사, UI helper의 JavaScript 구문 검사, `git diff --check`도 통과했다. Maclab `bf5a5102-e6d0-459d-827d-961efa41a659`에서 macOS 앱 빌드와 기본 입력·저장·창 복귀 검사가 통과했다. 설정 화면은 라이트/다크로 확인했으며, 항목 전환 시 상단 여백이 없어지던 문제를 수정해 원격 재빌드했다.

같은 가짜 `many` fixture에서 `settings-task-review.js --action settings|tasks|capture`를 각각 실행해 종료 코드 0과 모든 assertion을 확인했다. 설정 목차 검색·AI 연결/모델/effort 선택기, 별도 ‘등록됨’ 행 부재, 완료·취소 기본 접힘·검색·펼침·재접기, 빠른 입력의 취소 업무 제외·활성 후보 유지가 포함된다. 초기 helper는 SwiftUI의 AXFocused를 설정해도 텍스트 포커스가 이동하지 않는 문제와 CF 문자열 브리지 문제로 실패했으며, native 포인터 입력과 새 AX 참조를 사용하도록 고친 뒤 세 검사가 모두 통과했다. 앱 입력 자체는 마우스와 키보드로 별도 정상 동작을 확인했다.

원격 재빌드한 `SettingsScreen.swift`와 최종 helper는 로컬 SHA-256과 일치한다(`f597dca3…`, `6c92877d…`). 작은 창의 모든 조합·한글 IME 전체 동선·실계정 AI 추론은 이번 실행의 검증 범위에 포함하지 않는다.

검증 시 가짜 fixture만 사용하고 설정 검색·범주 이동·단축키 상태, 작은 창의 한글 줄바꿈, Tab 포커스, 종료 업무 펼침과 검색, 빠른 입력 재오픈을 확인한다. 실제 계정의 AI 추론이나 자격증명은 테스트하지 않는다.

## 키보드 탐색 개선 (2026-10-12)

빠른 입력·검색·앱 화면의 이동, 선택, 편집 진입점을 키보드로 연결한다. 단축키는 현재 창과 화면에만 적용하며 한글 조합을 보호한다. 입력 패널의 숫자·탭 키는 버튼에 포커스가 있어도 메인 메뉴보다 먼저 처리하고, 이전 창의 포커스 해제 알림 때문에 패널 메뉴 상태가 바뀌지 않도록 현재 키 창을 다시 확인한다. Core 계약과 저장 스키마는 변경하지 않는다.

| 위치 | 키 | 동작 |
| --- | --- | --- |
| 메인 앱 | ⌘1…9 | 오늘·업무·프로젝트·주간보고·성과자료·Secret·검색·그래프·휴지통 |
| 메인 앱 | ⌘, / ⌘⌥←·→ | 설정 / 이전·다음 화면(백업·설정 포함) |
| 메인 앱 | ⌘0 / ⌘⇧0 | 사이드바 / 현재 화면 내용에 포커스 |
| 앱 | ⌘⌥K | 키보드 단축키 안내 창 |
| 빠른 입력 | ⌘1·2·3 | 메모·업무·Secret 탭; 탭에 키캡 표시 |
| 빠른 입력 | ⌃Tab / ⌃⇧Tab, ⌘⇧] / ⌘⇧[ | 다음 / 이전 입력 탭 |
| 빠른 입력 | ⌘E / ⌘L | 본문(Secret은 제목) / 업무 선택으로 이동 |
| 빠른 입력 | Tab / ⇧Tab | 입력 항목과 버튼을 표시 순서대로 이동; Secret도 명시적 포커스 순서 사용 |
| Secret 편집 | ⌘⇧Return / ⌘⇧⌫ | 행 추가 / 현재 편집 중인 행 삭제 |
| 검색 | ⌃1·2·3, ⌃Tab / ⌃⇧Tab | 전체·기록·Secret 범위 / 범위 순환; 패널은 ⌘1·2·3도 지원 |
| 검색 | ↑↓ / Return / Tab·⇧Tab | 결과 선택 / 원문 열기 / 검색어와 결과 간 포커스 이동 |
| 검색 | ⌘E | 선택한 메모 편집 또는 업무 관리; 진행 기록은 소속 업무 관리 |
| 검색 | ⌘F / ⌘⌥F | 검색어로 복귀 / 필터 열기; 필터의 Esc는 필터 먼저 닫기 |
| 오늘 | ⌘⌥1·2·3, ⌃Tab / ⌃⇧Tab | 활동 기록·업무 상태·메모 영역 선택 / 영역 순환 |
| 오늘·업무·프로젝트 | ↑↓ / Return | 항목 선택 / 상세 열기; 닫으면 선택·스크롤·포커스 복원 |
| 프로젝트 | → 또는 Return / ← | 선택한 프로젝트의 업무 목록 / 프로젝트 목록 복귀 |
| 업무·Secret | ⌘⌥F / ↓ | 제목 검색 / 결과 목록으로 이동 |
| 메모 상세 | ⌘E / ⌘S 또는 ⌘Return | 본문 편집 / 수정 저장 |
| 업무 상세 | ⌘E / ⌘L / ⌘⇧J | 진행 기록 입력 / 업무 동작 / 체크리스트 입력 |
| 보고서 | ⌘E / ⌘S | 본문 편집에 포커스 / 변경 저장 |

메모는 기존 `updateMemoBody`로 이전 본문을 revision으로 보존하고 검색 인덱스를 갱신한다. 저장 실패 시 편집 내용은 유지한다. 미저장 편집을 닫을 때는 저장·버리기·계속 편집을 선택한다. 검색에서 원문·편집을 닫으면 검색어와 선택을 유지하되 수정으로 검색 조건에서 벗어난 결과는 다시 검증한다. 업무 상세의 미저장 진행 기록·체크리스트 입력도 Esc/⌘W에서 계속 편집 또는 ⌘D로 명시적으로 버리기를 선택한다. 편집 시트가 열린 동안 다른 창의 화면 이동으로 편집 내용을 제거하지 않는다. 단축키 안내 창을 반복해서 닫아도 원래 편집 창과 입력 위치로 복귀한다. Secret 편집 행은 ID로 다시 조회하는 바인딩을 사용해 행 삭제 뒤 남아 있는 입력 필드의 접근을 안전하게 처리한다. 과거 업무 상세의 읽기 전용 상태와 Secret의 인증·편집 소유권·암호화 경로는 유지한다.

검증 결과:

- Linux Swift 6.3.3 `swift build --build-tests` 통과.
- 전체 테스트 재실행 771개 통과. 첫 실행은 299개 통과 후 기존 `JSONRPCConnectionTests.testStdoutSplitMultibyteCharacterStillEmitsLine` 실행 중 Linux libdispatch signal 11로 중단됐다. assertion 실패는 없었으며 Core/Tests는 변경하지 않았다. 재실행에서는 해당 테스트를 포함해 전체 통과했다.
- 전체 App 파일의 macOS 대상 Swift 구문 검사와 `git diff --check` 통과. 구문 검사는 macOS SDK 타입 검사·실제 UI 동작 검증을 대체하지 않는다.
- 최종 앱 소스 `b5794a8`의 [macOS CI 38202697207](https://github.com/RunaticMoon/worktrail/actions/runs/38202697207) 통과: 전체 앱 빌드, Core 771개 테스트, 배포 도구 23개 테스트, DMG 패키징·서명 무결성·Sparkle 로딩 검증.

실제 Maclab 검증 (2026-10-12):

- run `27bbf0d4-bd8e-4ff7-8046-c304f9aee4bc`에서 최종 앱 소스 `b5794a8`을 다시 빌드하고 새 `many`/`empty` fixture로 네 검사를 순서대로 재실행했다. 전역 핫키 흐름 35개, ⌘N 입력 흐름 19개, 편집 보호·버튼 실행·Secret 생존 검사 35개, 빈 화면 검사 11개로 총 100개 assertion이 통과했다. 전체 재실행 exit code 0, `COMPLETE_KEYBOARD_SUITE_PASSED`; 증거 `a64e4b86-ff87-44c2-afba-fa4d39e63947_stdout`.
- 확인한 동선: 다른 앱에서 전역 입력·검색 호출, ⌘1·2·3 반복 전환과 CtrlTab, 사이드바/본문 이동, 업무 상세 복귀, 검색 결과 선택→원문→메모 수정·⌘S 저장→재열기, 미저장 메모·업무 입력의 Esc 유지/⌘D 버리기, 도움말 반복 열기와 Esc/⌘W 후 편집 위치 복귀, 업무 버튼의 Return/Space 실행, Secret Tab/ShiftTab 및 빈 행 삭제 후 동일 프로세스 생존, 빈 프로젝트 Return 입력 열기, 휴지통 Space 잠금 해제와 빈 목록 포커스.
- 최초 자동 실행에서 발견한 휴지통 버튼 실행 문제를 수정한 뒤 같은 세션에서 전체 흐름을 재실행했다. 따라서 run의 최초 자동 요약은 fail이며, 위 후속 실행 증거가 최종 소스의 검증 결과다. 이전 검증에서 발견한 입력 패널 메뉴 충돌, 도움말 복귀, Secret 삭제 행 바인딩 충돌도 수정 후 재검증했다.
- 버튼은 시스템 전체 키보드 접근 설정에 의존하지 않고 Return/Space로 실행한다. 비활성 상태·한글 조합·키 반복은 공통 처리로 보호한다. SwiftUI가 버튼 대신 콘텐츠 AXGroup을 포커스로 노출하는 휴지통은 같은 창·고유 버튼·사이드바 제외를 확인한 뒤 실제 Space 활성화 결과까지 필수로 검사한다.
- 모든 조작은 `dev.worklog.UIReview --ui-test-fixture many|empty`의 실제 PID를 검사한 뒤 수행했다. Secret 값 조회·저장이나 실제 인증 정보 접근 없이 가짜 인증을 사용했다.

추가 수동 확인 범위: 실제 한글 IME 조합과 사용자 키보드 접근 설정 조합, 여러 모니터·Space·작은 창에서의 배치, 저장 실패 재시도, 긴 Secret 붙여넣기와 실제 기기 인증, 배포 앱의 업데이트 교체·재시작. 위 100개 자동 검사에 이 범위까지 포함됐다고 간주하지 않는다.

## 0.2.0 추가 개선

- 날짜 선택은 숫자 스피너 대신 날짜·요일 버튼과 월요일 시작 달력 팝오버를 사용한다. 좌우 버튼은 하루 또는 한 달을 이동하며, 달력 안에서 방향키로 일/주 이동, Return으로 선택, Esc로 닫을 수 있다. 모든 계산은 기존 `WorkCalendar` 업무 시간대를 따른다.
- 화면 외곽 여백은 16pt, 기본 카드 여백은 12pt, 카드 모서리는 10pt로 줄였다. 사이드바·상단 바·검색·상세·리포트·백업 화면도 같은 밀도로 맞추고 버튼 높이와 테두리를 줄였다.
- 빠른 입력의 업무 탭은 `업무 선택 → 동작 → 내용`의 가로 3단계 구성이다. 목록의 ↑↓로 항목을 선택하고 Return/→로 다음 단계로 이동한다. 본문 편집 중에는 텍스트 커서·줄바꿈을 유지하며 저장은 ⌘Return이다.
- 앱 아이콘은 내장 이미지 생성 도구로 만든 인디고 기록장/기록의 길 모티프다. 원본은 `distribution/assets/AppIcon.png`, 생성 프롬프트는 `AppIcon.prompt.txt`에 저장했다. macOS 빌드에서 모든 표준 크기의 `.icns`로 변환해 Dock·Finder·사이드바에 적용한다.
- 앱 메뉴와 설정에 업데이트 확인을 추가했다. Sparkle의 업데이트 서명은 Apple Developer ID/공증과 별개이며, 배포·키 관리 절차는 `RELEASE.md`에 기록한다.

추가 수동 확인: 달력의 월말·윤년·연도 경계, 업무 세 열의 마우스/키보드 선택과 긴 목록 자동 스크롤, 한글 조합 및 팝오버 내부 키 입력, 작은 화면에서의 가로 스크롤, Finder/Dock 아이콘, 배포 앱의 업데이트 확인·설치·재시작. 기존 1.x 앱에는 업데이터가 없어 0.2.0을 한 번 직접 설치해야 한다.

0.2.0 검증: Linux 및 [macOS CI 37007758971](https://github.com/RunaticMoon/worktrail/actions/runs/37007758971) 전체 빌드와 Core 694개 테스트 통과. macOS에서 생성된 DMG의 버전·아이콘·코드 서명·Sparkle framework 로딩 smoke도 통과했다. 배포 Python 테스트는 23개 통과. 실제 IME 조작과 업데이트 교체·재시작은 위 수동 확인 항목으로 남는다.

## 이전 개선

2026-10-02 사용자 요청: macOS 기본 컨트롤 위주의 화면을 다듬고, Raycast처럼 단축키로 마우스 근처에서 여는 경험을 제공한다.

## 반영 내용

- 빠른 입력과 검색은 제목 표시줄 대신 커스텀 헤더를 가진 둥근 플로팅 패널로 열린다. 헤더를 드래그해 옮길 수 있다.
- 새로 열 때 커서가 있는 모니터를 선택한다. 커서 오른쪽 아래를 우선하고, 공간이 부족하면 반대편으로 뒤집은 뒤 메뉴 막대·Dock을 제외한 영역 안으로 보정한다. 이미 열린 패널을 다시 호출할 때는 위치를 유지한다.
- 메인 화면은 커스텀 사이드바, 접기 버튼, 검색 진입점과 카드형 콘텐츠를 사용한다. 업무 목록에서 이름으로 좁혀 볼 수 있다.
- 하루 기록은 타임라인·당일 상태의 업무·메모 원문 세 영역을 유지한다. 폭이 좁으면 세로로 배치한다.
- 검색은 큰 입력 영역, 필터 초기화, 원문 카드와 출처를 포함한 AI 답변을 제공한다.
- 공통 테마는 인디고 강조색, 불투명한 표면, 얇은 경계선, 키캡과 여백을 사용한다. 시스템 라이트/다크 모드를 따르고 사이드바 애니메이션은 동작 줄이기 설정을 존중한다.
- 빠른 입력의 Tab/Shift+Tab, Option+Tab, Return, Command+Return, Esc와 IME 보호, 완료 확인, Secret 편집 소유권·암호화 초안 경로는 유지한다.

## Mac에서 확인할 항목

이번 변경의 SwiftUI/AppKit 실행·렌더링은 Linux에서 확인할 수 없다. 기존 macOS CI의 `swift build --build-tests`와 다음 확인을 함께 수행한다. 실제 계정 정보 없이 테스트용 기록만 사용한다.

1. 라이트/다크 모드에서 메인 창과 두 패널을 연다. 글자 대비, 키보드 포커스, 닫기 버튼, 둥근 모서리와 그림자를 확인한다.
2. 서로 다른 위치·해상도의 모니터에서 입력/검색 핫키를 누른다. 커서가 화면 네 모서리나 Dock 근처에 있어도 패널을 조작할 수 있어야 한다.
3. 패널을 드래그·리사이즈한 뒤 다시 호출한다. 열린 동안에는 위치가 유지되고 닫았다 열면 현재 커서 근처로 이동해야 한다. 다른 Space와 전체 화면 앱에서도 확인한다.
4. 한글 조합 중 Tab/Return/Esc가 입력기로 전달되는지, 일반 Return은 줄바꿈인지 확인한다. Command+Return은 한 번만 저장하고 원래 앱으로 돌아가야 한다.
5. 메모·업무 탭을 번갈아 편집하고 Esc로 닫았다 연다. 각각의 초안과 관련 기록 선택이 유지되어야 한다. 미완료 체크리스트가 있는 업무 완료 시 확인 절차를 거쳐야 한다.
6. 테스트 Secret을 메인 화면/패널에서 번갈아 연다. 동시 편집 방지, 잠금, 초안 복구, 저장을 확인한다.
7. 검색을 다시 열면 검색창에 바로 입력할 수 있어야 한다. 필터 적용·초기화, 원문 sheet 열기·닫기, Esc의 이전 앱 복귀를 확인한다.
8. 최소 크기(메인 840×560, 메모·시크릿 입력 520×440, 업무 입력 800×440, 검색 580×480)에서 날짜·저장·검색 컨트롤이 잘리지 않고 긴 기록을 스크롤할 수 있어야 한다. 화면이 더 작으면 패널을 화면에 맞추고 업무 세 열은 가로 스크롤한다. 다시 큰 화면에서 열면 원래 크기를 복원한다.
9. 백업 복원 시 두 패널을 모두 열어 두어도 기존 저장소 참조가 해제되고 복원 후 패널을 다시 사용할 수 있어야 한다.

핵심 파일: `AppTheme.swift`, `AppRootView.swift`, `CapturePanel.swift`, `SearchPanel.swift`, `FloatingPanelPositioning.swift`, `DayScreen.swift`, `SearchScreen.swift`.

## 이번 변경 검증

- Linux / Swift 6.3.3: `swift build --build-tests` 성공, `swift test` 694건 통과(실패 0).
- `swiftc -frontend -parse -target arm64-apple-macos14 Sources/WorkLogApp/*.swift` 구문 검사와 `git diff --check` 통과. 이 구문 검사는 macOS SDK를 이용한 타입 검사나 앱 빌드를 대신하지 않는다.
- 실제 배치 함수의 계산부를 실행해 모니터 좌표·화면 네 모서리·작은 화면·반대편 배치 74개 경우를 확인했다. AppKit 대역으로 작은 화면의 최소 크기 축소와 큰 화면에서의 복구 2개 경우도 확인했다. 네이티브 창 동작 검증은 위 Mac 확인 항목에 남아 있다.
