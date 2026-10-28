# 업무 편집·이력·계획·필터 이슈 검증 (2026-10-28)

대상: #32, #33, #34, #35, #36. 구현 커밋: `b7aaf111e6db02dc26c0d70daac969cca0059205`. #32의 빠른 입력 마감·알림 DisclosureGroup은 기록 담당 커밋 `9a02387`에 포함된다.

## 수용 조건과 구현

| 이슈 | 구현 및 회귀 검증 |
| --- | --- |
| #32 업무 속성·마감 편집 | 업무명·마감·알림·프로젝트·태그를 한 트랜잭션으로 저장하고 같은 ID·상태 이력·프로젝트 상태를 유지한다. 검색 색인 갱신, 저장 실패 rollback과 입력 유지, 변경한 마감일의 계획 후보 재생성, 확정 계획 보존, DB 재열기 지속성을 검증했다. |
| #33 실제 업무일·상태 정정 | 실제 업무일을 활동·Task·프로젝트·체크리스트 상태 변경에 적용한다. 기록 시각은 Clock의 현재 시각을 유지한다. 정정은 원래 사건, 무효화 사건, 대체 사건을 함께 남기며 이후 상태 전이와 충돌하면 구체적인 이유를 표시하고 저장을 막는다. 같은 날 순서·완료/재개 반복·knownAt·DayBox/보고 근거·원자성·확정 스냅샷 보존을 검증했다. |
| #34 제외한 계획 복원 | Task 전체·프로젝트·체크리스트 범위의 제외 항목을 같은 ID·범위·문구로 후보 복원한다. 확정 시각은 지우고 업무 상태는 바꾸지 않는다. 직접 재추가도 중복을 만들지 않고 제외 항목을 복원한다. |
| #35 체크리스트 관리 | 내용·프로젝트 적용 범위 편집, 삭제와 실행 취소, 끌기 및 메뉴/키보드 순서 이동을 제공한다. 완료 사건을 새로 만들지 않고 원래 ID·완료일·보고서 스냅샷을 보존한다. 연결되지 않은 프로젝트 적용을 거절하며 실패 시 전체 변경을 되돌린다. |
| #36 실행 필터 | 전체·오늘 마감·마감 지남·이번 주 계획·마감 없음과 별도 상태 조건을 조합한다. 실행 조건은 기본적으로 완료/취소를 제외하며 예정·진행 조건으로 보류도 제외할 수 있다. 조건별 건수, 초기화, 검색/프로젝트와 조합, 부분 계획 범위 표시, KST 자정 경계를 검증했다. |

## 빌드와 자동 테스트

Apple Silicon macOS에서 실제 사용한 도구체인은 Swift 6.4 / Xcode 27.1 / macOS 27 SDK, Swift 5 언어 모드다. 지정된 Swift 6.3 또는 Linux 실행 결과로 보고하지 않는다.

```sh
swift build --build-tests
swift test --filter 'TaskEditingWorkflowTests|TaskServiceTests|TaskDueReminderTests|TaskProjectUXTests|WeekPlanTests|PresentationTests|SearchTaskIndexTests|ReportsPlanPresentationTests'
```

- macOS 앱을 포함한 빌드 성공. 최종 로그 `/tmp/worktrail-todos-final-build.log`.
- 관련 133개 테스트, 실패 0개. 종료 시각 2026-10-28 20:26:49 KST. 로그 `/tmp/worktrail-todos-verified.log`.
- 신규 `TaskEditingWorkflowTests` 13개 포함. 실패 주입, DB 재열기, 과거 knownAt, 상태 이력 정정과 보고서 근거 등 도메인 동작을 검증한다.
- `git diff --check` 성공. 기존 UndoManager actor-isolation 및 sqlite3 pkg-config 경고가 있으나 빌드 오류는 없었다.

## 실제 macOS fixture 화면·키보드 검증

운영 데이터와 분리된 `/tmp/worktrail-todos-review/TaskReview.app`를 ad-hoc 서명하고 bundle ID `dev.worklog.TodoReview`, `--ui-test-fixture many`로 실행했다. 실행 PID는 `97122`였으며 검증 종료 후 해당 프로세스만 종료했다. 앱 바이너리는 TODO 구현 커밋의 Debug 빌드다. 테스트 데이터의 오늘은 2026-10-10이다. 실제 자격증명·Keychain·녹음·AI 연결을 사용하지 않았다.

보조 스크립트 `/tmp/worktrail-todos-review/todos.js`는 저장소의 `scripts/maclab/workflow-enhancements-check.js`를 임시 복사하여 TODO 동작을 추가했다. 입력 전 PID·bundle ID·임시 앱 경로·fixture 실행 인자·foreground·console session을 검사한다. 화면은 물리 픽셀 1920×1300으로 캡처됐다. 다음 순서로 실제 AX와 키보드/포인터 입력을 실행했다.

```sh
osascript -l JavaScript /tmp/worktrail-todos-review/todos.js --pid 97122 --action todos
osascript -l JavaScript /tmp/worktrail-todos-review/todos.js --pid 97122 --action todoOpen
osascript -l JavaScript /tmp/worktrail-todos-review/todos.js --pid 97122 --action todoChecklist
osascript -l JavaScript /tmp/worktrail-todos-review/todos.js --pid 97122 --action todoHistory
osascript -l JavaScript /tmp/worktrail-todos-review/todos.js --pid 97122 --action todoPlanOpen
osascript -l JavaScript /tmp/worktrail-todos-review/todos.js --pid 97122 --action todoPlanRestore
```

각 action은 상태를 변경하므로 신규 fixture에서 위 순서로 실행해야 한다. 첫 `todos` 시도는 비동기 렌더링 전에 검사하여 `filterResetOffered` assertion이 실패했다. 렌더링 완료를 기다리는 검사로 바꾼 뒤 모든 위 action이 `ok:true`로 끝났다.

확인한 동작:

- 실행/상태 필터의 접근성 요소, 오늘 마감 선택, 필터 초기화 표시와 실행.
- 한국어 검색어 붙여넣기 → 아래 화살표/Return으로 상세 열기 → 상세 닫은 뒤 검색 조건 유지.
- 업무 정보 편집에서 Tab 포커스 이동, Escape 취소 시 원래 제목 유지, Cmd+Return 저장 후 변경 제목 반영.
- 완료된 체크리스트 내용 수정 후 완료 상태 유지, 아래로 이동 메뉴 실행, 삭제 후 사라짐, 실행 취소 후 원래 완료 상태로 복원.
- 기존 체크리스트 완료 이력의 정정 시트, 실제 업무일 컨트롤, 충돌 없음 표시, 정정 사유 입력과 Cmd+Return 저장. 저장 후 원래 기록 보존·대체 사건·정정 사유가 접근성 트리에 모두 남았다.
- 주간보고의 계획 검토에서 기존 계획 제외 → 제외한 항목 펼치기 → 후보로 되돌리기 → 복원 안내 및 제외 목록에서 제거. 계획 컨트롤은 AX로 조작했으며 당시 스크롤 밖에 있었다.

캡처: `/tmp/worktrail-todos-review/todo-detail.png`, `todo-properties-saved.png`, `todo-checklist-history.png`, `todo-history-correction.png`, `todo-plan-restored.png`. 상세 화면과 정정 시트를 직접 시각 검사하여 제목 줄바꿈·표준 컨트롤·저장 버튼의 표시를 확인했다. 계획 캡처는 스크롤 위치상 본문 보고서만 보여주므로 복원 UI의 시각 증거로 사용하지 않는다.

초기 GUI 접근 시 AX 창/foreground 실패가 있었으나 후속 실행에서는 `onConsole=true`, `loginDone=true`, `AXIsProcessTrusted=true`, lock 필드는 undefined, fixture foreground=true였다. 화면 잠금이 지속되었다고 판단하지 않는다.

## 검증 범위의 한계

- 한국어 문자열 붙여넣기와 Tab/Return/Escape/Cmd+Return은 확인했으나 실제 한국어 IME 조합 중 단축키 입력은 실행하지 않았다.
- 접근성 컨트롤을 확인했으나 VoiceOver 음성 읽기와 끌어서 순서 이동은 실행하지 않았다. 순서 이동 메뉴와 Core 저장 결과는 확인했다.
- 실제 업무일 DatePicker 조작 및 정정 충돌 차단의 GUI 경로는 추가로 실행하지 않았다. 선택 날짜의 모든 범위 전파와 충돌/rollback은 자동 테스트로 검증했다.
- 빠른 입력의 마감·알림 DisclosureGroup은 기록 담당 통합 변경이므로 이 TODO 단독 바이너리 GUI 검증 대상에서 제외했다.
- 이 문서는 개별 TODO 브랜치 결과이며 최종 통합 빌드/전체 테스트와 운영 배포 확인을 대체하지 않는다.

## 추가 아카이브 검토 및 회귀 검증

통합 브랜치의 `MeetingArchiveService.swift`, `MeetingArchiveTests.swift`를 담당 범위로 직접 보완했다. manifest의 missingTrackIDs 정확한 차집합, 선택 프로젝트/태그만의 이름·보관상태 snapshot, 빈 저장소 import와 기존 분류 ID/이름 충돌 매핑, 원래 없는 분류 유지, 분류 생성 포함 DB rollback, 구버전 snapshot 호환, 미리보기 이후 변경 검출, 원본 파일 부재와 검증 오류 구분, 기존 임시 디렉터리 보존을 처리했다.

`swift test --filter MeetingArchiveTests`: 14개 통과, 실패 0개(2026-10-28 20:34:13 KST). 로그 `/tmp/worktrail-archive-review-tests-final.log`. 이 테스트 수에는 기존 통합 테스트 6개와 추가 회귀 8개가 포함된다. export의 `expectedPreview` UI 전달은 통합 담당이 별도로 연결했다.
