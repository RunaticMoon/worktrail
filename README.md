# WorkLog (임시 코드명)

로컬 우선 Mac 업무 기록 앱. 빠른 Memo·Task 기록, 날짜별 3열 화면, 이번 주 계획, **제출용 주간보고**와 **상세 성과 리포트**(서로 분리), 회사 Codex를 통한 선택적 AI 초안, AI를 쓰지 않는 Secret 보관함, 자동 백업을 제공한다.

- 제품 요구: `docs/mac_worklog_ai_handoff/02_PRODUCT_SPEC.md` (실행 지시: `01_AI_BUILD_PROMPT.md`)
- 구현 계획: `docs/plan.md` · 기술 결정: `docs/decisions.md` · 인수 테스트 대응표: `docs/acceptance-tests.md`

> **검증 범위 안내** — 이 저장소는 Linux(aarch64, Swift 6.3) 개발 서버에서 작성했다. `WorkLogCore`와 `worklog` CLI는 Linux에서 실제 빌드·테스트했고, GitHub Actions `macos-15` 러너(run 36946540946)에서 macOS 앱을 포함한 전체 빌드와 WorkLogCore 테스트 472개도 통과했다. 그러나 **macOS 앱(SwiftUI/AppKit) 실행, Keychain, Touch ID, 전역 단축키, NSPasteboard, 실제 Codex Enterprise 계정 연결은 실행해 보지 않았다(미검증).** 자세한 목록은 아래 [미검증 항목](#미검증-항목).

## 구조

| 경로 | 내용 | 검증 |
|---|---|---|
| `Sources/WorkLogCore` | 도메인(Task 이벤트 재생, 계획, 날짜), 저장(SQLite), 검색(FTS5), Secret(AES-GCM, 세션 잠금, 클립보드), 백업·복원, 리포트(제출용/성과), AI 실행기·Codex 어댑터, 스케줄러, 앱 구성 루트(`AppEnvironment`), CLI 로직 | Linux `swift test` |
| `Sources/WorkLogApp` | macOS SwiftUI/AppKit 앱(메뉴 막대, 빠른 입력 패널, 화면) | macOS CI 컴파일 통과 · 실행은 **미검증** |
| `Sources/worklog` | 개발·시연용 CLI | Linux 실행 확인 |
| `Tests/WorkLogCoreTests` | XCTest | Linux |
| `scripts/build-macos-app.sh` | SwiftPM 결과를 `.app` 번들로 묶음(ad-hoc 서명) | **미검증** |
| `.github/workflows/macos.yml` | macOS 15 러너에서 전체 빌드·테스트 | 아직 실행 안 함(push 전) |

데이터는 두 SQLite 파일로 분리한다: `work.sqlite`(일반 기록) / `vault.sqlite`(Secret 암호문만). 암호화 키는 macOS Keychain에만 있고 DB·백업에는 없다.

## 요구 환경

- macOS 14 이상(제안값), Swift 6.x 툴체인(Xcode 16 이상 또는 swift.org 툴체인)
- Linux 개발: Swift 6.3, `libsqlite3-dev`(FTS5 포함)
- AI 기능(선택): 회사 계정으로 로그인한 공식 `codex` CLI (`codex app-server` 사용)

## 빌드·테스트

```bash
swift build --build-tests
swift test                      # Linux에서 WorkLogCore 전체 테스트
swift test --filter ReportServiceTests
```

macOS 앱 번들(Mac에서만):

```bash
scripts/build-macos-app.sh            # → .build/app/WorkLog.app
open .build/app/WorkLog.app
```

## 개발용 CLI (`worklog`)

실데이터 경로를 건드리지 않도록 데이터 위치를 반드시 지정해야 한다. AI는 호출하지 않고(결정적 초안만), **Secret 명령은 없다.**

```bash
D=$(mktemp -d)
swift run worklog --data-dir "$D" --now 2026-10-05T01:00:00Z memo "아키텍처 정리 회의 공유"
swift run worklog --data-dir "$D" task add "Java 자동 포맷팅 도입" --project "G 서비스" --tag 품질
swift run worklog --data-dir "$D" activity <taskId> "전체 코드 포맷 적용" --date 2026-10-01
swift run worklog --data-dir "$D" task done <taskId> --date 2026-10-02
swift run worklog --data-dir "$D" search 포맷
swift run worklog --data-dir "$D" report submission 2026-10-05          # 제출용 주간보고(실적 09-28~10-04 · 계획 10-05~10-11)
swift run worklog --data-dir "$D" report performance weekly 2026-09-30  # 상세 성과 리포트(별개)
swift run worklog --data-dir "$D" schedule run --since 2026-09-28
swift run worklog --data-dir "$D" backup create && swift run worklog --data-dir "$D" backup list
```

`WORKLOG_DATA_DIR` 환경 변수로 `--data-dir`를 대신할 수 있다. 종료 코드: 0 성공, 1 도메인 오류, 2 사용법 오류.

## 데이터 위치 (macOS 기본값)

| 항목 | 경로 |
|---|---|
| 일반 기록 | `~/Library/Application Support/WorkLog/work/work.sqlite` |
| Secret 암호문 | `~/Library/Application Support/WorkLog/vault/vault.sqlite` |
| 설정 | `~/Library/Application Support/WorkLog/settings.json` (토큰·Secret 값 없음) |
| AI 작업 임시 폴더 | `~/Library/Application Support/WorkLog/ai-jobs/` (작업 후 삭제) |
| 백업 | `~/WorkLog/backups/` (자동 생성, BACKUP-01) |
| Secret 키 | macOS Keychain (이 기기 전용, iCloud 동기화 안 함) |

디렉터리는 0700, DB·설정 파일은 0600으로 만든다. 표시 이름·bundle id·폴더 이름은 `AppIdentity`(임시 코드명 `WorkLog`)에서 바꾼다.

## 회사 Codex 연결 (선택)

앱은 **공식 `codex app-server`(stdio JSON-RPC)** 만 사용한다. OAuth 토큰을 추출하거나 API 키로 구독을 흉내 내지 않으며, 개인 계정·유료 API로 자동 전환하지 않는다.

1. 공식 Codex CLI를 설치하고 회사 ChatGPT Enterprise 계정으로 로그인한다(앱이 로그인 정보를 읽거나 저장하지 않음).
2. 실행 파일 탐색 순서: 설정의 `codexExecutablePath`(지정 시 그 경로만) → `PATH` → `/opt/homebrew/bin`, `/usr/local/bin`. Finder로 실행한 앱은 셸 `PATH`를 물려받지 않으므로 다른 위치라면 설정에서 경로를 지정한다.
3. 앱은 `account/read`로 로그인 상태만 표시한다. 인증 만료·정책 제한·한도 초과·미설치를 구분해 표시하고 AI 작업을 `blocked_auth`/`blocked_policy`/`failed`로 남긴다. AI가 없어도 기록·검색·Secret·결정적 리포트 초안은 모두 동작한다.
4. 실행 제한: 각 작업은 `sandbox: read-only`, `approvalPolicy: never`로 새 스레드를 열고, 서버의 명령·파일 변경 승인 요청은 모두 거절한다. 입력에 Secret DB·백업 경로가 섞이면 호출 전에 차단하고(`AIPayloadGuard`), 출력에 인증 정보 흔적(`.codex/`, `auth.json`, `*_token`, `PRIVATE KEY` 등)이나 차단 경로가 있으면 저장하지 않는다(`AIOutputGuard`).
5. AI 출력은 항상 로컬 검증기를 통과해야 초안으로 저장되며, 실패하면 기록 기반 결정적 초안으로 대체한다. 날짜·상태·집계는 앱이 계산하고 AI가 정하지 않는다.

### 작업별 스킬

설정 `skillBindings`에 작업 유형(`submission_weekly`, `performance_report`, `evidence_quiz`, `memo_task_suggestions`, `query_plan`, `grounded_answer`)별로 기존 Codex 스킬 이름 또는 `SKILL.md` 경로를 지정한다. 앱은 스킬 파일을 읽어 해시만 기록하고 **수정하지 않는다**. 스킬 파일이 바뀌면 다음 실행부터 새 결과를 만들고 이전 결과는 그대로 둔다. 리포트 버전에는 실제로 AI 본문을 쓴 경우에만 `스킬이름@해시`를 기록한다.

## 권한 (macOS)

| 권한 | 용도 | 비고 |
|---|---|---|
| Keychain | Secret 암호화 키 보관 | ad-hoc 서명 빌드는 접근 시 허용 여부를 물을 수 있음 |
| Touch ID/암호 (LocalAuthentication) | Secret 보관함 열기 | 30분 미사용·화면 잠금·종료 시 자동 잠금(제안값) |
| 전역 단축키 | 빠른 입력 `⌃⌥Space`, 검색 `⌃⌥F` (제안값) | Carbon `RegisterEventHotKey` — 손쉬운 사용 권한 불필요(미검증) |
| 클립보드 | Secret 값 복사 | 120초 뒤, 그 사이 다른 복사가 없을 때만 지움(제안값) |

네트워크는 Codex app-server 프로세스만 사용한다. Secret 경로에는 네트워크·AI 호출이 없다.

## 리포트: 제출용과 상세 성과는 별개

| | 제출용 주간보고 | 상세 성과 리포트 |
|---|---|---|
| family / 템플릿 | `submission` / `submission.weekly.default.v1` | `performance` / `performance.daily…periodic.default.v1` |
| 기간 | 지난주 월~일 상태 + 이번 주 확정 계획 | 일·주·월·분기·평가 기간 |
| 내용 | 짧은 완료/진행/예정 문장 | 근거·영향·보충 답변을 포함한 상세 기록 |
| 생성 | 월요일 준비(게시 안 함, 텍스트 복사) | 마감 후 자동 초안 + 수동 재생성 |

둘은 서로 다른 Report 행·버전·검증기를 쓰며 한쪽 편집이 다른 쪽에 영향을 주지 않는다. 확정본은 DB 트리거로 수정·삭제가 막혀 있고, 자동 작업은 확정본을 덮어쓰지 않고 새 초안 버전을 만든다.

## 백업과 복원

- 앱 시작 시 하루 1회, 내용이 바뀐 경우에만 `~/WorkLog/backups/<시각>-<id>/`에 SQLite Online Backup으로 `work.sqlite`, `vault.sqlite`(암호문), `settings.json`, `manifest.json`(SHA-256, 스키마 버전, vault 키 버전)을 만든다. 보관 기본 30일, 직전 백업이 실패했으면 오래된 백업을 지우지 않는다.
- 검증: 파일 해시, `PRAGMA integrity_check`, 스키마 버전, vault `key_version`과 manifest 대조.
- 복원 순서: 검증 → (Secret 포함 시) 키 존재 확인과 Secret 1건 **시험 복호화** → 현재 데이터를 `pre_restore` 백업으로 보존 → 임시 사본 해시 재확인 → 교체. 중간 실패 시 새로 놓은 파일을 지우고 원래 파일을 되돌린다. 복원 전에는 앱의 DB 연결을 닫아야 한다.

### Secret 복원 전제 조건

백업에는 **키가 없다**. Secret을 복원하려면 백업의 `vaultKeyVersion`과 같은 id의 키가 대상 Mac의 Keychain에 있어야 한다. 키는 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`로 저장되어 iCloud 키체인 동기화나 다른 Mac으로의 이전 대상이 아니므로, **Secret 복원은 키를 만든 같은 Mac(같은 사용자 계정)에서만** 가능하다. 다른 Mac으로 옮길 때 Secret 이전은 지원하지 않는다(미구현, 의도적 제한). 키가 없거나 맞지 않으면 아무 파일도 바꾸지 않고 `vaultKeyMissing`/`vaultKeyMismatch`로 중단한다. 이때 `includeVault: false`로 일반 기록·설정만 복원할 수 있으며 기존 Secret 보관함은 그대로 둔다. 키를 잃으면 Secret은 복구할 수 없다(의도된 설계).

## Secret

- AI·검색 색인·로그·`work.sqlite`에 Secret(제목 포함)을 넣지 않는다. 제목 검색은 vault 안에서만 한다.
- 표(key/value) 입력, `A=B`·`A : B` 붙여넣기 분리, 저장 시 trim, JSON/문자열 원문 보존, 버전·휴지통.
- 모든 복호화·수정은 `VaultSession`(기기 인증 후, 미사용 30분 자동 잠금)을 거친다.

## 화면 (macOS, 미검증)

`Sources/WorkLogApp`에 SwiftUI/AppKit 코드가 있다. macOS CI에서 컴파일은 통과했지만 앱을 실행해 화면·키 입력을 확인하지는 않았다.

- 사이드바: 날짜(3열: 타임라인·Task·Memo), 업무, 검색, 리포트(제출용/상세 성과를 상단 선택기로 분리), 이번 주 계획, Secret, 설정, 백업
- 빠른 입력 패널(`⌃⌥Space` 제안값): Return 줄바꿈 · ⌘Return 저장 · Esc 초안 보존 후 닫기, `@프로젝트`·`#태그` 자동완성, 저장 후 이전 앱으로 복귀
- 검색(`⌃⌥F` 제안값): 원문 검색, 명시적으로 요청할 때만 AI 답변(Secret 제외)
- 설정의 기본 입력 유형이 Secret이면 입력 단축키가 빠른 입력 패널 대신 메인 창의 Secret 화면을 연다. 잠겨 있으면 사용자가 기기 인증을 해야 새 항목이 열리고, 복구할 암호화 초안이 있으면 먼저 복구/버리기를 고른다. 이 경로는 저장 후 이전 앱으로 돌아가지 않는다(decisions T20)

## 알려진 제한

- AI 초안 생성이 실패한 뒤 원본 기록이 바뀌지 않았으면 자동 작업이 AI를 다시 호출하지 않는다(결정적 초안 유지). 다시 시도하려면 리포트 화면에서 다시 생성한다.
- 앱 시작 시 놓친 예약 리포트는 최근 92일까지만 만들고, AI는 최근 7일 작업에만 쓴다(decisions T19).
- 검색에서 태그 필터를 쓰는 동안에는 AI 답변을 요청할 수 없다.
- 결정적 초안(AI 미사용, CLI 포함)에는 템플릿 버전이 기록되지 않는다(decisions T21).
- 체크리스트·프로젝트 연결은 과거 시점(knownAt) 필터가 적용되지 않는다(기록 시각 컬럼 없음).
- 향후 Task 링크 자동 수집(LINK-T02)은 미구현이다. 링크는 URL만 보관하고 가져오지 않는다.
- Secret 항목은 행별 `복사` 버튼으로 값을 복사한다(사양의 "key 클릭=복사" 대신 명시적 버튼).

## 미검증 항목

실제로 실행하지 못한 것은 통과로 보지 않는다.

- macOS 앱 실행(컴파일은 CI 통과), SwiftUI 화면, 메뉴 막대, 빠른 입력 패널(NSPanel), 이전 앱으로 포커스 복귀
- 전역 단축키 등록·충돌 처리(Carbon)
- Keychain 키 저장(`KeychainVaultKeyStore`), Touch ID/암호 인증(`LocalDeviceAuthenticator`), `NSPasteboard` 조건부 삭제(`SystemPasteboard`)
- 실제 Codex Enterprise 계정 로그인·스킬 조회·턴 실행, 회사 정책 오류 분류(가짜 app-server 프로세스로 프로토콜만 테스트), 승인 거절 응답의 `decision` 필드 값
- Codex read-only sandbox가 실제로 vault·백업 파일 읽기를 막는지(AI-T07). 앱은 입력에서 해당 경로를 빼고 출력에 흔적이 있으면 저장하지 않을 뿐이다
- `scripts/build-macos-app.sh`, `.github/workflows/macos.yml`(아직 실행 안 함), 로그인 시 실행
- 대용량 성능(5만 건 삽입·검색 시간) 측정
- 체크리스트·프로젝트 연결의 과거 시점(knownAt) 필터: 스키마에 기록 시각 컬럼이 없어 미적용
- 인수 테스트별 상태는 `docs/acceptance-tests.md` 참고
