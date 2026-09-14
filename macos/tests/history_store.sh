#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
history_build="$(mktemp -d "${TMPDIR:-/tmp}/shallwetalk-history.XXXXXX")"
trap 'rm -rf "$history_build"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
core_scratch="${SHALLWETALK_VERIFY_CORE_SCRATCH:-/tmp/ShallWeTalk-verify-core}"
core_bin="$(swift build --package-path "$repo_root/core" --scratch-path "$core_scratch" --show-bin-path)"
core_objects=("$core_bin/ShallWeTalkCore.build/"*.o)
if [[ ! -f "${core_objects[0]}" ]]; then
  printf '%s\n' 'Build ShallWeTalkCore before running the HistoryStore checks.' >&2
  exit 1
fi
for platform in ios macos; do
  platform_flags=(-D IOS_HISTORY_SMOKE)
  if [[ "$platform" == ios ]]; then
    source_dir="$repo_root/ios/_sources/Shared"
    cloud_source="$source_dir/CloudHistorySync.swift"
  else
    platform_flags=(-D MAC_AUDIO_ASYNC)
    source_dir="$repo_root/macos/VoicePen/Storage"
    cloud_source="$repo_root/macos/VoicePen/Services/CloudHistorySync.swift"
  fi
  xcrun swiftc "${platform_flags[@]}" -I "$core_bin/Modules" \
    "$source_dir/HistoryStore.swift" "$cloud_source" \
    "$repo_root/macos/tests/HistoryStoreSmoke.swift" \
    "${core_objects[@]}" -o "$history_build/$platform"
  "$history_build/$platform"
done
