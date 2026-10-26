#!/bin/bash
# Requires the root-coordinated macOS SDK build. No SwiftPM resolve/build is started here.
# Uses only empty/corrupt fake local tokenizer data with all networking denied.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
sdk_products="${1:-$repo_root/.build/out/Products/Debug}"
for object in WhisperKit ArgmaxCore; do
    [[ -f "$sdk_products/$object.o" ]] || { echo "SKIP: build macOS SDK products first: $sdk_products"; exit 77; }
done
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/worklog-tokenizer-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" -emit-library -emit-module -module-name WorkLogCore \
    "$repo_root/Sources/WorkLogCore/Support/Clock.swift" \
    "$repo_root/Sources/WorkLogCore/Support/MeetingMonotonicClock.swift" \
    "$repo_root/Sources/WorkLogCore/Meetings/MeetingPreviewPipeline.swift" \
    -emit-module-path "$check_dir/WorkLogCore.swiftmodule" -o "$check_dir/libWorkLogCore.dylib"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" \
    -I "$check_dir" -I "$sdk_products" -L "$check_dir" -lWorkLogCore -Xlinker -rpath -Xlinker "$check_dir" \
    "$sdk_products/WhisperKit.o" "$sdk_products/ArgmaxCore.o" \
    "$repo_root/Sources/WorkLogApp/MeetingLocalModels.swift" \
    "$repo_root/Sources/WorkLogApp/MeetingModelRegistry.swift" \
    "$repo_root/Sources/WorkLogApp/MeetingWhisperEngine.swift" \
    "$repo_root/scripts/maclab/meeting-tokenizer-check.swift" -o "$check_dir/check"
sandbox-exec -p '(version 1)(allow default)(deny network*)' "$check_dir/check" "$check_dir/fixtures"
