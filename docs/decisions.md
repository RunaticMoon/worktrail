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
| T20 | 빠른 입력 키: Return 줄바꿈 · ⌘Return 저장 · Esc 초안 보존 후 닫기, 한글 IME 조합 중에는 저장하지 않음 | 02 사양 CAP-02 그대로. 기본 입력 유형이 Secret이면 일반 입력창 대신 메인 창 Secret 화면으로 연결(Secret 값이 일반 기록 경로에 들어가지 않게). 이 경로는 CAP-01의 "저장 후 이전 앱 복귀"를 적용하지 않음(메인 창 편집 흐름) |
| T21 | 결정적 초안(AI 미사용)은 `template_version_id`를 기록하지 않음 | 프롬프트 템플릿은 AI 지시문이며 결정적 초안은 코드 컴포저(`generator: deterministic`)가 만든다. AI 초안 버전에만 템플릿 버전·스킬 해시를 기록 |
| T22 | AI 출력 줄은 바이트 단위로 모아 줄바꿈에서만 UTF-8 해석 | 파이프 수신 단위가 한글 등 멀티바이트 문자 중간에서 잘려도 응답이 사라지지 않게 하기 위함(독립 검증 AO 재현 결함) |
| T23 | 백업 DB 사본은 DELETE 저널(단일 파일)로 저장하고, 복원 시 대상의 `-wal`/`-shm`은 DB와 함께 옮겨 두었다가 실패하면 되돌림 | macOS 시스템 SQLite는 읽기 전용 연결로 WAL DB를 열지 못하고(macOS CI에서 확인), 닫힌 뒤에도 `-wal`/`-shm`을 남긴다. 복원된 DB는 앱이 읽기·쓰기로 열 때 다시 WAL이 된다 |
