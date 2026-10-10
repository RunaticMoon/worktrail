#!/usr/bin/env bash
# Package source only for the isolated Maclab UI review. No local databases, build
# products, Keychain contents, tokens, or user configuration enter this archive.
# Usage: scripts/maclab/package-source.sh [baseline-commit] [output.tar]
set -euo pipefail

REVIEW_REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REVIEW_BASELINE="${1:-2bc2a3e367eaf941f9d88190d56d0d96d3af4440}"
REVIEW_OUTPUT="${2:-$REVIEW_REPO_ROOT/.build/maclab/ui-review.tar}"
REVIEW_FIXTURE="$REVIEW_REPO_ROOT/Sources/WorkLogApp/UITestFixture.swift"

if [[ ! -f "$REVIEW_FIXTURE" ]]; then
    echo "Missing isolated fake-data fixture: $REVIEW_FIXTURE" >&2
    exit 1
fi
if ! git -C "$REVIEW_REPO_ROOT" rev-parse --verify "$REVIEW_BASELINE^{commit}" >/dev/null; then
    echo "Invalid baseline commit: $REVIEW_BASELINE" >&2
    exit 1
fi
mkdir -p "$(dirname "$REVIEW_OUTPUT")"
REVIEW_OUTPUT="$(cd "$(dirname "$REVIEW_OUTPUT")" && pwd)/$(basename "$REVIEW_OUTPUT")"
REVIEW_STAGE="$(mktemp -d "$(dirname "$REVIEW_OUTPUT")/ui-review-package.XXXXXX")"
trap 'rm -rf "$REVIEW_STAGE"' EXIT
mkdir -p "$REVIEW_STAGE/baseline" "$REVIEW_STAGE/after" "$REVIEW_STAGE/scripts/maclab"

git -C "$REVIEW_REPO_ROOT" archive "$REVIEW_BASELINE" Sources Tests Package.swift VERSION |
    tar -xf - -C "$REVIEW_STAGE/baseline"
if git -C "$REVIEW_REPO_ROOT" cat-file -e "$REVIEW_BASELINE:Package.resolved" 2>/dev/null; then
    git -C "$REVIEW_REPO_ROOT" show "$REVIEW_BASELINE:Package.resolved" > "$REVIEW_STAGE/baseline/Package.resolved"
fi
cp -R "$REVIEW_REPO_ROOT/Sources" "$REVIEW_STAGE/after/Sources"
cp -R "$REVIEW_REPO_ROOT/Tests" "$REVIEW_STAGE/after/Tests"
cp "$REVIEW_REPO_ROOT/Package.swift" "$REVIEW_REPO_ROOT/VERSION" "$REVIEW_STAGE/after/"
if [[ -f "$REVIEW_REPO_ROOT/Package.resolved" ]]; then
    cp "$REVIEW_REPO_ROOT/Package.resolved" "$REVIEW_STAGE/after/Package.resolved"
fi
# Both versions use the same synthetic records and isolated environment factory.
# Preserve the baseline controller's own hotkey and other API calls: copying the
# entire current controller can break a baseline built against older app APIs.
cp "$REVIEW_FIXTURE" "$REVIEW_STAGE/baseline/Sources/WorkLogApp/UITestFixture.swift"
python3 - "$REVIEW_REPO_ROOT/Sources/WorkLogApp/AppController.swift" \
    "$REVIEW_STAGE/baseline/Sources/WorkLogApp/AppController.swift" <<'PY'
from pathlib import Path
import sys

current = Path(sys.argv[1]).read_text()
baseline_path = Path(sys.argv[2])
baseline = baseline_path.read_text()
factory_start = current.index("    private func openEnvironment() async throws -> AppEnvironment {")
factory_end = current.index("    func retryStart()", factory_start)
factory = current[factory_start:factory_end]
if "    private func openEnvironment() async throws -> AppEnvironment {" in baseline:
    start = baseline.index("    private func openEnvironment() async throws -> AppEnvironment {")
    end = baseline.index("    func retryStart()", start)
    baseline = baseline[:start] + factory + baseline[end:]
else:
    start = baseline.index("            let paths = AppPaths.standard()")
    end = baseline.index("            environment = env", start)
    baseline = baseline[:start] + "            let env = try await openEnvironment()\n            let settings = env.settings\n" + baseline[end:]
    insertion = baseline.index("    func retryStart()")
    baseline = baseline[:insertion] + factory + baseline[insertion:]
baseline_path.write_text(baseline)
PY
cp "$REVIEW_REPO_ROOT/scripts/maclab/build-remote.sh" "$REVIEW_STAGE/scripts/maclab/build-remote.sh"
# Include the read-only UI inspection driver when present in the current checkout.
for REVIEW_DRIVER in "$REVIEW_REPO_ROOT/scripts/maclab/"*.js; do
    if [[ -f "$REVIEW_DRIVER" ]]; then cp "$REVIEW_DRIVER" "$REVIEW_STAGE/scripts/maclab/"; fi
done

REVIEW_LAUNCHER="$REVIEW_STAGE/WorkLogReview.app/Contents"
mkdir -p "$REVIEW_LAUNCHER/MacOS" "$REVIEW_LAUNCHER/Resources"
cat > "$REVIEW_LAUNCHER/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>WorkLog UI Review</string>
<key>CFBundleIdentifier</key><string>dev.worklog.UIReview</string>
<key>CFBundleExecutable</key><string>WorkLogApp</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.0.1</string>
<key>CFBundleVersion</key><string>0.0.1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cat > "$REVIEW_LAUNCHER/MacOS/WorkLogApp" <<'LAUNCHER'
#!/bin/bash
set -euo pipefail
REVIEW_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
REVIEW_BINARY="$REVIEW_ROOT/After.app/Contents/MacOS/WorkLogApp"
if [[ ! -x "$REVIEW_BINARY" ]]; then
    echo "Build first: scripts/maclab/build-remote.sh before, then scripts/maclab/build-remote.sh after" >&2
    exit 0
fi
for REVIEW_ARGUMENT in "$@"; do
    if [[ "$REVIEW_ARGUMENT" == --ui-test-fixture ]]; then
        exec "$REVIEW_BINARY" "$@"
    fi
done
exec "$REVIEW_BINARY" --ui-test-fixture many "$@"
LAUNCHER
chmod +x "$REVIEW_LAUNCHER/MacOS/WorkLogApp" "$REVIEW_STAGE/scripts/maclab/build-remote.sh"
# Keep the build inputs and fixture revision reviewable without including git metadata.
{
    echo "baseline=$(git -C "$REVIEW_REPO_ROOT" rev-parse "$REVIEW_BASELINE")"
    echo "after=$(git -C "$REVIEW_REPO_ROOT" rev-parse HEAD)"
    echo "fixture=synthetic-only"
    echo "prepare-before=bash scripts/maclab/build-remote.sh before"
    echo "prepare-after=bash scripts/maclab/build-remote.sh after"
    echo "launch-before=open -n Before.app --args --ui-test-fixture many"
    echo "launch-after=open -n After.app --args --ui-test-fixture many"
} > "$REVIEW_STAGE/review-build.txt"
tar -cf "$REVIEW_OUTPUT" -C "$REVIEW_STAGE" WorkLogReview.app baseline after scripts review-build.txt
printf '%s\n' "$REVIEW_OUTPUT"
