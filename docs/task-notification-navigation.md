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

2026-10-29에는 리뷰 번들의 알림 **권한 요청**이 코드 1(`UNErrorCodeNotificationsNotAllowed`)로 실패했다. 2026-10-31 재진단 결과 원인은 번들 위치였다. `/tmp`(`/private/tmp`)의 앱은 LaunchServices에 `in-temp-dir`로 등록되고, `usernoted`의 `LSCopyApplicationURLsForBundleIdentifier`가 `kLSApplicationNotFoundErr`를 반환한 뒤 "Failed to find or validate client"로 요청을 거절한다. 서명(ad-hoc)이나 OS 설정 문제가 아니었다.

따라서 실제 OS 알림 방식은 같은 리뷰 번들을 `ditto`로 임시 디렉터리 밖(helper 기준 `~/.local/state/worktrail-issue-52-review/TaskNavigationReview.app`)에 두고 실행한다. 아래 실행은 같은 번들을 `~/.local/state/gh52-noti-20261031/review/`에 두고 helper 경로 검사만 그 위치로 바꾼 로컬 사본으로 했다. 임시 디렉터리 밖에서는 시스템 알림 권한 배너가 표시되었다. 권한은 가짜 리뷰 번들 `dev.worklog.TaskNavigationReview`의 배너에서만 허용했고, 다른 앱 알림·개인정보 보호(TCC)·운영 `dev.worklog.WorkLog` 설정은 변경하지 않았다.

OS 알림을 사용할 수 없는 검증 환경에는 명시적 `--ui-test-task-notification-dispatch callback` 옵션을 제공한다. 같은 스케줄러의 운영 `onOpenTask` 콜백을 호출하고 helper 결과에 `actualNotificationClicked=false`, `callbackInvoked=true`를 구분한다. 이 옵션 없이 OS 검사가 실패했다고 자동으로 콜백 방식으로 넘어가지는 않는다.

2026-10-29에는 이 명시적 콜백 방식의 실제 macOS 화면 검사 **3건(cancel/discard/same)이 모두 종료 코드 0으로 통과**했다. 취소(Escape) 후 A의 입력·날짜·범위·사유 유지, 입력 폐기 후 B의 빈 입력과 저장/추가 비활성, 동일 업무 알림 후 입력 유지와 A에 대한 진행 기록·체크리스트 저장을 확인했다. 키보드와 AX 버튼 액션을 함께 사용했다. 당시 권한 거절 때문에 `UNUserNotificationCenterDelegate`에 실제 OS 클릭 응답이 들어오는 구간은 실행하지 못했고, 위 2026-10-31 실행에서 확인했다.

### 실제 알림 센터 클릭 결과 (2026-10-31 KST)

`b0a50df`에서 만든 DEBUG 리뷰 번들과 가짜 `many` 저장소만 사용했다. `b0a50df`와 v0.16.2 태그 `a7b52bb`의 소스 트리는 동일하다(`git diff` 없음). 그러나 실행한 것은 정식 v0.16.2 바이너리가 아니다. 리뷰 번들은 DEBUG 빌드, ad-hoc 서명(CDHash `3832f8679f651b50bd1cb12ab76a7288d4ea0bb3`), 번들 ID `dev.worklog.TaskNavigationReview`, 임시 가짜 저장소를 쓴다. 정식 앱은 release 빌드, 고정 인증서 서명, `dev.worklog.WorkLog`, 사용자 저장소를 쓴다. helper가 알림 센터의 정확한 합성 제목 배너를 실제 마우스 이벤트로 클릭했다. 운영 `UNUserNotificationCenterDelegate` 응답 경로를 거쳤으며 콜백 직접 호출이 아니다. 결과는 모두 `actualNotificationClicked=true`, `callbackInvoked=false`, `realDataRead=false`다.

| 동작 | 결과 | 확인 내용 |
| --- | --- | --- |
| cancel | 통과 | 이동 확인창 표시, 계속 편집 후 A·진행 기록·체크리스트·날짜·프로젝트 범위·상태 사유 유지 |
| discard | 통과 | 입력 버리고 이동 후 B 표시, B 입력 비어 있음, A 문구 없음, 빈 입력 저장/추가 비활성 |
| same | 통과 | 확인창 없음, 입력 유지, A에 진행 기록과 체크리스트 저장 |

이 M1 화면에는 다른 작업이 남긴 시스템 창 두 개가 앞에 떠 있었다. 2026-10-29 15:18 KST `swift-package`가 요청한 키체인 SecurityAgent 대화상자(요청 프로세스는 이미 종료)와 다른 앱의 충돌 보고 창이다. 이 창들을 건드리지 않았다. SecurityAgent 창이 키보드 초점을 가져가 System Events 키 입력이 앱에 전달되지 않았다(같은 Escape를 앱 프로세스에 직접 보내면 확인창이 정상 종료됨). 그래서 이번 실행은 로컬 helper 사본에서 키 입력만 `CGEventPostToPid`로, 확인창 버튼은 겹침을 피하려 AX `AXPress`로 보냈다. 알림 클릭 자체는 실제 HID 마우스 이벤트다. 저장소의 helper는 기본 System Events 키 입력을 유지한다.

### 한글 IME 조합 중 알림 (부분 확인)

두벌식 입력으로 A의 진행 기록 끝에 `하`를 조합한 상태에서 실제 알림을 클릭했다. 클릭 직후 이동 확인창이 표시되었고, 계속 편집 후 A의 진행 기록은 기존 문구 + `하`로 유지되었다. 입력 손실이나 B로의 이동은 없었다. 실행 후 입력 소스는 ABC로 복원했다.

다만 "조합이 끝날 때까지 대기" 경로는 이 화면에서 검증하지 못했다. 알림 클릭 없이 콜백만 호출한 경우에도 조합 문자가 보이는 상태에서 확인창이 바로 표시되었다. 대기 판정은 `NSApp.keyWindow`의 first responder를 확인하는데, 위 SecurityAgent 창이 키 창 상태를 가져간 것으로 보이며(앱의 AX focused window가 비어 있음) 이 환경에서는 조합 중 여부를 판정할 수 없다. 따라서 실제 알림 클릭이 조합을 먼저 확정했는지, 대기 경로가 정상 동작하는지는 **미확정**이다. 남은 시스템 대화상자를 사용자가 닫은 뒤 일반 키 입력으로 재검증해야 한다.

### 사용자 설치본

과거 사용자 설치본의 버전은 알 수 없다. 운영 바이너리는 저장소를 `FileManager.homeDirectoryForCurrentUser` 기준 `~/Library/Application Support/WorkLog`로 고정하고, 금고 키를 로그인 키체인의 `dev.worklog.WorkLog` 서비스에 둔다. `HOME` 환경 변수로는 홈 경로가 바뀌지 않아(2026-10-31 확인) 같은 macOS 계정에서는 저장소를 격리할 수 없다. 운영 마감 알림은 알림일 09:00(업무 시간대)에만 예약되므로 즉시 재현할 수 없다.

따라서 정식 v0.16.2 바이너리에서의 실제 알림 클릭 확인은 **미실행**이다. 일반 HID 키 입력으로 확인하는 한글 조합 대기 경로도 **미실행**이다. 가짜 리뷰 번들 결과·콜백 검사·일반 입력·모델 테스트는 이 두 검증을 대신하지 않는다.

선택 후속 절차(사용자가 선택한 경우에만, 별도 #50 설치 검증이 끝난 뒤): 가짜 데이터만 있는 설치 검증 저장소에 가짜 업무 A와 B를 추가하고, B는 마감 2026-11-01·당일 알림(0일 전)으로 두어 2026-11-01 09:00 KST에 한 번만 알림이 오게 한다. 알림 직전 A 상세에 미저장 진행 기록·체크리스트를 입력하고, 실제 알림 클릭 후 계속 편집(입력 유지)과 입력 버리고 이동(B에 A 문구 없음)을 확인한다. 끝나면 A·B를 휴지통으로 옮기고 남은 마감 알림 예약이 없는지 확인한다. 공유 저장소·키체인을 바꾸거나 다른 검증 데이터를 재사용하지 않는다.

## 배포와 롤백

운영 대상은 GitHub Releases의 Apple Silicon DMG와 Sparkle 업데이트 피드다. 이 M1의 기본 설치 경로에는 운영 WorkLog 앱이 없으며, 기존 `.build/app` 및 `/tmp` 리뷰 앱을 사용자 설치본으로 취급하지 않는다.

승인된 PR HEAD를 merge → M1 원본 `/Users/runatic/Workspace/worktrail` main `pull --ff-only` → clean 및 `origin/main` 일치를 확인한 뒤, 정확한 merge SHA로 `macos-release.yml`을 `tag=v0.16.2`, `publish=publish`로 실행한다. CI가 고정 인증서 앱 서명과 Sparkle DMG/feed 서명, 업로드 자산 재다운로드 검증을 수행한다. 새 정식 바이너리는 승인 뒤 CI에서 생성하므로 사전 체크섬은 없으며 생성 후 manifest·DMG SHA256·고정 코드서명·피드 버전을 검증한다. manifest에는 소스 SHA가 없으므로 tag commit, release target, workflow 소스 SHA를 별도로 대조한다.

기존 v0.16.1 자산과 태그를 보존한다. 배포 실패 시 v0.16.1을 latest로 복구하고 공개 feed가 이전 버전을 가리키는지 확인한다. 이미 설치된 앱은 자동 다운그레이드하지 않으며 필요하면 보존된 DMG로 재설치한다. 저장 스키마 변경은 없다.
