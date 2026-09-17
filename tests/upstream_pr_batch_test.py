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
                title=f"PR {number}",
                url=f"https://example.test/pull/{number}",
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
        snapshot = {
            "schema_version": 1,
            "generated_at": "test",
            "upstream_repository": "owner/repo",
            "downstream_sha": downstream,
            "upstream_main_sha": self.base,
            "fingerprint": BATCH.snapshot_fingerprint(downstream, self.base, prs),
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
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        by_number = {item["pull_request"]["number"]: item for item in manifest["results"]}
        self.assertEqual("merged", by_number[1]["status"])
        self.assertIn(by_number[2]["status"], {"merged", "included-by-cohort"})
        self.assertEqual([1], by_number[2]["dependencies"])
        self.assertEqual("conflict", by_number[3]["status"])
        self.assertEqual(["shared.txt"], by_number[3]["conflict_files"])
        self.assertEqual(2, manifest["included_count"])
        self.assertFalse(manifest["complete"])
        self.assertIn("Exact heads present after assembly: **2/3**", summary_path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
