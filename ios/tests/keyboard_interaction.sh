#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SIMULATOR="${VOICEPEN_INTERACTION_SIMULATOR:-booted}"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
ARCH="$(uname -m)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/voicepen-interaction.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

xcrun --sdk iphonesimulator swiftc \
  -target "$ARCH-apple-ios18.0-simulator" -sdk "$SDK" \
  "$ROOT/_sources/Keyboard/KeyFieldStackView.swift" \
  "$ROOT/_sources/Keyboard/KeycapPreview.swift" \
  "$ROOT/tests/KeyboardInteractionSmoke.swift" \
  -o "$SCRATCH/smoke"
xcrun simctl spawn "$SIMULATOR" "$SCRATCH/smoke"
