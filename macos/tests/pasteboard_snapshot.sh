#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
snapshot_build="$(mktemp -d "${TMPDIR:-/tmp}/shallwetalk-pasteboard.XXXXXX")"
trap 'rm -rf "$snapshot_build"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc \
  "$repo_root/macos/VoicePen/System/PasteboardSnapshot.swift" \
  "$repo_root/macos/tests/PasteboardSnapshotSmoke.swift" \
  -o "$snapshot_build/PasteboardSnapshotSmoke"
"$snapshot_build/PasteboardSnapshotSmoke"
