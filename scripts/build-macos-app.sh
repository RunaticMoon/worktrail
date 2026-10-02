#!/bin/bash
# macOS에서 WorkLogApp 실행 파일을 .app 번들로 묶는다 (Xcode 프로젝트 없이 SwiftPM만 사용, decisions T03).
#
# 사용법: scripts/build-macos-app.sh [debug|release]   (기본 release)
# 결과:   .build/app/WorkLog.app
#
# 버전: 저장소 루트 VERSION 파일(한 줄, 예: 0.1.0)이 CFBundleShortVersionString.
#       환경변수 WORKLOG_BUILD_NUMBER(기본 1, 양의 정수)가 CFBundleVersion.
# 미검증: 이 스크립트는 Linux 개발 서버에서 작성했으며 실제 Mac에서 실행해 보지 않았다.
# 로컬 실행용 ad-hoc 서명만 한다. 배포용 Developer ID 서명·공증은 하지 않는다.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "macOS에서만 실행할 수 있습니다." >&2
    exit 1
fi

CONFIG="${1:-release}"
APP_NAME="WorkLog"
BUNDLE_ID="dev.worklog.WorkLog"   # AppIdentity.default와 같아야 한다
MIN_MACOS="14.0"                  # Package.swift platforms(.macOS(.v14))와 같아야 한다
BUILD_NUMBER="${WORKLOG_BUILD_NUMBER:-1}"

if [[ "$CONFIG" != "debug" && "$CONFIG" != "release" ]]; then
    echo "빌드 구성은 debug 또는 release만 가능합니다: $CONFIG" >&2
    exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "WORKLOG_BUILD_NUMBER는 양의 정수여야 합니다: $BUILD_NUMBER" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' < VERSION)"
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "VERSION 형식이 잘못되었습니다: $VERSION" >&2
    exit 1
fi

swift build -c "$CONFIG" --arch arm64 --product WorkLogApp
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

APP="$ROOT/.build/app/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/WorkLogApp" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# 로컬 실행용 ad-hoc 서명. Keychain 항목 접근 시 macOS가 허용 여부를 물을 수 있다.
codesign --force --sign - "$APP"

echo "$APP"
