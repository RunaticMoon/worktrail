# 기록·초안·검색 이슈 검증 (2026-10-28)

대상: #28, #29, #30, #31, #37. #32와 겹치는 빠른 입력 마감·알림 펼침 UI도 포함한다.

## 구현

- 메모의 본문·업무일·프로젝트·태그는 한 트랜잭션으로 저장한다. revision 충돌을 검출하며 원래 기록 시각·ID·수동 관련 연결을 유지한다. v10은 과거 분류와 수정 시각을 추가로 저장한다. 업그레이드 이전 revision의 알 수 없는 분류는 미기록으로 표시한다.
- AI 없이 기존 업무를 검색하고 확인한 뒤 보고서 근거로 승인할 수 있다. 기존 승인·거절을 다시 검토하고 해제할 수 있으며, 승인 당시 revision과 현재 revision 차이를 표시한다. 일반 관련 링크는 별도 관계로 남긴다.
- 메모·업무 초안을 각각 `capture-drafts/memo.json`, `task.json`에 350ms 지연 후 원자적으로 저장한다. 파일은 0600, 폴더는 0700이며 일반 초안 전용 타입에 Secret 필드가 없다. 앱 시작은 초안만 복구하고 업무를 실행하지 않는다. 종료 직전 flush 실패는 종료를 취소한다.
- 확정 리포트는 명시적인 ‘이 본문으로 새 수정본 만들기’로 편집한다. 저장할 때 기존 근거·생성 정보를 복사하는 Core 경로를 사용하며, 변경 없는 닫기와 취소는 버전을 생성하지 않는다.
- 로컬 검색은 50건과 `hasMore`를 제공한다. 더 보기(⇧⌘M)는 표시 범위를 늘려 다시 조회하므로 삭제·수정에 따른 offset 이동으로 중복되거나 빠지는 기록을 방지한다. 동률은 날짜·ID·유형 순으로 안정 정렬한다. 메인과 핫키 화면이 각각 표시 범위와 검색 조건을 보존한다.

## 실행 결과

호스트: Apple Silicon, macOS 27.0.1, Swift 6.4, macOS 27 SDK, Swift 5 언어 모드. 저장소가 지정한 Swift 6.3에서의 검증 결과와 구분한다.

- `swift build --build-tests -j 4`: 성공. 기존 CaptureTextEditor의 UndoManager actor-isolation 경고와 sqlite3 pkg-config 경고가 출력됐다.
- 추가 `RecordIssueRegressionTests`: 10개 통과. 메모 저장 실패/충돌·이력·검색 재색인, AI 없는 근거 재결정과 그래프, 두 초안 복구·독립 삭제·손상 격리·종료 flush 실패 재시도·중단된 임시 파일·debounce, 확정본 수정 분기, 검색 0/49/50/51/120건과 수정 후 페이지 복원을 다룬다.
- 전체 테스트 최초 실행: 1,043개 중 기존 `PresentationTests.testInvalidCaptureRetainsDraftAndActivityRequiresTarget`의 assertion 2개 실패. 새로 만든 업무가 후보 캐시에 없을 때 유효하지 않다고 판단하는 문제를 발견했다. 제출 직전 후보를 다시 조회하도록 수정했다.
- 수정 후 관련 테스트 (`PresentationTests|RecordIssueRegressionTests|Capture|Search|MemoLink|Reports|ReportStoreTests|WorkRepositoryTests|GraphRecordReaderTests`): 268개, 실패 0개.

5,000건 fixture 검색 측정(첫 추가 테스트 실행, Debug, 실제 wall-clock):

| 경로 | 첫 50건 | 다음 50건 | 표시 범위 100건 재조회 |
| --- | ---: | ---: | ---: |
| 한 글자 한국어 LIKE | 2.246ms | 2.125ms | 3.068ms |
| 두 글자 한국어 LIKE | 2.080ms | 2.138ms | 3.049ms |
| 세 글자 한국어 FTS | 2.072ms | 2.090ms | 3.014ms |

이는 Core 검색 함수 측정이며 실제 GUI 프레임 정지 여부를 증명하지 않는다.

## 실제 macOS 화면 검증 시도와 남은 확인

운영 데이터와 다른 `/tmp/WorkLogUIReview-records/RecordsReview.app`를 ad-hoc 서명하고 `--ui-test-fixture many`로 실행했다. Keychain·실제 회사 자격증명·AI 계정은 사용하지 않았다.

- `scripts/maclab/search-roundtrip.js --fixture many`: `REVIEW_WINDOW_MISSING`. fixture 재실행 후에는 `TEXTEDIT_NOT_ACTIVE`로 중단됐다.
- `scripts/maclab/report-flow.js --fixture many inspect`: `REVIEW_MAIN_WINDOW_NOT_FOUND`로 중단됐다.
- AX 권한 검사에서는 `AXIsProcessTrusted=true`였지만, 해당 fixture 프로세스의 AXWindows가 빈 배열 또는 AXWindow 대신 AXApplication 자신을 반환했다. Swift ApplicationServices로 직접 조회해도 동일했다.

이 최초 실행은 화면·키보드·IME 검증 성공으로 세지 않는다. 같은 날 정상 GUI 세션에서 다시 실행한 결과는 아래에 구분한다. Core 성능 수치와 GUI 응답성은 서로 다른 검증이다.

## 제출 완료 receipt 보완 검증

성공적으로 저장한 뒤 checkpoint 파일 갱신이 실패하면 오래된 파일이 다음 실행에서 미저장 초안으로 다시 나타날 수 있었다. v12 `capture_draft_receipt`를 도입하여 일반 기록과 제출 receipt를 같은 트랜잭션에 저장한다. receipt 쓰기 실패는 기록·링크·검색 색인까지 롤백하고 입력·선택·완료 확인을 복원한다. 파일 갱신만 실패한 경우에는 기록 저장 성공을 명확히 알린다.

- 일반 메모·업무 checkpoint의 optional `draftID`를 사용한다. 구형 파일은 유형과 정규 JSON 해시로 안정적인 식별자를 얻으므로 업그레이드 파일 쓰기가 실패해도 중복 제출을 막는다.
- 상태만 변경하거나 완료 확인할 때 사용하지 않은 본문·분류는 새 식별자의 후속 checkpoint로 receipt에 남긴다. 복원은 이미 제출된 단계들을 따라 남은 초안만 복원하며 순환·128단계 제한·JSON/버전 손상을 검출한다. Secret 경로는 receipt를 생성하지 않는다.
- `swift test -j 4 --filter CaptureDraftReceiptTests`: 최종 8개, 실패 0개. 별도 `AppEnvironment`/DB 연결 재열기, 실제 파일 경로 오류, receipt INSERT 강제 실패, 진행 기록, 직접 `confirmCompletion()` 경로, 남는 초안 체인, 구형 파일, 손상 방어, Secret 무동작을 검증했다. 저장 직후 패널이 날짜를 초기화해도 성공/파일 오류 안내가 구분됨을 확인했다.
- 관련 `CaptureDraftReceiptTests|CaptureSessionTests|CaptureNewDraftTests|CaptureReopenTests|QuickTaskCaptureTests|CaptureUXTests|RecordIssueRegressionTests`: 80개, 실패 0개. 이후 안내 문구·DB 재열기 확인을 추가한 최종 focused 8개도 통과했다.
- 로그: `/tmp/worktrail-capture-receipts-final.log`, `/tmp/worktrail-capture-receipts-regression.log`. 최초 focused 실행의 한 실패는 생성일보다 이전 날짜의 상태 변경을 요청한 테스트 fixture 오류였으며, 날짜를 바로잡고 재실행했다.

## 정상 GUI 세션 재검증

같은 `/tmp/WorkLogUIReview-records/RecordsReview.app`의 실행파일을 통합 Debug 빌드로 교체하고 ad-hoc 서명 후 `--ui-test-fixture many`로 새 실행했다. PID 2239, 번들 `dev.worklog.UIReview`, 가짜 실행 인자·임시 경로·잠금 해제된 콘솔·AX 권한·전면 앱을 검사했다. 회사 데이터·Keychain·실제 AI 계정·마이크를 사용하지 않았다. 검증 후 프로세스를 종료하고 `ps`에서 사라진 것을 확인했다.

조작은 native AX, 포인터 클릭, 실제 키 이벤트(⌘S/⇧⌘M/↓/Return/Esc), 합성 텍스트 붙여넣기를 사용했다. 다음은 화면과 AX 값으로 확인한 결과다.

- 메모: 본문, 실제 업무일(10월 10일→9일), 프로젝트 2개, 태그 2개를 편집했다. 미저장 닫기 확인에서 계속 편집한 뒤 내용이 유지되었고 ⌘S 후 revision 2, 수정 날짜·분류, 원래 기록 시각, revision 1의 이전 날짜·분류가 표시됐다.
- 근거: AI 비활성 상태에서 기존 가짜 업무 검색→명시적 근거 승인→승인 상태→다시 검토/해제→거절 상태를 확인했다.
- 보고서: 주간보고와 성과자료 각각 v1 확정 후 ‘이 본문으로 새 수정본 만들기’로 진입했다. 수정 후 되돌리면 원문과 확정본이 유지됐고, 다시 수정하여 ⌘S를 누르면 v2 수정본과 변경한 본문이 표시됐다.
- 검색: 기록 범위의 합성 검색어에서 50건/더 있음→⇧⌘M→100건/더 있음→136건/전체를 확인했다. ↓ 56회로 첫 페이지를 넘는 메모 32를 선택해 Return으로 저장된 원문을 열었다. 닫은 뒤 검색어, 136건 표시, 선택된 메모 32가 유지됐다. 전역 검색 핫키로 연 패널은 처음 50건을 표시하여 메인의 136건 범위와 구분됐다.

일부 AXPress가 화면 전환을 수행하고도 `-25200`을 반환해 초기 helper 실행이 중단됐다. 재실행에서는 실제 편집기·본문·버전·선택 상태를 별도 assertion으로 확인했다. 검색 원문 화면을 메모 편집 화면으로 오인한 assertion도 바로잡고 `저장된 원문` 표시와 닫은 후 상태를 확인했다. 이 helper 실패를 기능 성공으로 바꾸어 세지 않고 후속 상태 검증 결과를 기록한다.

증거는 `/tmp/WorkLogUIReview-records/`에 보존했다.

| 파일 | 확인 내용 |
| --- | --- |
| `memo-finish-result.json`, `memo-metadata-saved-history.png` | 날짜·분류 저장, 미저장 확인 후 내용 보존, revision 이력 |
| `evidence-choose.json`, `evidence-release-result.json` | 근거 승인 확인과 해제 |
| `report-revision-result.json`, `performance-revision-result.json` | 두 종류 보고서 수정 취소/저장 및 v2 생성 |
| `report-confirmed-new-revision.png` | 성과자료 v2 수정본 화면 |
| `search-loaded-beyond-first50.png`, `search-roundtrip-result.json`, `search-paging-roundtrip.png` | 136건 표시, 메모 32 원문 왕복과 선택 보존 |
| `search-panel-result.json`, `search-panel-open.png` | 전역 검색 패널 진입과 독립된 초기 50건 |

실행파일 SHA256: `848f656ddb4510cbe6aaed11eefbd86eb433e36b971ba37d47567f859252989c`.
임시 helper `records.js` SHA256: `960343d3995fd382a1bf95e88bb638259f0d38561bc31ddb4e4eb4ec7a42bfa1`.

이번 GUI 재검증은 한 기본 창 크기와 합성 데이터에서 수행했다. 한국어 IME 조합 중 단축키, VoiceOver, 모든 크기 조합, 실제 앱 프로세스 강제 종료/재시작에 따른 초안 복원, GUI에서의 저장 실패 주입, 전역 패널 자체의 더보기/이전 외부 앱 포커스 복귀는 미검증이다. 초안의 저장/복원/실패 원자성 및 보고서 저장 실패 보존은 위 Core 테스트로 별도 확인했다.
