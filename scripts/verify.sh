#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
build_configuration="${SHALLWETALK_VERIFY_CONFIGURATION:-Debug}"
case "$build_configuration" in
  Debug|Release) ;;
  *) printf '%s\n' 'error: SHALLWETALK_VERIFY_CONFIGURATION must be Debug or Release' >&2; exit 1 ;;
esac
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/ShallWeTalk-verify-clang}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/ShallWeTalk-verify-modules}"
ios_derived_data="${SHALLWETALK_VERIFY_IOS_DERIVED_DATA:-/tmp/ShallWeTalk-verify-ios}"
macos_derived_data="${SHALLWETALK_VERIFY_MACOS_DERIVED_DATA:-/tmp/ShallWeTalk-verify-macos}"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  selected_developer_dir="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$selected_developer_dir" == *CommandLineTools* && -d /Applications/Xcode.app/Contents/Developer ]]; then
    selected_developer_dir=/Applications/Xcode.app/Contents/Developer
  fi
  export DEVELOPER_DIR="$selected_developer_dir"
fi

if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  printf '%s\n' "error: a complete Xcode installation is required; current DEVELOPER_DIR=$DEVELOPER_DIR" >&2
  exit 1
fi

printf '%s\n' "[1/8] Generating the iOS project"
"$script_dir/bootstrap.sh"

printf '%s\n' "[2/8] Checking repository policy"
"$script_dir/check_repository.sh"

printf '%s\n' "[3/8] Running ShallWeTalkCore tests"
# 仓库位于 iCloud/Finder File Provider 管理的 Documents 目录；SwiftPM 默认写入
# core/.build 时可能带入 Finder 扩展属性，随后让测试 bundle codesign 报
# "resource fork, Finder information, or similar detritus not allowed"。强制把 scratch
# 放到仓库外，并允许 CI/操作者用项目专用变量覆盖。
core_scratch="${SHALLWETALK_VERIFY_CORE_SCRATCH:-/tmp/ShallWeTalk-verify-core}"
swift test --package-path "$repo_root/core" --scratch-path "$core_scratch"

printf '%s\n' "[4/8] Running transactional pending-text concurrency checks"
bash "$repo_root/ios/tests/pending_text_transaction.sh"
SHALLWETALK_VERIFY_CORE_SCRATCH="$core_scratch" bash "$repo_root/macos/tests/history_store.sh"
SHALLWETALK_VERIFY_CORE_SCRATCH="$core_scratch" bash "$repo_root/ios/tests/meeting_store.sh"
bash "$repo_root/ios/tests/todo_store.sh"
bash "$repo_root/macos/tests/ios_parity.sh"

printf '%s\n' "[5/8] Running iOS keyboard and integration regression checks"
bash "$repo_root/ios/tests/keyboard_voice_entry_regression.sh"

printf '%s\n' "[6/8] Running macOS clipboard restoration checks"
bash "$repo_root/macos/tests/pasteboard_snapshot.sh"
SHALLWETALK_VERIFY_CORE_SCRATCH="$core_scratch" bash "$repo_root/macos/tests/direct_insertion.sh"

printf '%s\n' "[7/8] Building iOS ($build_configuration) for a generic simulator without signing"
xcodebuild -quiet \
  -project "$repo_root/ios/VoicePenMobile.xcodeproj" \
  -scheme VoicePenMobile \
  -configuration "$build_configuration" \
  -derivedDataPath "$ios_derived_data" \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build

printf '%s\n' "[8/8] Building macOS ($build_configuration) without signing"
xcodebuild -quiet \
  -project "$repo_root/macos/VoicePen.xcodeproj" \
  -scheme VoicePen \
  -configuration "$build_configuration" \
  -derivedDataPath "$macos_derived_data" \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ "${SHALLWETALK_VERIFY_HOST_MATRIX:-0}" == 1 ]]; then
  printf '%s\n' 'Running the real keyboard host acceptance matrix'
  bash "$repo_root/ios/tests/real_host_matrix.sh"
fi

printf '%s\n' "Verification complete: policy, tests, iOS build, and macOS build ($build_configuration) passed."
