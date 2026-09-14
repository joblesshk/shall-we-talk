#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

if ! command -v xcodegen >/dev/null 2>&1; then
  printf '%s\n' "error: XcodeGen is required. Install it with: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate \
  --spec "$repo_root/ios/project.yml" \
  --project "$repo_root/ios"

project_file="$repo_root/ios/VoicePenMobile.xcodeproj/project.pbxproj"
if [[ ! -f "$project_file" ]]; then
  printf '%s\n' "error: XcodeGen did not create the iOS project" >&2
  exit 1
fi

# LocalSecrets.swift 已从工程 sources 排除；构建产物不携带任何预置 token。

printf '%s\n' "Bootstrap complete: generated ios/VoicePenMobile.xcodeproj"
