#!/bin/bash
# macOS에서 WorkLogApp 실행 파일을 .app 번들로 묶는다 (Xcode 프로젝트 없이 SwiftPM만 사용, decisions T03).
#
# 사용법: scripts/build-macos-app.sh [debug|release]   (기본 release)
# 결과:   .build/app/WorkLog.app
#
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

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG" --product WorkLogApp
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$ROOT/.build/app/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/WorkLogApp" "$APP/Contents/MacOS/$APP_NAME"

VERSION="$(git describe --tags --always 2>/dev/null || echo 0.1.0)"

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
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# 로컬 실행용 ad-hoc 서명. Keychain 항목 접근 시 macOS가 허용 여부를 물을 수 있다.
codesign --force --sign - "$APP"

echo "$APP"
