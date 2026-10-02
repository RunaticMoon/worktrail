# 릴리즈: 버전별 macOS DMG

참고: [RunaticMoon/pr-context-explorer](https://github.com/RunaticMoon/pr-context-explorer)의 macOS 릴리즈 흐름(태그·버전 일치 검사 → macOS 15 arm64 러너 빌드 → 산출물 검증·해시 manifest → draft 업로드 → 재다운로드 바이트 비교 → 선택적 공개)을 SwiftPM 앱에 맞게 옮겼다. Electron 업데이터, 개인 설치 관리자(`prce`), Developer ID 서명·공증 경로는 가져오지 않았다.

## 버전

- 저장소 루트 `VERSION`(예: `0.1.0`)이 유일한 버전 원본이다.
- 릴리즈 태그는 `v` + `VERSION`(예: `v0.1.0`). 형식(`vMAJOR.MINOR.PATCH`)이 다르거나 `VERSION`과 다르면 빌드 전에 실패한다.
- 앱 `Info.plist`: `CFBundleShortVersionString` = `VERSION`, `CFBundleVersion` = `WORKLOG_BUILD_NUMBER`(워크플로에서는 run 번호, 로컬 기본 1).
- 산출물 이름: `WorkLog-<VERSION>-arm64.dmg` (+ `release-manifest.json`: 이름·크기·SHA-256).

## 새 버전 릴리즈 절차

1. `VERSION`을 새 버전으로 올리는 PR을 만들어 main에 머지한다. 이미 있는 태그·릴리즈 이름은 다시 쓸 수 없다.
2. 머지된 main의 커밋 SHA를 확인한다: `git rev-parse origin/main`
3. 릴리즈 워크플로를 실행한다.

```sh
gh workflow run macos-release.yml --ref main \
  -f commit=<main의 40자 SHA> -f tag=v0.1.0 -f publish=artifact-only   # 또는 draft / publish
gh run list --workflow macos-release.yml --limit 3
```

| `publish` | 결과 |
|---|---|
| `artifact-only` (기본) | 테스트·DMG 빌드·검증 후 Actions artifact로만 보관(14일). GitHub Release를 만들지 않는다 |
| `draft` | 위 + draft Release 생성, DMG·manifest 업로드, 다시 내려받아 바이트 비교 |
| `publish` | 위 + draft를 공개 Release(latest)로 전환 |

`commit` 입력은 실행 브랜치(main)의 현재 SHA와 정확히 같아야 한다(검토한 커밋만 빌드). 빌드 job은 쓰기 권한이 없고, `GITHUB_TOKEN`은 publish job의 업로드 단계에만 주어진다.

## 빌드 job이 확인하는 것

1. 입력 SHA = 실행 SHA, 러너가 arm64
2. 태그 형식·`VERSION` 일치 (`distribution/release.py version`)
3. `swift build --build-tests`, `swift test`
4. `scripts/build-dmg.sh` → `release/WorkLog-<VERSION>-arm64.dmg`
5. `distribution/verify-dmg.sh`: DMG를 읽기 전용으로 마운트해 `WorkLog.app` 하나, `Applications` 링크, 앱 버전·번들 ID, arm64 실행 파일, `codesign --verify --deep --strict`
6. `distribution/release.py manifest`/`verify`: DMG 하나·이름·SHA-256

PR·push CI(`macos.yml`)도 같은 4~6단계를 실행해 DMG를 artifact(7일)로 남긴다. 릴리즈 전에 PR에서 DMG를 미리 받아 확인할 수 있다.

## 실패·재실행

- 같은 태그의 tag 또는 Release(초안 포함)가 이미 있으면 publish 단계가 실패한다. 덮어쓰기(`--clobber`)는 하지 않는다.
- 업로드·비교·공개 중 실패하면 draft가 남는다. 실패 원인을 확인한 뒤 **공개되지 않은** draft를 직접 지우고 다시 실행하거나, `VERSION`을 올려 새 태그로 실행한다. 이미 공개되어 설치된 태그는 지우거나 다시 쓰지 않는다.

## 서명과 설치

- Apple Developer 계정이 없어 **ad-hoc 서명**만 한다. Developer ID 서명·Apple 공증이 없으므로 Gatekeeper가 첫 실행을 막을 수 있다. 앱과 소스를 확인한 뒤 시스템 설정 › 개인정보 보호 및 보안에서 직접 허용한다(조직 정책이 막을 수 있다). 이 저장소의 어떤 스크립트도 quarantine 속성을 지우거나 Gatekeeper를 끄지 않는다.
- ad-hoc 서명은 번들 무결성 확인용이며 배포자 신원을 증명하지 않는다. 앱이 바뀌면(새 버전) Keychain 항목 접근 시 macOS가 다시 허용을 물을 수 있다.
- Apple Silicon(arm64) 전용이다. Intel Mac용 빌드는 만들지 않는다.

## 로컬 확인

```sh
python3 -m unittest discover -s distribution/tests -v   # Linux 가능
bash -n scripts/*.sh distribution/*.sh
scripts/build-dmg.sh && distribution/verify-dmg.sh release/WorkLog-$(cat VERSION)-arm64.dmg $(cat VERSION)   # Mac에서만
```

## 미검증

- 릴리즈 워크플로(`macos-release.yml`)의 실제 draft/publish 실행
- DMG를 받은 Mac에서의 설치·첫 실행·Gatekeeper 승인
