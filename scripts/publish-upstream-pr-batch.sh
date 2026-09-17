#!/usr/bin/env bash
set -euo pipefail

required=(
  GH_TOKEN
  BRANCH
  DOWNSTREAM_BRANCH
  GITHUB_REPOSITORY
  MANIFEST_PATH
  SUMMARY_PATH
  VALIDATION_RESULT
  RUN_URL
)

for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    printf 'upstream PR batch publication requires %s\n' "$name" >&2
    exit 2
  fi
done

body_file=$(mktemp "${TMPDIR:-/tmp}/apollo-upstream-pr-body.XXXXXX")
trap 'rm -f "$body_file"' EXIT

retry() {
  local attempt=1
  local max_attempts=${RETRY_MAX_ATTEMPTS:-3}
  local delay=${RETRY_DELAY_SECONDS:-2}
  until "$@"; do
    if (( attempt >= max_attempts )); then
      return 1
    fi
    printf 'attempt %d/%d failed; retrying: %s\n' "$attempt" "$max_attempts" "$*" >&2
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}

read_manifest() {
  python3 - "$MANIFEST_PATH" "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
for part in sys.argv[2].split("."):
    value = value[part]
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

complete=$(read_manifest complete)
changed=$(read_manifest changed)
fingerprint=$(read_manifest fingerprint)
total=$(read_manifest total)
included=$(read_manifest included_count)

{
  # shellcheck disable=SC2016
  printf 'This fork-only batch inventories **all open pull requests** in `Apollo-Reborn/Apollo-Reborn`, including drafts, blocked work, and stacked branches.\n\n'
  printf -- '- Workflow run: %s\n' "$RUN_URL"
  # shellcheck disable=SC2016
  printf -- '- Snapshot: `%s`\n' "$fingerprint"
  printf -- '- Exact heads included: **%s/%s**\n' "$included" "$total"
  printf -- '- Secretless validation job: **%s**\n\n' "$VALIDATION_RESULT"
  cat "$SUMMARY_PATH"
} > "$body_file"

# GitHub limits pull request bodies to 65,536 characters. Preserve the complete
# machine-readable manifest as the run artifact and keep the PR readable.
python3 - "$body_file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
body = path.read_text(encoding="utf-8")
limit = 64000
if len(body) > limit:
    body = body[:limit] + "\n\n_Report truncated; download the run artifact for the full manifest._\n"
path.write_text(body, encoding="utf-8")
PY

if [[ "$changed" != true ]]; then
  printf 'All %s exact upstream PR heads are already present on %s.\n' "$total" "$DOWNSTREAM_BRANCH"
  if [[ "$complete" != true ]]; then
    printf 'manifest is incomplete despite no repository change\n' >&2
    exit 1
  fi
  exit 0
fi

if [[ "$complete" == true && "$VALIDATION_RESULT" == success ]]; then
  title="chore: integrate all ${total} open upstream PRs (${fingerprint:0:12})"
  ready=true
else
  title="chore: resolve all-open upstream PR integration (${fingerprint:0:12})"
  ready=false
fi

owner=${GITHUB_REPOSITORY%%/*}
existing=$(retry gh api --method GET "repos/${GITHUB_REPOSITORY}/pulls" \
  -f state=open \
  -f "head=${owner}:${BRANCH}" \
  -f "base=${DOWNSTREAM_BRANCH}" \
  -f per_page=1 \
  --jq 'if length == 0 then empty else .[0] | [.number, .html_url, .draft] | @tsv end')

if [[ -n "$existing" ]]; then
  IFS=$'\t' read -r number url is_draft <<< "$existing"
  retry gh api --method PATCH "repos/${GITHUB_REPOSITORY}/pulls/${number}" \
    -f "title=${title}" \
    -F "body=@${body_file}" \
    --silent
  printf 'Refreshed fork integration PR: %s\n' "$url"
else
  if [[ "$ready" == true ]]; then
    draft=false
  else
    draft=true
  fi
  created=$(retry gh api --method POST "repos/${GITHUB_REPOSITORY}/pulls" \
    -f "title=${title}" \
    -f "head=${BRANCH}" \
    -f "base=${DOWNSTREAM_BRANCH}" \
    -F "body=@${body_file}" \
    -F "draft=${draft}" \
    --jq '[.number, .html_url, .draft] | @tsv')
  IFS=$'\t' read -r number url is_draft <<< "$created"
  printf 'Created fork integration PR: %s\n' "$url"
fi

if [[ "$ready" == true && "$is_draft" == true ]]; then
  retry gh pr ready "$number" --repo "$GITHUB_REPOSITORY"
elif [[ "$ready" != true && "$is_draft" != true ]]; then
  retry gh pr ready "$number" --repo "$GITHUB_REPOSITORY" --undo
fi

if [[ "$ready" == true && "${AUTO_MERGE:-true}" == true ]]; then
  retry gh pr merge "$number" --repo "$GITHUB_REPOSITORY" --merge --delete-branch
  printf 'Merged complete validated all-open PR snapshot: %s\n' "$url"
fi

if [[ "$complete" != true || "$VALIDATION_RESULT" != success ]]; then
  printf 'batch remains review-required: complete=%s validation=%s\n' "$complete" "$VALIDATION_RESULT" >&2
  exit 1
fi
