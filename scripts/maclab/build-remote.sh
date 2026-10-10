#!/usr/bin/env bash
# On the isolated Maclab host, build the baseline and edited UI with one shared
# SwiftPM cache. Run "before" and "after" as separate prepare steps if needed.
# Usage: bash scripts/maclab/build-remote.sh [before|after|all]
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
    echo "This script requires macOS." >&2
    exit 1
fi
REVIEW_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REVIEW_PHASE="${1:-all}"
REVIEW_BUILD_ROOT="$REVIEW_ROOT/.review-build"
case "$REVIEW_PHASE" in before|after|all) ;; *) echo "Expected before, after, or all." >&2; exit 1 ;; esac
mkdir -p "$REVIEW_BUILD_ROOT"

build_review_app() {
    local review_snapshot="$1" review_name="$2"
    local review_source="$REVIEW_ROOT/$review_snapshot"
    local review_app="$REVIEW_ROOT/$review_name.app"
    local review_bin_dir review_framework review_version
    if [[ ! -f "$review_source/Sources/WorkLogApp/UITestFixture.swift" ]]; then
        echo "Refusing to build without the synthetic-data fixture." >&2
        exit 1
    fi
    # The only deletion target is this archive's disposable source checkout;
    # preserve its .build directory for the second compilation.
    rsync -a --delete --exclude=.build "$review_source/" "$REVIEW_BUILD_ROOT/"
    (
        cd "$REVIEW_BUILD_ROOT"
        swift build -c debug --product WorkLogApp
    )
    review_bin_dir="$(cd "$REVIEW_BUILD_ROOT" && swift build -c debug --show-bin-path)"
    review_framework="$REVIEW_BUILD_ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    if [[ ! -d "$review_framework" ]]; then
        echo "Missing Sparkle framework: $review_framework" >&2
        exit 1
    fi
    review_version="$(tr -d '[:space:]' < "$REVIEW_BUILD_ROOT/VERSION")"
    if [[ ! "$review_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Invalid review version." >&2
        exit 1
    fi
    rm -rf "$review_app/Contents"
    mkdir -p "$review_app/Contents/MacOS" "$review_app/Contents/Resources" "$review_app/Contents/Frameworks"
    cp "$review_bin_dir/WorkLogApp" "$review_app/Contents/MacOS/WorkLogApp"
    ditto "$review_framework" "$review_app/Contents/Frameworks/Sparkle.framework"
    cat > "$review_app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>WorkLog UI Review $review_name</string>
<key>CFBundleDisplayName</key><string>WorkLog UI Review $review_name</string>
<key>CFBundleIdentifier</key><string>dev.worklog.UIReview</string>
<key>CFBundleExecutable</key><string>WorkLogApp</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$review_version</string>
<key>CFBundleVersion</key><string>$review_version</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>SUEnableAutomaticChecks</key><false/>
</dict></plist>
PLIST
    # No feed URL or public key: AppUpdater remains unconfigured and does not
    # create an updater controller or perform automatic update network requests.
    codesign --force --sign - "$review_app"
    printf 'BUILT_APP=%s\n' "$review_app"
}

if [[ "$REVIEW_PHASE" == before || "$REVIEW_PHASE" == all ]]; then
    build_review_app baseline Before
fi
if [[ "$REVIEW_PHASE" == after || "$REVIEW_PHASE" == all ]]; then
    build_review_app after After
fi
