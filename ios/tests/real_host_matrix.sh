#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
DEVICE="${VOICEPEN_HOST_DEVICE:-platform=iOS Simulator,name=iPhone Air,OS=27.0}"
DERIVED="${VOICEPEN_HOST_DERIVED_DATA:-${TMPDIR:-/tmp}/VoicePenHostAcceptance-DerivedData}"
SIMULATOR_UDID="${VOICEPEN_HOST_UDID:-}"

if [ ! -d "$DEVELOPER_DIR" ]; then
  echo "FAIL: complete Xcode not found at $DEVELOPER_DIR" >&2
  exit 1
fi

"$ROOT/../scripts/bootstrap.sh"
"$ROOT/tests/pending_text_transaction.sh"

# 将可读的 Xcode destination 解析成确定的模拟器 UDID。也允许 CI 直接传
# VOICEPEN_HOST_UDID，避免同名模拟器带来的歧义。
if [ -z "$SIMULATOR_UDID" ]; then
  DEVICE_NAME="$(printf '%s\n' "$DEVICE" | sed -n 's/.*name=\([^,]*\).*/\1/p')"
  DEVICE_OS="$(printf '%s\n' "$DEVICE" | sed -n 's/.*OS=\([^,]*\).*/\1/p')"
  if [ -z "$DEVICE_NAME" ] || [ -z "$DEVICE_OS" ]; then
    echo "FAIL: set VOICEPEN_HOST_UDID or use a destination containing name= and OS=" >&2
    exit 1
  fi
  DEVICE_LINE="$(xcrun simctl list devices available | awk -v os="$DEVICE_OS" -v name="$DEVICE_NAME" '
    $0 == "-- iOS " os " --" { in_section = 1; next }
    in_section && /^-- / { exit }
    in_section && index($0, "    " name " (") == 1 { print; exit }
  ')"
  SIMULATOR_UDID="$(printf '%s\n' "$DEVICE_LINE" | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')"
fi

if ! printf '%s\n' "$SIMULATOR_UDID" | rg -q '^[0-9A-Fa-f-]{36}$'; then
  echo "FAIL: cannot resolve simulator UDID for $DEVICE" >&2
  exit 1
fi

DESTINATION="platform=iOS Simulator,id=$SIMULATOR_UDID"
if ! xcrun simctl list devices | rg -q "$SIMULATOR_UDID.*\(Booted\)"; then
  xcrun simctl boot "$SIMULATOR_UDID"
fi
xcrun simctl bootstatus "$SIMULATOR_UDID" -b

# UI 测试宿主会由 XCTest 安装；生产 App 必须先显式安装，系统设置才会列出
# Shall We Talk 键盘扩展。这样全新模拟器也不依赖开发者之前手工运行过主 App。
xcodebuild \
  -project "$ROOT/VoicePenMobile.xcodeproj" \
  -scheme VoicePenMobile \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED" \
  build

VOICEPEN_APP="$DERIVED/Build/Products/Debug-iphonesimulator/Shall We Talk.app"
if [ ! -d "$VOICEPEN_APP" ]; then
  echo "FAIL: built VoicePen app not found at $VOICEPEN_APP" >&2
  exit 1
fi
xcrun simctl install "$SIMULATOR_UDID" "$VOICEPEN_APP"

# First complete/verify the simulator's one-time third-party keyboard permission, then run the
# four host cases. Both commands fail hard; the matrix never counts a skipped case as a pass.
xcodebuild \
  -project "$ROOT/VoicePenMobile.xcodeproj" \
  -scheme VoicePenHostAcceptance \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED" \
  -only-testing:VoicePenHostUITests/VoicePenHostUITests/test00EnableVoicePenFullAccess \
  test

xcodebuild \
  -project "$ROOT/VoicePenMobile.xcodeproj" \
  -scheme VoicePenHostAcceptance \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED" \
  -skip-testing:VoicePenHostUITests/VoicePenHostUITests/test00EnableVoicePenFullAccess \
  test
