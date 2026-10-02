#!/bin/bash
# macOS에서 버전별 DMG 내용을 검증한다 (ad-hoc 서명 무결성 검사, Developer ID·공증 아님).
#
# 사용법: distribution/verify-dmg.sh <dmg> <version>
# 검사: WorkLog.app 정확히 하나, Applications -> /Applications 심볼릭 링크,
#       CFBundleShortVersionString == <version>, CFBundleIdentifier == dev.worklog.WorkLog,
#       CFBundleExecutable이 arm64, codesign --verify --deep --strict 통과.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "macOS에서만 실행할 수 있습니다." >&2
    exit 1
fi

DMG="${1:?사용법: verify-dmg.sh <dmg> <version>}"
VERSION="${2:?사용법: verify-dmg.sh <dmg> <version>}"

if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "버전 형식이 잘못되었습니다: $VERSION" >&2
    exit 1
fi
if [[ ! -f "$DMG" ]]; then
    echo "DMG 파일이 없습니다: $DMG" >&2
    exit 1
fi

MOUNT="$(mktemp -d)"
DETACHED=false
cleanup() {
    if [[ "$DETACHED" == false ]]; then
        hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
    fi
    rm -rf "$MOUNT"
}
trap cleanup EXIT

hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" >/dev/null

APPS=("$MOUNT"/*.app)
if [[ ${#APPS[@]} -ne 1 || ! -d "${APPS[0]}" ]]; then
    echo "DMG 안에 .app이 정확히 하나여야 합니다." >&2
    exit 1
fi
APP="${APPS[0]}"
if [[ "$(basename "$APP")" != "WorkLog.app" ]]; then
    echo "예상한 앱 번들이 아닙니다: $(basename "$APP")" >&2
    exit 1
fi
if [[ ! -L "$MOUNT/Applications" || "$(readlink "$MOUNT/Applications")" != "/Applications" ]]; then
    echo "Applications -> /Applications 심볼릭 링크가 없습니다." >&2
    exit 1
fi

PLIST="$APP/Contents/Info.plist"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"

[[ "$SHORT" == "$VERSION" ]] || { echo "CFBundleShortVersionString 불일치: $SHORT != $VERSION" >&2; exit 1; }
[[ "$BUNDLE_ID" == "dev.worklog.WorkLog" ]] || { echo "CFBundleIdentifier 불일치: $BUNDLE_ID" >&2; exit 1; }
[[ "$EXECUTABLE" != */* && -n "$EXECUTABLE" ]] || { echo "CFBundleExecutable이 올바르지 않습니다: $EXECUTABLE" >&2; exit 1; }
[[ "$(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE")" == "arm64" ]] || { echo "arm64 실행 파일이 아닙니다." >&2; exit 1; }
codesign --verify --deep --strict "$APP" || { echo "코드 서명 검증에 실패했습니다." >&2; exit 1; }

hdiutil detach "$MOUNT" >/dev/null
DETACHED=true

echo "Verified DMG: $DMG ($VERSION)"
