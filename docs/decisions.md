# 기술 결정 기록

| ID | 결정 | 이유 |
|---|---|---|
| T01 | 문서 제안 스택(Swift/SwiftUI + AppKit 브리지 + SQLite)을 유지 | 제품 요구(네이티브 Mac, 로컬 우선)와 일치. 변경 사유 없음 |
| T02 | 로직은 플랫폼 공통 `WorkLogCore` 라이브러리, UI는 macOS 전용 타깃으로 분리 | 개발 환경이 Linux여서 macOS 없이도 도메인·저장·보안 로직을 실제 빌드·테스트하기 위함 |
| T03 | Xcode 프로젝트 대신 SwiftPM + `.app` 번들 스크립트 | Xcode가 없는 환경에서 생성·검증 가능한 형식. macOS에서 `swift build` 후 번들링 |
| T04 | CryptoKit 대신 `swift-crypto`의 `Crypto` 모듈 사용 | Apple 플랫폼에서는 CryptoKit을 그대로 재노출하고, Linux에서 같은 AES.GCM API로 테스트 가능. 자체 암호 구현 없음 |
| T05 | SQLite C API를 직접 쓰는 얇은 래퍼(`SQLiteDatabase`), 외부 ORM 없음 | 의존성 최소화, Online Backup API·FTS5 직접 사용 |
| T06 | 날짜는 `WorkDate`(지역 달력 날짜) 타입, 기간은 `[start, endExclusive)` | 날짜만 아는 사건에 시각을 만들지 않기 위함(DAY-02) |
| T07 | 상태 이력은 append-only `domain_event` + 재생, 정정은 `voided` 사건 | 늦은 입력·과거 상태 조회·확정본 재현(DAY-03) |
| T08 | 확정 리포트 버전은 DB 트리거로 UPDATE/DELETE 차단 | 자동 작업이 확정본을 덮어쓰지 못하게 저장소 수준에서 보장(PERF-04) |
| T09 | macOS 최소 버전 14 (제안값) | SwiftUI 최신 API 사용. macOS에서 실제 빌드 검증 전까지 미확정 |
| T10 | AI는 공식 `codex app-server`(stdio JSON-RPC)만 사용, 설치된 codex-cli 0.159.2의 `generate-json-schema` 결과로 메서드·필드 확인 | 01 지시(토큰 추출·API 키 대체 금지). 실제 Enterprise 계정 연결은 미검증 |
| T11 | AI 작업은 `ai_job` 영속 + idempotency key(작업·기간·입력 digest·템플릿 버전·스킬 해시·재생성 nonce), 동시성 1 FIFO | 자동 작업 중복 실행·중복 저장 방지(PERF-05), 회사 한도 보호 |
| T12 | AI 입력 차단(`AIPayloadGuard`: vault·백업 경로)과 출력 검사(`AIOutputGuard`: 인증 정보 흔적·차단 경로) | read-only sandbox도 로컬 읽기는 허용하므로 프롬프트 인젝션으로 인증 정보가 work.sqlite·백업에 저장되는 경로를 차단. 정상 기록의 같은 단어는 오탐 가능 → 결정적 초안 대체 |
| T13 | 검색은 SQLite FTS5 `trigram` + 3자 미만 질의는 LIKE | 한국어 부분 일치를 형태소 분석기 없이 처리 |
| T14 | Secret 키는 Keychain `WhenUnlockedThisDeviceOnly`, 백업에는 암호문만 | 키 유출 범위 최소화. 대가로 Secret 복원은 같은 Mac에서만 가능(다른 Mac 이전 미지원) |
| T15 | 개발용 CLI 로직을 `WorkLogCore/CLI`에 두고 `worklog`는 얇은 진입점 | Linux에서 사용자 여정을 테스트·시연하기 위함. CLI는 데이터 경로 지정 필수, AI·Secret 명령 없음 |
| T16 | 기본 프롬프트 템플릿 버전은 DB 트리거로 불변(migration v3), 변경은 새 버전 | 과거 리포트가 어떤 지침으로 만들어졌는지 재현 |
| T17 | `codex` 탐색: 설정 경로 → PATH → `/opt/homebrew/bin`, `/usr/local/bin` | Finder로 실행한 앱은 로그인 셸 PATH를 물려받지 않음(실제 Mac 미검증) |
| T18 | `.app`은 `scripts/build-macos-app.sh`로 만들고 ad-hoc 서명 | T03 유지. 배포 서명·공증은 범위 밖 |
| T19 | 앱 시작 catch-up은 `max(가장 이른 기록일, 오늘-92일)`부터, AI는 최근 7일 예약 작업에만 사용 | 오래 쓰지 않던 앱을 열었을 때 수백 건의 리포트·회사 AI 호출이 한꺼번에 생기지 않게 하기 위함. 그보다 오래된 기간은 결정적 초안만 만들고 필요하면 사용자가 다시 생성 |
| T20 | 빠른 입력 키: Return 줄바꿈 · ⌘Return 저장 · Esc 초안 보존 후 닫기, 한글 IME 조합 중에는 저장하지 않음 | 02 사양 CAP-02 그대로. 기본 입력 유형이 Secret이면 일반 입력창 대신 메인 창 Secret 화면으로 연결(Secret 값이 일반 기록 경로에 들어가지 않게). 이 경로는 CAP-01의 "저장 후 이전 앱 복귀"를 적용하지 않음(메인 창 편집 흐름). **T25에서 변경됨**: 기본 입력 유형이 Secret이어도 패널의 시크릿 탭에서 기존 Secret 편집기를 그대로 쓴다(일반 기록 경로와의 격리는 유지). 메인 창을 강제로 여는 우회는 제거 대상이며, 메인 Secret 화면의 Tab 셀 이동은 유지한다 |
| T21 | 결정적 초안(AI 미사용)은 `template_version_id`를 기록하지 않음 | 프롬프트 템플릿은 AI 지시문이며 결정적 초안은 코드 컴포저(`generator: deterministic`)가 만든다. AI 초안 버전에만 템플릿 버전·스킬 해시를 기록 |
| T22 | AI 출력 줄은 바이트 단위로 모아 줄바꿈에서만 UTF-8 해석 | 파이프 수신 단위가 한글 등 멀티바이트 문자 중간에서 잘려도 응답이 사라지지 않게 하기 위함(독립 검증 AO 재현 결함) |
| T23 | 백업 DB 사본은 DELETE 저널(단일 파일)로 저장하고, 복원 시 대상의 `-wal`/`-shm`은 DB와 함께 옮겨 두었다가 실패하면 되돌림 | macOS 시스템 SQLite는 읽기 전용 연결로 WAL DB를 열지 못하고(macOS CI에서 확인), 닫힌 뒤에도 `-wal`/`-shm`을 남긴다. 복원된 DB는 앱이 읽기·쓰기로 열 때 다시 WAL이 된다 |
| T24 | 릴리즈는 `VERSION` 파일을 버전 원본으로, 수동 `macos-release.yml`이 태그 `v<VERSION>` 검사 후 ad-hoc 서명 `WorkLog-<VERSION>-arm64.dmg`와 SHA-256 manifest를 만들어 draft 업로드·재다운로드 비교·선택적 공개 | 사용자 요청(pr-context-explorer 참고). Apple Developer 계정이 없어 서명·공증 없이 배포하며 첫 실행 승인이 필요함을 문서·릴리즈 노트에 명시. arm64 전용(macos-15 러너) |
| T25 | 빠른 입력 패널을 메모·업무·시크릿 세 탭으로 두고 `CaptureSessionModel`이 현재 탭과 두 일반 초안(`CaptureModel`)을 관리한다. Tab/Shift+Tab은 **패널 안에서만** 탭을 순환하고, Option+Tab/Shift+Option+Tab은 필드를 이동한다. IME 조합 중 Tab·Return·Esc는 입력기에 먼저 전달해 탭 변경·저장·닫기를 하지 않는다. Return은 줄바꿈, ⌘Return은 활성 탭 저장, Esc는 초안 보존 후 닫기. 업무 탭은 검색어와 무관하게 `+ New task`를 맨 위에 두고 기존 업무는 진행기록 추가(`addActivity`)와 상태 변경(`changeStatus`)을 명시적으로 구분하며 한 번에 둘 다 하지 않는다. 완료는 `completeTask`의 남은 체크리스트·프로젝트 확인을 건너뛰지 않는다. 기본 입력 유형은 새 세션 시작 탭에만 적용하고 탭 전환으로 설정을 바꾸지 않는다. 시크릿 탭은 기존 `SecretEditorView`를 재사용하고 `SecretsModel`의 `SecretEditorHost.main/.capture` 소유권으로 메인 화면과 동시 편집을 막는다(소유권 전환은 초안을 폐기하지 않음) | 진행기록을 별도 탭으로 두지 않아도 업무 탭에서 생성·검색·상태 변경을 처리할 수 있다. 별도 Secret 모델을 만들면 정규화·암호화 초안·잠금·복구가 중복되므로 기존 편집기를 재사용하되 값은 일반 기록·그래프·AI에 넣지 않는다. 제품 사양의 "Secret 표 Tab 셀 이동"과 패널 Tab 순환이 충돌하므로 패널에만 예외를 두고 메인 Secret 화면은 기존 Tab 셀 이동을 유지한다(T20 변경됨) |
| T26 | 일반 기록 간 수동 관련 연결은 새 `record_link` 테이블(v4)에 **무방향**으로 저장한다. 종류는 memo/task/activity/report_version만 허용하고 Secret은 후보·참조 타입·SQL 어디에도 넣지 않는다. 원본 생성과 링크는 `LinkedCaptureService`가 하나의 트랜잭션으로 저장하고(중첩은 SAVEPOINT), 링크 대상이 없거나 자기 연결이면 원본·FTS·링크를 모두 롤백한다. 수동 연결은 보고서 근거 승인(`memo_task_link.accepted`)·업무 완료·AI 근거와 다른 의미이며 그래프에서 `manualRelated` 엣지로 구분한다. 그래프는 `GraphService`가 기존 관계(`GraphRecordReader`)·리포트 근거(`GraphEvidenceReader`)·수동 링크를 병합하고, `GraphLayout`이 정렬·고정 반복으로 결정적 좌표를 계산한다. 공유 태그는 직접 엣지가 아니라 태그 노드를 경유한다. 리포트 근거는 스냅샷·revision 기준(`report:<versionId>`)이며 삭제된 근거는 `historicalSource`로 보존한다. 노드 상한은 250이고 잘림 여부를 표시한다. **범위 조정**: 리포트 생성 시 수동 연결 선택(작업 K/L/M/AF)은 이번 범위에서 제외한다. 리포트는 기존 근거 엣지로 그래프에 연결되고, 메모·업무 생성 시 리포트 버전을 관련 기록으로 선택할 수 있다 | 수동 연결과 확정 근거의 의미를 합치지 않아 근거 재현성이 유지된다. 태그를 경유해 관계 수의 제곱 증가를 피하고, Secret은 타입·SQL·후보에서 배제해 격리를 코드 수준에서 보장한다. 리포트 생성 경로는 AI 대기와 트랜잭션 경계가 복잡해 이번 범위에서 분리한다 |
| T27 | 작업별 프롬프트는 설정 JSON이 아니라 기존 `template_version`에 새 버전으로 저장한다. `PromptSettingsModel`이 `preferredTemplate → activeVersion`으로 불러오고, 수정·내장 기본값 복원 모두 새 버전을 만들며 과거 버전은 삭제·수정하지 않는다(내용이 같으면 버전 미생성). 성과 리포트는 Daily와 Periodic을 따로 편집한다. 적용 우선순위는 앱 공통 보호 지침 → 해당 작업 지침 → 선택 스킬 보충 지침 순이며, 스킬 선택이 수정 프롬프트를 대체하지 않는다. `queryPlan`은 현재 검색 경로에서 사용되지 않음을 표시한다. 프롬프트 저장·취소는 일반 "설정 저장"과 독립이다 | 과거 리포트가 어떤 지침으로 만들어졌는지 재현하고(T16), 프롬프트 override를 설정 JSON에 중복 저장하지 않기 위함. 앱 보호 규칙·결정적 facts·출력 검증이 항상 우선한다 |
| T28 | 단축키 문자열은 `HotkeyBinding` 한 곳에서 파싱·정규화한다(지원 키 space·return·a-z·0-9·f1-f12, 수정자 ctrl/opt/shift/cmd, 별칭·기호 허용). 레코더는 문자 변환 결과가 아니라 키코드와 modifier flags로 녹화하고, 녹화 중에는 `HotkeySettingsCoordinator`가 전역 등록을 일시 해제했다가 종료·취소·포커스 이탈 시 복구한다. 적용은 "검증 → 변경분 해제 → 신규 등록 → 파일 저장" 순이며 실패 유형(형식·중복·등록·저장·복구)을 구분해 안내한다. Carbon 핸들러는 인스턴스당 한 번만 설치하고 명시 해제한다. 검색 기본값은 선언·디코딩 fallback 모두 `ctrl+opt+d`로 두되 **기존 settings.json의 저장값은 보존**하고 설정의 '기본값으로 되돌리기'로만 새 기본값을 적용한다. settings.json 외부 직접 편집은 재시작 시 반영된다 | 반복 교체 시 Carbon handler 누적을 막고, 한글 입력 상태에서도 실제 키를 안정적으로 읽는다. 사용자가 고른 값을 기본값 변경만으로 덮어쓰지 않으며, 복구 실패를 "기존 키 유지"로 잘못 보고하지 않는다 |
| T29 | 백업 화면은 단일 `ScrollView` + 상단 정렬 `LazyVStack`으로 구성하고 루트에 `maxWidth/maxHeight: .infinity`와 `.topLeading` 정렬을 명시한다 | 작은 창에서 고정 헤더·가변 안내문과 목록의 크기 협상으로 콘텐츠가 상단 위로 밀리던 문제를 스크롤 좌표계 하나로 고정한다. 복원·검증 sheet 동작은 그대로 유지한다 |
