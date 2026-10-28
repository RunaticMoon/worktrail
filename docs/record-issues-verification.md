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

따라서 화면·키보드·IME 검증 성공으로 보고하지 않는다. 정상 GUI 세션에서 메모 날짜/분류 저장과 미저장 확인, 근거 재검토, 두 초안의 앱 종료/재실행 복구, 확정 리포트 수정/실패/취소, 메인·핫키 검색 더 보기/포커스 복귀, 한국어 조합 중 단축키를 재검증해야 한다. 성능 수치와 GUI 응답성을 구분한다.
