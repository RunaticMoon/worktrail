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
