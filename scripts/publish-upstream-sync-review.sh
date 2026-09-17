#!/usr/bin/env bash
set -euo pipefail

required=(
  GH_TOKEN
  BRANCH
  UPSTREAM_SHA
  DOWNSTREAM_BRANCH
  GITHUB_REPOSITORY
  GITHUB_REPOSITORY_OWNER
  UPSTREAM_REPOSITORY
)

for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    printf 'upstream sync publication requires %s\n' "$name" >&2
    exit 2
  fi
done

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

if [[ "${CONFLICTED:-false}" == true ]]; then
  title="chore: resolve ${UPSTREAM_REPOSITORY} sync conflicts"
  body="Reviews \`${UPSTREAM_REPOSITORY}@${UPSTREAM_SHA}\` against downstream customizations. Automatic merge conflicts: \`${CONFLICT_FILES:-not reported}\`. Resolve locally, preserve both contracts, and run the downstream validation before marking this ready."
else
  title="chore: sync ${UPSTREAM_REPOSITORY} main"
  body="Merges \`${UPSTREAM_REPOSITORY}@${UPSTREAM_SHA}\` through the downstream package validation contract."
fi

retry git push --set-upstream origin "$BRANCH"

existing=$(retry gh api --method GET "repos/${GITHUB_REPOSITORY}/pulls" \
  -f state=open \
  -f "head=${GITHUB_REPOSITORY_OWNER}:${BRANCH}" \
  -f "base=${DOWNSTREAM_BRANCH}" \
  -f per_page=1 \
  --jq 'if length == 0 then empty else .[0] | [.number, .html_url] | @tsv end')

if [[ -n "$existing" ]]; then
  IFS=$'\t' read -r existing_number existing_url <<< "$existing"
  retry gh api --method PATCH "repos/${GITHUB_REPOSITORY}/pulls/${existing_number}" \
    -f "title=${title}" \
    -f "body=${body}" \
    --silent
  printf 'Refreshed upstream review pull request: %s\n' "$existing_url"
  exit 0
fi

if [[ "${CONFLICTED:-false}" == true ]]; then
  created=$(retry gh api --method POST "repos/${GITHUB_REPOSITORY}/pulls" \
    -f "title=${title}" \
    -f "head=${BRANCH}" \
    -f "base=${DOWNSTREAM_BRANCH}" \
    -f "body=${body}" \
    -F draft=true \
    --jq '.html_url')
else
  created=$(retry gh api --method POST "repos/${GITHUB_REPOSITORY}/pulls" \
    -f "title=${title}" \
    -f "head=${BRANCH}" \
    -f "base=${DOWNSTREAM_BRANCH}" \
    -f "body=${body}" \
    --jq '.html_url')
fi

printf 'Created upstream review pull request: %s\n' "$created"
