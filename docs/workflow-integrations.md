# 업무 연결과 입력 개선 — 0.13.0

사용자 요청에 따라 기존 요구사항의 외부 링크 보관 범위를 확장한다. GitHub/Jira의 본인 활동을 읽어서 일반 메모로 저장하며, 원격 이슈 수정·Task 상태 자동 변경은 하지 않는다.

## AI 연결

- 기본은 Codex CLI 0.163.0 이상의 `app-server`다. 앱 전용 OAuth 등록 대신 CLI가 관리하는 로그인 상태를 사용한다. Finder 실행에서도 `~/.local/bin`, Homebrew 설치 경로를 찾으며 실행 파일을 직접 지정할 수 있다.
- 설정 → AI 연결에서 OpenAI 호환 API를 선택하면 DeepSeek 기본 URL·모델을 채운다. HTTPS 기본 URL, 모델명, API 키를 직접 바꿀 수 있다. `/chat/completions`의 JSON 응답을 기존 출력 검증에 통과시킨 뒤 초안으로 저장한다.
- 공급자를 바꿀 때 이전 공급자의 모델·effort 선택을 초기화한다. 실행 중 연결을 바꾸면 이전 연결의 결과가 새 연결의 결과로 저장되지 않는다.
- API 키는 전용 WorkLog Keychain 항목에만 저장한다. 설정 JSON·업무 DB·백업에는 키가 없다. 기존 OAuth 등록과 CLI 인증 파일을 복사하거나 삭제하지 않는다.
- Secret은 모든 AI 입력에서 계속 제외한다. 선택한 SKILL.md는 앱이 경로를 검증해 텍스트로 첨부하고, CLI 작업의 파일·셸·MCP 도구 접근을 제한한다. 빈 MCP 설정만으로 기존 설정이 제거되지 않으므로 서버별 비활성화와 환경·도구 제한을 함께 적용한다. CLI 0.163.0을 합성 설정·로컬 응답 서버로 실행해 모델 요청의 도구 목록이 비어 있고 가짜 MCP 프로세스가 시작되지 않는 것을 확인했다.

## 마감일과 알림

빠른 업무 입력과 업무 상세에서 마감일을 지정하고, 0~365일 전 중 알림 시작일을 고른다. 알림은 시작일부터 마감 당일까지 앱 업무 시간대의 매일 오전 9시에 예약한다. 0일은 마감 당일만 뜻한다. 이미 지난 오전 9시 알림을 소급 발송하지 않는다.

완료·취소·삭제·마감일 변경 때 예약을 다시 계산한다. macOS 알림 권한이 없으면 화면에 허용 방법을 알린다. 가까운 60건 안에서 시스템 예약 한도를 지키며, 앱 실행·저장·복귀·분 단위 갱신으로 다음 알림을 채운다. 이미 예약된 알림은 앱이 닫혀 있어도 macOS가 전달하지만, 장기간 앱을 실행하지 않으면 예약 한도 이후 알림은 보충되지 않는다.

기존 업무의 마감일은 그대로 보존하고 알림은 기본 꺼짐이다. WorkSchema v7이 선택적인 `due_reminder_days_before`만 추가한다.

## GitHub Enterprise / Atlassian Cloud Jira

설정 → 활동 수집에서 서비스를 켜고 HTTPS 주소·계정·API 토큰을 저장한다. GitHub와 Jira 입력란은 각각 기본 GroupBox에 항상 표시한다. 토큰은 서버와 계정별 별도 Keychain 항목이다. 다른 서버로 주소를 바꿔도 기존 토큰을 자동 전송하지 않는다. 리디렉션을 따라 인증을 전송하지 않고 시스템 TLS 검증을 사용한다. 사내 서버 연결에는 Mac의 VPN·사내 DNS·인증서 설정이 필요하다.

| 서비스 | 설정 | 가져오는 활동 |
| --- | --- | --- |
| GitHub Enterprise Server | 웹 주소 또는 `/api/v3`, 본인 사용자명, 읽기 토큰 | 본인이 보낸 push·PR 생성/종료·리뷰 이벤트 |
| Jira Cloud | 사이트 URL, Atlassian 이메일, API 토큰, JQL 범위 | 본인 이슈 생성·변경 이력·작업 시간 기록 |
| Jira scoped API 토큰 | `https://api.atlassian.com/ex/jira/<cloudId>` | 동일, 웹 링크는 서버의 사이트 주소에서 구성 |

앱 실행·복귀와 실행 중 날짜 변경에 하루 한 번 수집한다. 처음에는 최근 7일 전부터 오늘까지, 이후에는 마지막 성공 이전 7일부터 재조회한다. 오래 오프라인이었던 경우 최대 최근 30일을 조회한다. API 지연으로 늦게 나타난 이벤트를 다시 찾고 `(서버/계정, 외부 이벤트 ID)`로 중복을 막는다. 사용자가 가져온 메모를 편집하거나 휴지통에 넣어도 다음 수집이 덮어쓰거나 되살리지 않는다. 실패한 자동 수집은 같은 날 반복하지 않으며 ‘지금 가져오기’로 명시적으로 다시 시도할 수 있다.

GitHub Events API는 서버 보존 기간과 최대 300개 제한이 있어 전체 활동의 영구 감사 로그를 대신하지 않는다. 제한에 도달하면 누락 가능성을 표시한다. Jira는 설정한 JQL과 읽기 권한 안에서만 조회한다. 기본 JQL은 현재 담당자·작성자·작업 시간 작성자를 대상으로 하므로 타인에게 넘긴 이슈까지 필요하면 프로젝트 등의 JQL 범위를 넓힌다. JQL에는 `ORDER BY`를 넣지 않는다. 페이지가 잘리거나 반복되면 부분 결과를 저장하지 않는다.

가져온 기록은 출처 URL, 원본 발생 시각, 가져온 시각과 함께 저장한다(WorkSchema v8). 실제 활동 날짜는 WorkCalendar로 결정한다. Jira의 타인 변경을 내 활동으로 표시하지 않는다. 일반 메모에 들어온 이후에는 기존 검색·보고서·AI 전송 설정을 따른다. 서비스 인증 정보는 수집 메모에 포함하지 않는다.

## 리포트·회의 녹음·Secret

- 리포트 보관함: 제출용 주간보고는 문서 아이콘, 성과자료는 막대그래프 아이콘으로 구분한다.
- 회의 녹음: CoreAudio 내장 장치를 우선해 Mac 마이크를 기본 선택한다. 내장 장치가 없으면 사용자가 다른 입력 장치를 선택한다. 오디오 콜백을 MainActor와 분리하고, 시작 도중의 장치 변경 오탐과 실패 시 tap 정리를 보완했다.
- Secret: 잠금 해제된 보관함 목록을 그룹별로 묶는다. 빠른 저장은 그룹 자동완성 → 제목 → key/value 순서다. 그룹 후보는 vault 메타데이터에서만 읽으며 AI나 일반 검색 인덱스에 전달하지 않는다.

## 확인한 문서

- [Codex app-server](https://developers.openai.com/codex/app-server/): CLI와 앱 간 공식 프로토콜. 설치된 CLI 0.163.0의 공개 스키마와 대조.
- [DeepSeek Chat Completions](https://api-docs.deepseek.com/api/create-chat-completion/): 모델·JSON 응답 형식.
- [GitHub Enterprise Events](https://docs.github.com/en/enterprise-server@3.21/rest/activity/events): 이벤트 종류·페이지네이션·보존 제한.
- [Jira enhanced JQL search](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-search/): `/search/jql`과 `nextPageToken`.
- [Jira currentUser 함수](https://support.atlassian.com/jira-software-cloud/docs/jql-functions/#currentUser()): `WAS`와 직접 조합할 수 없어 기본 JQL에 넣지 않음.
- SwiftUI 자동완성, CoreAudio, AVAudioNodeTapBlock, UserNotifications는 설치 macOS SDK와 대조했다.

## 검증과 실제 계정 확인

자동 검증은 가짜 API·가짜 계정·합성 오디오·격리된 화면 fixture만 사용한다.

- macOS 27 SDK / Apple Swift 6.4: `swift build --build-tests` 및 최적화 release 빌드 성공, XCTest 전체 992개 통과. 마감일 Binding의 신규 동시성 경고 4건도 명시적 클로저로 해소했다.
- 로컬 검증용 DMG 0.13.0: arm64·최소 macOS 26·서명 무결성·Sparkle 로더 smoke 통과. 로컬 ad-hoc 서명본은 배포하지 않으며 운영 산출물은 CI에서 고정 인증서로 다시 서명한다.
- OCI Linux aarch64 / Swift 6.3.3: 전체 빌드 성공, 전체 991개와 이후 추가된 rollback 검사를 포함한 ActivityImportTests 9개를 별도 검증. 호스트의 libxml2 ABI 차이는 `/tmp`에만 호환 라이브러리를 추출해 해결했고 시스템 패키지는 변경하지 않았다.
- 배포 도구 Python 검사: 60개 중 55개 통과, 조건부 검사 5개 생략.
- 합성 PCM 기반 native 회의 세션 검사: 9개 통과. 실제 마이크는 열지 않았다.
- 실제 Codex 0.163.0 + localhost 가짜 API: 인증 헤더 없음, 노출 도구 `[]`, 가짜 MCP 실행 없음, 임시 HOME 정리 확인. 재실행: `python3 scripts/maclab/run-codex-isolation-check.py --codex /path/to/codex`.
- 화면·키보드: 전용 fixture에서 오늘 화면 렌더링과 Cmd2 → CmdN → 마감일 설정 → 알림 시작 3일/4일 변경 → 마감일 해제 시 알림 제거 → Escape 동선을 통과했다. CLI/API 전환·DeepSeek 기본값, Secret 그룹별 목록·그룹 초기 포커스·자동완성 선택·Tab으로 제목 이동, 리포트 목록의 두 계열 아이콘 구분도 확인했다. `scripts/maclab/workflow-enhancements-check.js`는 입력 전에 소유 PID·fixture 경로·foreground·화면 잠금을 검사하고 사용자 클립보드를 조작하지 않는다. 기존 사용자의 fixture 프로세스는 보존한다.

실제 Enterprise 로그인, DeepSeek 유료 호출, 사내 GitHub/Jira 접근, 마이크 녹음과 OS 알림 전달은 별도 사용자 환경 확인 대상이다. 녹음 시작 코드의 결함을 수정했지만, 사용자가 겪은 마이크 실패의 실제 권한·장치 상태까지 확인한 것은 아니다.

운영 배포는 기존 `macos-release.yml`의 검토한 merge SHA 빌드 → 고정 인증서 서명 → DMG/manifest/서명된 appcast 검증 → GitHub Release 공개 경로를 따른다. 사용자 승인 전에는 배포하지 않는다. 롤백 시 기존 v0.12.0 릴리즈를 유지하고 latest/feed를 이전 버전으로 돌리며, 설치된 앱의 자동 다운그레이드는 수행하지 않는다. DB v7/v8은 additive migration이므로 롤백 전에 데이터 백업을 보존한다.
