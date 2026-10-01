# 제안 기술 설계

이 문서는 구현 출발점이다. 제품 행동은 `02_PRODUCT_SPEC.md`가 우선하며, 라이브러리·정확한 파일 배치·최소 OS 버전은 구현 환경을 확인해 정한다. 기술 참고의 `[S#]`는 `06_DECISIONS_AND_SOURCES.md`를 가리킨다.

## 1. 구성 원칙

**네이티브 Mac 앱 하나 + 로컬 데이터 저장소 + 필요할 때 실행하는 공식 Codex 어댑터**를 기본으로 한다. 별도 웹 서버·원격 DB·Docker·로컬 LLM을 필수로 두지 않는다.

제안 스택은 Swift/SwiftUI, 필요한 전역 핫키·패널·클립보드에 한정한 AppKit 브리지, SQLite, Apple Keychain과 CryptoKit이다. 기존 저장소에 합리적인 스택이 있으면 마이그레이션 비용을 먼저 평가한다. 이 스택 자체는 사용자가 선택한 확정 요구가 아니다.

배포는 우선 로컬 개발 빌드 중심으로 하고 Mac App Store 배포를 가정하지 않는다. 앱 샌드박스·로그인 항목·홈 폴더 접근·외부 Codex 프로세스 실행의 실제 제약을 확인한다. macOS 최소 버전과 패키지 버전을 추측으로 고정하지 말고 개발 환경에서 검증해 기록한다.

## 2. 모듈 경계

| 모듈 | 책임 | 갖지 않아야 할 책임 |
|---|---|---|
| Capture | 전역 입력, 초안, 업무일, 모드 전환 | AI 완료까지 저장 지연 |
| Workspace | 날짜별 3열, 전체 Task, 프로젝트·태그 | 원본 데이터 복제 |
| Domain | 상태 전환, 계획 범위, 기간, 집계 | OS UI·Codex 프로토콜 의존 |
| WorkRepository | Memo·Task·이력·계획·보고서 영속화 | Secret 평문 조회 |
| Search | 일반 원문 인덱스·필터·근거 검색 | Secret value 색인 |
| ReportEngine | 원본 스냅샷 구성·생성 작업·검증·버전 | LLM에 상태 판정 위임 |
| CodexAdapter | 공식 인증·스킬·턴·취소·오류 | 회사 정책 우회·토큰 추출 |
| SecretVault | 표 데이터·trim·암호화·잠금·버전·복사 | 어떤 형태의 AI 호출 |
| Backup | 일관된 스냅샷·manifest·복원 | Keychain 평문 덤프 |
| Scheduler | 마감·월요일·재시도·누락 복구 | 절전 중 실행 성공 가정 |

단일 프로세스 내 인터페이스 분리로 시작한다. 전체 CQRS 플랫폼이나 분산 이벤트 버스를 구축하지 않는다. 상태 이력은 로컬 이벤트 테이블과 재생 가능한 조회 캐시로 충분하다.

## 3. 저장 경로와 격리 — 제안

```text
~/Library/Application Support/<앱이름>/
  work/work.sqlite
  vault/vault.sqlite
  ai-jobs/<job-id>/             # 허용된 일반 기록의 제한된 스냅샷만
  cache/                       # 재생성 가능한 일반 캐시
  settings.json                # 토큰·Secret 값 없음

~/<앱이름>/backups/
  <backup-id>/
    manifest.json
    work.sqlite
    vault.sqlite               # 본문과 버전은 이미 암호화된 상태
    settings.json
```

작업 DB와 Secret DB를 분리한다. 검색에 필요한 Secret 제목 메타데이터도 전용 저장소/서비스가 제공한다. AI 입력을 위해 work DB 전체를 덤프하거나 vault DB 파일 경로를 넘기지 않는다.

디렉터리는 사용자 전용 권한을 기본으로 만들고, symlink·경로 정규화·백업 목적지 혼동을 검증한다. 앱의 데이터 루트를 Codex의 작업 루트로 지정하지 않는다. Codex의 계정 자격증명은 공식 구성요소가 관리하며 앱 백업 대상이 아니다.

제목 검색 메타데이터는 잠금 중 노출할 수 있지만 제목·그룹 이름도 민감할 수 있음을 UI에 설명한다. 이 메타데이터를 노출한다고 본문 복호화 권한이 생기지 않는다.

## 4. 일반 데이터 모델

아래는 개념 스키마다. 실제 SQLite DDL과 migration은 구현 단계에서 작성한다. 모든 엔터티에는 안정적인 UUID·schema version·필요한 revision 정보를 둔다.

| 엔터티 | 핵심 필드 |
|---|---|
| Memo | id, body, workDate, recordedAt, revision, deletedAt |
| Task | id, title, cachedStatus, firstStartedOn?, lastCompletedOn?, dueOn?, createdAt, projectTrackingMode, revision |
| Project | id, name, archivedAt? |
| Tag | id, name |
| TaskProject | id, taskId, projectId, trackingEnabled, cachedStatus?, linkedOn, removedOn? |
| ChecklistItem | id, taskId, text, sortOrder, cachedDone, deletedAt? |
| ChecklistProject | checklistItemId, taskProjectId |
| Activity | id, taskId, body, workDate, recordedAt, activityKind, revision |
| ActivityProject | activityId, taskProjectId |
| ActivityChecklist | activityId, checklistItemId |
| DomainEvent | id, scopeType, scopeId, taskId, kind, payload, effectiveDate, effectiveTime?, effectiveOrder, recordedAt, supersedesEventId? |
| MemoTaskLink | memoId, taskId, status(proposed/accepted/rejected), reason, sourceRevision |
| TaskRelation | fromTaskId, toTaskId, relationType(followUp/related), createdAt |
| WorkLink | id, ownerType, ownerId, url, linkType, createdAt, fetchPolicy |
| WeekPlan | id, weekStart, weekEndExclusive, status, revision, confirmedAt? |
| WeekPlanItem | id, weekPlanId, taskId, scopeType, scopeId?, label?, selected, confirmedAt? |
| EvidenceSupplement | id, taskId, questionId, answer, appliesStart, appliesEndExclusive, recordedAt |
| Template | id, purpose, name, activeVersion |
| TemplateVersion | id, templateId, version, instructions, outputExample, createdAt |
| SkillBinding | jobType, discoveredSkillId/path, cwd, lastKnownHash?, enabled |
| Report | id, family(submission/performance), periodType, periodId, start, endExclusive, planStart?, planEndExclusive? |
| ReportVersion | id, reportId, version, state, content, sourceSnapshotId, templateVersionId, skillRef, createdAt, confirmedAt? |
| SourceSnapshot | id, period, stateCutoff, sourceIdsAndRevisions, frozenFacts, digest |
| ReportEvidence | reportVersionId, itemId, taskId?, sourceId, sourceRevision, excerptLocator |
| EvaluationPeriod | id, start, endExclusive, previousPeriodId?, confirmedReportVersionId? |
| AIJob | id, type, idempotencyKey, inputDigest, status, attempts, providerRefs?, lastErrorClass, createdAt |
| ScheduledJob | type, periodKey, scheduledFor, state, lastAttemptAt |

Memo와 Task의 프로젝트·태그 조인 테이블은 별도로 둔다. JSON 컬럼을 사용하는 부분에도 앱에서 schema validation을 한다. 일반 문자열을 SQL에 직접 결합하지 않는다.

TaskProject와 ActivityProject를 분리해야 프로젝트 상태와 활동 근거를 독립적으로 표현할 수 있다. 고유 Task 수와 프로젝트 기여 수를 하나의 count 필드로 혼합하지 않는다.

## 5. 상태와 시간 이력

### 5.1 두 시간축

- `recordedAt`: 앱이 기록을 받은 UTC 시각.
- `effectiveDate`: 사용자가 지정한 실제 업무일, 지역 달력 기준.
- `effectiveTime`: 실제 시각을 알고 입력한 경우만. 날짜만 입력했는데 오전 9시 같은 시각을 사실처럼 만들지 않는다.
- `effectiveOrder`: 같은 업무일 내 상태 사건의 결정적 순서. 시간을 알면 그 순서를 반영하고, 모르거나 충돌하면 사용자 확인 또는 명시적인 입력 순서로 정한다.

현 상태는 단순 `MAX(recordedAt)`가 아니라 실제 업무 이력의 순서로 계산한다. 화요일 완료 기록이 존재할 때 나중에 입력한 월요일 진행 기록이 현재 상태를 다시 진행으로 돌리면 안 된다.

### 5.2 상태 재생

개념 알고리즘:

```text
stateAt(scope, targetDate, knownAt):
  사건 중 recordedAt <= knownAt인 버전을 선택한다.
  그 시점까지의 명시적 수정/대체 관계를 적용해 유효 사건을 정한다.
  effectiveDate <= targetDate인 사건을 실제 업무 순서로 정렬한다.
  상태 전이 규칙을 순서대로 적용한다.
  결과 상태와 근거 사건 ID를 반환한다.
```

현재 보기의 `knownAt`은 현재다. 확정 보고서는 생성 당시의 source snapshot을 사용한다. 늦은 기록을 추가하면 과거 조회가 더 정확한 근거를 반영할 수 있지만 과거 확정 문서는 바뀌지 않는다.

`Task.cachedStatus`와 날짜별 snapshot은 재생성 가능한 캐시다. 원본을 캐시만으로 대체하지 않는다. 단일 Mac에서는 변경 transaction과 조회 projection 갱신을 같은 저장소 경계에서 처리한다.

### 5.3 사건 종류

TaskCreated, WorkStarted, ActivityAdded, TaskPaused, TaskCancelled, TaskCompleted, TaskReopened, ProjectLinked, ProjectUnlinked, ProjectStatusChanged, ChecklistChanged, EvidenceAdded, ExplicitCorrection 등을 제안한다.

상태 사건에는 대상 scope가 필수다. `ProjectStatusChanged`는 프로젝트만, `TaskCompleted`는 전체 Task만 바꾼다. 명시적 일괄 변경은 각 대상을 포함한 하나의 검증된 transaction으로 처리한다.

‘새 Task를 완료로 등록’은 생성과 완료를 원자적으로 저장한다. 시작일을 모르면 WorkStarted를 만들지 않는다. Task를 재개할 때 이전 완료 사건을 삭제하지 않는다.

### 5.4 기간과 집계

달력 서비스를 주입해 `[start, endExclusive)`를 계산한다. UI에서 ‘10월 4일까지’는 내부에서 ‘10월 5일 00:00 미만’으로 변환한다.

- 수행 활동 수: Activity ID distinct.
- 고유 업무 수: Task ID distinct.
- 완료 사건 수: TaskCompleted event ID distinct.
- 프로젝트 적용 완료 수: TaskProject의 완료 사건 기준.

각 지표는 이름과 기준을 붙인다. 둘 이상의 프로젝트 join으로 Activity·Task 행이 증식한 결과를 그대로 집계하지 않는다.

## 6. 계획 정규화

계획 범위는 `wholeTask | taskProject | checklistItem`로 표현한다. 가능한 가장 큰 범위로 무조건 지우지 말고 사용자가 적은 세부 계획 설명도 보존한다.

정규화 예:

```text
입력: Task A 전체 + A/J 적용 + A/운영 문서 체크리스트
실행 의미: Task A를 이번 주에 수행
표현: Task A — J 적용 및 운영 문서 정리
집계: Task A를 한 번, 세부 표기는 필요에 따라 병합
```

체크리스트가 여러 프로젝트와 연관돼도 같은 체크리스트 ID는 계획에 한 번만 들어간다. 후보와 확인된 계획을 분리하고, 계획 revision을 제출용 보고서 snapshot에 고정한다.

## 7. 리포트 생성 파이프라인

```text
기간·상태·확정 계획 계산(로컬)
→ 허용된 원문과 승인된 연결 근거 수집
→ 중복 제거·출처 ID·기간 필터·스냅샷 생성
→ 회사 Codex의 지정 스킬/템플릿 실행
→ 결과 구조·근거·상태·범위 검증
→ 편집 가능한 초안 저장
→ 사용자 편집·확정
```

프롬프트만으로 정확성을 보장하지 않는다. 로컬 검증기가 다음을 확인한다.

- 출력의 sourceId가 snapshot에 실제 존재하는지.
- Task ID·project scope·상태·실제 날짜가 입력과 일치하는지.
- 미확정 계획을 ‘예정’으로 쓰지 않았는지.
- 완료 재개·프로젝트별 완료를 전체 완료로 바꾸지 않았는지.
- 같은 Task의 중복 성과, 기간 밖 내용을 섞지 않았는지.
- 구조 오류나 근거 없는 수치가 발견되면 초안 경고/실패로 처리하는지.

AI 출력에 검증되지 않은 sourceId가 있으면 링크를 날조하지 않는다. 명백한 구조 오류는 제한된 재시도를 허용하되 재시도도 사용량을 소비할 수 있음을 표시한다. 영구적인 자동 재시도 루프를 만들지 않는다.

### 상위 리포트

하위 리포트 ID와 근거 Activity/Task ID를 함께 입력한다. 월·평가 기간 경계를 벗어나는 하위 리포트는 원문 날짜로 재필터한다. 하위 요약에만 있고 원본으로 확인되지 않는 사실은 신뢰할 수 있는 성과로 승격하지 않는다.

기존 확정본을 재료로 사용할 수 있지만 나중에 발견된 근거는 새 버전에서만 반영한다. 사용자 편집 문장은 원문 사실 여부와 편집 출처를 함께 보존한다.

## 8. 검색 설계

SQLite FTS5는 로컬 전문 검색의 기반 후보이며 tokenizer·prefix·trigram 등 선택지를 공식 문서에서 확인한다. 플랫폼 SQLite의 실제 빌드 기능을 검사한다. [S4]

제안 구성:

1. 일반 본문·업무명·진행 기록·리포트 본문을 source ID와 함께 색인한다.
2. 날짜·유형·프로젝트·태그는 구조화 필터로 처리한다.
3. 한글 검색을 영문 단어 검색으로 검증했다고 끝내지 않는다. 한국어 부분 문자열·1~2글자·붙여 쓴 단어·기호를 테스트한다.
4. trigram 또는 별도 부분 문자열 보조 색인을 선택할 수 있다. 짧은 검색어는 제한된 결과·기간 필터·정확/접두 검색 또는 escape된 LIKE 경로를 사용한다.
5. 검색어를 SQL/FTS 문법으로 무조건 해석하지 않는다. 바인딩과 리터럴 escaping을 적용한다.
6. 원문 색인은 저장과 연동하고 재생성 가능하게 한다. 삭제·휴지통·수정이 결과에 즉시 반영돼야 한다.

별도 벡터 DB나 임베딩 구독은 첫 버전 필수가 아니다. 자연어 답변은 사용자가 실행할 때 질의의 기간·프로젝트·검색어를 추출하고 로컬 검색을 수행한 뒤, 관련 근거만 다시 보내는 방식으로 시작할 수 있다. 의미가 다른 질문을 키워드 검색만으로 완벽히 이해한다고 주장하지 않는다.

앱 내부 `searchWorkRecords` 같은 제한된 인터페이스를 모델 도구로 제공할 경우 필터와 결과 상한을 검증하고 Secret 자료형을 반환할 수 없게 한다. 임의 SQL 실행을 AI에 허용하지 않는다.

## 9. Codex 어댑터

공식 app-server 문서는 stdio JSONL 연결, 초기화, ChatGPT 로그인, 스킬 조회, turn 처리, 읽기 접근 범위 설정을 설명한다. 실제 설치 버전과 스키마를 확인하고 어댑터에서 호환성을 검사한다. [S1]

회사 ChatGPT 로그인과 Codex 이용 권한·한도는 회사 계정 설정에 종속된다. Enterprise 과금은 계약에 따라 다르므로 ‘항상 같은 크레딧’으로 고정하지 않는다. [S3]

### 앱 소유 추상 인터페이스

아래 이름은 **앱 내부 인터페이스**이며 실제 Codex RPC 이름이 아니다.

```text
AIProvider
  checkCapabilities()
  getAccountStatus()
  beginOfficialLogin()
  listAvailableSkills(approvedRoots)
  run(jobInput, skillBinding, outputContract)
  cancel(jobId)
```

공식 RPC에 대응할 때 `initialize`, `initialized`, `account/read`, `account/login/start`, `skills/list`, `thread/start`, `turn/start` 등의 실제 메서드·필드는 검증된 버전 스키마로 연결한다. 문서의 예제를 그대로 영구 하드코딩하지 않는다. [S1]

### 실행 정책 — 이 앱의 요구

- 로컬 공식 프로세스를 자식으로 시작하고 stdout은 프로토콜, stderr는 민감정보를 걸러 진단용으로 취급한다.
- 인증 파일을 읽어 토큰을 추출하거나 앱이 OAuth refresh token을 별도로 복제하지 않는다.
- 계정·워크스페이스 식별 정보를 제공받는 범위에서 표시한다. 확인되지 않는 권한은 ‘미확인’으로 나타낸다.
- 기존 스킬은 작업별 선택을 허용한다. cwd/추가 루트·의존성·사용 가능 여부를 확인하고 기존 파일을 수정하지 않는다. [S2]
- 보고서 생성 시 선택 스킬의 식별자·해시와 앱 템플릿 버전을 기록한다. 스킬 파일이 변경되면 다음 실행에 반영하되 이전 결과를 조용히 바꾸지 않는다.
- 보고 스킬이 없을 때에는 앱의 기본 텍스트 지침으로 실행 가능한지 구분해 표시한다. ‘기존 스킬로 실행함’을 허위 표시하지 않는다.
- 로그인 실패·만료·회사 권한 제한·한도·네트워크·프로토콜 불일치·출력 검증 실패를 구분한다.
- 모델명·effort를 현재 권한에서 확인하고 기본값을 사용한다. 특정 비공개 모델이나 가격을 가정하지 않는다.
- 읽기전용 프로세스라도 원문 상태 변경은 앱의 승인된 명령만 한다. 보고 결과를 직접 DB 파일에 쓰게 하지 않는다.

### 도구·파일 경계

공식 문서에서 단순 readOnly의 읽기 접근과 제한된 readable roots는 구별된다. 읽기 전용이라는 이름만으로 파일 비노출이 보장되는 것은 아니다. [S1]

앱은 보고서 작업에 필요한 staging 디렉터리와 승인된 스킬 자료만 허용한다. Secret 저장소·백업·Keychain·클립보드·일반 사용자 홈 전체는 허용 대상이 아니다. 기본 보고 작업에서는 불필요한 shell·browser·computer use·MCP·커넥터·hook을 비활성화하거나 제한한다.

기존 스킬이 광범위한 파일/도구 권한을 요구하면 그 권한을 몰래 승계하지 않는다. 사용 불가 이유를 표시하거나 안전한 텍스트 작업으로 제한한다. 적용할 수 있는 공식 제한을 버전별로 확인하고, 제한을 검증할 수 없는 민감한 모드에서는 실행을 차단한다.

`cwd`를 바꾸는 것과 프롬프트에 ‘읽지 마라’고 쓰는 것은 접근 통제가 아니다. 가짜 Secret 표식을 가진 테스트 파일로 실제 read-denial·전송 미포함을 검사한다. 같은 사용자 권한의 악성 프로그램이나 관리자 침해까지 이 앱 혼자 방어한다고 주장하지 않는다.

## 10. Secret 저장소

### 10.1 메타데이터와 암호화 본문

```text
SecretMetadata
  id, title, groupId?, latestRevisionId, deletedAt?, createdAt, updatedAt

SecretRevision
  id, secretId, version, keyVersion, encryptedPayload, createdAt

DecryptedPayload (메모리 내부)
  schemaVersion
  items: [{ id, key: String, value: String, order: Int }]
```

JSON은 `DecryptedPayload`의 직렬화 형식이다. key/value 전체를 하나의 인증된 암호화 payload로 보관해 무결성을 확인한다. 값별 타입 변환은 하지 않는다.

Apple Keychain은 키 보관의 기반 후보이고, CryptoKit AES.GCM은 인증 암호화 구현 후보다. 구현은 공식 API·지원 조건을 확인하며 자체 암호 알고리즘을 만들지 않는다. [S6][S7]

제안: 무작위 vault key, 인증 암호화, 매 암호화의 고유 nonce, secret ID·revision·schema 정보를 바인딩한 AAD. 키는 Keychain에 보관하고 평문 설정 파일·DB·백업에 넣지 않는다. 복호화 실패 때 값을 부분적으로 보여주거나 새 키로 기존 암호문을 덮어쓰지 않는다.

### 10.2 정규화 순서

```text
사용자 표 입력
→ key/value 앞뒤 whitespace trim
→ 완전히 빈 새 행 제외
→ 빈 key의 충돌 없는 keyN 할당
→ 중복 key·행 ID·변경 대상 검증
→ 직전 revision과 비교
→ 변경이 있으면 JSON 직렬화
→ 암호화 후 revision과 metadata를 단일 transaction으로 저장
```

Swift 구현에서 `.whitespacesAndNewlines`와 동등한 앞뒤 trim을 제안한다. 내부 문자·정규화·따옴표·URL encoding은 변경하지 않는다. `key`만 trim할 뿐 value는 보존하는 과거 대화의 더 이른 설명은 적용하지 않는다. 최종 요구는 **key와 value 모두 trim**이다.

빈 값은 행 삭제가 아니다. `PASSWORD=""`를 저장할 때 따옴표를 자동 제거하지 않는다. 사용자가 표에 빈 문자열을 넣은 것과 문자열 `""`를 넣은 것은 다르다.

### 10.3 부분 수정과 버전

항목 ID로 patch한다. 표 전체의 최신 메모리 상태를 저장하더라도 바꾸지 않은 행은 보존하고 실제 변경 여부로 새 revision을 판단한다. 이력 미리보기·이전 값 복사·복원은 인증 상태에서만 가능하다.

이전 revision 복원은 과거 기록을 삭제하는 대신 그 내용을 새 최신 revision으로 저장하는 제안 기본값이다. 행 삭제 역시 새 revision으로 기록한다.

### 10.4 잠금과 클립보드

기기 인증 이후 세션 동안만 복호화 키·필요 payload를 메모리에 유지한다. 제안 기본값은 30분 idle timeout이다. 일반 앱 사용이 아니라 Secret 접근·편집·복사 활동으로 idle을 갱신한다.

화면 잠금과 앱 종료 시 vault를 잠근다. 강제 종료 후 평문 draft·로그가 남지 않게 한다. Swift 메모리의 완전한 비트 소거를 보장한다고 설명하지 않고, 메모리 유지 최소화와 플랫폼 보호를 적용한다.

클립보드 복사 시 앱이 쓴 항목의 change marker를 저장한다. 2분 후 marker가 바뀌지 않은 경우에만 해당 clipboard를 비운다. 다른 앱이 같은 문자열을 다시 복사했더라도 marker가 달라지면 지우지 않는다. 값을 비교하려고 전역 클립보드 이력을 저장하지 않는다.

### 10.5 휴지통과 영구 삭제

전체 Secret soft delete는 metadata의 deletedAt과 revision 보존으로 처리한다. 복원은 같은 ID를 유지한다. 영구 삭제 시 현재 DB의 metadata·revision·연관 title index를 삭제한다.

과거 백업·OS snapshot·다른 클립보드 관리자·디스크 잔존물까지 완전 소거한다고 보장하지 않는다. 논리 삭제와 암호화 저장의 보호 경계를 정확히 설명한다.

## 11. 백업

SQLite를 실행 중인 상태에서 단순히 `.sqlite` 파일 하나만 복사하는 대신 일관된 snapshot API를 사용한다. SQLite 공식 Online Backup API를 구현 후보로 검토한다. [S5]

작업 DB와 vault DB의 공통 snapshot 시점을 맞추기 위해 짧은 앱 저장 barrier를 걸고 두 DB를 snapshot한 뒤 해제하는 것을 제안한다. AI 작업·본문 평문을 백업하려고 vault를 복호화할 필요는 없다.

```text
백업 시작
→ 앱 저장 transaction 경계 확보
→ 두 DB snapshot + 설정 복사
→ manifest(버전·시각·파일별 hash·암호화 key version ID) 생성
→ 무결성 확인
→ 임시 디렉터리를 완료 디렉터리로 원자적 전환
→ 성공 상태 표시
→ 보존 기간이 지난 완성본만 정리
```

실패한 백업 때문에 기존 성공본을 삭제하지 않는다. 새 성공본 검증 전에는 retention 정리를 하지 않는다. 복원 전에도 현재 데이터의 복원 지점을 확보한다.

암호화 키는 같은 Mac의 기존 Keychain에 남아 있어야 한다. 키가 사라진 백업은 복호화 불가로 보고한다. 다음 기기 이관을 추가할 때에만 사용자 소유 복구 키로 래핑하는 설계를 별도로 승인받는다. 현재 버전에서 복구 능력을 과장하지 않는다.

## 12. 스케줄러와 작업 상태

영속 작업 상태는 queued / running / succeeded / failed / blockedAuth / blockedPolicy / cancelled 등을 둔다. 프로세스가 죽은 running 작업은 재시작 시 회복 대상이다.

제안 idempotency key:

```text
jobType + periodStart + periodEndExclusive + inputDigest
+ templateVersion + skillRevision + explicitRegenerationNonce?
```

기간별 자동 작업의 중복을 막고, 사용자의 의도적 재생성은 구분한다. confirm한 리포트가 있는 경우 자동 재생성 결과는 그 확정본의 덮어쓰기 대상이 아니다.

월요일 검토 알림 시각은 09:00를 제안하되 설정 가능하게 한다. OS 알림 권한이 없어도 앱 안의 준비 상태는 유지한다. 일반 창을 닫아도 동작하는 메뉴 막대 상주와 로그인 실행은 선택 설정으로 제공한다. 사용자가 앱을 완전히 종료했거나 Mac이 잠들었는데 작업이 실행됐다고 표시하지 않는다.

다량의 누락 날짜는 날짜순으로 처리하고 현재 입력을 막지 않는다. AI 동시성 기본값은 1로 시작해 실제 사용량·응답을 보며 조정한다. 요청 취소와 앱 종료 처리에 timeout을 둔다.

## 13. 향후 외부 연결 인터페이스

첫 버전에서는 `WorkLink` 저장과 타입 표시까지만 구현해도 된다. 후속 읽기 어댑터는 다음 정도로 한정한다.

```text
TaskEvidenceConnector
  canHandle(explicitTaskLink)
  fetchReadOnly(link, approvedAuthContext)
  return snapshot(title, body, state, authorInfo?, sourceUrl, fetchedAt, revision)
```

GitHub PR과 Jira 이슈 이외의 링크를 자동 탐색하지 않는다. Task에 직접 연결된 링크만 큐에 넣는다. PR 본문에 있는 다른 URL을 따라가는 재귀 수집은 범위 밖이다.

연결 서비스 인증은 회사의 공식 절차를 사용한다. 비밀번호·SSO 쿠키를 스크래핑하는 구현을 하지 않는다. 향후 connector credential은 Secret 표에 저장된 임의의 값을 자동 재사용하지 않는다.

## 14. 관찰성과 실패 처리

작업 ID, 기간, source 개수, 경과 시간, 오류 분류, 모델·스킬 식별자(반환된 정보), 재시도 횟수만 기본 로그로 남긴다. 회사 본문도 로그에서 최소화하고 Secret은 완전히 제외한다.

디버그 기능에 ‘모든 요청 dump’가 필요하더라도 실제 비밀값을 넣지 않으며 기본으로 끈다. 샘플 데이터와 MockAI 응답은 모두 가짜다.

보안 테스트는 실제 회사 키가 아닌 고유 canary 문자열을 사용한다. 검색·리포트·AI job staging·stdout/stderr·backup manifest·crash 진단을 확인한다. 미실행 테스트와 실환경 권한 미확인 상태를 UI·개발 문서에서 구분한다.
