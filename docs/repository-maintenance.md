# Repository Maintenance

## Ownership And Upstream

`Thetromboneman1/Apollo-Reborn` is a maintained fork of
`Apollo-Reborn/Apollo-Reborn`. The upstream project owns product development;
this fork owns only reviewed downstream changes and local build validation.

## Safe Synchronization

1. Snapshot upstream `main` and every selected open upstream pull request,
   including drafts, review-blocked work, and stacked branches. Apply the
   persistent exclusions in `.github/upstream-pr-exclusions.json` before the
   fingerprint and merge plan are created.
2. Fetch each PR through its immutable `refs/pull/<number>/head` ref and verify
   that it still matches the advertised SHA.
3. Order stacked heads by commit ancestry, then merge every exact head into a
   fork-owned snapshot branch with one detailed merge commit per PR.
4. Preserve unknown semantic conflicts for reviewed resolution. Never use a
   repository-wide `ours` or `theirs` strategy.
5. Run documentation checks and a full release-package build in a secretless
   job. Candidate code never runs with the write-capable sync token.
6. Publish the complete inventory, per-PR state, conflicts, and validation
   result in the fork PR, job summary, and machine-readable run artifact.
7. Merge into fork `main` only when every frozen exact head is present and the
   full validation job passes.

Upstream PRs 1383, 1401, and 1413 are intentionally excluded from fork
integration. The snapshot records their state but does not select or merge their
heads. If GitHub reports that an excluded PR was merged, or if upstream `main`
contains a commit whose recorded source is one of those PRs, automation stops
before assembling or publishing a candidate and requires manual upstream-main
review. Do not remove an exclusion merely to make a sync green.

This guard follows pull-request identity and the PR number recorded in normal
GitHub squash/merge commit subjects. It cannot prove semantic absence when the
same feature is copied manually, rewritten without its source PR number, or
introduced through a different pull request. Such an upstream-main change must
be surfaced and reviewed explicitly; the sync must never describe that case as
an automatically validated exclusion.

The scheduled sync requires a repository Actions secret named
`BONEMAN_UPSTREAM_SYNC_TOKEN`. Use a dedicated fine-grained token with access
only to `Thetromboneman1/Apollo-Reborn` and grant Contents, Pull requests, and
Workflows write permissions. Workflows permission is required because a
review branch can legitimately contain upstream changes under
`.github/workflows/`; the built-in `GITHUB_TOKEN` cannot push those changes.
Rotate the token through GitHub Actions or the Boneman vault, never a tracked
file.

Automated review branches use the
`Thetromboneman1/all-open-upstream-prs-<snapshot>` naming convention. The
snapshot includes fork `main`, upstream `main`, and every open PR head SHA.

If a PR conflicts, the workflow records its unmerged files and stage blob IDs,
aborts only that merge, and continues inventorying the remaining independent
PRs. The fork PR remains draft and the workflow fails its completeness gate
instead of reporting a false green. A reviewed resolution pushed to the exact
snapshot branch is retained on the next run. Repeated head drift is retried at
most three times, and network operations use bounded backoff.
