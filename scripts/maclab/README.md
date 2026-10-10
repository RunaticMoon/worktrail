# Maclab UI 검증

실제 macOS 화면과 키보드 동선을 확인하는 가짜 데이터 전용 도구다. 스크립트가 있다는 사실이나 구문 검사 통과를 GUI 검증 성공으로 간주하지 않는다. 각 실행의 종료 코드, JSON, 스크린샷을 함께 확인한다.

## 준비와 실행

- 기존 Maclab 플러그인 연결, 계정·예산 설정, `.build/maclab` 업로드 허용이 필요하다. 이 도구는 계정이나 예산 설정을 생성·변경하지 않는다.
- 원격 Mac에는 macOS 14 이상, 프로젝트가 요구하는 Swift 도구체인, System Events 자동화·손쉬운 사용 권한이 필요하다. 패키지 의존성 다운로드에는 네트워크가 필요할 수 있다.
- 검토할 소스와 `.maclab/tests/*.json`을 커밋하고 작업 트리를 정리한 뒤 저장소 루트에서 아카이브를 만든다. `after`는 현재 작업 트리를 복사하므로 커밋과 아카이브가 일치해야 한다.

```sh
bash scripts/maclab/package-source.sh
# 다른 비교 기준이 필요하면:
bash scripts/maclab/package-source.sh <baseline-commit> .build/maclab/ui-review.tar
```

기본 기준 커밋은 `2bc2a3e367eaf941f9d88190d56d0d96d3af4440`이다. 아카이브 루트에는 `WorkLogReview.app`, `baseline/`, `after/`, `scripts/maclab/`, `review-build.txt`이 들어간다. 두 버전은 동일한 현재 `UITestFixture.swift`와 시작용 `AppController.swift`를 사용한다. 따라서 기준본은 과거 UI와 동일한 가짜 데이터의 비교용이며, 과거 시작 동작 전체를 그대로 재현하는 빌드는 아니다.

Maclab의 `mac_test_start`에 아래 `test_name`과 검증 목적을 전달한다. 실제 준비·실행 결과는 반환된 run ID로 `mac_test_status`에서 확인한다.

| test_name | 정의 | 자동 실행 범위 |
| --- | --- | --- |
| `ui-review` | [ui-review.json](../../.maclab/tests/ui-review.json) | Before/After 빌드, `many` 데이터, 날짜 화면 크기별·주요 화면 스크린샷, AX 창/컨트롤 범위 점검 |
| `ui-flows` | [ui-flows.json](../../.maclab/tests/ui-flows.json) | After 빌드, Memo 핫키 입력·저장·이전 앱 복귀, ⌘N 입력창 회귀 검사 |
| `ui-edge-cases` | [ui-edge-cases.json](../../.maclab/tests/ui-edge-cases.json) | After 빌드, `empty`·`few`의 세 가지 창 크기와 `many` 화면 비교 |

`ui-review`는 약 960×640, 1280×800, 1440×875pt를 요청한다. 호스트의 화면 작업 영역과 앱 최소 크기에 따라 실제 크기는 달라질 수 있으므로 AX 결과의 실제 frame을 기록한다. 스크린샷 이름만으로 해당 화면이 열렸다고 판단하지 않는다.

모든 정의의 빌드 단계 제한은 단계당 600초이며, 자동 실행 후 수동 확인 시간은 최대 900초다. `exploration.ready=true`일 때 한 번에 한 동작을 실행하고 이전 동작의 완료를 확인한다. `accepted:true`는 접수일 뿐 성공이 아니다. 확인을 마치면 `mac_test_finish`를 요청하고 cleanup·정산 상태도 확인한다.

## 가짜 데이터 격리

아카이브에는 소스·테스트·패키지 정의만 포함하며 로컬 DB, 설정, Keychain, 토큰을 포함하지 않는다. 반드시 DEBUG 리뷰 번들 `dev.worklog.UIReview`를 `--ui-test-fixture empty|few|many`로 실행한다. fixture는 임시 저장 경로, 가짜 인증·암호화 키 저장소, 합성 기록을 사용하며 실제 회사 데이터나 자격증명을 읽지 않는다. Secret에는 AI를 호출하지 않는다. 리뷰 번들은 자동 업데이트 피드도 설정하지 않는다.

Before와 After의 프로세스 이름은 모두 `WorkLogApp`이고 번들 ID도 같다. 한 번에 하나만 실행한다. `--fixture` 옵션과 번들 ID 확인만으로 앱이 격리된 데이터로 시작되었다고 증명할 수는 없으므로 실행 인자를 반드시 확인한다. 워크플로 스크립트는 클립보드를 가짜 문장으로 바꾸고 가짜 데이터에 기록·수정을 남길 수 있다. 기존 초안이나 열린 시트가 있으면 닫거나 새 fixture 프로세스로 시작한다.

원격 Mac에서 아카이브를 푼 디렉터리를 작업 경로로 삼아 직접 실행할 수도 있다.

```sh
bash scripts/maclab/build-remote.sh before
bash scripts/maclab/build-remote.sh after
open -n After.app --args --ui-test-fixture many
```

## 추가 동선 검사

JXA는 **파일 경로로 실행한다**. 특히 `capture-search-flow.js`는 16KB를 넘으므로 실행 도구에 전체 내용을 `osascript -e`로 전달하지 않는다. Maclab `exec`에는 아래 명령을 각각 argv 배열로 전달한다.

```sh
# 같은 fixture 프로세스에서 capture 다음 search를 실행한다.
osascript -l JavaScript scripts/maclab/capture-search-flow.js --action capture
osascript -l JavaScript scripts/maclab/capture-search-flow.js --action search

# 검색 핫키와 별개로 ⌘F 진입 이후 동선만 검증할 때 명시적으로 선택한다.
osascript -l JavaScript scripts/maclab/capture-search-flow.js --action search --search-open command-f

# native AX로 many fixture의 '메모' 결과에서 Down 12회·원문 왕복을 검사한다.
osascript -l JavaScript scripts/maclab/search-roundtrip.js --fixture many

# 기본 Memo·기본 창 크기이며 입력창이 닫힌 상태에서 실행한다.
osascript -l JavaScript scripts/maclab/capture-shortcut.js

# 각 동선은 열린 입력창/시트가 없는 새 many fixture에서 시작한다.
osascript -l JavaScript scripts/maclab/task-flow.js
osascript -l JavaScript scripts/maclab/report-flow.js --fixture many run
osascript -l JavaScript scripts/maclab/secret-flow.js --fixture many

# 크기/탐색만 수행하는 AX 점검 예시
osascript -l JavaScript scripts/maclab/verify-ui.js --phase after --fixture many resize 960 640 2
```

검색 helper는 가짜 Memo를 방향키·Return으로 열고 Esc로 돌아와 검색어·선택·노출된 스크롤 위치를 비교한다. `command-f` 모드는 `entryMethod`로 구분되며 전역 검색 핫키 성공을 뜻하지 않는다. ⌘N helper는 660×500 입력창, 본문 포커스, 추가 주 창이 생기지 않았는지를 확인하고 스크린샷을 위해 입력창을 열어 둔다. 다음 동선 전에 Esc로 닫는다.

`search-roundtrip.js`는 System Events의 결과 탐색 문제를 피하도록 native AX로 검색어·선택·원문 시트를 검사한다. 실제 Mac에서 동일한 native AX 왕복 동작은 확인했지만, 저장된 이 파일 전체의 재실행은 아직 미검증이다. 검색어와 선택 보존만 판정하며 수치 스크롤 위치 보존을 주장하지 않는다. 기존 검색어가 비어 있거나 가짜 검색어 `메모`일 때만 입력을 진행한다.

Task는 가짜 진행 기록 추가, 보고서는 편집·저장·계획 확인·복사, Secret은 검색·복사·부분 편집을 검사한다. 자동 spec에 포함된 동선과 수동으로 실행한 helper 결과를 따로 기록한다. 단계별 실행 옵션은 각 파일 상단에 있다.

## 결과 해석과 한계

- 성공 출력은 JSON의 불리언, 단계명, 창 크기·좌표 등이다. 원문, Secret 값, 클립보드 내용을 출력하지 않는다. `null`인 측정값은 검증 불가능을 뜻하며 통과로 세지 않는다.
- 실패하면 비정상 종료와 내용이 제거된 오류 또는 JSON이 반환된다. `stage`, 실패한 assertion, 포커스·창 존재 여부를 먼저 보고 같은 시점의 스크린샷을 확인한다. 타임아웃은 UI 결함, 권한, 포커스, 잘못된 실행 상태를 추가로 구분해야 한다.
- `verify-ui.js`는 스크롤 내부 잘림·겹침·실제 조작 가능성을 모두 검사하지 않는다. 실제 화면에서 긴 한국어, 다중 프로젝트, 여러 줄 Memo, 많은 Secret key와 접근 가능한 버튼을 확인한다.
- 고유 검색어 하나로는 많은 결과에서의 0이 아닌 스크롤 위치 보존을 충분히 검증할 수 없다. 한글 IME 조합, 실행 재시작 후 초안 보존, Undo 및 모든 화면×창 크기×데이터 수 조합은 별도 확인이 필요하다.
- `empty`·`few`·`many` 실행 결과와 화면 전후 비교를 각각 남긴다. 구문 검사, 빌드, 창 존재 assertion만 통과한 항목을 실제 전체 동선 통과로 보고하지 않는다.
