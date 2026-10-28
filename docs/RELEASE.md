# 릴리즈와 앱 자동 업데이트

## 버전

- 저장소 루트 `VERSION`이 유일한 버전 원본이다. 현재 개발·개선 릴리즈는 `0.x.x`를 사용한다.
- 기능 추가·UX 개편은 minor, 수정은 patch를 올린다. major(`v1`, `v2`)는 제품 세대를 교체하기로 명시적으로 결정했을 때만 올린다.
- 릴리즈 태그는 `v` + `VERSION`이다. 형식이나 값이 다르면 빌드 전에 실패한다.
- 앱의 `CFBundleShortVersionString`과 `CFBundleVersion` 모두 `VERSION`이다. Sparkle은 후자를 비교한다. 워크플로마다 독립적인 `run_number`는 업데이트 순서에 쓰지 않는다.
- 잘못 발행된 `1.x.x` 릴리즈·태그는 이번 사용자 요청에 한해 회수하고 `0.2.0`으로 이어간다. 그 외 이미 공개된 태그를 덮어쓰거나 재사용하지 않는 원칙은 유지한다.

## 자동 업데이트

[공식 Sparkle 2](https://sparkle-project.org/documentation/)의 `SPUStandardUpdaterController`를 사용한다. 의존성은 `2.10.0`에 고정하고 macOS에서만 resolve한다. Linux Core 빌드·테스트에는 Sparkle 의존성이 없다.

- WorkLog 메뉴, 메뉴 막대 상주 메뉴, 설정에서 **업데이트 확인…**을 실행할 수 있다.
- 기본적으로 하루에 한 번 새 버전을 확인한다. 설정에서 자동 확인·다운로드를 바꾸면 즉시 적용된다. 다운로드 후 설치·재시작은 Sparkle UI에서 선택한다.
- 공개 feed는 `https://github.com/RunaticMoon/worktrail/releases/latest/download/appcast.xml`이다. draft 공개 전에는 기존 latest feed가 유지된다.
- DMG와 feed 모두 전용 Ed25519 키로 서명한다. 앱에 포함된 공개키로 서명을 확인하고 **검증 후에만** DMG를 연다(`SURequireSignedFeed`, `SUVerifyUpdateBeforeExtraction`).
- 회사 기록·Secret·AI 입력은 업데이터에 전달하지 않는다. Sparkle 시스템 프로필 전송도 켜지 않는다.
- 업데이터가 없던 기존 `1.x.x`/`0.1.0` 앱은 `0.2.0`을 한 번 직접 설치해야 한다.

Apple Developer ID/공증과 Sparkle의 Ed25519 업데이트 서명은 별개다. [Sparkle 공식 보안 지침](https://sparkle-project.org/documentation/#3-segue-for-security-concerns)은 Developer ID를 가능한 경우 권장하고 Ed25519 검증을 지원한다. Apple 계정 없이도 후자를 쓸 수 있다. 앱은 업데이트 간 Keychain 접근 승인을 유지하도록 고정 자체서명 인증서를 사용한다. 첫 설치 시 Gatekeeper 승인이 필요할 수 있는 제한은 그대로다. Team ID가 없는 자체서명 앱에서 Sparkle을 로드할 수 있도록 Hardened Runtime Library Validation은 켜지 않는다.

## 전용 앱 서명 인증서 최초 등록

업데이트마다 나타나던 Keychain 승인은 ad-hoc 서명이 앱 바이너리 버전마다 달라지기 때문이다. [Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)과 [TN2206](https://developer.apple.com/library/archive/technotes/tn2206/)에 따라, 같은 인증서와 designated requirement(DR)를 계속 사용한다. Apple 개발자 계정 없이 생성한 자체서명 인증서도 Keychain의 앱 식별에 사용할 수 있다.

인증된 `gh` CLI와 OpenSSL 3이 있는 환경에서 한 번 실행한다.

```sh
python3 distribution/provision-code-signing-key.py
```

이 명령은 새 전용 RSA 3072 코드 서명 키·인증서를 만들고 PKCS#12를 GitHub Actions secret **`WORKLOG_CODESIGN_P12`**에 등록한다. 공개 인증서 **`distribution/code-signing-cert.pem`**만 저장소에 커밋한다. 기존 인증서·같은 이름의 secret이 있으면 덮어쓰지 않으며, 기존 Keychain·회사 자격증명·Codex 토큰을 읽지 않는다. 개인키는 메모리와 표준입력에서만 다룬다. PKCS#12는 macOS/OpenSSL의 빈 암호 호환성 문제를 피하기 위한 공개 고정 문자열을 암호로 사용한다. 비밀성은 GitHub Secret 암호화로 보호하므로 PKCS#12를 파일·로그·artifact에 보관하지 않는다.

릴리즈 서명 step은 PKCS#12의 공개 인증서를 먼저 대조한 뒤, 전용 임시 keychain으로만 가져온다. [Apple DTS 설명](https://developer.apple.com/forums/thread/728073)에 따라 `--keychain`만으로는 인증서를 찾을 수 없으므로, 서명 중 사용자 keychain 검색 목록을 전용 임시 keychain 하나로 제한한다. 이 설정 변경은 일회용 GitHub-hosted macOS 러너에서만 허용한다. 기존 목록은 경로 이름만 읽어서 보존하고 성공/실패 후 정확히 복원·대조하며, 임시 keychain·파일을 삭제한 뒤 서명을 검증한다. 인증서 신뢰 설정이나 시스템 인증 정책은 변경하지 않는다. 설치하는 사용자 Mac의 login keychain·신뢰 설정은 변경하지 않으며 인증서를 설치할 필요도 없다. DR은 `dev.worklog.WorkLog`와 공개 인증서의 정확한 hash에 묶으며, bundle ID나 인증서 이름만 일치하는 다른 앱에는 접근을 허용하지 않는다. 누락·잘못된 secret·다른 인증서·ad-hoc 서명은 패키징/DMG 검증에서 실패하고 자동으로 대체하지 않는다.

인증서와 secret은 릴리즈마다 재생성하지 않는다. 잃어버리거나 교체하면 사용자 재승인이 필요하다. 기존 ad-hoc 버전에서 처음 전환할 때는 Keychain의 **항상 허용**을 한 번 더 선택해야 할 수 있으며, 이후 같은 인증서로 서명한 업데이트는 그 승인을 이어받는다. 기존 vault 키·service/account·암호문·ACL은 수정하거나 삭제하지 않는다. 이 서명은 Apple 공증이나 Gatekeeper 승인을 대신하지 않는다.

## 전용 업데이트 키 최초 등록

한 번만 실행한다. 인증되어 있는 `gh` CLI와 Ed25519를 지원하는 OpenSSL이 필요하다.

```sh
python3 distribution/provision-update-key.py
```

이 명령은 **새 업데이트 전용 키**만 생성한다. 기존 Keychain·회사 자격증명·Codex 토큰을 읽지 않는다. 비밀키는 메모리와 `gh` 표준입력으로만 전달해 `RunaticMoon/worktrail` 저장소 Actions secret **`WORKLOG_SPARKLE_PRIVATE_KEY`**에 등록한다. 디스크에는 공개키 `distribution/sparkle-public-key.txt`만 저장하며 이 파일은 커밋한다. 기존 공개키 또는 같은 이름의 secret이 있으면 덮어쓰지 않는다.

Sparkle 2.10의 현재 키 포맷은 `base64(32-byte seed)`다([공식 소스](https://github.com/sparkle-project/Sparkle/blob/2.10.0/common_cli/Secret.swift)). 비밀키를 인자·로그·소스·artifact에 넣지 않는다. SwiftPM 도구 resolve는 비밀키 없는 별도 step에서 수행한다. 서명 step은 CryptoKit으로 seed에서 공개키를 재계산해 커밋된 공개키와 비교하고 `sign_update --ed-key-file -`의 표준입력으로만 키를 보내며 Keychain fallback을 허용하지 않는다. 전용 secret을 삭제하면 같은 키를 복구할 수 없으므로 보존해야 한다. Developer ID가 없는 배포에서 키를 잃으면 기존 앱으로 자동 업데이트할 수 없고 재설치가 필요하다.

## 새 버전 릴리즈 절차

1. `VERSION`을 올리는 PR을 main에 머지한다. Sparkle 공개키·앱 서명 공개 인증서가 커밋되고 대응하는 두 전용 secret이 등록되어 있어야 한다.
2. 머지된 main의 커밋 SHA를 확인한다: `git rev-parse origin/main`.
3. 검토된 정확한 SHA로 수동 워크플로를 실행한다.

```sh
gh workflow run macos-release.yml --ref main \
  -f commit=<main의 40자 SHA> -f tag=v0.2.0 -f publish=artifact-only
# publish는 artifact-only / draft / publish 중 선택
gh run list --workflow macos-release.yml --limit 3
```

| `publish` | 결과 |
|---|---|
| `artifact-only` (기본) | 테스트·DMG 빌드·검증 후 Actions artifact 보관(14일). Release 생성·업데이트 서명 없음 |
| `draft` | 위 + 전용 키로 DMG·appcast 서명, draft Release 생성, 업로드·재다운로드 바이트 비교 |
| `publish` | 위 + draft를 공개 Release/latest로 전환. 설치된 앱의 새 feed가 됨 |

빌드·테스트·의존성 다운로드에는 쓰기 권한·서명키가 없다. 앱 조립 후 별도 서명 step만 전용 앱 서명 secret을 받는다. publish job의 업데이트 서명 step만 전용 Sparkle secret을 받으며, `GITHUB_TOKEN`은 실제 Release 게시 step에만 주입된다.

산출물은 `WorkLog-<VERSION>-arm64.dmg`, DMG SHA-256을 담는 `release-manifest.json`, 서명된 `appcast.xml`이다. feed의 버전·다운로드 원본·파일명·크기를 검증하고 DMG/feed 서명을 공식 Sparkle 도구로 다시 검증한다. 업로드 후 세 파일을 다시 받아 로컬 바이트와 비교한 뒤 공개한다. 같은 태그의 tag/Release(초안 포함)가 있으면 덮어쓰지 않고 실패한다.

## 빌드 검증

macOS CI와 릴리즈 job은 다음을 확인한다.

1. `swift build --build-tests`, `swift test`
2. 아이콘을 `.icns`로 만들고 Sparkle framework를 symlink·실행권한·helper 서명 그대로 앱에 포함
3. DMG 안 앱 이름·버전·최소 macOS 26.0·bundle ID·arm64 실행 파일·아이콘·Sparkle 공개키/feed 설정 검사
4. `codesign --verify --deep --strict`, 실행 파일의 framework 링크·런타임 검색 경로 검사. 릴리즈는 공개 인증서·고정 DR까지 패키징 전과 마운트된 DMG에서 각각 검사
5. 마운트된 앱의 `--updater-smoke-test` 실행: 실제 dyld framework 로딩과 updater 생성 확인. 앱 `AppController`를 만들기 전에 종료하므로 저장소·Keychain·AI·업데이트 네트워크에 접근하지 않음
6. DMG manifest·SHA-256 확인

`--skip-build`는 기존 앱 버전이 `VERSION`과 다르면 실패한다. 공개키가 없는 개발용 `.app`은 자동 업데이트를 비활성화하며 릴리즈 workflow는 공개키 누락 시 실패한다.

## 서명과 설치

- 릴리즈 앱은 **고정 자체서명 인증서**로 코드 서명한다. Developer ID 서명·Apple 공증이 없어 Gatekeeper가 첫 실행을 막을 수 있다. 앱과 소스를 확인한 뒤 시스템 설정 › 개인정보 보호 및 보안에서 직접 허용한다. quarantine 속성을 지우거나 Gatekeeper를 끄는 스크립트는 없다.
- 로컬 `build-macos-app.sh`와 PR CI는 여전히 ad-hoc 서명으로 조립하며 개인키를 받지 않는다. 이 산출물을 릴리즈 대신 설치하면 Keychain 재승인이 필요할 수 있다. 릴리즈 workflow는 조립 후 반드시 고정 인증서로 다시 서명한다.
- Apple Silicon(arm64), macOS 26.0 이상 전용이다. Package.swift·번들 `LSMinimumSystemVersion`·Sparkle `minimumSystemVersion`을 모두 26.0으로 유지한다. 이전 macOS에는 이 업데이트를 제공하지 않는다.
- CI smoke는 framework 로딩까지 검증한다. 사용자 Mac에서의 첫 설치 승인과 실제 다운로드 → 교체 → 재시작 전체 흐름은 별도 수동 검증 대상이다.

## 로컬 확인

```sh
python3 -m unittest discover -s distribution/tests -v
bash -n scripts/*.sh distribution/*.sh
scripts/build-dmg.sh
bash distribution/verify-dmg.sh "release/WorkLog-$(cat VERSION)-arm64.dmg" "$(cat VERSION)"
```

같은 release 디렉터리에 이전 버전 DMG가 있으면 manifest 검사가 실패한다. 빌드·DMG·Sparkle 런타임 검증은 macOS에서 실행한다.

서명 회귀 테스트는 Linux에서 인증서/P12 생성·검증·실패 시 차단을, 일회용 macOS CI에서는 새 가짜 인증서·임시 keychain으로 서로 다른 두 앱 바이너리의 DR 호환성과 가짜 항목의 재승인 없는 읽기·다른 서명자 거부를 확인한다. 패키징한 앱의 임시 복사본에도 가짜 인증서로 서명해 Sparkle 로더 smoke를 실행한다. macOS 테스트에는 Homebrew `openssl@3`를 PATH 앞에 둔다. 이 테스트는 실제 사용자의 Keychain 경고나 기존 항목의 최초 재승인을 자동으로 검증하지 않는다.

2026-10-19 검증: [macOS CI 39239121884](https://github.com/RunaticMoon/worktrail/actions/runs/39239121884)에서 앱 전체 빌드, Core 테스트 826개, 배포 도구 테스트, 가짜 Keychain 업데이트 연속성·다른 서명자 거부, DMG 패키징과 자체서명 앱의 Sparkle 로더 실행을 통과했다. 실제 사용자 항목의 최초 재승인과 Sparkle의 전체 업데이트 설치는 별도 확인 대상이다.

### 업데이트 후 시작 시 Keychain 창 방지

2026-10-28 재조사에서 공개 v0.15.0 DMG를 읽기 전용으로 마운트하여 `code_signing.py verify`를 통과했다(앱 실행 없음). 공개 앱 DR은 `identifier "dev.worklog.WorkLog" and certificate leaf = H"bc82901fe15589e2a0f095c2b84dc6915680ccc8"`로 고정돼 있었다. 원본 체크아웃 `.build/app/WorkLog.app`의 v0.13.0은 개발용 ad-hoc 서명(`cdhash`)이었다. 두 산출물을 혼동하면 안 된다. 사용자 설치본은 기본 설치 경로에서 발견하지 못했으므로 실제 경고가 이전 ad-hoc 항목의 ACL 때문인지, 잠긴 login Keychain 때문인지는 미확인이다.

앱을 여는 과정에서 `SecretVault.init`이 곧바로 키를 조회·생성하던 경로를 제거했다. 앱 시작, 백업 생성, 잠금 상태 제목 검색은 Keychain에 접근하지 않는다. 기존 키 버전을 보존하고 사용자가 Secret 잠금 해제를 요청할 때만 조회하며, 일시적인 접근 거절은 다음 명시적 요청에서 재시도한다. 키가 실제로 없으면 새 키로 덮어쓰지 않는다. 기존 기기 인증과 암호화는 유지한다.

자동 활동 수집과 예약 AI 요청은 Keychain 인증창 없이 읽기를 시도한다. 승인이 필요하면 실패 상태를 남기고 해당 작업을 중단한다. 설정의 연결 상태 확인·모델 조회, 지금 수집, 키 저장/삭제는 사용자가 선택한 요청이므로 기존 승인 UI를 허용한다. 정상 서명의 기존 승인 항목은 그대로 읽으며, 이전 ACL을 우회하거나 모든 앱에 접근 권한을 주지 않는다.

macOS 파일 기반 Keychain은 `kSecUseNoAuthenticationUI` 같은 Data Protection 전용 쿼리 플래그만으로 UI를 차단할 수 없다(macOS SDK `SecItem.h` 명시). [Apple의 UI 제어 문서](https://developer.apple.com/documentation/security/seckeychainsetuserinteractionallowed(_:))에 따라 비대화형 조회 동안 `SecKeychainSetUserInteractionAllowed(false)`를 적용하고 원래 상태를 복원한다. 앱의 모든 파일 Keychain 연산은 같은 동기 잠금을 거치므로 자동 조회가 명시적 승인 요청의 정책을 바꾸지 않는다. [Apple 동시성 지침](https://developer.apple.com/documentation/security/working-with-concurrency)도 macOS Security API 호출의 직렬화를 안내한다. 검색 목록, 인증서 신뢰, Keychain 잠금 설정, 기존 항목·ACL은 변경하지 않는다.

가짜 저장소 회귀 테스트는 첫 실행/업데이트 재실행의 Keychain 무접근, 시작 백업, 명시적 재시도, 키 누락 시 암호문 보존을 검증한다. 가짜 UI 정책 테스트는 성공·실패 후 복원, 중첩/동시 요청, 정책 변경 실패 시 조회 차단을 검증한다. 실제 사용자 Keychain·토큰·회사 데이터는 검증에 사용하지 않는다. 이전 승인 기록이 없는 항목의 최초 승인과 실제 설치본 업데이트 후 동작은 사용자 환경에서 추가 확인해야 한다.
