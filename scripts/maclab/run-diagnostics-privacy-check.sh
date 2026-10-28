#!/bin/bash
# Actual diagnostic facade and store, with synthetic errors only. No app data or Keychain access.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'SKIP: the app diagnostic facade requires macOS.'
    exit 77
fi
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/worklog-diagnostics-privacy.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT

# Extract the exact small production contracts, avoiding unrelated app/database initialization.
python3 "$repo_root/scripts/maclab/extract-diagnostic-contracts.py" "$repo_root" "$check_dir/AIErrorContracts.swift"

xcrun swiftc -emit-library -emit-module -module-name WorkLogCore -swift-version 5 \
    -target "$(uname -m)-apple-macos26.0" \
    "$repo_root/Sources/WorkLogCore/Support/Clock.swift" \
    "$repo_root/Sources/WorkLogCore/Support/Errors.swift" \
    "$repo_root/Sources/WorkLogCore/Diagnostics/DiagnosticEvent.swift" \
    "$repo_root/Sources/WorkLogCore/Diagnostics/DiagnosticLogStore.swift" \
    "$check_dir/AIErrorContracts.swift" \
    -emit-module-path "$check_dir/WorkLogCore.swiftmodule" -o "$check_dir/libWorkLogCore.dylib"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" \
    -I "$check_dir" -L "$check_dir" -lWorkLogCore \
    "$repo_root/Sources/WorkLogApp/AppDiagnostics.swift" \
    "$repo_root/scripts/maclab/diagnostics-privacy-check.swift" -o "$check_dir/check"
WORKLOG_DIAGNOSTICS_DISABLED=0 sandbox-exec -p '(version 1)(allow default)(deny network*)' \
    "$check_dir/check" "$check_dir"
