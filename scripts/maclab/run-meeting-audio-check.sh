#!/bin/bash
# Fake PCM only: never activates a microphone, screen capture, account or app store.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'SKIP: the native PCM archive requires macOS.'
    exit 77
fi
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/worklog-audio-check.XXXXXX")"
cleanup() {
    python3 - "$check_dir" <<'PY'
import pathlib, shutil, sys
folder = pathlib.Path(sys.argv[1])
if folder.name.startswith('worklog-audio-check.') and folder.is_dir():
    shutil.rmtree(folder)
PY
}
trap cleanup EXIT
python3 "$repo_root/scripts/maclab/extract-diagnostic-contracts.py" "$repo_root" "$check_dir/AIErrorContracts.swift"
xcrun swiftc -emit-library -emit-module -module-name WorkLogCore -swift-version 5 \
    -target "$(uname -m)-apple-macos26.0" \
    "$repo_root/Sources/WorkLogCore/Support/Clock.swift" \
    "$repo_root/Sources/WorkLogCore/Support/MeetingMonotonicClock.swift" \
    "$repo_root/Sources/WorkLogCore/Support/Errors.swift" \
    "$check_dir/AIErrorContracts.swift" \
    "$repo_root/Sources/WorkLogCore/Diagnostics/"*.swift \
    -emit-module-path "$check_dir/WorkLogCore.swiftmodule" -o "$check_dir/libWorkLogCore.dylib"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" \
    -I "$check_dir" -L "$check_dir" -lWorkLogCore \
    "$repo_root/Sources/WorkLogApp/MeetingAudioArchive.swift" \
    "$repo_root/Sources/WorkLogApp/MeetingAudioCapture.swift" \
    "$repo_root/Sources/WorkLogApp/AppDiagnostics.swift" \
    "$repo_root/Sources/WorkLogApp/MeetingPCMReader.swift" \
    "$repo_root/scripts/maclab/meeting-audio-check.swift" -o "$check_dir/check"
WORKLOG_DIAGNOSTICS_DISABLED=1 sandbox-exec -p '(version 1)(allow default)(deny network*)' "$check_dir/check" "$check_dir"
