#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
parity_build="$(mktemp -d /tmp/swt-mac-parity.XXXXXX)"
trap 'rm -rf "$parity_build"' EXIT
xcrun swiftc "$repo_root/macos/VoicePen/Storage/TodoStore.swift" "$repo_root/macos/tests/TodoParitySmoke.swift" -o "$parity_build/todo"
"$parity_build/todo"
xcrun swiftc -parse-as-library "$repo_root/macos/VoicePen/Storage/TodoStore.swift" \
  "$repo_root/macos/VoicePen/Storage/AppDataDirectory.swift" "$repo_root/ios/tests/TodoDateResolverSmoke.swift" -o "$parity_build/dates"
"$parity_build/dates"
xcrun swiftc "$repo_root/macos/VoicePen/Services/CredentialSync.swift" \
  "$repo_root/macos/tests/CredentialSyncSmoke.swift" -o "$parity_build/config"
"$parity_build/config"
rg -q 'bearerToken: settings.usesWorkerRelay' "$repo_root/macos/VoicePen/AppState.swift"
rg -q 'bearerToken: settings.activeWorkerToken' "$repo_root/macos/VoicePen/AppState.swift"
rg -q 'warmupURL: settings.workerWarmupURL' "$repo_root/macos/VoicePen/AppState.swift"
rg -q 'PromptBuilder.buildDictation\(route: route' "$repo_root/macos/VoicePen/AppState.swift"
if rg -q 'LocalSecrets' "$repo_root/macos/project.yml" "$repo_root/macos/VoicePen.xcodeproj/project.pbxproj"; then
  echo 'FAIL: macOS build must not bundle provider credentials'; exit 1
fi
echo 'PASS: macOS relay consumer wiring and credential-free build policy'
