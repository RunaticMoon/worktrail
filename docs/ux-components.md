# 의미 기반 테마·재사용 컴포넌트 (UXFL-E55A · G/U)

`Sources/WorkLogApp/AppTheme.swift`와 `Components.swift`의 앱 모듈 내부 공통 API다. 모든 Swift 코드는 `#if os(macOS)` 안에 있고 지원 기준은 `Package.swift`의 macOS 14다. 화면 통합은 후속 H~K 작업에서 한다. 도메인·날짜 계산·저장·AI 실행은 컴포넌트가 담당하지 않는다.

## 시각·상호작용 원칙

- 시스템 글꼴과 `.title2`, `.headline`, `.body`, `.callout`을 사용한다. 키캡의 10pt 모노스페이스만 예외다. 긴 한국어 라벨은 줄바꿈을 허용하고 높이를 고정하지 않는다.
- `canvas`는 `windowBackgroundColor`, `surface`는 `controlBackgroundColor`, `elevated`는 `underPageBackgroundColor`, `border`는 `separatorColor`, `text`와 `muted`는 시스템 라벨 색이다. `accent`는 사용자 시스템 강조색, `accentSoft`는 그 색의 12% 채움이다. hex·장식 그라데이션을 쓰지 않는다.
- 기본 간격 4/8/12/16pt, 화면 여백 16pt, 카드 여백 12pt, 카드 모서리 10pt를 유지한다. 모든 콘텐츠를 카드로 감쌀 필요는 없다.
- 상태 라벨은 시스템 기본 텍스트 색으로 읽고, 아이콘과 낮은 농도의 배경에만 의미 색을 적용한다. 사용자 강조색의 밝기에 텍스트 가독성을 의존하지 않는다. 색만으로 의미를 전달하지 않는다.
- `colorSchemeContrast == .increased`이면 사용자 지정 경계는 기본 라벨 색의 2pt 선으로 강화하고 상태 아이콘도 라벨 색을 쓴다. 카드·일반 버튼의 기본 경계는 시스템 구분선 1pt이고 소스 목록 행·배지·칩에는 기본 테두리가 없다. 실제 대비 수치는 Mac 렌더링 후 확인해야 한다.
- 기존 `WorkLogButtonStyle`은 호출법·`ButtonStyle` 타입을 유지한다. 주요 버튼은 강조색의 옅은 채움과 기본 텍스트를 쓰고, 포커스 시 바깥 윤곽을 추가한다. 신규 컴포넌트의 버튼은 표준 `.bordered` / `.borderedProminent`를 사용한다. 필수 행동은 항상 보인다.
- 화면 헤더·과거 날짜·복구 버튼 묶음은 `ViewThatFits`로 좁은 폭에서 세로 배치한다. 상태 안내는 작은 인라인 영역으로 표시해 다른 원문·로컬 기능의 사용을 막지 않는다.

## API와 사용 예

아래 이름은 앱 모듈에서 사용하는 공통 API이며 별도 라이브러리용 `public` 접근 수준을 추가하지 않았다. 예제의 액션·상태 변수는 호출 화면이 제공한다.

### 상태 배지

```swift
enum StatusTone: Equatable { case neutral, info, success, warning, danger }
// StatusTone.color: Color
StatusBadge(label: String, systemImage: String, tone: StatusTone)
// TaskStatus.badgeSymbol: String, TaskStatus.badgeTone: StatusTone
TaskStatusBadge(status: TaskStatus)

StatusBadge(label: "로컬 저장됨", systemImage: "checkmark.circle", tone: .success)
TaskStatusBadge(status: .inProgress)
```

`StatusBadge`는 아이콘+라벨+톤을 제공한다. VoiceOver는 장식 아이콘을 제외하고 라벨을 하나의 요소로 읽는다. 업무 배지는 원본 `status.koreanLabel`을 사용한다. 전체 업무 상태인지 프로젝트별 상태인지는 화면의 주변 제목으로 구분한다.

U에서 배지·칩을 `.caption`, 수평 8pt/수직 3pt 여백의 반투명 캡슐로 정리했다. 배지는 톤의 12%, 칩은 보조 라벨 색의 10% 채움이며 불투명 `surface`를 덧대지 않는다. 라벨은 시스템 기본 텍스트 색을 유지한다. 대비 높이기에서만 2pt 라벨 색 테두리를 표시한다. 여러 줄 라벨과 칩 제거 버튼의 기존 API·접근성 이름을 유지한다. 오늘·프로젝트·업무 상세·검색 근거·빠른 입력 등 기존 호출은 변경 없이 새 스타일을 받는다.

| 상태 | 아이콘 | 톤 |
|---|---|---|
| 예정 | `clock` | neutral |
| 진행 | `arrow.triangle.2.circlepath` | info |
| 보류 | `pause.circle` | warning |
| 완료 | `checkmark.circle` | success |
| 취소 | `xmark.circle` | danger |

### 화면 헤더

```swift
ScreenHeader<Trailing: View>(title: String, purpose: String,
                           @ViewBuilder trailing: () -> Trailing)
ScreenHeader<EmptyView>(title: String, purpose: String)

ScreenHeader(title: "주간보고", purpose: "팀 제출용") {
    Button("보고서 복사", action: copyReport)
}
ScreenHeader(title: "성과자료", purpose: "성과평가용 상세 기록")
```

제목은 `.title2.weight(.semibold)`와 접근성 헤더 특성, 목적 부제는 `.callout`과 시스템 보조 텍스트 색이다. 목적 부제를 생략하지 않는다. 우측 컨트롤은 독립된 접근성 요소를 유지한다.

### 빈 상태·처리·연결 실패

```swift
enum StateView.Kind: Equatable {
    case empty, noResults, loading, offline, aiUnavailable, failure
}
StateView(kind: StateView.Kind, title: String, detail: String,
          actionTitle: String? = nil, action: (() -> Void)? = nil)

StateView(kind: .empty, title: "이 날짜의 기록이 없습니다",
          detail: "메모나 업무 기록을 추가하세요.",
          actionTitle: "기록 추가", action: addRecord)
StateView(kind: .loading, title: "AI 답변 작성 중…",
          detail: "결과 목록은 계속 볼 수 있습니다.")
StateView(kind: .aiUnavailable, title: "AI에 연결되어 있지 않습니다",
          detail: "기록 기반 초안을 사용합니다.",
          actionTitle: "설정에서 연결", action: openSettings)
```

문구와 동작은 호출자가 제공한다. 주요 버튼을 표시하려면 `actionTitle`과 `action`을 함께 전달한다. `.loading`은 시스템 `ProgressView`를 쓰며 제목에 처리 중임을 명시한다. 본문은 하나의 접근성 요소로 읽고 액션은 별도로 접근할 수 있다. 검색 결과 없음에는 필터·철자 안내와 필요 시 필터 초기화를 제공한다. 이 뷰 자체는 네트워크나 AI를 호출하지 않는다.

### 실패 복구 안내

```swift
RecoveryNotice(failed: String, preserved: String,
               retryTitle: String = "다시 시도", retry: @escaping () -> Void,
               dismiss: (() -> Void)? = nil)

RecoveryNotice(failed: "AI 초안 생성 실패", preserved: "기존 본문은 그대로 보존됩니다",
               retry: regenerateDraft)
```

실패 내용·보존 내용·재시도를 함께 보여주는 인라인 경고 박스다. 본문의 접근성 라벨에 실패·보존·재시도 방법 세 문장이 들어간다. 버튼은 별도 요소로 유지한다. 타이머로 사라지지 않으며 복구 성공 또는 사용자의 명시적인 닫기 때 호출자가 제거한다. `dismiss`는 선택 사항이고, 제공한다면 화면에 복구·이력으로 돌아가는 경로를 남긴다. 재시도 진행 중 비활성화와 중복 실행 방지도 화면 책임이다.

### 날짜 기준

```swift
AsOfDateBadge(dateLabel: String)
PastDateBadge(label: String, onReset: () -> Void)

AsOfDateBadge(dateLabel: "10월 4일(일)") // “10월 4일(일) 종료 기준”
PastDateBadge(label: "10월 4일(일)", onReset: resetWorkDate)
// “과거 날짜 · 10월 4일(일)” + [오늘로]
```

두 배지는 시계 아이콘과 warning 톤을 사용한다. `label`에는 포맷된 날짜만 전달한다. `오늘로`는 항상 보이고 VoiceOver에는 “업무일을 오늘로 변경”으로 읽힌다. 날짜 계산·업무 시간대·다음 새 기록의 오늘 초기화는 호출자가 기존 `WorkCalendar`로 처리한다.

### 단축키 발견

```swift
ShortcutLabel(title: String, keys: String)
View.worklogHelp(_ title: String, keys: String? = nil) -> some View

Button(action: saveRecord) { ShortcutLabel(title: "저장", keys: "⌘Return") }
    .worklogHelp("기록 저장", keys: "⌘Return")
```

제목과 키캡을 함께 표시하고 접근성 라벨에도 단축키를 포함한다. `worklogHelp`는 macOS `.help` 툴팁을 “기록 저장 (⌘Return)” 형식으로 만든다. 키보드 단축키를 등록하지는 않으므로 실제 `.keyboardShortcut`·메뉴·패널 키 처리는 화면이 담당한다. Secret 값은 툴팁에 넣지 않는다.

### 요약이 있는 펼침 섹션

```swift
SectionDisclosure<Content: View>(title: String, summary: String,
                               isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content)

SectionDisclosure(title: "프로젝트별 적용 상태", summary: "G 완료 · J 진행 · K 예정",
                  isExpanded: $projectsExpanded) {
    projectStatusRows
}
```

접힌 상태에서만 요약을 보여주며 표준 `DisclosureGroup`과 호출자 바인딩을 사용한다. 표준 키보드 조작을 유지하고 접근성 값에 “펼침”/“접힘”을 제공한다. 그룹 전체를 `children: .ignore`로 감싸지 않아 펼친 콘텐츠의 컨트롤에 접근할 수 있다. 확장 애니메이션은 동작 줄이기 설정을 따른다.

### 프로젝트·태그 칩

```swift
ChipView(label: String, systemImage: String? = nil, onRemove: (() -> Void)? = nil)

ChipView(label: "앱 배포", systemImage: "folder", onRemove: removeProject)
ChipView(label: "회고", systemImage: "number")
```

제거 가능한 값에는 항상 × 버튼을 보여주고 접근성 라벨은 “앱 배포 제거”처럼 이름을 포함한다. 아이콘은 장식으로 숨기고 라벨과 제거 버튼은 독립적으로 접근할 수 있다. `onRemove`를 생략하면 표시 전용이다. 여러 칩의 줄바꿈 배치는 화면이 제공한다.

### Secret 가림 표시

```swift
MaskedValueText()
```

실제 값 문자열을 받는 API가 없다. 화면에는 항상 `••••••`, VoiceOver에는 “가려진 값”만 제공한다. `.accessibilityValue`와 `.help`를 부착하지 않고 `.textSelection(.disabled)`로 텍스트 선택을 막는다. 부모·행·컨테이너도 실제 값을 접근성 라벨/값/힌트/툴팁에 전달하거나 이 뷰를 접근성 값으로 덮어쓰면 안 된다. 이 표시는 Secret 저장 payload가 아니며 실제 값 복사는 기존 명시적인 행 실행 경로가 담당한다.

### 동작 줄이기

```swift
View.worklogAnimation<Value: Equatable>(_ animation: Animation?, value: Value) -> some View

details.worklogAnimation(.easeInOut(duration: 0.16), value: isExpanded)
```

`accessibilityReduceMotion`이 켜지면 `.animation(nil, value:)`를 적용하고 해당 하위 트랜잭션의 애니메이션도 해제한다. 상태 변경·저장·키 입력은 애니메이션 완료에 의존하지 않는다. 시스템 진행 표시는 그대로 표준 `ProgressView`를 사용한다.

## 기존 API 호환성

다음 심볼의 이름·타입·호출 형태를 유지한다. `accent`/`accentSoft`는 현재 시스템 강조색으로 계산하는 `Color` 프로퍼티다.

```swift
WorkLogTheme.cornerRadius: CGFloat // 10
WorkLogTheme.contentInset: CGFloat // 16
WorkLogTheme.cardInset: CGFloat    // 12
WorkLogTheme.accent: Color
WorkLogTheme.accentSoft: Color
WorkLogTheme.canvas: Color
WorkLogTheme.surface: Color
WorkLogTheme.elevated: Color
WorkLogTheme.border: Color
WorkLogTheme.text: Color
WorkLogTheme.muted: Color
View.worklogCard(padding: CGFloat = WorkLogTheme.cardInset) -> some View
WorkLogButtonStyle(prominent: Bool = false) // ButtonStyle
Keycap(_ label: String)                     // View
WorkLogGroupBoxStyle()                      // GroupBoxStyle
WorkLogAppIcon()                            // View
```

경계 처리를 공유하는 추가 API:

```swift
WorkLogTheme.outlineColor(for contrast: ColorSchemeContrast) -> Color
WorkLogTheme.outlineWidth(for contrast: ColorSchemeContrast) -> CGFloat
```

## 사이드바·업무 목록 행 (UXFL-E55A · U)

```swift
WorkLogTheme.rowCornerRadius: CGFloat // 6
WorkLogTheme.rowHeight: CGFloat       // 최소 32
WorkLogTheme.rowHover: Color          // 기본 라벨 색의 5% 채움
WorkLogSourceRowStyle(isSelected: Bool, isFocused: Bool) // ButtonStyle
TaskStatusIcon(status: TaskStatus?)   // 업무 목록용 20pt 영역, 16pt SF Symbol
```

- 일반 행은 투명하고 테두리가 없다. hover는 은은한 채움, 선택은 `accentSoft`와 굵은 업무명/메뉴명, 포커스는 2pt 강조색 윤곽이다. 대비 높이기에서는 선택·포커스 윤곽 모두 기본 라벨 색을 쓴다. hover·선택·누름에서 행 크기는 바뀌지 않는다.
- `AppRootView`의 `WorkLogButtonStyle` 범위를 콘텐츠 영역으로 옮겼다. 사이드바의 빠른 입력은 표준 `.bordered`/`.regular` 버튼이다. 기본·보조 메뉴는 동일한 행 스타일과 한 개 구분선을 쓰며 아이콘 레일에서도 같은 규칙이다. 기본 높이 32pt, 부제가 있는 주간보고·성과자료는 최소 42pt로 시작하고 긴 부제는 줄바꿈한다. 하나의 스크롤 영역으로 작은 창 높이에서도 모든 메뉴에 접근한다.
- `List(selection:)`/`.sidebar`를 검토했으나 기본 강조색 선택과 접힌 레일의 표현을 피하고 지정된 은은한 선택 스타일을 유지하기 위해 사이드바는 네이티브 `Button`과 `FocusState`로 구성했다. Tab/Shift+Tab으로 메뉴에 포커스를 주고 ↑↓로 주·보조 메뉴 사이를 이동하며 Return으로 연다. 포커스 이동은 현재 화면을 바꾸지 않는다. 기존 메뉴의 ⌘1~6 등록 경로는 그대로이며 사이드바 선택은 `controller.route`를 따른다.
- 업무 목록과 프로젝트 업무 표는 `ScrollView`/`LazyVStack`에 명시적 선택을 둔다. 기본 `List`의 진한 전체 폭 강조색 배경을 사용하지 않는다. 목록 전체를 하나의 키보드 포커스 영역으로 두고 행 버튼은 별도 Tab 정지점을 만들지 않는다. Tab 진입 시 선택이 없으면 첫 행을 선택하며 ↑↓로 선택하고 Return으로 상세를 연다. 클릭은 선택, 더블클릭은 상세 열기다. 기존의 눈에 보이는 상세 열기 버튼을 유지한다. 선택 이동 시 스크롤을 따라가고 필터·새로고침 후 사라진 선택을 정리한다.
- 업무 행은 상태 아이콘 → 업무명 → 프로젝트/마감 → 이번 주 칩 순서다. 예정 `circle`, 진행 `circle.lefthalf.filled`, 보류 `pause.circle`, 완료 `checkmark.circle`, 취소 `xmark.circle`, 상태 없음 `questionmark.circle`로 색 외에도 모양을 구분한다. 아이콘 자체에 상태 이름·툴팁이 있고 전체 행의 접근성 라벨에는 업무명·전체 상태·모든 프로젝트명·마감 지남 여부·주간 계획을 포함한다.
- 넓은 폭에서는 한 줄, 보조 정보를 담기 어려운 폭에서는 `ViewThatFits`로 두 줄 이상을 허용한다. 업무명은 한 줄 말줄임하되 전체 이름을 툴팁과 행 접근성 라벨에 남긴다. 프로젝트 업무 표는 전체 상태와 프로젝트 기준 상태를 별도로 유지하며 좁은 폭에서는 각 상태의 제목을 반복 표시한다. 프로젝트 선택 목록과 도메인 계산은 수정하지 않는다.
- 새로운 행에는 이동·선택 애니메이션을 추가하지 않았다. 기존 사이드바 접기·프로젝트 화면 전환의 `worklogAnimation`과 동작 줄이기 처리는 유지한다.

## 검증 및 후속 재현 방법

Linux / Swift 6.3.3에서 가능한 검사는 구문과 정적 검토뿐이다. 아래 구문 검사 통과는 SDK 타입 검사나 macOS 빌드 성공을 뜻하지 않는다.

```sh
swiftc -frontend -parse -target arm64-apple-macos14 Sources/WorkLogApp/*.swift
git diff --check
rg -n 'WorkLogTheme\.|worklogCard|WorkLogButtonStyle|Keycap\(' Sources/WorkLogApp --glob '!AppTheme.swift'
```

Mac에서 가짜 데이터로 다음을 확인해야 한다. 이번 Linux 작업에서는 실행하지 않았다.

1. `swift build --build-tests`로 macOS 14 SDK 기준 공통 API와 후속 화면의 타입 검사·빌드를 수행한다.
2. 라이트/다크 각각에서 시스템 강조색 변경 및 대비 높이기를 켠다. 텍스트·상태 아이콘·경계·주요 버튼의 대비와 사용자 지정 버튼의 포커스 윤곽을 확인한다.
3. 화면의 지원 최소 폭(메인 840pt, 패널 520/580pt 등)과 긴 한국어 문구·글자 확대에서 잘림 없이 헤더·배지·경고·칩이 표시되고 복구 버튼이 보이는지 확인한다.
4. 키보드 탐색 설정을 켠 뒤 Tab/Shift+Tab과 표준 버튼 실행 키로 재시도·닫기·오늘로·제거·펼침을 실행한다. `DisclosureGroup` 확장 상태와 하위 포커스 이동을 확인한다.
5. VoiceOver로 배지 단일 라벨, 헤더, 경고의 세 문장과 별도 버튼, 펼침/접힘 상태, 칩 제거 이름을 읽는다. 가린 Secret은 접근성 Inspector에서도 실제 값·툴팁·선택 가능한 값이 없어야 한다.
6. 동작 줄이기 설정으로 펼침과 호출 화면의 `worklogAnimation`을 확인한다. 정상·기록 없음·검색 결과 없음·처리 중·오프라인·AI 미연결·실패·재시도 각각에서 원문·로컬 기능을 계속 사용할 수 있어야 한다. 복구 안내는 자동으로 사라지지 않아야 한다.

이번 변경은 다른 화면 파일·Core·배포를 수정하지 않는다. 실제 macOS 렌더링·VoiceOver·키보드·글자 확대·대비·동작 줄이기와 화면별 통합 동작은 미검증이다.

### U 검증·Mac 확인 포인트

Linux / Swift 6.3.3에서 전체 앱 파일에 대한 macOS 대상 구문 검사와 `git diff --check`를 통과했다. `rg -n 'StatusBadge\(|TaskStatusBadge\(|ChipView\(' Sources/WorkLogApp`로 오늘·프로젝트·업무 상세·검색 등 공용 호출처를 대조했고 기존 이니셜라이저를 유지했다. Context7에서 Apple SwiftUI 문서의 `FocusState`, `focusable`, `onKeyPress`, `focusEffectDisabled`를 조회했다. 문서는 최신으로 특정 SDK 버전이 고정되어 있지 않으므로 macOS 14 SDK 타입 검사는 Mac에서 별도로 필요하다. 웹/Playwright 화면을 실제 macOS 검증으로 사용하지 않았다.

Mac에서 가짜 업무 데이터(5개 상태, 상태 없음, 긴 한국어 이름, 여러 프로젝트, 마감 지남, 이번 주 계획)로 다음을 확인한다.

1. `swift build --build-tests`로 macOS 14 이상에서 빌드한다. Linux 구문 검사만으로 SwiftUI 타입 검사 성공을 판단하지 않는다.
2. 라이트/다크와 여러 시스템 강조색에서 사이드바 기본·hover·선택, 아이콘 레일, 업무/프로젝트 업무 표의 부드러운 선택을 비교한다. 대비 높이기를 켜면 선택·포커스·배지·칩의 윤곽이 보이는지 확인한다.
3. 키보드 탐색을 켠 뒤 Tab/Shift+Tab으로 사이드바에 진입 → ↑↓로 첫/마지막 메뉴와 구분선을 넘어서 이동 → Return으로 열기 → ⌘1~6으로 이동을 확인한다. 빠른 입력 ⌘N과 콘텐츠 버튼 스타일도 확인한다.
4. 업무와 프로젝트 업무 표에 Tab 진입 → ↑↓(키 반복 포함)로 화면 밖의 행까지 선택 → Return 한 번으로 상세 열기 → 닫기 → 선택·스크롤 복원을 확인한다. 클릭/더블클릭, 선택 상세 버튼, 검색어 변경 후 선택 해제·결과 없음·오류/재시도도 확인한다.
5. 메인 최소 폭 840pt, 프로젝트 상세의 좁은 폭, 작은 창 높이와 긴 이름에서 보조 정보·상태 열 제목·포커스 윤곽이 잘리지 않는지 확인한다. VoiceOver로 전체 이름·전체/프로젝트 상태·마감 지남·이번 주 계획·칩 제거 버튼을 읽고 실행한다.
6. 오늘·업무 상세·검색 근거·빠른 입력에서 긴 배지/제거 가능한 칩이 캡슐 스타일로 자연스럽게 표시되는지 확인한다. 동작 줄이기에서 사이드바 접기와 프로젝트 전환이 즉시 반영되는지 확인한다.

위 Mac 항목과 실제 대비 측정은 이 Linux 작업에서 미실행이다. U는 지정된 `AppRootView.swift`, `TaskListScreen.swift`, `Components.swift`, `AppTheme.swift`, `ProjectsScreen.swift`, 이 문서만 수정했다.
