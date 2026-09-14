#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="$ROOT/_sources/Shared/MobileSettingsStore.swift"
VIEWS="$ROOT/_sources/App/Views.swift"
CONTROLLER="$ROOT/_sources/App/DictationController.swift"
CORE_CLEANUP="$ROOT/../core/Sources/ShallWeTalkCore/CleanupService.swift"
CORE_STREAM="$ROOT/../core/Sources/ShallWeTalkCore/VolcStreamingSession.swift"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

grep -Fq 'case overseas = "overseasWorker"' "$SETTINGS" \
  && grep -Fq 'case domestic = "domesticWorker"' "$SETTINGS" \
  || fail "formal app must define both Worker routes"
grep -Fq 'Text(route.title).tag(route.rawValue)' "$VIEWS" \
  && grep -Fq 'case overseas = "overseasWorker"' "$SETTINGS" \
  && grep -Fq 'case domestic = "domesticWorker"' "$SETTINGS" \
  && grep -Fq 'case .overseas: return "海外连接"' "$SETTINGS" \
  && grep -Fq 'case .domestic: return "国内连接"' "$SETTINGS" \
  || fail "settings must expose the requested Chinese route labels"
grep -Fq 'static let workerCleanupPath = "/v1/cleanup"' "$SETTINGS" \
  || fail "Worker cleanup base must stop before chat/completions"
grep -Fq 'workerRelayCleanupBaseURL' "$SETTINGS" \
  && grep -Fq 'activeLLMBaseURL' "$SETTINGS" \
  || fail "settings must route the LLM through the selected Worker"
grep -Fq 'warmupURL: settings.cleanupWarmupURL' "$CONTROLLER" \
  || fail "recording start must retain the parallel cleanup warmup"
grep -Fq 'bearerToken: usesWorker ? streamToken : nil' "$CONTROLLER" \
  || fail "streaming ASR must use a relay bearer token only on Worker routes"
grep -Fq 'baseURL.appendingPathComponent("chat/completions")' "$CORE_CLEANUP" \
  || fail "CleanupService request path contract changed unexpectedly"
grep -Fq 'Authorization' "$CORE_STREAM" \
  || fail "streaming core must support the relay Authorization header"
grep -Fq 'KeychainSecretStore.set(newValue, for: "cloudflareWorkerToken")' "$SETTINGS" \
  && grep -Fq 'KeychainSecretStore.set(newValue, for: "tencentWorkerToken")' "$SETTINGS" \
  || fail "Worker tokens must remain in the formal app keychain"
! grep -Fq 'cloudflareWorkerToken" var' "$SETTINGS" \
  || fail "Worker token must not be declared as AppStorage"
! grep -Fq 'tencentWorkerToken" var' "$SETTINGS" \
  || fail "Worker token must not be declared as AppStorage"

echo "PASS: formal app network route smoke checks"
