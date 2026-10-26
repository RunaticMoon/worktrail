#!/bin/bash
# Local HTTP callback fixtures only; no OAuth, credential store or external requests.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/worklog-loopback-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" \
    "$repo_root/Sources/WorkLogApp/ChatGPTLoginLoopback.swift" \
    "$repo_root/scripts/maclab/chatgpt-loopback-check.swift" -o "$check_dir/check"
"$check_dir/check"
