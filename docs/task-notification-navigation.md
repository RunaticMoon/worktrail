# 마감 알림의 업무 입력 보호 (0.16.2)

## 수정 범위

[이슈 #52](https://github.com/RunaticMoon/worktrail/issues/52)의 알림 경로는 현재 업무 ID를 바꾸면서 이전 진행 기록·체크리스트 입력을 유지했다. 이후 저장하면 다른 업무에 기록될 수 있었다.

`AppController.openTask`에서 업무 선택과 모델 전환을 함께 처리한다. 미저장 진행 기록·체크리스트·상태 변경 사유가 있으면 이동을 보류하고 **계속 편집 / 입력 버리고 이동**을 표시한다. 취소하면 업무·입력·날짜·프로젝트 범위·과거 조회 기준을 유지한다. 명시적으로 버리면 입력을 지운 뒤 새 업무를 연다. 모델의 직접 `load`도 미저장 입력이 있는 다른 선택을 거절한다.

같은 업무·같은 조회 기준의 알림은 현재 편집을 다시 로드하지 않는다. 일반 저장 후 새로고침은 다른 입력과 날짜·범위를 보존한다. 상태 변경 사유는 성공적으로 저장한 값을 기준으로 미저장 여부를 판단하며, 저장 실패나 완료 확인 취소는 저장으로 처리하지 않는다.

업무 정보·체크리스트 수정·이력 정정 등 중첩 편집창과 완료/닫기 확인창이 열려 있으면 외부 업무 열기를 보류한다. 편집창을 닫은 뒤 공통 전환 경로로 재진입한다. 한글 조합 중에도 조합이 끝날 때까지 기다린다. 첫 대기 요청을 유지하고, 상세 닫기·재시작 시 대기 작업을 정리한다. 알림은 기존 메인 창을 활성화하며 매번 새 창을 생성하지 않는다.

DB·마이그레이션·Secret·AI 입력 계약은 바꾸지 않는다. #50의 회의 오류 코드 수정은 기존 PR #51에 이미 포함되어 있다. 실제 사용자 녹음 재현은 [회의 오류 문서](meeting-error-recovery.md)의 미검증 범위로 남으므로 이번 PR에서 #50을 닫지 않는다.

## 검증

2026-10-29 KST, 가짜 계정과 임시 저장소만 사용했다.

- M1 Apple Swift 6.4 / Xcode 27.1 / SDK 27: `swift build --build-tests` 성공. Swift 언어 모드 5, 최소 macOS 26.0 유지. 로컬 설치 도구체인이 지침의 Swift 6.3과 다르므로 해당 버전의 Core 호환성은 아래 Linux 검사로 별도 확인했다.
- macOS `swift test --skip-build`: 전체 **1,146개 통과**, 새 모델 회귀 **12개** 포함. 취소/폐기·업무 귀속·날짜/범위·과거 기준·조회/저장 실패·상태 사유 저장 기준을 검사한다.
- OCI의 일회용 `swift:6.3.3-noble` arm64 컨테이너: 빌드, 신규 12개, 기존 업무 편집 13개, 전체 **1,146개 통과**(88.153초). 이미지 digest `sha256:1038d54c80063f5cdfabc4560990c30af64b5de8ebf28161deb22ca4ad5db866`. 컨테이너에만 SQLite 개발 패키지를 설치했고 호스트·운영 서비스는 변경하지 않았다.
- 최초 양쪽 전체 검사는 저장된 상태 사유를 미저장으로 오판하여 기존 `TaskEditingWorkflowTests` 1개가 실패했다. 저장 성공 기준을 추가한 뒤 기존 테스트를 수정하지 않고 전체 재실행이 통과했다.
- 배포 도구 `python3 -m unittest discover -s distribution/tests -v`: 60개 중 55개 통과, 환경 조건에 따른 5개 skip. 실제 사용자 Keychain을 검사하지 않았다.
- `bash scripts/maclab/run-task-navigation-check.sh`: 실제 `AppController`와 모델의 통합 회귀 7그룹 통과. 취소 후 A 저장, 명시적 폐기, 동일 선택, 중첩 업무 정보 편집의 A 귀속, 부모 초안 재확인, 첫 대기 대상 유지/닫기 정리, 조회 실패 재시도를 검사한다. 앱 진입점과 실제 전역 핫키 어댑터만 테스트 대역으로 바꾸며 네트워크를 차단한다. 창·알림·IME는 이 검사에서 실행하지 않는다.

### 화면·알림 확인 범위

DEBUG 전용 `--ui-test-fixture many --ui-test-task-notification cancel|discard|same`은 `dev.worklog.TaskNavigationReview` 번들과 임시 가짜 저장소에서만 동작한다. 실제 OS 알림을 선택적으로 예약하며, helper는 정확한 합성 알림 제목만 클릭한다.

이 M1에서는 리뷰 번들의 알림 **권한 요청**이 코드 1(`UNErrorCodeNotificationsNotAllowed`)로 실패했다. `usernoted`의 해당 bundle 로그도 클라이언트 식별자 검증 실패를 나타냈다. OS 권한이나 사용자 알림 설정을 변경하지 않았다. 따라서 **실제 알림 센터 클릭 수용 검증은 미완료**다. 콜백/모델 통과를 실제 알림 클릭 통과로 해석하지 않는다.

OS 알림을 사용할 수 없는 검증 환경에는 명시적 `--ui-test-task-notification-dispatch callback` 옵션을 제공한다. 같은 스케줄러의 운영 `onOpenTask` 콜백을 호출하고 helper 결과에 `actualNotificationClicked=false`, `callbackInvoked=true`를 구분한다. 이 옵션 없이 OS 검사가 실패했다고 자동으로 콜백 방식으로 넘어가지는 않는다.

이 명시적 콜백 방식의 실제 macOS 화면 검사 **3건(cancel/discard/same)이 모두 종료 코드 0으로 통과**했다. 취소(Escape) 후 A의 입력·날짜·범위·사유 유지, 입력 폐기 후 B의 빈 입력과 저장/추가 비활성, 동일 업무 알림 후 입력 유지와 A에 대한 진행 기록·체크리스트 저장을 확인했다. 키보드와 AX 버튼 액션을 함께 사용했다. 가짜 알림 클라이언트 제한 때문에 `UNUserNotificationCenterDelegate`에 실제 OS 클릭 응답이 들어오는 구간은 실행하지 않았다.

실제 한글 IME 조합 중 알림 클릭과 사용자 설치본에서도 추가 확인이 필요하다. 일반 입력·키보드 확인과 모델 테스트는 그 검증을 대신하지 않는다.

## 배포와 롤백

운영 대상은 GitHub Releases의 Apple Silicon DMG와 Sparkle 업데이트 피드다. 이 M1의 기본 설치 경로에는 운영 WorkLog 앱이 없으며, 기존 `.build/app` 및 `/tmp` 리뷰 앱을 사용자 설치본으로 취급하지 않는다.

승인된 PR HEAD를 merge → M1 원본 `/Users/runatic/Workspace/worktrail` main `pull --ff-only` → clean 및 `origin/main` 일치를 확인한 뒤, 정확한 merge SHA로 `macos-release.yml`을 `tag=v0.16.2`, `publish=publish`로 실행한다. CI가 고정 인증서 앱 서명과 Sparkle DMG/feed 서명, 업로드 자산 재다운로드 검증을 수행한다. 새 정식 바이너리는 승인 뒤 CI에서 생성하므로 사전 체크섬은 없으며 생성 후 manifest·DMG SHA256·고정 코드서명·피드 버전을 검증한다. manifest에는 소스 SHA가 없으므로 tag commit, release target, workflow 소스 SHA를 별도로 대조한다.

기존 v0.16.1 자산과 태그를 보존한다. 배포 실패 시 v0.16.1을 latest로 복구하고 공개 feed가 이전 버전을 가리키는지 확인한다. 이미 설치된 앱은 자동 다운그레이드하지 않으며 필요하면 보존된 DMG로 재설치한다. 저장 스키마 변경은 없다.
