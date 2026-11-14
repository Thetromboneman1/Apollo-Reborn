#!/usr/bin/env bash
# Regression tests for scripts/verify-base-ipa.sh (the base IPA pin).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$ROOT/scripts/verify-base-ipa.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pinned_url=$(grep -Ev '^[[:space:]]*(#|$)' "$ROOT/distribution/base-ipa.sha256" | awk 'NR == 1 { print $2 }')
printf 'not the base ipa\n' > "$work/other.ipa"
if command -v sha256sum >/dev/null 2>&1; then
  other_sha=$(sha256sum "$work/other.ipa" | awk '{ print $1 }')
else
  other_sha=$(shasum -a 256 "$work/other.ipa" | awk '{ print $1 }')
fi

expect() {
  local want=$1 label=$2
  shift 2
  if "$@" >"$work/out" 2>&1; then got=0; else got=1; fi
  if [[ "$got" != "$want" ]]; then
    printf 'FAIL: %s (exit %s, wanted %s)\n' "$label" "$got" "$want" >&2
    cat "$work/out" >&2
    exit 1
  fi
}

expect 1 "default URL rejects a file that differs from the pin" bash "$VERIFY" "$work/other.ipa" "$pinned_url"
expect 1 "custom URL without a digest is refused" bash "$VERIFY" "$work/other.ipa" https://example.test/a.ipa
expect 0 "custom URL with a matching digest passes" bash "$VERIFY" "$work/other.ipa" https://example.test/a.ipa "$other_sha"
expect 0 "digest comparison ignores case" bash "$VERIFY" "$work/other.ipa" https://example.test/a.ipa "$(printf '%s' "$other_sha" | tr 'a-f' 'A-F')"
expect 1 "a wrong digest fails even for the default URL" bash "$VERIFY" "$work/other.ipa" "$pinned_url" "$(printf '0%.0s' {1..64})"
expect 1 "a malformed digest fails" bash "$VERIFY" "$work/other.ipa" https://example.test/a.ipa nothex
ALLOW_UNPINNED_BASE_IPA=1 expect 0 "manual builds may opt into an unpinned IPA" bash "$VERIFY" "$work/other.ipa" https://example.test/a.ipa
echo "base IPA pin tests passed"
