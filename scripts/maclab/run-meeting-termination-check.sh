#!/bin/bash
# Tests termination decisions without running or quitting the WorkLog application.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'SKIP: the application delegate requires macOS.'
    exit 77
fi
macos_version="$(sw_vers -productVersion)"
if (( ${macos_version%%.*} < 26 )); then
    echo 'SKIP: the application target requires macOS 26 or newer.'
    exit 77
fi
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/worklog-termination-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" \
    "$repo_root/Sources/WorkLogApp/WorkLogApplicationDelegate.swift" \
    "$repo_root/scripts/maclab/meeting-termination-check.swift" -o "$check_dir/check"
sandbox-exec -p '(version 1)(allow default)(deny network*)' "$check_dir/check"
