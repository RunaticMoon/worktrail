#!/bin/bash
# Local integration check. No microphone, private data, login, or model downloads.
# Exit 77 means the required installed system voice/model/platform is unavailable.
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
    echo 'SKIP: Apple SpeechTranscriber requires macOS 26 or newer.'
    exit 77
fi
macos_version="$(sw_vers -productVersion)"
if (( ${macos_version%%.*} < 26 )); then
    echo 'SKIP: Apple SpeechTranscriber requires macOS 26 or newer.'
    exit 77
fi
if ! say -v '?' | awk '$1 == "Yuna" && index($0, "ko_KR") { found = 1 } END { exit !found }'; then
    echo 'SKIP: the local Korean Yuna voice is unavailable; no voice download was attempted.'
    exit 77
fi

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/worklog-stt-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT

# File synthesis is silent and does not capture any real audio.
say -v Yuna -o "$check_dir/meeting.aiff" \
    '오늘 회의에서는 다음 주 출시 계획을 논의했습니다. 민수는 금요일까지 테스트를 완료하고 지수는 회의록을 작성합니다.'
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" \
    "$repo_root/Sources/WorkLogApp/MeetingSpeechTranscriber.swift" \
    "$repo_root/scripts/maclab/meeting-stt-check.swift" -o "$check_dir/check"

# Deny network access in the test process. Apple's system speech service performs
# on-device inference; this does not change networking for other applications.
sandbox-exec -p '(version 1)(allow default)(deny network*)' "$check_dir/check" "$check_dir/meeting.aiff"
