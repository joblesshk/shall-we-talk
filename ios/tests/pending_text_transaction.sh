#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/voicepen-pending-text.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT HUP INT TERM

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  xcrun swiftc \
    -D DEBUG \
    "$ROOT/_sources/Shared/PendingTextStore.swift" \
    "$ROOT/tests/PendingTextTransactionSmoke.swift" \
    -o "$BUILD_DIR/PendingTextTransactionSmoke"

"$BUILD_DIR/PendingTextTransactionSmoke"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  xcrun swiftc "$ROOT/_sources/Shared/PendingClipboardCopyStore.swift" \
    "$ROOT/tests/PendingClipboardCopySmoke.swift" -o "$BUILD_DIR/PendingClipboardCopySmoke"
"$BUILD_DIR/PendingClipboardCopySmoke"
