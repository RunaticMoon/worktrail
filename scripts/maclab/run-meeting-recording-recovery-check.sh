#!/bin/bash
# Actual recorder/storage code with fake files. Never captures microphone audio.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'SKIP: the recorder requires macOS.'
    exit 77
fi
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/worklog-recording-recovery.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT

# Compile the exact repository IDGenerator definitions into a small Core module;
# this isolated harness does not open app storage, accounts, or Keychain.
xcrun swiftc -emit-library -emit-module -module-name WorkLogCore -swift-version 5 \
    -target "$(uname -m)-apple-macos26.0" "$repo_root/Sources/WorkLogCore/Support/Clock.swift" \
    -emit-module-path "$check_dir/WorkLogCore.swiftmodule" -o "$check_dir/libWorkLogCore.dylib"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" \
    -I "$check_dir" -L "$check_dir" -lWorkLogCore \
    "$repo_root/Sources/WorkLogApp/MeetingAudioRecorder.swift" \
    "$repo_root/scripts/maclab/meeting-recording-recovery-check.swift" -o "$check_dir/check"
sandbox-exec -p '(version 1)(allow default)(deny network*)' "$check_dir/check" "$check_dir"
