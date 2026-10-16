#!/usr/bin/env bash
set -euo pipefail

: "${BRANCH:?BRANCH must name the candidate branch}"

remote=${PUBLISH_REMOTE:-origin}
max_attempts=${PUBLISH_MAX_ATTEMPTS:-3}
delay_seconds=${PUBLISH_RETRY_DELAY_SECONDS:-2}
local_head=$(git rev-parse HEAD)
base_head=$(git rev-parse HEAD^)
tracking_ref="refs/remotes/${remote}/validated-docs/${GITHUB_RUN_ID:-local}/${BRANCH}"

require_docs_only() {
    local from=$1
    local to=$2
    local path

    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        if [[ "$path" != README.md && "$path" != docs/* ]]; then
            printf 'refusing publication: unexpected path advanced on %s: %s\n' "$BRANCH" "$path" >&2
            return 1
        fi
    done < <(git diff --name-only "$from..$to")
}

write_head_output() {
    local head=$1
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf 'head=%s\n' "$head" >> "$GITHUB_OUTPUT"
    fi
}

require_docs_only "$base_head" "$local_head"

for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    git fetch --no-tags "$remote" "refs/heads/${BRANCH}:${tracking_ref}"
    remote_head=$(git rev-parse "$tracking_ref")

    if [[ "$remote_head" == "$local_head" ]]; then
        write_head_output "$local_head"
        printf 'validated documentation commit is already published at %s\n' "$local_head"
        exit 0
    fi

    if [[ "$remote_head" == "$base_head" ]]; then
        if git push "$remote" "${local_head}:refs/heads/${BRANCH}"; then
            write_head_output "$local_head"
            printf 'published validated documentation commit %s\n' "$local_head"
            exit 0
        fi

        if ((attempt < max_attempts)); then
            printf 'candidate branch moved during push; rechecking (%d/%d)\n' \
                "$attempt" "$max_attempts" >&2
            sleep "$delay_seconds"
            continue
        fi
        break
    fi

    if git merge-base --is-ancestor "$base_head" "$remote_head"; then
        require_docs_only "$base_head" "$remote_head"
        if git diff --quiet "$remote_head" "$local_head" -- README.md docs; then
            write_head_output "$remote_head"
            printf 'adopted equivalent remote documentation commit %s without rewriting history\n' \
                "$remote_head"
            exit 0
        fi
        printf 'refusing publication: remote documentation differs from validated output at %s\n' \
            "$remote_head" >&2
        exit 1
    fi

    printf 'refusing publication: %s moved away from validated base %s to %s\n' \
        "$BRANCH" "$base_head" "$remote_head" >&2
    exit 1
done

printf 'failed to publish validated documentation after %d attempts; remote history was preserved\n' \
    "$max_attempts" >&2
exit 1
