#!/bin/bash
# Offline generated RSA fixtures only. Never reads credentials, Keychain, or the network.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/worklog-identity-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" \
    "$repo_root/Sources/WorkLogApp/ChatGPTLoginIdentity.swift" \
    "$repo_root/scripts/maclab/chatgpt-identity-check.swift" -o "$check_dir/check"
sandbox-exec -p '(version 1)(allow default)(deny network*)' "$check_dir/check"
