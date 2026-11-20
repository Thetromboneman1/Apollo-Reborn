#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

git init --bare "$TEST_ROOT/remote.git" >/dev/null
git clone "$TEST_ROOT/remote.git" "$TEST_ROOT/publisher" >/dev/null 2>&1
git -C "$TEST_ROOT/publisher" config user.name Publisher
git -C "$TEST_ROOT/publisher" config user.email publisher@example.test

printf 'code\n' > "$TEST_ROOT/publisher/code.txt"
mkdir -p "$TEST_ROOT/publisher/docs"
printf 'old\n' > "$TEST_ROOT/publisher/docs/REPOSITORY_STATE.md"
git -C "$TEST_ROOT/publisher" add .
git -C "$TEST_ROOT/publisher" commit -m base >/dev/null
base=$(git -C "$TEST_ROOT/publisher" rev-parse HEAD)
git -C "$TEST_ROOT/publisher" push origin "HEAD:refs/heads/candidate" >/dev/null

printf 'generated\n' > "$TEST_ROOT/publisher/docs/REPOSITORY_STATE.md"
git -C "$TEST_ROOT/publisher" commit -am 'docs: local generated state' >/dev/null
local_docs=$(git -C "$TEST_ROOT/publisher" rev-parse HEAD)

output_file="$TEST_ROOT/push-output"
(
    cd "$TEST_ROOT/publisher"
    BRANCH=candidate GITHUB_OUTPUT="$output_file" PUBLISH_RETRY_DELAY_SECONDS=0 \
        "$ROOT/scripts/push-validated-docs.sh"
)
[[ $(git --git-dir="$TEST_ROOT/remote.git" rev-parse refs/heads/candidate) == "$local_docs" ]]
grep -F "head=$local_docs" "$output_file" >/dev/null

git -C "$TEST_ROOT/publisher" switch --detach "$base" >/dev/null 2>&1
git -C "$TEST_ROOT/publisher" push origin "$base:refs/heads/race" >/dev/null
git clone "$TEST_ROOT/remote.git" "$TEST_ROOT/self-healer" >/dev/null 2>&1
git -C "$TEST_ROOT/self-healer" config user.name SelfHealer
git -C "$TEST_ROOT/self-healer" config user.email self-healer@example.test
git -C "$TEST_ROOT/self-healer" switch race >/dev/null 2>&1
printf 'generated\n' > "$TEST_ROOT/self-healer/docs/REPOSITORY_STATE.md"
git -C "$TEST_ROOT/self-healer" commit -am 'docs: remote generated state' >/dev/null
remote_docs=$(git -C "$TEST_ROOT/self-healer" rev-parse HEAD)
git -C "$TEST_ROOT/self-healer" push origin race >/dev/null

printf 'generated\n' > "$TEST_ROOT/publisher/docs/REPOSITORY_STATE.md"
git -C "$TEST_ROOT/publisher" commit -am 'docs: local equivalent state' >/dev/null
output_file="$TEST_ROOT/adopt-output"
(
    cd "$TEST_ROOT/publisher"
    BRANCH=race GITHUB_OUTPUT="$output_file" PUBLISH_RETRY_DELAY_SECONDS=0 \
        "$ROOT/scripts/push-validated-docs.sh"
)
[[ $(git --git-dir="$TEST_ROOT/remote.git" rev-parse refs/heads/race) == "$remote_docs" ]]
grep -F "head=$remote_docs" "$output_file" >/dev/null

git -C "$TEST_ROOT/self-healer" switch --detach "$base" >/dev/null 2>&1
git -C "$TEST_ROOT/self-healer" switch -C unsafe >/dev/null 2>&1
printf 'remote code change\n' > "$TEST_ROOT/self-healer/code.txt"
git -C "$TEST_ROOT/self-healer" commit -am 'code: competing change' >/dev/null
unsafe_head=$(git -C "$TEST_ROOT/self-healer" rev-parse HEAD)
git -C "$TEST_ROOT/self-healer" push origin "HEAD:refs/heads/unsafe" >/dev/null

git -C "$TEST_ROOT/publisher" switch --detach "$base" >/dev/null 2>&1
printf 'generated\n' > "$TEST_ROOT/publisher/docs/REPOSITORY_STATE.md"
git -C "$TEST_ROOT/publisher" commit -am 'docs: rejected local state' >/dev/null
if (
    cd "$TEST_ROOT/publisher"
    BRANCH=unsafe PUBLISH_RETRY_DELAY_SECONDS=0 "$ROOT/scripts/push-validated-docs.sh"
) >"$TEST_ROOT/unsafe.out" 2>&1; then
    printf 'publisher unexpectedly accepted a non-documentation remote change\n' >&2
    exit 1
fi
[[ $(git --git-dir="$TEST_ROOT/remote.git" rev-parse refs/heads/unsafe) == "$unsafe_head" ]]
grep -F 'unexpected path advanced on unsafe: code.txt' "$TEST_ROOT/unsafe.out" >/dev/null

printf 'validated documentation publication tests passed\n'
