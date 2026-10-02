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
UPDATE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"

[[ "$SHORT" == "$VERSION" ]] || { echo "CFBundleShortVersionString 불일치: $SHORT != $VERSION" >&2; exit 1; }
[[ "$UPDATE_VERSION" == "$VERSION" ]] || { echo "Sparkle 비교 버전 불일치" >&2; exit 1; }
[[ "$BUNDLE_ID" == "dev.worklog.WorkLog" ]] || { echo "CFBundleIdentifier 불일치: $BUNDLE_ID" >&2; exit 1; }
[[ "$EXECUTABLE" != */* && -n "$EXECUTABLE" ]] || { echo "CFBundleExecutable이 올바르지 않습니다: $EXECUTABLE" >&2; exit 1; }
[[ "$(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE")" == "arm64" ]] || { echo "arm64 실행 파일이 아닙니다." >&2; exit 1; }
[[ -s "$APP/Contents/Resources/WorkLog.icns" ]] || { echo "앱 아이콘이 없습니다." >&2; exit 1; }
[[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]] || { echo "Sparkle framework가 없습니다." >&2; exit 1; }
otool -L "$APP/Contents/MacOS/$EXECUTABLE" | grep '@rpath/Sparkle.framework/' >/dev/null
otool -l "$APP/Contents/MacOS/$EXECUTABLE" | grep '@executable_path/../Frameworks' >/dev/null
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$PLIST" "$ROOT/distribution/sparkle-public-key.txt" <<'PY'
import base64, pathlib, plistlib, sys
data = plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
assert data['SUFeedURL'] == 'https://github.com/RunaticMoon/worktrail/releases/latest/download/appcast.xml'
assert data['SURequireSignedFeed'] is True and data['SUVerifyUpdateBeforeExtraction'] is True
key_file = pathlib.Path(sys.argv[2])
if key_file.exists():
    key = key_file.read_text().strip()
    assert len(base64.b64decode(key, validate=True)) == 32
    assert data['SUPublicEDKey'] == key
PY
codesign --verify --deep --strict "$APP" || { echo "코드 서명 검증에 실패했습니다." >&2; exit 1; }

# Exercise the bundled executable/rpath on macOS without starting the app's storage,
# AI, Secret or update network paths. The smoke entry point returns before App init.
"$APP/Contents/MacOS/$EXECUTABLE" --updater-smoke-test

hdiutil detach "$MOUNT" >/dev/null
DETACHED=true

echo "Verified DMG: $DMG ($VERSION)"
