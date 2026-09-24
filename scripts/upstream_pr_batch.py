#!/usr/bin/env python3
"""Snapshot and assemble every open upstream pull request into a fork branch."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


GRAPHQL_QUERY = r"""
query($owner: String!, $name: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(
      first: 100
      after: $cursor
      states: OPEN
      orderBy: {field: CREATED_AT, direction: ASC}
    ) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number
        title
        url
        isDraft
        baseRefName
        headRefName
        headRefOid
        mergeable
        mergeStateStatus
        reviewDecision
        additions
        deletions
        changedFiles
        author { login }
        headRepository { nameWithOwner }
        commits(last: 1) {
          nodes {
            commit {
              statusCheckRollup { state }
            }
          }
        }
      }
    }
  }
}
"""


@dataclass(frozen=True)
class PullRequest:
    number: int
    title: str
    url: str
    draft: bool
    base_ref: str
    head_ref: str
    head_sha: str
    head_repository: str | None
    author: str
    mergeable: str
    merge_state: str
    review_decision: str
    checks: str
    additions: int
    deletions: int
    changed_files: int

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "PullRequest":
        commits = value.get("commits", {}).get("nodes", [])
        rollup = commits[-1].get("commit", {}).get("statusCheckRollup") if commits else None
        repository = value.get("headRepository")
        author = value.get("author")
        return cls(
            number=int(value["number"]),
            title=str(value.get("title") or ""),
            url=str(value.get("url") or ""),
            draft=bool(value.get("isDraft", value.get("draft", False))),
            base_ref=str(value.get("baseRefName", value.get("base_ref", "")) or ""),
            head_ref=str(value.get("headRefName", value.get("head_ref", "")) or ""),
            head_sha=str(value.get("headRefOid", value.get("head_sha", "")) or ""),
            head_repository=(repository or {}).get("nameWithOwner")
            if isinstance(repository, dict)
            else value.get("head_repository"),
            author=(author or {}).get("login", "unknown")
            if isinstance(author, dict)
            else str(value.get("author", "unknown")),
            mergeable=str(value.get("mergeable") or "UNKNOWN"),
            merge_state=str(value.get("mergeStateStatus", value.get("merge_state", "UNKNOWN")) or "UNKNOWN"),
            review_decision=str(value.get("reviewDecision", value.get("review_decision", "NONE")) or "NONE"),
            checks=str((rollup or {}).get("state", value.get("checks", "NONE")) or "NONE"),
            additions=int(value.get("additions", 0)),
            deletions=int(value.get("deletions", 0)),
            changed_files=int(value.get("changedFiles", value.get("changed_files", 0))),
        )

    def as_dict(self) -> dict[str, Any]:
        return {
            "number": self.number,
            "title": self.title,
            "url": self.url,
            "draft": self.draft,
            "base_ref": self.base_ref,
            "head_ref": self.head_ref,
            "head_sha": self.head_sha,
            "head_repository": self.head_repository,
            "author": self.author,
            "mergeable": self.mergeable,
            "merge_state": self.merge_state,
            "review_decision": self.review_decision,
            "checks": self.checks,
            "additions": self.additions,
            "deletions": self.deletions,
            "changed_files": self.changed_files,
        }


def run(
    args: list[str],
    *,
    cwd: Path | None = None,
    check: bool = True,
    capture: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        args,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    if check and result.returncode != 0:
        output = ((result.stdout or "") + (result.stderr or ""))[-6000:]
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(args)}\n{output}")
    return result


def retry(args: list[str], *, cwd: Path, attempts: int = 3) -> subprocess.CompletedProcess[str]:
    for attempt in range(1, attempts + 1):
        result = run(args, cwd=cwd, check=False)
        if result.returncode == 0:
            return result
        if attempt == attempts:
            output = ((result.stdout or "") + (result.stderr or ""))[-6000:]
            raise RuntimeError(f"command failed after {attempts} attempts: {' '.join(args)}\n{output}")
        print(f"retry {attempt}/{attempts}: {' '.join(args)}", file=sys.stderr)
        time.sleep(attempt * 2)
    raise AssertionError("unreachable")


def git(root: Path, *args: str, check: bool = True) -> str:
    return run(["git", *args], cwd=root, check=check).stdout.strip()


def is_ancestor(root: Path, ancestor: str, descendant: str) -> bool:
    return run(["git", "merge-base", "--is-ancestor", ancestor, descendant], cwd=root, check=False).returncode == 0


def snapshot_fingerprint(downstream_sha: str, upstream_main_sha: str, prs: list[PullRequest]) -> str:
    payload = {
        "downstream_sha": downstream_sha,
        "upstream_main_sha": upstream_main_sha,
        "pull_requests": [[pr.number, pr.head_sha] for pr in sorted(prs, key=lambda item: item.number)],
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def fetch_open_prs(owner: str, name: str) -> list[PullRequest]:
    prs: list[PullRequest] = []
    cursor: str | None = None
    while True:
        args = [
            "gh",
            "api",
            "graphql",
            "-f",
            f"query={GRAPHQL_QUERY}",
            "-F",
            f"owner={owner}",
            "-F",
            f"name={name}",
        ]
        if cursor:
            args.extend(["-F", f"cursor={cursor}"])
        result = run(args)
        payload = json.loads(result.stdout)
        connection = payload["data"]["repository"]["pullRequests"]
        prs.extend(PullRequest.from_dict(node) for node in connection["nodes"])
        page = connection["pageInfo"]
        if not page["hasNextPage"]:
            break
        cursor = page["endCursor"]
        if not cursor:
            raise RuntimeError("GitHub reported another page without an end cursor")
    return prs


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def command_snapshot(args: argparse.Namespace) -> int:
    owner, name = args.upstream_repository.split("/", 1)
    prs = fetch_open_prs(owner, name)
    fingerprint = snapshot_fingerprint(args.downstream_sha, args.upstream_main_sha, prs)
    payload = {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "upstream_repository": args.upstream_repository,
        "downstream_sha": args.downstream_sha,
        "upstream_main_sha": args.upstream_main_sha,
        "fingerprint": fingerprint,
        "pull_requests": [pr.as_dict() for pr in prs],
    }
    write_json(args.output, payload)
    print(f"snapshotted {len(prs)} open upstream pull requests ({fingerprint[:12]})")
    return 0


def load_snapshot(path: Path) -> tuple[dict[str, Any], list[PullRequest]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    return payload, [PullRequest.from_dict(value) for value in payload["pull_requests"]]


def topological_order(root: Path, prs: list[PullRequest]) -> tuple[list[PullRequest], dict[int, list[int]]]:
    dependencies: dict[int, set[int]] = {pr.number: set() for pr in prs}
    by_number = {pr.number: pr for pr in prs}
    for candidate in prs:
        for possible_parent in prs:
            if candidate.number == possible_parent.number:
                continue
            if is_ancestor(root, possible_parent.head_sha, candidate.head_sha):
                dependencies[candidate.number].add(possible_parent.number)

    ordered: list[PullRequest] = []
    remaining = set(by_number)
    while remaining:
        ready = sorted(number for number in remaining if not (dependencies[number] & remaining))
        if not ready:
            raise RuntimeError(f"cycle detected in upstream PR ancestry: {sorted(remaining)}")
        for number in ready:
            ordered.append(by_number[number])
            remaining.remove(number)
    return ordered, {number: sorted(values) for number, values in dependencies.items()}


def conflict_details(root: Path) -> tuple[list[str], list[dict[str, Any]]]:
    files = [line for line in git(root, "diff", "--name-only", "--diff-filter=U").splitlines() if line]
    stages: list[dict[str, Any]] = []
    for line in git(root, "ls-files", "-u").splitlines():
        if not line:
            continue
        metadata, path = line.split("\t", 1)
        mode, blob, stage = metadata.split()
        stages.append({"path": path, "stage": int(stage), "blob": blob, "mode": mode})
    return files, stages


def patch_equivalent_upstream_commits(root: Path, upstream_sha: str) -> list[str] | None:
    """Return patch-equivalent upstream commits when a topology-only merge is safe."""
    merge_commits = [
        line for line in git(root, "rev-list", "--merges", f"HEAD..{upstream_sha}").splitlines() if line
    ]
    if merge_commits:
        return None
    cherry = run(["git", "cherry", "HEAD", upstream_sha], cwd=root, check=False)
    if cherry.returncode != 0:
        return None
    lines = [line.strip() for line in cherry.stdout.splitlines() if line.strip()]
    if not lines or any(not line.startswith("- ") for line in lines):
        return None
    return [line[2:] for line in lines]


def upstream_commit_source_pr(root: Path, commit_sha: str) -> int | None:
    """Return the squash/merge PR number recorded in an upstream commit title."""
    subject = git(root, "show", "-s", "--format=%s", commit_sha)
    match = re.search(r"\(#(\d+)\)\s*$", subject)
    return int(match.group(1)) if match else None


def source_integrated_upstream_commits(
    root: Path,
    upstream_sha: str,
    upstream_remote: str,
    *,
    merge_missing: bool,
) -> list[dict[str, Any]] | None:
    """Prove upstream-only commits are present through their exact merged PR heads.

    GitHub squash commits often stop being patch-equivalent after this fork has
    resolved the original PR head additively.  The upstream commit title still
    records the source PR number.  Fetching that immutable merged PR ref and
    proving its exact head is an ancestor gives us a stronger lineage check than
    taking either side of a repeated text conflict.
    """
    cherry = run(["git", "cherry", "HEAD", upstream_sha], cwd=root, check=False)
    if cherry.returncode != 0:
        return None
    records: list[dict[str, Any]] = []
    for line in [value.strip() for value in cherry.stdout.splitlines() if value.strip()]:
        sign, commit_sha = line.split(maxsplit=1)
        if sign == "-":
            records.append({"upstream_commit": commit_sha, "status": "patch-equivalent"})
            continue
        pr_number = upstream_commit_source_pr(root, commit_sha)
        if pr_number is None:
            return None
        ref = f"refs/remotes/upstream-main-prs/{pr_number}"
        try:
            retry(
                ["git", "fetch", "--force", upstream_remote, f"refs/pull/{pr_number}/head:{ref}"],
                cwd=root,
            )
        except RuntimeError:
            return None
        pr_head = git(root, "rev-parse", ref)
        status = "already-present"
        merge_commit: str | None = None
        if not is_ancestor(root, pr_head, "HEAD"):
            if not merge_missing:
                return None
            merged = run(
                [
                    "git",
                    "merge",
                    "--no-ff",
                    "-m",
                    f"Merge exact source head for upstream main PR #{pr_number}",
                    "-m",
                    f"Source head: {pr_head}\nUpstream squash commit: {commit_sha}",
                    pr_head,
                ],
                cwd=root,
                check=False,
            )
            if merged.returncode != 0:
                git(root, "merge", "--abort")
                return None
            status = "merged"
            merge_commit = git(root, "rev-parse", "HEAD")
        record: dict[str, Any] = {
            "upstream_commit": commit_sha,
            "source_pr": pr_number,
            "source_head": pr_head,
            "status": status,
        }
        if merge_commit:
            record["merge_commit"] = merge_commit
        records.append(record)
    return records


def markdown_escape(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ").replace("\r", " ")


def render_summary(manifest: dict[str, Any]) -> str:
    lines = [
        "# All-open upstream PR integration",
        "",
        f"- Snapshot: `{manifest['fingerprint']}`",
        f"- Fork base: `{manifest['downstream_sha']}`",
        f"- Upstream main: `{manifest['upstream_main_sha']}`",
        f"- Upstream main result: **{manifest['upstream_main_result']['status']}**",
        f"- Open PRs inventoried: **{manifest['total']}**",
        f"- Exact heads present after assembly: **{manifest['included_count']}/{manifest['total']}**",
        f"- Complete: **{'yes' if manifest['complete'] else 'no'}**",
        "",
        "| PR | State | Draft | Upstream state | Head | Title |",
        "|---:|---|:---:|---|---|---|",
    ]
    for result in manifest["results"]:
        pr = result["pull_request"]
        upstream_state = f"{pr['merge_state']} / {pr['review_decision']} / {pr['checks']}"
        lines.append(
            f"| [#{pr['number']}]({pr['url']}) | `{result['status']}` | "
            f"{'yes' if pr['draft'] else 'no'} | {markdown_escape(upstream_state)} | "
            f"`{pr['head_sha'][:12]}` | {markdown_escape(pr['title'])} |"
        )
    lines.extend(["", "## Per-PR merge record", ""])
    for result in manifest["results"]:
        pr = result["pull_request"]
        lines.extend(
            [
                f"### #{pr['number']}: {markdown_escape(pr['title'])}",
                "",
                f"- Result: `{result['status']}`",
                f"- Source: `{pr['head_repository'] or 'deleted repository'}:{pr['head_ref']}`",
                f"- Exact head: `{pr['head_sha']}`",
                f"- Original base: `{pr['base_ref']}`",
                f"- Author: `{pr['author']}`",
                f"- Draft/review/checks: `{pr['draft']}` / `{pr['review_decision']}` / `{pr['checks']}`",
                f"- Upstream merge state: `{pr['mergeable']} / {pr['merge_state']}`",
                f"- Size: `{pr['changed_files']} files, +{pr['additions']}/-{pr['deletions']}`",
                f"- Dependencies in this snapshot: `{', '.join('#' + str(value) for value in result['dependencies']) or 'none'}`",
            ]
        )
        if result.get("merge_commit"):
            lines.append(f"- Integration merge commit: `{result['merge_commit']}`")
        if result.get("conflict_files"):
            lines.append(f"- Conflicts: `{', '.join(result['conflict_files'])}`")
        if result.get("error"):
            lines.append(f"- Error: `{markdown_escape(result['error'])}`")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def command_assemble(args: argparse.Namespace) -> int:
    root = args.repository.resolve()
    snapshot, prs = load_snapshot(args.snapshot)
    downstream = snapshot["downstream_sha"]
    branch = args.branch or f"Thetromboneman1/all-open-upstream-prs-{snapshot['fingerprint'][:12]}"
    remote_tracking = f"refs/remotes/{args.origin_remote}/{branch}"

    remote_branch = retry(
        ["git", "ls-remote", "--heads", args.origin_remote, branch],
        cwd=root,
    ).stdout.strip()
    if remote_branch:
        retry(
            ["git", "fetch", args.origin_remote, f"refs/heads/{branch}:{remote_tracking}"],
            cwd=root,
        )
    if run(["git", "show-ref", "--verify", "--quiet", remote_tracking], cwd=root, check=False).returncode == 0:
        starting_point = remote_tracking
        if not is_ancestor(root, downstream, starting_point):
            raise RuntimeError(f"existing integration branch {branch} does not contain fork base {downstream}")
    else:
        starting_point = downstream
    git(root, "switch", "--force-create", branch, starting_point)
    git(root, "config", "user.name", "github-actions[bot]")
    git(root, "config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com")

    upstream_main_result: dict[str, Any] = {"status": "already-present", "conflict_files": []}
    upstream_main_sha = snapshot["upstream_main_sha"]
    if not is_ancestor(root, upstream_main_sha, "HEAD"):
        merged_main = run(
            [
                "git",
                "merge",
                "--no-ff",
                "-m",
                f"Merge {snapshot['upstream_repository']} main",
                "-m",
                f"Exact upstream main: {upstream_main_sha}",
                upstream_main_sha,
            ],
            cwd=root,
            check=False,
        )
        if merged_main.returncode == 0:
            upstream_main_result = {"status": "merged", "merge_commit": git(root, "rev-parse", "HEAD")}
        else:
            files, stages = conflict_details(root)
            git(root, "merge", "--abort")
            equivalent = patch_equivalent_upstream_commits(root, upstream_main_sha)
            if equivalent:
                topology_merge = run(
                    [
                        "git",
                        "merge",
                        "--strategy=ours",
                        "--no-ff",
                        "-m",
                        f"Bridge patch-equivalent {snapshot['upstream_repository']} main ancestry",
                        "-m",
                        "Every upstream-only patch is already patch-equivalent in the fork; "
                        "preserve the validated fork tree while recording exact upstream ancestry.",
                        upstream_main_sha,
                    ],
                    cwd=root,
                    check=False,
                )
                if topology_merge.returncode != 0 or not is_ancestor(root, upstream_main_sha, "HEAD"):
                    raise RuntimeError("patch-equivalent upstream topology merge failed")
                upstream_main_result = {
                    "status": "patch-equivalent-topology-merge",
                    "merge_commit": git(root, "rev-parse", "HEAD"),
                    "patch_equivalent_commits": equivalent,
                    "original_conflict_files": files,
                }
            else:
                source_records = source_integrated_upstream_commits(
                    root,
                    upstream_main_sha,
                    args.upstream_remote,
                    merge_missing=True,
                )
                source_proof = (
                    source_records
                    and source_integrated_upstream_commits(
                        root,
                        upstream_main_sha,
                        args.upstream_remote,
                        merge_missing=False,
                    )
                )
                if source_proof:
                    topology_merge = run(
                        [
                            "git",
                            "merge",
                            "--strategy=ours",
                            "--no-ff",
                            "-m",
                            f"Bridge source-integrated {snapshot['upstream_repository']} main ancestry",
                            "-m",
                            "Every upstream-only squash commit is represented by its exact merged PR head "
                            "in the fork; preserve the fork-resolved tree while recording upstream ancestry.",
                            upstream_main_sha,
                        ],
                        cwd=root,
                        check=False,
                    )
                    if topology_merge.returncode != 0 or not is_ancestor(root, upstream_main_sha, "HEAD"):
                        raise RuntimeError("source-integrated upstream topology merge failed")
                    upstream_main_result = {
                        "status": "source-pr-topology-merge",
                        "merge_commit": git(root, "rev-parse", "HEAD"),
                        "source_pr_commits": source_records,
                        "original_conflict_files": files,
                    }
                else:
                    upstream_main_result = {
                        "status": "conflict",
                        "conflict_files": files,
                        "conflict_stages": stages,
                        "source_pr_commits": source_records or [],
                        "error": ((merged_main.stdout or "") + (merged_main.stderr or ""))[-2000:].strip(),
                    }

    fetch_errors: dict[int, str] = {}
    for pr in sorted(prs, key=lambda item: item.number):
        ref = f"refs/remotes/upstream-open-prs/{pr.number}"
        try:
            retry(
                ["git", "fetch", "--force", args.upstream_remote, f"refs/pull/{pr.number}/head:{ref}"],
                cwd=root,
            )
            fetched = git(root, "rev-parse", ref)
            if fetched != pr.head_sha:
                fetch_errors[pr.number] = f"head moved: snapshot {pr.head_sha}, fetched {fetched}"
        except RuntimeError as exc:
            fetch_errors[pr.number] = str(exc).splitlines()[-1]

    fetchable = [pr for pr in prs if pr.number not in fetch_errors]
    ordered, dependencies = topological_order(root, fetchable)
    results: list[dict[str, Any]] = []
    result_by_number: dict[int, dict[str, Any]] = {}

    for pr in ordered:
        record: dict[str, Any] = {
            "pull_request": pr.as_dict(),
            "dependencies": dependencies[pr.number],
            "status": "pending",
        }
        print(f"::group::Upstream PR #{pr.number}: {pr.title}")
        print(f"url={pr.url}")
        print(f"head={pr.head_sha}")
        print(f"draft={pr.draft} merge_state={pr.merge_state} review={pr.review_decision} checks={pr.checks}")
        if is_ancestor(root, pr.head_sha, "HEAD"):
            record["status"] = "already-present" if is_ancestor(root, pr.head_sha, downstream) else "included-by-cohort"
            print(f"result={record['status']}")
        else:
            before = git(root, "rev-parse", "HEAD")
            message = f"Merge upstream PR #{pr.number}: {pr.title}"
            details = (
                f"Source: {pr.url}\n"
                f"Head: {pr.head_sha}\n"
                f"Author: {pr.author}\n"
                f"Draft: {pr.draft}\n"
                f"Review: {pr.review_decision}\n"
                f"Checks: {pr.checks}"
            )
            merged = run(
                ["git", "merge", "--no-ff", "-m", message, "-m", details, pr.head_sha],
                cwd=root,
                check=False,
            )
            if merged.returncode == 0:
                record["status"] = "merged"
                record["merge_commit"] = git(root, "rev-parse", "HEAD")
                record["changed_paths"] = [
                    line for line in git(root, "diff", "--name-only", f"{before}..HEAD").splitlines() if line
                ]
                print(f"result=merged commit={record['merge_commit']}")
                print(git(root, "show", "--stat", "--oneline", "--no-renames", "HEAD"))
            else:
                files, stages = conflict_details(root)
                record["status"] = "conflict"
                record["conflict_files"] = files
                record["conflict_stages"] = stages
                record["error"] = ((merged.stdout or "") + (merged.stderr or ""))[-2000:].strip()
                print(f"result=conflict files={','.join(files)}")
                git(root, "merge", "--abort")
        print("::endgroup::")
        results.append(record)
        result_by_number[pr.number] = record

    for pr in sorted(prs, key=lambda item: item.number):
        if pr.number in result_by_number:
            continue
        record = {
            "pull_request": pr.as_dict(),
            "dependencies": [],
            "status": "unfetchable-or-moved",
            "error": fetch_errors[pr.number],
        }
        results.append(record)
        result_by_number[pr.number] = record

    for record in results:
        pr = PullRequest.from_dict(record["pull_request"])
        if is_ancestor(root, pr.head_sha, "HEAD"):
            if record["status"] in {"conflict", "unfetchable-or-moved"}:
                record["status"] = "included-by-later-pr"
                record.pop("error", None)
            record["included"] = True
        else:
            record["included"] = False

    results.sort(key=lambda item: int(item["pull_request"]["number"]))
    head = git(root, "rev-parse", "HEAD")
    included_count = sum(1 for record in results if record["included"])
    upstream_main_included = is_ancestor(root, upstream_main_sha, "HEAD")
    complete = included_count == len(prs) and upstream_main_included
    changed = head != downstream
    manifest = {
        **{key: value for key, value in snapshot.items() if key != "pull_requests"},
        "branch": branch,
        "assembled_head": head,
        "total": len(prs),
        "included_count": included_count,
        "upstream_main_included": upstream_main_included,
        "upstream_main_result": upstream_main_result,
        "complete": complete,
        "changed": changed,
        "results": results,
    }
    write_json(args.manifest, manifest)
    args.summary.parent.mkdir(parents=True, exist_ok=True)
    args.summary.write_text(render_summary(manifest), encoding="utf-8")
    if args.github_output:
        with args.github_output.open("a", encoding="utf-8") as handle:
            handle.write(f"branch={branch}\n")
            handle.write(f"fingerprint={snapshot['fingerprint']}\n")
            handle.write(f"changed={'true' if changed else 'false'}\n")
            handle.write(f"complete={'true' if complete else 'false'}\n")
            handle.write(f"included_count={included_count}\n")
            handle.write(f"total={len(prs)}\n")
    print(f"assembled {included_count}/{len(prs)} exact heads on {branch}; complete={complete}")
    return 0


def command_compare(args: argparse.Namespace) -> int:
    before, _ = load_snapshot(args.before)
    after, _ = load_snapshot(args.after)
    if before["fingerprint"] != after["fingerprint"]:
        print(
            f"snapshot drifted: {before['fingerprint'][:12]} -> {after['fingerprint'][:12]}",
            file=sys.stderr,
        )
        return 75
    print(f"snapshot stable: {before['fingerprint'][:12]}")
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    subparsers = root.add_subparsers(dest="command", required=True)

    snapshot = subparsers.add_parser("snapshot")
    snapshot.add_argument("--upstream-repository", required=True)
    snapshot.add_argument("--downstream-sha", required=True)
    snapshot.add_argument("--upstream-main-sha", required=True)
    snapshot.add_argument("--output", type=Path, required=True)
    snapshot.set_defaults(func=command_snapshot)

    assemble = subparsers.add_parser("assemble")
    assemble.add_argument("--repository", type=Path, default=Path.cwd())
    assemble.add_argument("--snapshot", type=Path, required=True)
    assemble.add_argument("--manifest", type=Path, required=True)
    assemble.add_argument("--summary", type=Path, required=True)
    assemble.add_argument("--branch")
    assemble.add_argument("--origin-remote", default="origin")
    assemble.add_argument("--upstream-remote", default="upstream")
    assemble.add_argument("--github-output", type=Path)
    assemble.set_defaults(func=command_assemble)

    compare = subparsers.add_parser("compare")
    compare.add_argument("--before", type=Path, required=True)
    compare.add_argument("--after", type=Path, required=True)
    compare.set_defaults(func=command_compare)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        return int(args.func(args))
    except (KeyError, ValueError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"upstream PR batch failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
