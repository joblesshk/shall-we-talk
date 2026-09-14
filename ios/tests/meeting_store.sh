#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
review_build="$(mktemp -d "${TMPDIR:-/tmp}/shallwetalk-meeting.XXXXXX")"
trap 'rm -rf "$review_build"' EXIT
core_scratch="${SHALLWETALK_VERIFY_CORE_SCRATCH:-/tmp/ShallWeTalk-verify-core}"
core_bin="$(swift build --package-path "$repo_root/core" --scratch-path "$core_scratch" --show-bin-path)"
xcrun swiftc -I "$core_bin/Modules" \
  "$repo_root/ios/_sources/Shared/MeetingStore.swift" \
  "$repo_root/ios/_sources/Shared/CloudMeetingSync.swift" \
  "$repo_root/ios/_sources/Shared/MeetingAudioWriter.swift" \
  "$repo_root/ios/tests/MeetingStoreSmoke.swift" \
  "$core_bin"/ShallWeTalkCore.build/*.o -o "$review_build/meeting"
"$review_build/meeting"
