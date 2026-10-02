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

Apple Developer ID/공증과 Sparkle의 Ed25519 업데이트 서명은 별개다. [Sparkle 공식 보안 지침](https://sparkle-project.org/documentation/#3-segue-for-security-concerns)은 Developer ID를 가능한 경우 권장하고 Ed25519 검증을 지원한다. Apple 계정 없이도 후자를 쓸 수 있다. 첫 설치 시 Gatekeeper 승인이 필요할 수 있는 제한은 그대로다. 이 빌드는 Hardened Runtime Library Validation을 켜지 않는 ad-hoc 앱이며, [공식 통합 문서의 ad-hoc 로딩 제한](https://sparkle-project.org/documentation/#1-add-the-sparkle-framework-to-your-project)을 따른다.

## 전용 업데이트 키 최초 등록

한 번만 실행한다. 인증되어 있는 `gh` CLI와 Ed25519를 지원하는 OpenSSL이 필요하다.

```sh
python3 distribution/provision-update-key.py
```

이 명령은 **새 업데이트 전용 키**만 생성한다. 기존 Keychain·회사 자격증명·Codex 토큰을 읽지 않는다. 비밀키는 메모리와 `gh` 표준입력으로만 전달해 `RunaticMoon/worktrail` 저장소 Actions secret **`WORKLOG_SPARKLE_PRIVATE_KEY`**에 등록한다. 디스크에는 공개키 `distribution/sparkle-public-key.txt`만 저장하며 이 파일은 커밋한다. 기존 공개키 또는 같은 이름의 secret이 있으면 덮어쓰지 않는다.

Sparkle 2.10의 현재 키 포맷은 `base64(32-byte seed)`다([공식 소스](https://github.com/sparkle-project/Sparkle/blob/2.10.0/common_cli/Secret.swift)). 비밀키를 인자·로그·소스·artifact에 넣지 않는다. SwiftPM 도구 resolve는 비밀키 없는 별도 step에서 수행한다. 서명 step은 CryptoKit으로 seed에서 공개키를 재계산해 커밋된 공개키와 비교하고 `sign_update --ed-key-file -`의 표준입력으로만 키를 보내며 Keychain fallback을 허용하지 않는다. 전용 secret을 삭제하면 같은 키를 복구할 수 없으므로 보존해야 한다. Developer ID가 없는 배포에서 키를 잃으면 기존 앱으로 자동 업데이트할 수 없고 재설치가 필요하다.

## 새 버전 릴리즈 절차

1. `VERSION`을 올리는 PR을 main에 머지한다. 공개키 파일이 커밋되어 있어야 한다.
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

빌드 job은 쓰기 권한·서명키가 없다. publish job의 서명 step만 전용 업데이트 secret을 받으며, `GITHUB_TOKEN`은 실제 Release 게시 step에만 주입된다.

산출물은 `WorkLog-<VERSION>-arm64.dmg`, DMG SHA-256을 담는 `release-manifest.json`, 서명된 `appcast.xml`이다. feed의 버전·다운로드 원본·파일명·크기를 검증하고 DMG/feed 서명을 공식 Sparkle 도구로 다시 검증한다. 업로드 후 세 파일을 다시 받아 로컬 바이트와 비교한 뒤 공개한다. 같은 태그의 tag/Release(초안 포함)가 있으면 덮어쓰지 않고 실패한다.

## 빌드 검증

macOS CI와 릴리즈 job은 다음을 확인한다.

1. `swift build --build-tests`, `swift test`
2. 아이콘을 `.icns`로 만들고 Sparkle framework를 symlink·실행권한·helper 서명 그대로 앱에 포함
3. DMG 안 앱 이름·버전·bundle ID·arm64 실행 파일·아이콘·Sparkle 공개키/feed 설정 검사
4. `codesign --verify --deep --strict`, 실행 파일의 framework 링크·런타임 검색 경로 검사
5. 마운트된 앱의 `--updater-smoke-test` 실행: 실제 dyld framework 로딩과 updater 생성 확인. 앱 `AppController`를 만들기 전에 종료하므로 저장소·Keychain·AI·업데이트 네트워크에 접근하지 않음
6. DMG manifest·SHA-256 확인

`--skip-build`는 기존 앱 버전이 `VERSION`과 다르면 실패한다. 공개키가 없는 개발용 `.app`은 자동 업데이트를 비활성화하며 릴리즈 workflow는 공개키 누락 시 실패한다.

## 서명과 설치

- 앱은 **ad-hoc 코드 서명**이다. Developer ID 서명·Apple 공증이 없어 Gatekeeper가 첫 실행을 막을 수 있다. 앱과 소스를 확인한 뒤 시스템 설정 › 개인정보 보호 및 보안에서 직접 허용한다. quarantine 속성을 지우거나 Gatekeeper를 끄는 스크립트는 없다.
- ad-hoc 서명은 번들 무결성 확인용이다. 새 버전에서 Keychain 항목 접근 승인이 다시 필요할 수 있다.
- Apple Silicon(arm64), macOS 14 이상 전용이다.
- CI smoke는 framework 로딩까지 검증한다. 사용자 Mac에서의 첫 설치 승인과 실제 다운로드 → 교체 → 재시작 전체 흐름은 별도 수동 검증 대상이다.

## 로컬 확인

```sh
python3 -m unittest discover -s distribution/tests -v
bash -n scripts/*.sh distribution/*.sh
scripts/build-dmg.sh
bash distribution/verify-dmg.sh "release/WorkLog-$(cat VERSION)-arm64.dmg" "$(cat VERSION)"
```

같은 release 디렉터리에 이전 버전 DMG가 있으면 manifest 검사가 실패한다. 빌드·DMG·Sparkle 런타임 검증은 macOS에서 실행한다.
