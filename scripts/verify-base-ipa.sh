#!/usr/bin/env bash
# Verify a downloaded Apollo base IPA against a pinned SHA-256 before anything
# is built on top of it.
#
#   scripts/verify-base-ipa.sh <ipa> <source-url> [expected-sha256]
#
# The expected digest is, in order: the third argument (a workflow input), or
# distribution/base-ipa.sha256 when <source-url> is the default base IPA URL
# recorded in that file. A non-default URL with no digest fails unless
# ALLOW_UNPINNED_BASE_IPA=1, which only build-ipa.yml (private test builds)
# sets; release and PR builds always require a pin.
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  printf 'usage: %s <ipa> <source-url> [expected-sha256]\n' "$0" >&2
  exit 2
fi

ipa=$1
url=$2
expected=${3:-}
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pin_file="$root/distribution/base-ipa.sha256"

# Pin file format: "<sha256>  <url>", one line, comments allowed.
pinned_sha=$(grep -Ev '^[[:space:]]*(#|$)' "$pin_file" | awk 'NR == 1 { print $1 }')
pinned_url=$(grep -Ev '^[[:space:]]*(#|$)' "$pin_file" | awk 'NR == 1 { print $2 }')

expected=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
if [[ -z "$expected" && "$url" == "$pinned_url" ]]; then
  expected=$pinned_sha
fi

if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$ipa" | awk '{ print $1 }')
else
  actual=$(shasum -a 256 "$ipa" | awk '{ print $1 }')
fi
echo "Base IPA SHA-256: ${actual}"

if [[ -z "$expected" ]]; then
  if [[ "${ALLOW_UNPINNED_BASE_IPA:-0}" == 1 ]]; then
    echo "::warning title=Unpinned base IPA::${url} has no pinned SHA-256; the build continues because this is a manual test build."
    exit 0
  fi
  echo "::error title=Unpinned base IPA::${url} has no pinned SHA-256. Pass apollo_ipa_sha256, or update distribution/base-ipa.sha256 after reviewing the new file."
  exit 1
fi

if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
  echo "::error title=Invalid base IPA digest::Expected a 64-character hex SHA-256, got '${expected}'."
  exit 1
fi

if [[ "$actual" != "$expected" ]]; then
  echo "::error title=Base IPA changed::${url} hashed to ${actual}, expected ${expected}. Do not build on it until the new file is reviewed and the pin updated."
  exit 1
fi
echo "Base IPA matches the pinned SHA-256."
