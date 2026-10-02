#!/bin/bash
# macOS에서 WorkLog.app을 버전별 DMG로 묶는다 (ad-hoc 서명, Developer ID·공증 없음).
#
# 사용법: scripts/build-dmg.sh [--skip-build]
#   --skip-build  .build/app/WorkLog.app 이 이미 있을 때 앱 빌드를 생략한다.
# 결과:   release/WorkLog-<VERSION>-arm64.dmg
#
# GitHub Actions macos-15(arm64)에서 실행·검증했다. 개인 Mac에서의 실행은 미검증이다.
# 같은 이름의 기존 DMG만 덮어쓴다(-ov). 다른 DMG는 건드리지 않는다.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "macOS에서만 실행할 수 있습니다." >&2
    exit 1
fi

SKIP_BUILD=false
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=true ;;
        *)
            echo "알 수 없는 인자입니다: $arg" >&2
            exit 1
            ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' < VERSION)"
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "VERSION 형식이 잘못되었습니다: $VERSION" >&2
    exit 1
fi

if [[ "$SKIP_BUILD" == false ]]; then
    "$ROOT/scripts/build-macos-app.sh" release >/dev/null
fi

APP="$ROOT/.build/app/WorkLog.app"
if [[ ! -d "$APP" ]]; then
    echo "앱 번들이 없습니다: $APP (먼저 scripts/build-macos-app.sh release 실행)" >&2
    exit 1
fi

# --skip-build 로 이전 버전 앱이 남아 있으면 파일명과 앱 버전이 어긋나므로 거부한다.
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [[ "$APP_VERSION" != "$VERSION" ]]; then
    echo "앱 번들 버전($APP_VERSION)이 VERSION($VERSION)과 다릅니다. --skip-build 없이 다시 실행하세요." >&2
    exit 1
fi

RELEASE_DIR="$ROOT/release"
DMG="$RELEASE_DIR/WorkLog-$VERSION-arm64.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

mkdir -p "$RELEASE_DIR"
cp -R "$APP" "$STAGING/WorkLog.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "WorkLog $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"

echo "$DMG"
