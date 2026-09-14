#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

failures=0
fail() {
  printf 'error: %s\n' "$1" >&2
  failures=$((failures + 1))
}

required_files=(
  README.md
  CONTRIBUTING.md
  SECURITY.md
  LICENSE
  REPOSITORY_POLICY.md
  .gitignore
  .gitattributes
  .editorconfig
  core/Package.swift
  ios/project.yml
  macos/VoicePen.xcodeproj/project.pbxproj
  scripts/bootstrap.sh
  scripts/verify.sh
  .github/workflows/ci.yml
)

for path in "${required_files[@]}"; do
  [[ -f "$path" ]] || fail "required repository file is missing: $path"
done

while IFS= read -r -d '' path; do
  case "$path" in
    .DS_Store|*/.DS_Store|.env|.env.*|*/LocalSecrets.swift|*/LocalSecrets.private.swift|\
    *.p8|*.pem|*.key|*.p12|*.cer|*.mobileprovision|\
    DerivedData/*|*/DerivedData/*|*/xcuserdata/*|*.xcuserstate|\
    core/.build/*|macos/build/*|ios/build/*|ios/VoicePenMobile.xcodeproj/*|\
    *.ipa|*.pkg|*.xcarchive/*|*.dSYM/*)
      [[ "$path" == ".env.example" ]] || fail "forbidden local/secret/generated file is tracked: $path"
      ;;
  esac

  if [[ -f "$path" ]]; then
    bytes=$(wc -c < "$path" | tr -d ' ')
    if (( bytes > 10485760 )); then
      case "$path" in
        ios/_sources/Keyboard/PinyinData/pinyin_ice.sqlite|\
        ios/_sources/Keyboard/PinyinData/pinyin_ice_t9.sqlite|\
        ios/_sources/Keyboard/PinyinData/pinyin_ice_initials.sqlite|\
        ios/_sources/Keyboard/PinyinData/pinyin_ice_sources.zip)
          (( bytes <= 104857600 )) || fail "reviewed dictionary resource exceeds 100 MiB: $path"
          ;;
        *) fail "tracked file exceeds 10 MiB and needs explicit Git LFS/repository review: $path" ;;
      esac
    fi
  fi
done < <(git ls-files -z)

# Only the four explicitly reviewed dictionary artifacts may exceed 10 MiB.
# Each must match its committed source/build manifest; never permit arbitrary large binaries.
python3 - <<'PYHASH' || fail "reviewed dictionary resource hashes do not match manifests"
import hashlib, json
from pathlib import Path
root = Path('ios/_sources/Keyboard/PinyinData')
if (root/'pinyin_ice.json').exists():
    records = json.loads((root/'pinyin_ice.json').read_text())['outputs']
    records.append(json.loads((root/'pinyin_ice_sources.json').read_text()))
    for item in records:
        assert hashlib.sha256((root/item['file']).read_bytes()).hexdigest() == item['sha256'], item['file']
PYHASH

secret_pattern='-----BEGIN ([A-Z ]+)?PRIVATE KEY-----|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|sk-(proj-)?[A-Za-z0-9_-]{32,}|xox[baprs]-[A-Za-z0-9-]{20,}|AIza[0-9A-Za-z_-]{30,}'
secret_hits=$(git grep -Il -E -e "$secret_pattern" -- . ':(exclude)scripts/check_repository.sh' || true)
if [[ -n "$secret_hits" ]]; then
  fail "possible credential material found in tracked files: $(printf '%s' "$secret_hits" | tr '\n' ' ')"
fi

# LocalSecrets.swift 只能存在于本机且永远不得被 Git 跟踪；当前 iOS 分发配置也明确
# 排除该文件。生成工程的排除契约由 iOS 集成回归脚本验证，这里的禁止跟踪清单和
# 密钥格式扫描负责仓库边界，两者都不得放松。

git diff --check || fail "working tree contains whitespace errors"
git diff --cached --check || fail "staged changes contain whitespace errors"

if (( failures > 0 )); then
  printf 'Repository policy failed with %d issue(s).\n' "$failures" >&2
  exit 1
fi

printf '%s\n' "Repository policy passed: required files, tracked paths, size limits, and secret patterns are clean."
