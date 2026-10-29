#!/bin/bash
# Headless checks of the actual AppController and task model. The application
# entry point and Carbon hotkey adapter are replaced by the fixture harness.
# No windows, notifications, microphone, account, or real hotkeys are used.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'SKIP: native task navigation checks require macOS.'
    exit 77
fi
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
bin_dir="${WORKLOG_CHECK_BIN_DIR:-$repo_root/.build/out/Products/Debug}"
for module in WorkLogCore Crypto ArgmaxCore WhisperKit SpeakerKit; do
    if [[ ! -f "$bin_dir/$module.o" || ! -e "$bin_dir/$module.swiftmodule" ]]; then
        echo "SKIP: build WorkLogApp first; missing $module products in $bin_dir"
        exit 77
    fi
done
if [[ ! -d "$bin_dir/Sparkle.framework" ]]; then
    echo "SKIP: build WorkLogApp first; missing $bin_dir/Sparkle.framework"
    exit 77
fi
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/worklog-task-navigation-check.XXXXXX")"
cleanup() {
    python3 - "$check_dir" <<'PY'
import pathlib, shutil, sys
folder = pathlib.Path(sys.argv[1])
if folder.name.startswith('worklog-task-navigation-check.') and folder.is_dir():
    shutil.rmtree(folder)
PY
}
trap cleanup EXIT
mkdir "$check_dir/sources" "$check_dir/products"
# Snapshot every compiler input; do not write to or compete for the app build.
for source in "$repo_root/Sources/WorkLogApp/"*.swift; do
    case "$(basename "$source")" in
        WorkLogApp.swift|GlobalHotkeys.swift) continue ;;
    esac
    cp "$source" "$check_dir/sources/"
done
cp "$repo_root/scripts/maclab/task-navigation-check.swift" "$check_dir/sources/"
cp -R "$repo_root/Sources/CSQLite" "$check_dir/CSQLite"
for module in WorkLogCore Crypto ArgmaxCore WhisperKit SpeakerKit; do
    cp "$bin_dir/$module.o" "$check_dir/products/"
    cp -R "$bin_dir/$module.swiftmodule" "$check_dir/products/"
done
ditto "$bin_dir/Sparkle.framework" "$check_dir/products/Sparkle.framework"
xcrun swiftc -D DEBUG -swift-version 5 -target "$(uname -m)-apple-macos26.0" \
    -I "$check_dir/products" -I "$check_dir/CSQLite" -lsqlite3 \
    -F "$check_dir/products" -framework Sparkle \
    -Xlinker -rpath -Xlinker "$check_dir/products" \
    "$check_dir/products/WorkLogCore.o" "$check_dir/products/Crypto.o" \
    "$check_dir/products/ArgmaxCore.o" "$check_dir/products/WhisperKit.o" \
    "$check_dir/products/SpeakerKit.o" \
    "$check_dir/sources/"*.swift -o "$check_dir/check"
WORKLOG_DIAGNOSTICS_DISABLED=1 sandbox-exec -p '(version 1)(allow default)(deny network*)' \
    "$check_dir/check" --ui-test-fixture many
