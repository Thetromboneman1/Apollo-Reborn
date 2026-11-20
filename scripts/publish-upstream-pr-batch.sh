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
recovery_file=$(mktemp "${TMPDIR:-/tmp}/apollo-upstream-recovery.XXXXXX")
pending_file=$(mktemp "${TMPDIR:-/tmp}/apollo-upstream-predecessors.XXXXXX")
trap 'rm -f "$body_file" "$recovery_file" "$pending_file"' EXIT

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
owner=${GITHUB_REPOSITORY%%/*}

# A new snapshot name does not supersede manually resolved commits. Only close
# a prior PR once exact ancestry proves its pinned head is retained by a fully
# validated replacement. Unknown, moved, or incomparable heads require review.
preserved_batches=false
candidate_changed=false
# Supplied only by the trusted report job after allowlisted documentation.
validated_head=${VALIDATED_HEAD:-}

contains_commit() {
  local ancestor=$1 descendant=$2 comparison status merge_base
  [[ "$ancestor" =~ ^[0-9a-f]{40}$ && "$descendant" =~ ^[0-9a-f]{40}$ ]] || return 1
  [[ "$ancestor" == "$descendant" ]] && return 0
  comparison=$(retry gh api --method GET \
    "repos/${GITHUB_REPOSITORY}/compare/${ancestor}...${descendant}" \
    --jq '[.status, .merge_base_commit.sha] | @tsv') || return 1
  IFS=$'\t' read -r status merge_base <<< "$comparison"
  [[ ( "$status" == ahead || "$status" == identical ) && "$merge_base" == "$ancestor" ]]
}

candidate_head_matches() {
  local current_number=$1 live_candidate
  [[ "$validated_head" =~ ^[0-9a-f]{40}$ ]] || return 1
  live_candidate=$(retry gh api --method GET "repos/${GITHUB_REPOSITORY}/pulls/${current_number}" --jq '.head.sha') || return 1
  [[ "$live_candidate" == "$validated_head" ]]
}

block_changed_candidate() {
  candidate_changed=true
  ready=false
  printf '\n## Candidate head requires revalidation\n\nExpected trusted post-documentation head: `%s`. The live PR head differs or could not be verified. Keep this candidate draft and rerun validation; ancestry is insufficient.\n' \
    "${validated_head:-missing}" | tee -a "$recovery_file" >> "$SUMMARY_PATH"
}

preserve_batch() {
  local number=$1 url=$2 old_head=$3 replacement_head=$4 reason=$5
  if [[ "$preserved_batches" != true ]]; then
    printf '\n## Preserved prior integration work\n\n' | tee -a "$recovery_file" >> "$SUMMARY_PATH"
    printf 'These branches are recovery candidates, not imported changes. Manual review is required before reuse, especially when upstream heads changed.\n\n' | tee -a "$recovery_file" >> "$SUMMARY_PATH"
  fi
  preserved_batches=true
  printf -- '- Fork integration PR %s: preserved head `%s`; replacement assembled head `%s`. %s\n' \
    "$number" "$old_head" "$replacement_head" "$reason" | tee -a "$recovery_file" >> "$SUMMARY_PATH"
  printf 'Preserved prior integration PR %s at %s: %s\n' "$url" "$old_head" "$reason"
}

inspect_superseded_batches() {
  local current_number=${1:-} replacement_head records
  local old_number old_url old_head live_old reason
  if [[ "$changed" == true ]]; then
    replacement_head=$(read_manifest assembled_head)
  else
    replacement_head=$(read_manifest downstream_sha)
  fi
  records=$(retry gh api --paginate --method GET "repos/${GITHUB_REPOSITORY}/pulls" \
    -f state=open \
    -f "base=${DOWNSTREAM_BRANCH}" \
    -f per_page=100 \
    --jq '.[] | select(.head.repo.full_name == "'"$GITHUB_REPOSITORY"'" and (.head.ref | startswith("Thetromboneman1/all-open-upstream-prs-"))) | [.number, .html_url, .head.sha] | @tsv')
  while IFS=$'\t' read -r old_number old_url old_head; do
    [[ -n "$old_number" ]] || continue
    [[ -n "$current_number" && "$old_number" == "$current_number" ]] && continue
    reason=""
    if [[ "$complete" != true || "$VALIDATION_RESULT" != success || "$candidate_changed" == true ]]; then
      reason="Replacement is incomplete or not successfully validated."
    elif ! contains_commit "$old_head" "$replacement_head"; then
      reason="Prior-head containment is not proven; keep its conflict resolutions for manual review."
    elif [[ -n "$current_number" ]]; then
      if ! candidate_head_matches "$current_number"; then
        reason="Replacement branch differs from the trusted validated head or could not be verified."
        block_changed_candidate
      fi
    fi
    if [[ -z "$reason" ]]; then
      live_old=$(retry gh api --method GET "repos/${GITHUB_REPOSITORY}/pulls/${old_number}" --jq '.head.sha') || live_old=""
      if [[ "$live_old" != "$old_head" ]]; then
        reason="Prior branch moved during publication or could not be rechecked."
      fi
    fi
    if [[ -n "$reason" ]]; then
      preserve_batch "$old_number" "$old_url" "$old_head" "$replacement_head" "$reason"
      continue
    fi
    # Inspection does not close anything. A rejected/queued merge must leave
    # every predecessor open, even if all of these comparisons passed.
    printf '%s\t%s\t%s\t%s\n' "$old_number" "$old_url" "$old_head" "$replacement_head" >> "$pending_file"
  done <<< "$records"
}

close_landed_predecessors() {
  local old_number old_url old_head replacement_head live_old live_downstream
  while IFS=$'\t' read -r old_number old_url old_head replacement_head; do
    [[ -n "$old_number" ]] || continue
    live_downstream=$(retry gh api --method GET "repos/${GITHUB_REPOSITORY}/branches/${DOWNSTREAM_BRANCH}" --jq '.commit.sha') || live_downstream=""
    if ! contains_commit "$replacement_head" "$live_downstream"; then
      preserve_batch "$old_number" "$old_url" "$old_head" "$replacement_head" \
        "Downstream no longer contains the inspected replacement or could not be verified."
      continue
    fi
    live_old=$(retry gh api --method GET "repos/${GITHUB_REPOSITORY}/pulls/${old_number}" --jq '.head.sha') || live_old=""
    if [[ "$live_old" != "$old_head" ]]; then
      preserve_batch "$old_number" "$old_url" "$old_head" "$replacement_head" \
        "Prior branch moved before post-merge cleanup or could not be rechecked."
      continue
    fi
    retry gh api --method PATCH "repos/${GITHUB_REPOSITORY}/pulls/${old_number}" \
      -f state=closed \
      --silent
    printf 'Closed superseded fork integration PR after exact-head containment and landing: %s\n' "$old_url"
  done < "$pending_file"
}

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
import re
import sys

path = Path(sys.argv[1])
body = path.read_text(encoding="utf-8")
# Defense in depth: even if a future report accidentally copies an upstream
# title, URL, or author mention, the published PR body must not notify them.
# The JSON manifest remains the lossless machine-readable provenance record.
body = re.sub(
    r"https://github\.com/([^/\s)]+/[^/\s)]+)/(pull|issues)/(\d+)(?:[^\s)]*)?",
    lambda match: (
        f"{match.group(1)} "
        f"{'pull request' if match.group(2) == 'pull' else 'issue'} {match.group(3)}"
    ),
    body,
)
body = re.sub(
    r"(?<![\w/.-])([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#(\d+)",
    lambda match: f"{match.group(1)} pull request {match.group(2)}",
    body,
)
body = re.sub(r"(?<![\w])#(\d+)", r"PR \1", body)
body = re.sub(
    r"(?<![\w])@([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))",
    lambda match: f"GitHub user {match.group(1)}",
    body,
)
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
  inspect_superseded_batches
  close_landed_predecessors
  if [[ "$preserved_batches" == true ]]; then
    printf 'prior integration work requires manual review; no branches imported or deleted\n' >&2
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

existing=$(retry gh api --method GET "repos/${GITHUB_REPOSITORY}/pulls" \
  -f state=open \
  -f "head=${owner}:${BRANCH}" \
  -f "base=${DOWNSTREAM_BRANCH}" \
  -f per_page=1 \
  --jq 'if length == 0 then empty else .[0] | [.number, .html_url, .draft] | @tsv end')

if [[ -n "$existing" ]]; then
  IFS=$'\t' read -r number url is_draft <<< "$existing"
  # Fail closed before metadata, comparison, or API operations can fail. Only
  # promote after all prior-work checks below have completed successfully.
  if [[ "$is_draft" != true ]]; then
    retry gh pr ready "$number" --repo "$GITHUB_REPOSITORY" --undo
    is_draft=true
  fi
  retry gh api --method PATCH "repos/${GITHUB_REPOSITORY}/pulls/${number}" \
    -f "title=${title}" \
    -F "body=@${body_file}" \
    --silent
  printf 'Refreshed fork integration PR: %s\n' "$url"
else
  # Completeness alone does not establish that prior resolutions survived.
  draft=true
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

# Enforce the head gate even when there are no predecessor PRs to inspect.
if [[ "$ready" == true ]] && ! candidate_head_matches "$number"; then
  block_changed_candidate
fi
inspect_superseded_batches "$number"
# Recheck after the inventory/containment calls and before promoting the PR.
if [[ "$ready" == true ]] && ! candidate_head_matches "$number"; then
  block_changed_candidate
fi

if [[ "$preserved_batches" == true || "$candidate_changed" == true ]]; then
  ready=false
  # Put recovery provenance first so the body limit cannot hide this blocker.
  python3 - "$body_file" "$recovery_file" <<'PY_BODY'
from pathlib import Path
import sys
body, recovery = map(Path, sys.argv[1:])
text = recovery.read_text() + "\n" + body.read_text()
if len(text) > 64000:
    text = text[:64000] + "\n\n_Report truncated; the job summary retains the complete recovery list._\n"
body.write_text(text)
PY_BODY
  title="chore: review preserved upstream PR resolutions (${fingerprint:0:12})"
  retry gh api --method PATCH "repos/${GITHUB_REPOSITORY}/pulls/${number}" \
    -f "title=${title}" \
    -F "body=@${body_file}" \
    --silent
fi

if [[ "$ready" == true && "$is_draft" == true ]]; then
  retry gh pr ready "$number" --repo "$GITHUB_REPOSITORY"
elif [[ "$ready" != true && "$is_draft" != true ]]; then
  retry gh pr ready "$number" --repo "$GITHUB_REPOSITORY" --undo
fi

if [[ "$ready" == true && "${AUTO_MERGE:-true}" == true ]]; then
  # GitHub performs this exact-head check atomically with the merge, closing
  # the race between the final read above and another writer's push.
  if ! retry gh pr merge "$number" --repo "$GITHUB_REPOSITORY" --merge --delete-branch \
    --match-head-commit "$validated_head"; then
    retry gh pr ready "$number" --repo "$GITHUB_REPOSITORY" --undo
    printf 'Pinned merge rejected; candidate remains review-required.\n' >&2
    exit 1
  fi
  # A successful CLI call can enqueue a PR instead of landing it. Confirm the
  # pinned head actually merged before closing recovery PRs.
  merged_state=$(retry gh api --method GET "repos/${GITHUB_REPOSITORY}/pulls/${number}" \
    --jq '[.merged, .head.sha, .base.ref] | @tsv')
  IFS=$'\t' read -r is_merged merged_head merged_base <<< "$merged_state"
  if [[ "$is_merged" != true || "$merged_head" != "$validated_head" || "$merged_base" != "$DOWNSTREAM_BRANCH" ]]; then
    printf 'Pinned merge has not been confirmed; predecessor PRs remain open.\n' >&2
    exit 1
  fi
  printf 'Merged complete validated all-open PR snapshot: %s\n' "$url"
  close_landed_predecessors
fi

if [[ "$complete" != true || "$VALIDATION_RESULT" != success || "$preserved_batches" == true || "$candidate_changed" == true ]]; then
  printf 'batch remains review-required: complete=%s validation=%s preserved-prior-work=%s candidate-changed=%s\n' "$complete" "$VALIDATION_RESULT" "$preserved_batches" "$candidate_changed" >&2
  exit 1
fi
