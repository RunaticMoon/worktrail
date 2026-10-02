#!/bin/bash
# macOS에서 WorkLogApp 실행 파일을 .app 번들로 묶는다 (Xcode 프로젝트 없이 SwiftPM만 사용, decisions T03).
#
# 사용법: scripts/build-macos-app.sh [debug|release]   (기본 release)
# 결과:   .build/app/WorkLog.app
#
# 버전: 저장소 루트 VERSION 파일(한 줄, 예: 0.1.0)이 표시 버전과 Sparkle 비교 버전.
# GitHub Actions macos-15(arm64)에서 실행·검증했다. 개인 Mac에서의 실행은 미검증이다.
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

if [[ "$CONFIG" != "debug" && "$CONFIG" != "release" ]]; then
    echo "빌드 구성은 debug 또는 release만 가능합니다: $CONFIG" >&2
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
"$ROOT/scripts/build-icon.sh" "$ROOT/distribution/assets/AppIcon.png" "$APP/Contents/Resources/WorkLog.icns"

# SwiftPM links Sparkle; a standalone .app must also embed the complete framework.
# ditto preserves framework symlinks, executable permissions and nested helper signatures.
SPARKLE_FRAMEWORK="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
    echo "Sparkle framework가 없습니다: $SPARKLE_FRAMEWORK" >&2
    exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$ROOT/.build/artifacts/sparkle/Sparkle/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"

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
    <key>CFBundleIconFile</key><string>WorkLog.icns</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>SUFeedURL</key><string>https://github.com/RunaticMoon/worktrail/releases/latest/download/appcast.xml</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
    <key>SUAutomaticallyUpdate</key><false/>
    <key>SUAllowsAutomaticUpdates</key><true/>
    <key>SUEnableSystemProfiling</key><false/>
    <key>SUVerifyUpdateBeforeExtraction</key><true/>
    <key>SURequireSignedFeed</key><true/>
</dict>
</plist>
PLIST

PUBLIC_KEY_FILE="$ROOT/distribution/sparkle-public-key.txt"
if [[ -f "$PUBLIC_KEY_FILE" ]]; then
    python3 - "$PUBLIC_KEY_FILE" "$APP/Contents/Info.plist" <<'PY'
import base64, pathlib, plistlib, sys
key = pathlib.Path(sys.argv[1]).read_text().strip()
assert len(base64.b64decode(key, validate=True)) == 32, 'Invalid Sparkle public key'
plist = pathlib.Path(sys.argv[2])
data = plistlib.loads(plist.read_bytes())
data['SUPublicEDKey'] = key
plist.write_bytes(plistlib.dumps(data))
PY
fi

# 로컬 실행용 ad-hoc 서명. Keychain 항목 접근 시 macOS가 허용 여부를 물을 수 있다.
codesign --force --sign - "$APP"

echo "$APP"
