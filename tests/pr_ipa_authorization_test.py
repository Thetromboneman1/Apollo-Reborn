#!/usr/bin/env python3
"""Execute the real workflow gates without GitHub credentials or network access."""
from __future__ import annotations

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / ".github/workflows/pr-build-ipa.yml"
COMMENT = ROOT / ".github/workflows/pr-build-ipa-comment.yml"


def step_script(path: Path, name: str) -> str:
    lines = path.read_text().splitlines()
    start = lines.index(f"      - name: {name}")
    run = next(i for i in range(start, len(lines)) if lines[i] == "        run: |") + 1
    end = run
    while end < len(lines) and (not lines[end].strip() or lines[end].startswith("          ")):
        end += 1
    return textwrap.dedent("\n".join(lines[run:end])) + "\n"


class AuthorizationTests(unittest.TestCase):
    def run_gate(self, reporter: bool, author: str, actor: str, owners: str) -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".github").mkdir()
            (root / ".github/CODEOWNERS").write_text(owners)
            output = root / "output"
            output.touch()
            script = step_script(COMMENT if reporter else BUILD,
                                 "Post or update comment" if reporter else "Determine authorization")
            if reporter:
                # The reporter takes the author from the API-resolved PR, never
                # from the artifact. Exercise its authoritative gate verbatim.
                script = script[script.index('OWNERS=$('):script.index('# Build the request body')]
                script = 'gh() { cat .github/CODEOWNERS; }\n' + script + '\necho gate-passed\n'
            env = dict(os.environ, PR_AUTHOR=author, TRIGGERING_ACTOR=actor,
                       RUN_TRIGGERING_ACTOR=actor, HEAD_OWNER=author,
                       GITHUB_REPOSITORY_OWNER="ForkOwner",
                       GITHUB_REPOSITORY="ForkOwner/Apollo-Reborn", GITHUB_OUTPUT=str(output))
            result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", script],
                                    cwd=root, env=env, text=True, capture_output=True)
            observed = "gate-passed" in result.stdout if reporter else "authorized=true" in output.read_text()
            return result.returncode, "authorized" if observed else "denied"

    def test_matching_build_and_reporter_authorization(self) -> None:
        cases = [
            ("ForkOwner", "outsider", "* @upstream\n", "authorized"),
            ("outsider", "fOrKoWnEr", "* @upstream\n", "authorized"),
            ("upstream", "outsider", "* @upstream\n", "authorized"),
            ("outsider", "UPSTREAM", "* @upstream\n", "authorized"),
            ("outsider", "outsider", "* @upstream\n", "denied"),
            ("attacker", "attacker", "* @upstream # @attacker\n", "denied"),
            ("team", "team", "* @team/maintainers @upstream\n", "denied"),
            ("", "", "* @upstream\n", "denied"),
        ]
        for reporter in (False, True):
            for author, actor, owners, expected in cases:
                with self.subTest(reporter=reporter, author=author, actor=actor, owners=owners):
                    status, observed = self.run_gate(reporter, author, actor, owners)
                    self.assertEqual(0, status)
                    self.assertEqual(expected, observed)

    def test_build_status_requires_actual_success(self) -> None:
        script = step_script(BUILD, "Require successful IPA validation")
        for authorization, result, expected in [
            ("true", "success", 0), ("false", "skipped", 1),
            ("true", "failure", 1), ("true", "cancelled", 1),
            ("true", "skipped", 1), ("", "skipped", 1),
        ]:
            with self.subTest(authorization=authorization, result=result):
                with tempfile.TemporaryDirectory() as directory:
                    summary = Path(directory) / "summary"
                    env = dict(os.environ, AUTHORIZED=authorization, BUILD_RESULT=result,
                               GITHUB_STEP_SUMMARY=str(summary))
                    completed = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", script],
                                               env=env, text=True, capture_output=True)
                    self.assertEqual(expected, completed.returncode)
                    if expected:
                        self.assertIn("::error", completed.stdout)

    def test_security_boundaries_remain_explicit(self) -> None:
        build = BUILD.read_text()
        comment = COMMENT.read_text()
        self.assertIn("permissions:\n  contents: read\n", build)
        self.assertNotIn(": write", build)
        self.assertNotIn("pull_request_target", build)
        self.assertIn("ref: ${{ github.event.pull_request.base.sha }}", build)
        self.assertIn("needs: [authorize, build]", build)
        self.assertIn("if: ${{ always() }}", build)
        self.assertNotIn("actions/checkout", comment)
        self.assertIn('repos/${GITHUB_REPOSITORY}/contents/.github/CODEOWNERS', comment)
        self.assertIn("pull-requests: write", comment)


if __name__ == "__main__":
    unittest.main()
