#!/bin/bash
# Reuses built SDK/Core objects, compiles actual session sources, and injects fake
# PCM capture. No SwiftPM build, real microphone, system capture or model download.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'SKIP: native meeting sessions require macOS.'
    exit 77
fi
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
bin_dir="${WORKLOG_CHECK_BIN_DIR:-$repo_root/.build/out/Products/Debug}"
for module in WorkLogCore Crypto ArgmaxCore WhisperKit SpeakerKit; do
    if [[ ! -f "$bin_dir/$module.o" ]]; then
        echo "SKIP: build WorkLogApp first; missing $bin_dir/$module.o"
        exit 77
    fi
done
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/worklog-session-check.XXXXXX")"
cleanup() {
    python3 - "$check_dir" <<'PY'
import pathlib, shutil, sys
folder = pathlib.Path(sys.argv[1])
if folder.name.startswith('worklog-session-check.') and folder.is_dir():
    shutil.rmtree(folder)
PY
}
trap cleanup EXIT
mkdir "$check_dir/sources"
# Snapshot sources before compiling so another implementation worker cannot alter
# a Swift input halfway through this independent verification process.
for source in MeetingAudioArchive MeetingImportedAudioArchive MeetingAudioCapture MeetingPCMReader MeetingLocalModels \
              MeetingModelRegistry MeetingWhisperEngine MeetingDiarizationEngine \
              MeetingPostProcessing MeetingRecordingSession MeetingsModel MeetingAudioRecorder; do
    cp "$repo_root/Sources/WorkLogApp/$source.swift" "$check_dir/sources/$source.swift"
done
cp "$repo_root/scripts/maclab/meeting-session-check.swift" "$check_dir/sources/meeting-session-check.swift"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" \
    -I "$bin_dir" -I "$repo_root/Sources/CSQLite" -lsqlite3 \
    "$bin_dir/WorkLogCore.o" "$bin_dir/Crypto.o" "$bin_dir/ArgmaxCore.o" \
    "$bin_dir/WhisperKit.o" "$bin_dir/SpeakerKit.o" \
    "$check_dir/sources/"*.swift -o "$check_dir/check"
sandbox-exec -p '(version 1)(allow default)(deny network*)' "$check_dir/check" "$check_dir"
