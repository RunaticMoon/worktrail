# 구현 계획 (WLOG-45A3)

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
