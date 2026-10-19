#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("upstream_pr_batch", ROOT / "scripts/upstream_pr_batch.py")
assert SPEC and SPEC.loader
BATCH = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = BATCH
SPEC.loader.exec_module(BATCH)


def command(root: Path, *args: str) -> str:
    result = subprocess.run(
        list(args),
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    return result.stdout.strip()


def graph_node(number: int) -> dict[str, object]:
    return {
        "number": number,
        "title": f"PR {number}",
        "url": f"https://example.test/pull/{number}",
        "isDraft": number % 2 == 0,
        "baseRefName": "main",
        "headRefName": f"feature/{number}",
        "headRefOid": f"{number:040x}",
        "mergeable": "MERGEABLE",
        "mergeStateStatus": "CLEAN",
        "reviewDecision": "APPROVED",
        "additions": 1,
        "deletions": 0,
        "changedFiles": 1,
        "author": {"login": "tester"},
        "headRepository": {"nameWithOwner": "tester/repo"},
        "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS"}}}]},
    }


class SnapshotTests(unittest.TestCase):
    def test_graphql_paginates_beyond_one_hundred_prs(self) -> None:
        pages = [
            {
                "data": {
                    "repository": {
                        "pullRequests": {
                            "nodes": [graph_node(number) for number in range(1, 101)],
                            "pageInfo": {"hasNextPage": True, "endCursor": "page-2"},
                        }
                    }
                }
            },
            {
                "data": {
                    "repository": {
                        "pullRequests": {
                            "nodes": [graph_node(101)],
                            "pageInfo": {"hasNextPage": False, "endCursor": None},
                        }
                    }
                }
            },
        ]
        responses = [subprocess.CompletedProcess([], 0, json.dumps(page), "") for page in pages]
        with mock.patch.object(BATCH, "run", side_effect=responses) as mocked:
            prs = BATCH.fetch_open_prs("owner", "repo")
        self.assertEqual(101, len(prs))
        self.assertIn("cursor=page-2", mocked.call_args_list[1].args[0])

    def test_snapshot_excludes_configured_pull_requests(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            exclusions = root / "exclusions.json"
            output = root / "snapshot.json"
            exclusions.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "upstream_repository": "owner/repo",
                        "pull_requests": [
                            {"number": 1383, "reason": "excluded settings work"},
                            {"number": 1401, "reason": "excluded setup work"},
                            {"number": 1413, "reason": "excluded video work"},
                        ],
                    }
                ),
                encoding="utf-8",
            )
            args = type(
                "Args",
                (),
                {
                    "upstream_repository": "owner/repo",
                    "downstream_sha": "a" * 40,
                    "upstream_main_sha": "b" * 40,
                    "exclusions": exclusions,
                    "output": output,
                },
            )()
            prs = [BATCH.PullRequest.from_dict(graph_node(number)) for number in (1383, 1401, 1413, 1500)]
            statuses = {
                number: {
                    "number": number,
                    "state": "open",
                    "merged_at": None,
                    "head_sha": f"{number:040x}",
                }
                for number in (1383, 1401, 1413)
            }
            with mock.patch.object(BATCH, "fetch_open_prs", return_value=prs), mock.patch.object(
                BATCH,
                "fetch_pull_request_status",
                side_effect=lambda owner, name, number: statuses[number],
            ):
                self.assertEqual(0, BATCH.command_snapshot(args))
            snapshot = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual([1500], [record["number"] for record in snapshot["pull_requests"]])
            self.assertEqual(
                [1383, 1401, 1413],
                [record["number"] for record in snapshot["excluded_pull_requests"]],
            )

    def test_snapshot_stops_when_excluded_pull_request_is_merged(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            exclusions = root / "exclusions.json"
            exclusions.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "upstream_repository": "owner/repo",
                        "pull_requests": [{"number": 1383, "reason": "excluded settings work"}],
                    }
                ),
                encoding="utf-8",
            )
            args = type(
                "Args",
                (),
                {
                    "upstream_repository": "owner/repo",
                    "downstream_sha": "a" * 40,
                    "upstream_main_sha": "b" * 40,
                    "exclusions": exclusions,
                    "output": root / "snapshot.json",
                },
            )()
            merged = {
                "number": 1383,
                "state": "closed",
                "merged_at": "2026-10-20T00:00:00Z",
                "head_sha": "c" * 40,
            }
            with mock.patch.object(BATCH, "fetch_open_prs", return_value=[]), mock.patch.object(
                BATCH, "fetch_pull_request_status", return_value=merged
            ):
                with self.assertRaisesRegex(RuntimeError, "manual upstream-main review is required"):
                    BATCH.command_snapshot(args)


class SummarySafetyTests(unittest.TestCase):
    def test_human_summary_omits_notification_producing_upstream_metadata(self) -> None:
        manifest = {
            "fingerprint": "fingerprint",
            "downstream_sha": "a" * 40,
            "upstream_main_sha": "b" * 40,
            "upstream_main_result": {"status": "already-present"},
            "total": 1,
            "included_count": 0,
            "complete": False,
            "results": [
                {
                    "status": "conflict",
                    "dependencies": [123],
                    "conflict_files": ["safe`@path-owner"],
                    "error": "ping @maintainer about owner/repo#456 and #789",
                    "pull_request": {
                        "number": 7,
                        "title": "Ping @maintainer about #789",
                        "url": "https://github.com/owner/repo/pull/7",
                        "draft": False,
                        "base_ref": "main`@base-owner",
                        "head_ref": "feature`@branch-owner",
                        "head_sha": "c" * 40,
                        "head_repository": "owner/repo",
                        "author": "maintainer",
                        "mergeable": "CONFLICTING",
                        "merge_state": "DIRTY",
                        "review_decision": "NONE",
                        "checks": "FAILURE",
                        "additions": 1,
                        "deletions": 1,
                        "changed_files": 1,
                    },
                }
            ],
        }

        summary = BATCH.render_summary(manifest)

        self.assertIn("Upstream PR 7", summary)
        self.assertIn("upstream PR 123", summary)
        self.assertIn("Error details: retained in the machine-readable manifest", summary)
        for notifying_text in (
            "@maintainer",
            "#789",
            "owner/repo#456",
            "https://github.com/owner/repo/pull/7",
            "Ping @maintainer",
            "@path-owner",
            "@base-owner",
            "@branch-owner",
        ):
            self.assertNotIn(notifying_text, summary)
        self.assertIn("Conflict paths: retained in the machine-readable manifest", summary)


class AssemblyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "repo"
        self.upstream = Path(self.temp.name) / "upstream.git"
        self.origin = Path(self.temp.name) / "origin.git"
        self.root.mkdir()
        command(self.root, "git", "init", "-b", "main")
        command(self.root, "git", "config", "user.name", "Test")
        command(self.root, "git", "config", "user.email", "test@example.test")
        command(self.root, "git", "init", "--bare", str(self.upstream))
        command(self.root, "git", "init", "--bare", str(self.origin))
        command(self.root, "git", "remote", "add", "origin", str(self.origin))
        command(self.root, "git", "remote", "add", "upstream", str(self.upstream))
        (self.root / "shared.txt").write_text("base\n", encoding="utf-8")
        command(self.root, "git", "add", "shared.txt")
        command(self.root, "git", "commit", "-m", "base")
        self.base = command(self.root, "git", "rev-parse", "HEAD")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def make_pr(self, number: int, parent: str, path: str, content: str) -> str:
        command(self.root, "git", "switch", "--detach", parent)
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        command(self.root, "git", "add", path)
        command(self.root, "git", "commit", "-m", f"PR {number}")
        sha = command(self.root, "git", "rev-parse", "HEAD")
        command(self.root, "git", "push", "upstream", f"{sha}:refs/pull/{number}/head")
        return sha

    def assemble_snapshot(self, downstream: str, upstream_main: str, prs: list[object]) -> dict[str, object]:
        snapshot = {
            "schema_version": 1,
            "generated_at": "test",
            "upstream_repository": "owner/repo",
            "downstream_sha": downstream,
            "upstream_main_sha": upstream_main,
            "fingerprint": BATCH.snapshot_fingerprint(downstream, upstream_main, prs),
            "pull_requests": [pr.as_dict() for pr in prs],
        }
        snapshot_path = self.root / "snapshot.json"
        manifest_path = self.root / "manifest.json"
        summary_path = self.root / "summary.md"
        snapshot_path.write_text(json.dumps(snapshot), encoding="utf-8")
        result = subprocess.run(
            [
                "python3",
                str(ROOT / "scripts/upstream_pr_batch.py"),
                "assemble",
                "--repository",
                str(self.root),
                "--snapshot",
                str(snapshot_path),
                "--manifest",
                str(manifest_path),
                "--summary",
                str(summary_path),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        return json.loads(manifest_path.read_text(encoding="utf-8"))

    def test_patch_equivalent_upstream_conflict_uses_topology_bridge(self) -> None:
        upstream = self.make_pr(90, self.base, "shared.txt", "shared upstream change\n")
        command(self.root, "git", "switch", "--force-create", "main", self.base)
        (self.root / "shared.txt").write_text("shared upstream change\n", encoding="utf-8")
        command(self.root, "git", "add", "shared.txt")
        command(self.root, "git", "commit", "-m", "equivalent fork patch")
        (self.root / "shared.txt").write_text("fork customization after shared change\n", encoding="utf-8")
        command(self.root, "git", "add", "shared.txt")
        command(self.root, "git", "commit", "-m", "fork customization")
        downstream = command(self.root, "git", "rev-parse", "HEAD")

        manifest = self.assemble_snapshot(downstream, upstream, [])
        self.assertTrue(manifest["complete"])
        self.assertTrue(manifest["upstream_main_included"])
        self.assertEqual("patch-equivalent-topology-merge", manifest["upstream_main_result"]["status"])
        self.assertEqual([upstream], manifest["upstream_main_result"]["patch_equivalent_commits"])
        self.assertEqual(
            "fork customization after shared change\n",
            (self.root / "shared.txt").read_text(encoding="utf-8"),
        )

    def test_squashed_upstream_conflict_reuses_exact_merged_source_heads(self) -> None:
        command(self.root, "git", "switch", "--detach", self.base)
        (self.root / "shared.txt").write_text("upstream part one\n", encoding="utf-8")
        command(self.root, "git", "add", "shared.txt")
        command(self.root, "git", "commit", "-m", "source part one")
        (self.root / "shared.txt").write_text("upstream final\n", encoding="utf-8")
        command(self.root, "git", "add", "shared.txt")
        command(self.root, "git", "commit", "-m", "source part two")
        source_92 = command(self.root, "git", "rev-parse", "HEAD")
        command(self.root, "git", "push", "upstream", f"{source_92}:refs/pull/92/head")

        source_93 = self.make_pr(93, self.base, "later.txt", "later source\n")

        command(self.root, "git", "switch", "--detach", self.base)
        (self.root / "shared.txt").write_text("upstream final\n", encoding="utf-8")
        command(self.root, "git", "add", "shared.txt")
        command(self.root, "git", "commit", "-m", "Shared feature (#92)")
        (self.root / "later.txt").write_text("later source\n", encoding="utf-8")
        command(self.root, "git", "add", "later.txt")
        command(self.root, "git", "commit", "-m", "Later feature (#93)")
        upstream_main = command(self.root, "git", "rev-parse", "HEAD")

        command(self.root, "git", "switch", "--force-create", "main", self.base)
        command(self.root, "git", "merge", "--no-ff", "-m", "integrate source 92", source_92)
        (self.root / "shared.txt").write_text("fork-resolved final\n", encoding="utf-8")
        command(self.root, "git", "add", "shared.txt")
        command(self.root, "git", "commit", "-m", "fork customization")
        downstream = command(self.root, "git", "rev-parse", "HEAD")

        manifest = self.assemble_snapshot(downstream, upstream_main, [])
        self.assertTrue(manifest["complete"])
        self.assertTrue(manifest["upstream_main_included"])
        self.assertEqual("source-pr-topology-merge", manifest["upstream_main_result"]["status"])
        records = manifest["upstream_main_result"]["source_pr_commits"]
        self.assertEqual([92, 93], [record["source_pr"] for record in records])
        self.assertEqual("already-present", records[0]["status"])
        self.assertEqual("merged", records[1]["status"])
        self.assertTrue(BATCH.is_ancestor(self.root, source_93, "HEAD"))
        self.assertEqual("fork-resolved final\n", (self.root / "shared.txt").read_text(encoding="utf-8"))
        self.assertEqual("later source\n", (self.root / "later.txt").read_text(encoding="utf-8"))

    def test_non_equivalent_upstream_conflict_remains_blocked(self) -> None:
        upstream = self.make_pr(91, self.base, "shared.txt", "upstream only\n")
        command(self.root, "git", "switch", "--force-create", "main", self.base)
        (self.root / "shared.txt").write_text("different fork change\n", encoding="utf-8")
        command(self.root, "git", "add", "shared.txt")
        command(self.root, "git", "commit", "-m", "different fork patch")
        downstream = command(self.root, "git", "rev-parse", "HEAD")

        manifest = self.assemble_snapshot(downstream, upstream, [])
        self.assertFalse(manifest["complete"])
        self.assertFalse(manifest["upstream_main_included"])
        self.assertEqual("conflict", manifest["upstream_main_result"]["status"])

    def test_assembly_stops_before_importing_excluded_upstream_commit(self) -> None:
        command(self.root, "git", "switch", "--detach", self.base)
        (self.root / "excluded.txt").write_text("excluded feature\n", encoding="utf-8")
        command(self.root, "git", "add", "excluded.txt")
        command(self.root, "git", "commit", "-m", "Excluded feature (#1383)")
        upstream_main = command(self.root, "git", "rev-parse", "HEAD")
        command(self.root, "git", "switch", "--force-create", "main", self.base)
        snapshot = {
            "schema_version": 2,
            "generated_at": "test",
            "upstream_repository": "owner/repo",
            "downstream_sha": self.base,
            "upstream_main_sha": upstream_main,
            "fingerprint": "blocked",
            "pull_requests": [],
            "excluded_pull_requests": [
                {
                    "number": 1383,
                    "reason": "excluded settings work",
                    "state": "open",
                    "merged_at": None,
                    "head_sha": "c" * 40,
                }
            ],
        }
        snapshot_path = self.root / "snapshot.json"
        snapshot_path.write_text(json.dumps(snapshot), encoding="utf-8")
        result = subprocess.run(
            [
                "python3",
                str(ROOT / "scripts/upstream_pr_batch.py"),
                "assemble",
                "--repository",
                str(self.root),
                "--snapshot",
                str(snapshot_path),
                "--manifest",
                str(self.root / "manifest.json"),
                "--summary",
                str(self.root / "summary.md"),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(1, result.returncode)
        self.assertIn("upstream main contains excluded pull-request commits", result.stderr)
        self.assertEqual(self.base, command(self.root, "git", "rev-parse", "HEAD"))

    def test_stacked_heads_are_ordered_and_conflict_is_reported(self) -> None:
        first = self.make_pr(1, self.base, "first.txt", "first\n")
        second = self.make_pr(2, first, "second.txt", "second\n")
        conflict = self.make_pr(3, self.base, "shared.txt", "upstream\n")

        command(self.root, "git", "switch", "--force-create", "main", self.base)
        (self.root / "shared.txt").write_text("fork\n", encoding="utf-8")
        command(self.root, "git", "add", "shared.txt")
        command(self.root, "git", "commit", "-m", "fork customization")
        downstream = command(self.root, "git", "rev-parse", "HEAD")

        prs = [
            BATCH.PullRequest(
                number=number,
                title="Ping @maintainer about #123" if number == 1 else f"PR {number}",
                url=f"https://github.com/owner/repo/pull/{number}",
                draft=number == 2,
                base_ref="main",
                head_ref=f"feature/{number}",
                head_sha=sha,
                head_repository="tester/repo",
                author="tester",
                mergeable="MERGEABLE",
                merge_state="CLEAN",
                review_decision="APPROVED",
                checks="SUCCESS",
                additions=1,
                deletions=0,
                changed_files=1,
            )
            for number, sha in ((1, first), (2, second), (3, conflict))
        ]
        manifest = self.assemble_snapshot(downstream, self.base, prs)
        by_number = {item["pull_request"]["number"]: item for item in manifest["results"]}
        self.assertEqual("merged", by_number[1]["status"])
        self.assertIn(by_number[2]["status"], {"merged", "included-by-cohort"})
        self.assertEqual([1], by_number[2]["dependencies"])
        self.assertEqual("conflict", by_number[3]["status"])
        self.assertEqual(["shared.txt"], by_number[3]["conflict_files"])
        self.assertEqual(2, manifest["included_count"])
        self.assertFalse(manifest["complete"])
        self.assertEqual(3, manifest["total"])
        first_record = by_number[1]["pull_request"]
        self.assertEqual("Ping @maintainer about #123", first_record["title"])
        self.assertEqual("https://github.com/owner/repo/pull/1", first_record["url"])
        merge_messages = command(self.root, "git", "log", "--format=%B", f"{downstream}..HEAD")
        self.assertNotIn("@maintainer", merge_messages)
        self.assertNotIn("#123", merge_messages)
        self.assertNotIn("https://github.com/owner/repo/pull/1", merge_messages)
        self.assertIn("Merge upstream PR 1 exact head", merge_messages)


if __name__ == "__main__":
    unittest.main()
