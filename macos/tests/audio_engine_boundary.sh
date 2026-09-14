#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/swt-audio-boundary.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
audio_dir="$repo_root/macos/VoicePen/Audio"
xcrun clang -fobjc-arc -fobjc-arc-exceptions -fmodules -I "$audio_dir" \
  "$audio_dir/AudioEngineBoundary.m" "$repo_root/macos/tests/AudioEngineBoundarySmoke.m" \
  -framework Foundation -framework AVFoundation -o "$build_dir/boundary"
"$build_dir/boundary"
xcrun clang -fobjc-arc -fobjc-arc-exceptions -fmodules \
  -c "$audio_dir/AudioEngineBoundary.m" -o "$build_dir/boundary.o"
xcrun swiftc -sanitize=thread \
  -import-objc-header "$repo_root/macos/VoicePen/VoicePen-Bridging-Header.h" \
  "$audio_dir/Recorder.swift" "$repo_root/macos/tests/RecorderCallbackSmoke.swift" \
  "$build_dir/boundary.o" -o "$build_dir/recorder"
"$build_dir/recorder"
