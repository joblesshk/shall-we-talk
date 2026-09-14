#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
bench_dir="$(mktemp -d /tmp/voicepen-pinyin-performance.XXXXXX)"
trap 'rm -rf "$bench_dir"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cp "$root/_sources/Keyboard/PinyinData/"*.txt "$root/_sources/Keyboard/PinyinData/"*.sqlite "$bench_dir/"
xcrun swiftc -O -parse-as-library -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  "$root/_sources/Keyboard/Pinyin/"*.swift "$root/tests/PinyinPerformanceBenchmark.swift" \
  -o "$bench_dir/benchmark"
"$bench_dir/benchmark" "$root/tests/fixtures/pinyin_performance_inputs.txt" 3
