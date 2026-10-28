#!/bin/bash
# Public registry and tiny fake model files only; no model download or microphone use.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/worklog-model-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
python3 "$repo_root/scripts/maclab/extract-diagnostic-contracts.py" "$repo_root" "$check_dir/AIErrorContracts.swift"
# Compile only the Core contracts used by this isolated model-store harness.
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" -emit-library -emit-module -module-name WorkLogCore \
    "$repo_root/Sources/WorkLogCore/Support/Clock.swift" \
    "$repo_root/Sources/WorkLogCore/Support/MeetingMonotonicClock.swift" \
    "$repo_root/Sources/WorkLogCore/Support/Errors.swift" \
    "$check_dir/AIErrorContracts.swift" \
    "$repo_root/Sources/WorkLogCore/Diagnostics/"*.swift \
    -emit-module-path "$check_dir/WorkLogCore.swiftmodule" -o "$check_dir/libWorkLogCore.dylib"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" \
    -I "$check_dir" -L "$check_dir" -lWorkLogCore -Xlinker -rpath -Xlinker "$check_dir" \
    "$repo_root/Sources/WorkLogApp/MeetingLocalModels.swift" \
    "$repo_root/Sources/WorkLogApp/AppDiagnostics.swift" \
    "$repo_root/Sources/WorkLogApp/MeetingModelRegistry.swift" \
    "$repo_root/scripts/maclab/meeting-model-check.swift" -o "$check_dir/check"
WORKLOG_DIAGNOSTICS_DISABLED=1 sandbox-exec -p '(version 1)(allow default)(deny network*)' "$check_dir/check" "$check_dir/fixtures"
