# 구현 계획 (WLOG-45A3)

## GitHub·Jira 기록 분리와 전용 목록 (0.14.0)

날짜 화면에서 수집 기록을 일반 메모와 분리한다. GitHub는 저장소·PR 번호·동작·브랜치, Jira는 이슈 키·상태 전환·작업 시간 중심으로 표시하고 긴 원문은 상세에서 확인한다. 기존 기록 ID·본문 수정·업무 연결·보고서 근거는 유지하며 v9는 표시용 JSON만 추가한다. 검색에도 GitHub/Jira 유형을 제공한다. 상세 동작과 검증은 [source-activities.md](source-activities.md)에 기록한다.

## 업무 연결과 입력 개선 (0.13.0)

Codex CLI 기본 연결·DeepSeek/OpenAI 호환 API, 업무 마감일/사전 알림, 리포트 유형 아이콘, GitHub Enterprise/Jira Cloud 일별 활동 수집, Mac 내장 마이크 우선 및 녹음 시작 보완, Secret 그룹 목록·빠른 입력 자동완성을 추가한다. 저장은 additive migration v7/v8과 인증 없는 별도 설정 파일을 사용한다. 범위·설정·제약·배포 경로는 [workflow-integrations.md](workflow-integrations.md)에 기록한다.

## 로컬 실시간 회의 음성 확장

WhisperKit 미리보기 → 원본 기반 large-v3 → SpeakerKit OSS 화자 분리를 순차 실행한다. native PCM 원본 보존, 화면과 독립된 세션, 앱별 온라인 오디오 분리, 전사 버전·사용자 수정, migration v6 및 localOnly 기본 정책을 추가한다. 구현·검증·남은 수동 확인은 [live-meeting-audio.md](live-meeting-audio.md), SDK·모델 고정과 라이선스는 [meeting-models.md](meeting-models.md)를 따른다.

기준: `docs/mac_worklog_ai_handoff/01_AI_BUILD_PROMPT.md`(실행 지시), `02_PRODUCT_SPEC.md`(요구사항 기준).

## 실행 환경 (2026-10-01 확인)
- 개발 서버: Ubuntu 24.04 aarch64 (Linux). **macOS·Xcode 없음** → SwiftUI/AppKit/Keychain/LocalAuthentication/전역 핫키는 이 환경에서 빌드·실행 불가.
- Swift 6.3.3 툴체인을 /opt/swift에 설치. SQLite 3.45.1 (FTS5 trigram 지원 여부는 테스트에서 확인).
- codex-cli 0.159.2 설치됨. `codex app-server generate-json-schema`로 실제 프로토콜 스키마를 확인(실제 Enterprise 계정 연결은 미검증).

## 아키텍처
SwiftPM 패키지 하나. `WorkLogCore`(플랫폼 공통 로직, Linux에서 전부 테스트) + `WorkLogApp`(macOS SwiftUI 얇은 UI) + `worklog`(CLI, Linux에서 사용자 여정 시연).
저장: `work.sqlite`(일반) / `vault.sqlite`(Secret 암호문) 분리. 암호화: swift-crypto(Apple 플랫폼에서는 CryptoKit 재노출) AES-GCM, 키는 KeyStore(macOS Keychain).

## 마일스톤 매핑
| 단계 | 내용 | 이 환경 검증 |
|---|---|---|
| M0 | 패키지·SQLite 래퍼·스키마·모델 계약 | Linux 빌드·테스트 |
| M1/M2 | Memo·Task 저장, 이벤트 재생, 프로젝트별 상태, 계획 | 단위 테스트 + CLI |
| M3 | Secret 정규화·암호화·버전·휴지통·잠금·클립보드 로직 | 단위 테스트 (Keychain·Touch ID는 macOS 미검증) |
| M4 | 날짜 3열 조회 모델, FTS 검색 | 단위 테스트 |
| M5 | 백업·복원 | 임시 경로 실제 테스트 |
| M6 | Codex app-server 어댑터 + MockAI | 가짜 서버 프로세스로 프로토콜 테스트, 실계정 미검증 |
| M7 | 제출용 주간보고 / 성과 리포트 / 질문 카드 / Memo 연결 / AI 답변 | 단위·통합 테스트 |
| M8 | 스케줄러 복구, 설정, macOS UI, 문서 | UI는 macOS 빌드 미검증 |

## 0.2.0 사용자 개선 요청 (2026-10-02)

날짜 팝오버, 화면 밀도 축소, 가로 3단계 업무 입력과 키보드 탐색, 생성 아이콘, 앱 내부 자동 업데이트, 0.x 버전 정책을 함께 반영한다. UI 상세와 수동 확인 항목은 `docs/ui-refresh.md`, 업데이트 배포/서명과 버전 정책은 `docs/RELEASE.md`를 따른다. Core 공용 모델과 저장 스키마는 변경하지 않는다.

## 키보드 중심 조작 개선 (2026-10-12)

빠른 입력·검색의 탭 순환/숫자키와 포커스 이동, 메인 앱 화면·사이드바·내용 이동, 오늘·업무·프로젝트 목록의 방향키/Return과 상세 복귀, 메모 수정·업무/보고서 편집 진입, Secret 입력 표의 명시적 Tab 순서를 연결했다. 설정과 별도 안내 창에 단축키를 노출한다. Core 계약 변경 없이 메모 수정은 기존 revision 보존 API를 사용한다. Linux 빌드 및 전체 테스트 재실행 771개 통과; 첫 실행의 기존 프로세스 테스트 signal 11과 macOS 확인 동선은 `docs/ui-refresh.md`에 기록한다.

## 설정과 업무 목록 개선 (2026-10-13)

설정 내부 검색·목차, 한글 정렬과 헤더 단위 포커스, 배경을 줄인 공통 버튼, 간결한 단축키 등록 상태를 반영한다. 종료 업무는 기본 접힘으로 표시하며 빠른 입력에서 취소 업무를 제외하고 패널 재오픈 시 후보를 갱신한다. 작업별 AI 모델·effort는 공용 모델 변경 없이 별도 설정 파일과 모델 목록 조회로 연결하며, 저장·복원과 실제 RPC 반영을 가짜 서버로 검증한다. 상세 동작과 검증 결과는 `docs/ui-refresh.md`를 따른다.

## 프로젝트·입력 UI 후속 개선 (2026-10-13)

화면별 ⌘N과 독립 프로젝트 생성, 단축키 설정 크기, 자동 AI 모델명 표시, @/# 연결 토큰, 직접 노출하는 프로젝트별 상태 옵션, 접힌 사이드바 상단 정렬을 반영한다. 공용 계약과 스키마 변경 없이 기존 저장·프로필 실행 경로를 사용한다. Linux 회귀 및 격리된 macOS 화면 검증 범위는 `docs/ui-refresh.md`에 기록한다.

## macOS 26 · Apple HIG 적용 (2026-10-15)

최소 지원 버전을 macOS 26.0으로 올리고 SwiftUI 표준 사이드바·툴바·시스템 버튼·날짜/분할 선택기·설정 Form·DisclosureGroup을 적용한다. Liquid Glass는 탐색과 조작 영역에 한정하고 본문에는 시스템 의미 색을 사용한다. Package.swift, 번들, Sparkle 피드, macOS CI를 함께 갱신한다. 도메인·저장 스키마·Core 공용 계약은 유지한다. 실제 변경과 검증/미검증 범위는 `docs/ui-refresh.md`의 같은 날짜 항목에 기록한다.

## 주간보고 AI 출력 형식 수정 (2026-10-19)

주간보고의 일반 텍스트 출력 예시가 JSON 반환 형식으로 오해되지 않도록 문체 참고임을 명시했다. 기존 사용자 템플릿과 과거 버전에도 실행 시점에 `SubmissionDraft`의 필수 JSON Schema를 추가하고, 제출용 작업의 `turn/start.outputSchema`에 같은 스키마를 전송한다. 필수 배열·분류값을 고정하되 Task·상태·확정 계획·근거 검증과 오류 시 기록 기반 대체 초안 저장은 유지한다. 공용 계약·DB 스키마·저장된 프롬프트 버전은 변경하지 않는다. 기존 대체 초안은 원본이 같으면 자동 재생성하지 않으므로, 수정된 앱에서 ‘AI로 다시 쓰기’를 켜고 사용자가 재생성해야 한다.

검증: Swift 6.3.3/Linux에서 `swift build --build-tests` 통과. 관련 테스트 51개 통과. 전체 814개 실행에서 신규 재생성 테스트의 이전 초안 상태 기대값 1건만 실패했다. 기존 동작인 `draft → superseded` 전환에 맞춰 테스트를 보정한 뒤 `SubmissionGenerationRegressionTests` 4개를 다시 실행해 모두 통과했다. 가짜 app-server를 통한 정상 저장, 일반 텍스트·필수 배열 누락 시 대체, 잘못된 상태·근거 거부, 대체 초안 이후 사용자 재생성과 이전 본문 보존을 확인했다. 로컬 프로토콜 스키마에서 `outputSchema` 지원을 확인했으며 실제 AI 호출·회사 계정·macOS SDK 빌드·앱 화면 검증·배포는 수행하지 않았다. 사용자 화면만으로 실제 응답의 어떤 필드가 잘못되었는지는 확정하지 않았다.

## 주간보고 업무 연결 누락 후속 수정 (2026-10-19, 0.10.2)

JSON 해석 이후 `taskIds: []`로 검증에 실패하는 경로를 보완한다. 앱이 계산한 `submissionDraft`를 AI 입력에 함께 전달하고, 항목의 업무·분류·프로젝트·확정 계획 연결은 그대로 유지하면서 문장을 다듬게 한다. 상태만 변경한 Task도 활동 근거 없이 포함한다. `taskIds` 최소 1개를 출력 스키마에 명시하고, 저장 시 원래 항목 연결과 근거의 업무 연결을 다시 검증한다. 보류·취소 검토 안내는 결정적 초안에서 보존한다. 독립 메모나 ‘기록 없음’ 안내를 임의 업무로 만들지 않으며, 제출 대상이 아예 없으면 AI를 호출하지 않고 기간·상태·계획 확인 안내를 저장한다.

회귀 범위는 가짜 Task·상태 변경과 독립 메모 혼합, 메모만 있는 기간, 보류·취소만 있는 기간, 미확정 계획, 빈 업무 ID와 유효한 다른 업무 ID 바꿔치기, 승인된 메모와 무관한 근거, 검토 안내 보존이다. 공용 모델·DB 스키마·성과자료·사용자 편집의 포함/제외 계약은 변경하지 않는다. 실제 회사 계정의 응답과 사용자 Mac 화면은 이 자동 검증의 대상이 아니다. 기존 대체 초안은 수정된 앱에서 ‘AI로 다시 쓰기’를 켜고 재생성한다. 빌드·전체 테스트·macOS DMG 검증 결과는 해당 PR과 릴리즈 실행에 기록한다.

## OAuth와 로컬 회의록 (2026-10-26, 0.11.0)

macOS AI를 공식 ChatGPT OAuth 직접 연결로 전환하고 회의 생성·관리, Apple 온디바이스 한국어 전사, 전사+직접 메모+선택 일반 메모의 요약 초안을 추가한다. 새 Meeting 모델/스키마 v5와 AIJobType.meetingSummary만 확장하며 기존 도메인 Models.swift는 유지한다. 기존 요구사항의 자동 음성 수집 제외는 유지하고 사용자가 시작한 회의 녹음만 추가한다. 설계·지원 범위·검증 방법은 `docs/oauth-meetings.md`를 따른다.
