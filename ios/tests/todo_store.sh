#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
review_build="$(mktemp -d "${TMPDIR:-/tmp}/shallwetalk-todo.XXXXXX")"
trap 'rm -rf "$review_build"' EXIT
for source in "$repo_root/ios/_sources/Shared/TodoStore.swift" "$repo_root/macos/VoicePen/Storage/TodoStore.swift"; do
  xcrun swiftc "$source" "$repo_root/ios/tests/TodoStorePersistenceSmoke.swift" -o "$review_build/todo"
  "$review_build/todo"
done
