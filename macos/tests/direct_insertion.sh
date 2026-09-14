#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
scratch="${SHALLWETALK_VERIFY_CORE_SCRATCH:-/tmp/ShallWeTalk-verify-core}"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/swt-insertion.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
core_bin="$(xcrun swift build --package-path "$repo_root/core" --scratch-path "$scratch" --show-bin-path)"
xcrun swiftc -I "$core_bin/Modules" \
  "$repo_root/macos/VoicePen/System/TextInserter.swift" \
  "$repo_root/macos/VoicePen/System/PasteboardSnapshot.swift" \
  "$repo_root/macos/tests/DirectInsertionSmoke.swift" \
  "$core_bin"/ShallWeTalkCore.build/*.o -o "$build_dir/smoke"
"$build_dir/smoke"
xcrun swiftc "$repo_root/macos/VoicePen/System/HotkeyManager.swift" \
  "$repo_root/macos/tests/HotkeyRepeatSmoke.swift" -o "$build_dir/hotkey"
"$build_dir/hotkey"
bash "$repo_root/macos/tests/audio_engine_boundary.sh"
xcrun swiftc -sanitize=thread "$repo_root/macos/VoicePen/Services/OpenAIRealtimeSession.swift" \
  "$repo_root/macos/tests/RealtimeLifecycleSmoke.swift" -o "$build_dir/realtime"
"$build_dir/realtime"
