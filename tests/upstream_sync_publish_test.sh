#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

WORKFLOW="$ROOT/.github/workflows/boneman-upstream-sync.yml"
grep -F 'scripts/upstream_pr_batch.py' "$WORKFLOW" >/dev/null
grep -F 'scripts/publish-upstream-pr-batch.sh' "$WORKFLOW" >/dev/null
grep -F 'persist-credentials: false' "$WORKFLOW" >/dev/null
grep -F 'Secretless documentation and package validation' "$WORKFLOW" >/dev/null
grep -F 'batch-manifest.json' "$WORKFLOW" >/dev/null
grep -F 'Imported whitespace findings' "$WORKFLOW" >/dev/null
if grep -F 'secrets.GITHUB_TOKEN' "$WORKFLOW" >/dev/null; then
  printf 'all-open upstream workflow must not use the built-in token for publication\n' >&2
  exit 1
fi

FAKE_BIN="$TEST_ROOT/bin"
FAKE_LOG="$TEST_ROOT/calls.log"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh' >> "$FAKE_LOG"
printf ' <%s>' "$@" >> "$FAKE_LOG"
printf '\n' >> "$FAKE_LOG"
if [[ "$*" == *"--method GET"* ]]; then
  printf '%s\n' "${FAKE_EXISTING:-}"
elif [[ "$*" == *"--method POST"* ]]; then
  printf '%s\n' $'42\thttps://github.com/Thetromboneman1/Apollo-Reborn/pull/42\t'"${FAKE_CREATED_DRAFT:-false}"
fi
SH
chmod +x "$FAKE_BIN/gh"

SUMMARY="$TEST_ROOT/summary.md"
printf '# Complete batch report\n' > "$SUMMARY"

write_manifest() {
  python3 - "$TEST_ROOT/manifest.json" "$1" "$2" <<'PY'
import json
import sys

json.dump({
    "complete": sys.argv[2] == "true",
    "changed": sys.argv[3] == "true",
    "fingerprint": "0123456789abcdef",
    "total": 18,
    "included_count": 18 if sys.argv[2] == "true" else 13,
}, open(sys.argv[1], "w", encoding="utf-8"))
PY
}

run_publish() {
  env \
    PATH="$FAKE_BIN:$PATH" \
    FAKE_LOG="$FAKE_LOG" \
    FAKE_EXISTING="${FAKE_EXISTING:-}" \
    FAKE_CREATED_DRAFT="${FAKE_CREATED_DRAFT:-false}" \
    GH_TOKEN=test-token \
    BRANCH=Thetromboneman1/all-open-upstream-prs-0123456789ab \
    DOWNSTREAM_BRANCH=main \
    GITHUB_REPOSITORY=Thetromboneman1/Apollo-Reborn \
    MANIFEST_PATH="$TEST_ROOT/manifest.json" \
    SUMMARY_PATH="$SUMMARY" \
    VALIDATION_RESULT="${VALIDATION_RESULT:-success}" \
    RUN_URL=https://github.com/example/actions/runs/1 \
    AUTO_MERGE="${AUTO_MERGE:-false}" \
    RETRY_DELAY_SECONDS=0 \
    "$ROOT/scripts/publish-upstream-pr-batch.sh"
}

: > "$FAKE_LOG"
write_manifest true false
run_publish > "$TEST_ROOT/no-change.out"
grep -F 'already present on main' "$TEST_ROOT/no-change.out" >/dev/null
if [[ -s "$FAKE_LOG" ]]; then
  printf 'no-change publication unexpectedly called GitHub\n' >&2
  exit 1
fi

: > "$FAKE_LOG"
write_manifest false true
FAKE_CREATED_DRAFT=true
export FAKE_CREATED_DRAFT
if run_publish > "$TEST_ROOT/incomplete.out" 2>&1; then
  printf 'incomplete batch unexpectedly passed the completeness gate\n' >&2
  exit 1
fi
grep -F '<draft=true>' "$FAKE_LOG" >/dev/null
grep -F 'batch remains review-required' "$TEST_ROOT/incomplete.out" >/dev/null

: > "$FAKE_LOG"
write_manifest true true
unset FAKE_CREATED_DRAFT
AUTO_MERGE=false run_publish > "$TEST_ROOT/ready.out"
grep -F '<draft=false>' "$FAKE_LOG" >/dev/null
if grep -F ' <pr> <merge>' "$FAKE_LOG" >/dev/null; then
  printf 'auto-merge=false unexpectedly merged the PR\n' >&2
  exit 1
fi

: > "$FAKE_LOG"
FAKE_EXISTING=$'41\thttps://github.com/Thetromboneman1/Apollo-Reborn/pull/41\ttrue' \
AUTO_MERGE=true \
run_publish > "$TEST_ROOT/existing.out"
grep -F ' <pr> <ready> <41>' "$FAKE_LOG" >/dev/null
grep -F ' <pr> <merge> <41>' "$FAKE_LOG" >/dev/null
grep -F 'Merged complete validated all-open PR snapshot' "$TEST_ROOT/existing.out" >/dev/null

printf 'upstream sync publication tests passed\n'
