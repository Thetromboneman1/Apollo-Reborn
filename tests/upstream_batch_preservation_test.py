#!/usr/bin/env python3
"""Exercise the real publisher against local Git histories and a network-free gh."""
from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def git(root: Path, *args: str, check: bool = True) -> str:
    result = subprocess.run(['git', *args], cwd=root, text=True, capture_output=True)
    if check and result.returncode:
        raise AssertionError(result.stderr)
    return result.stdout.strip()


class PreservationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.repo = self.root / 'history'
        self.repo.mkdir()
        git(self.repo, 'init', '-b', 'main')
        git(self.repo, 'config', 'user.name', 'Fixture')
        git(self.repo, 'config', 'user.email', 'fixture@example.invalid')
        for number in [1245, 1364, 1393, 1395]:
            (self.repo / f'feature-{number}').write_text('base\n')
        self.base = self.commit('initial upstream base')
        self.heads = {}
        for number in [1245, 1364, 1393, 1395]:
            git(self.repo, 'switch', '--detach', self.base)
            (self.repo / f'feature-{number}').write_text(f'upstream {number}\n')
            self.heads[number] = self.commit(f'upstream #{number}')
        git(self.repo, 'switch', '--force-create', 'main', self.base)
        for number in self.heads:
            (self.repo / f'feature-{number}').write_text('fork customization\n')
        self.old_main = self.commit('fork customizations')
        git(self.repo, 'switch', '-c', 'resolved-old-batch')
        for number, head in self.heads.items():
            git(self.repo, 'merge', '--no-ff', '--no-commit', head, check=False)
            (self.repo / f'feature-{number}').write_text(f'reviewed resolution {number}\n')
            self.commit(f'resolve upstream #{number}')
        self.old_head = git(self.repo, 'rev-parse', 'HEAD')
        git(self.repo, 'switch', 'main')
        (self.repo / 'workflow').write_text('owner IPA validation repaired\n')
        self.new_main = self.commit('new main SHA without upstream-head changes')
        git(self.repo, 'switch', '--detach', self.base)
        (self.repo / 'inline-images').write_text('new upstream #1400\n')
        self.new_head = self.commit('upstream #1400')
        git(self.repo, 'switch', '-c', 'new-batch', self.new_main)
        git(self.repo, 'merge', '--no-ff', '-m', 'include only new #1400', self.new_head)
        self.candidate = git(self.repo, 'rev-parse', 'HEAD')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'calls.jsonl'
        self.state = self.root / 'state.json'
        fake = self.bin / 'gh'
        fake.write_text('''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as handle:
    handle.write(json.dumps(args) + '\\n')
joined = ' '.join(args)
state_path = Path(os.environ['STATE'])
state = json.loads(state_path.read_text())
def save(): state_path.write_text(json.dumps(state))
if args[:2] == ['pr', 'ready']:
    state[args[2]]['draft'] = '--undo' in args
    save()
    sys.exit(0)
if args[:2] == ['pr', 'merge']:
    if state[args[2]]['draft']: sys.exit(1)
    state[args[2]]['merged'] = True
    save()
    sys.exit(0)
if '/compare/' in joined:
    if os.environ.get('COMPARE_ERROR') == 'true': sys.exit(1)
    spec = next(a for a in args if '/compare/' in a).split('/compare/')[1]
    old, new = spec.split('...')
    result = subprocess.run(['git', 'merge-base', '--is-ancestor', old, new], cwd=os.environ['HISTORY'])
    base = subprocess.check_output(['git', 'merge-base', old, new], cwd=os.environ['HISTORY'], text=True).strip()
    print(('identical' if old == new else 'ahead') + '\\t' + base if result.returncode == 0 else 'diverged\\t' + base)
elif '--method POST' in joined:
    state['62'] = {'draft': 'draft=true' in args, 'state': 'open'}
    save()
    print('62\\thttps://github.com/Thetromboneman1/Apollo-Reborn/pull/62\\t' + ('true' if 'draft=true' in args else 'false'))
elif '--method PATCH' in joined:
    if os.environ.get('REPORT_ERROR') == 'true' and '/pulls/62' in joined: sys.exit(1)
    if 'state=closed' in args: state['60']['state'] = 'closed'; save()
elif 'head=' in joined:
    if os.environ.get('EXISTING_READY') == 'true':
        state['62'] = {'draft': False, 'state': 'open'}
        save()
        print('62\\thttps://github.com/Thetromboneman1/Apollo-Reborn/pull/62\\tfalse')
elif '/pulls/60' in joined:
    print(os.environ.get('MOVED_OLD_HEAD', os.environ['OLD_HEAD']))
elif '/pulls/62' in joined:
    print(os.environ.get('MOVED_CANDIDATE', os.environ['CANDIDATE']))
else:
    if os.environ.get('LIST_ERROR') == 'true': sys.exit(1)
    if os.environ.get('SECOND_PAGE') == 'true' and '--paginate' not in args: sys.exit(0)
    print('60\\thttps://github.com/Thetromboneman1/Apollo-Reborn/pull/60\\t' + os.environ['OLD_HEAD'])
''')
        fake.chmod(0o755)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def commit(self, message: str) -> str:
        git(self.repo, 'add', '.')
        git(self.repo, 'commit', '-m', message)
        return git(self.repo, 'rev-parse', 'HEAD')

    def publish(self, complete: bool, changed: bool = True, **overrides: str) -> tuple[subprocess.CompletedProcess[str], list[list[str]], str]:
        manifest = self.root / 'manifest.json'
        manifest.write_text(json.dumps({
            'complete': complete, 'changed': changed,
            'fingerprint': 'new-main-and-added-1400',
            'total': 5, 'included_count': 5 if complete else 1,
            'downstream_sha': self.new_main, 'assembled_head': self.candidate,
            'results': [{'pull_request': {'number': n, 'head_sha': h}} for n, h in
                        {**self.heads, 1400: self.new_head}.items()],
        }))
        summary = self.root / 'summary.md'
        summary.write_text('# New snapshot\n')
        self.state.write_text(json.dumps({'60': {'draft': True, 'state': 'open'}}))
        env = dict(os.environ, STATE=str(self.state), PATH=f'{self.bin}:{os.environ["PATH"]}', CALLS=str(self.log),
                   HISTORY=str(self.repo), OLD_HEAD=self.old_head, CANDIDATE=self.candidate,
                   GH_TOKEN='fixture-only', BRANCH='Thetromboneman1/all-open-upstream-prs-new',
                   DOWNSTREAM_BRANCH='main', GITHUB_REPOSITORY='Thetromboneman1/Apollo-Reborn',
                   MANIFEST_PATH=str(manifest), SUMMARY_PATH=str(summary), VALIDATION_RESULT='success',
                   RUN_URL='https://github.com/example/actions/runs/1', AUTO_MERGE='true',
                   RETRY_MAX_ATTEMPTS='1', RETRY_DELAY_SECONDS='0')
        env.update(overrides)
        result = subprocess.run(['bash', str(ROOT / 'scripts/publish-upstream-pr-batch.sh')],
                                env=env, text=True, capture_output=True)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        return result, calls, summary.read_text()

    def assert_preserved(self, complete: bool = False, **overrides: str) -> None:
        before = git(self.repo, 'rev-parse', 'HEAD')
        result, calls, summary = self.publish(complete, **overrides)
        self.assertNotEqual(0, result.returncode)
        self.assertFalse(any('state=closed' in call for call in calls), calls)
        self.assertFalse(any(call[:2] == ['pr', 'merge'] for call in calls), calls)
        self.assertFalse(any(call[:2] == ['pr', 'ready'] and '--undo' not in call for call in calls), calls)
        for call in calls:
            if '--method' in call and 'POST' in call:
                self.assertIn('draft=true', call)
        self.assertIn(self.old_head, summary)
        self.assertIn(self.candidate, summary)
        self.assertIn('manual review', summary.lower())
        state = json.loads(self.state.read_text())
        self.assertTrue(state['62']['draft'])
        self.assertEqual('open', state['60']['state'])
        self.assertEqual(before, git(self.repo, 'rev-parse', 'HEAD'))
        self.assertEqual(self.old_head, git(self.repo, 'rev-parse', 'resolved-old-batch'))

    def test_unchanged_four_heads_new_main_and_1400_preserve_resolutions(self) -> None:
        self.assert_preserved()

    def test_declared_complete_does_not_prove_prior_resolution_containment(self) -> None:
        self.assert_preserved(complete=True)

    def test_changed_upstream_head_is_not_imported_as_a_stale_resolution(self) -> None:
        git(self.repo, 'switch', '--detach', self.heads[1245])
        (self.repo / 'feature-1245').write_text('new incompatible upstream revision\n')
        self.heads[1245] = self.commit('advance #1245')
        self.assert_preserved()

    def test_page_two_prior_batch_is_included_in_preservation_gate(self) -> None:
        self.assert_preserved(complete=True, SECOND_PAGE='true')

    def test_inventory_failure_leaves_new_candidate_draft(self) -> None:
        result, calls, _ = self.publish(True, LIST_ERROR='true')
        self.assertNotEqual(0, result.returncode)
        state = json.loads(self.state.read_text())
        self.assertTrue(state['62']['draft'])
        self.assertEqual('open', state['60']['state'])
        self.assertFalse(any('state=closed' in call or call[:2] == ['pr', 'merge'] for call in calls))

    def test_no_change_does_not_close_uncontained_prior_batch(self) -> None:
        result, calls, summary = self.publish(True, changed=False)
        self.assertNotEqual(0, result.returncode)
        self.assertEqual('open', json.loads(self.state.read_text())['60']['state'])
        self.assertFalse(any('state=closed' in call or call[:2] == ['pr', 'merge'] for call in calls))
        self.assertIn(self.old_head, summary)
        self.assertIn(self.new_main, summary)

    def test_reporting_failure_never_leaves_new_uncontained_batch_ready(self) -> None:
        self.assert_preserved(complete=True, REPORT_ERROR='true')

    def test_existing_ready_batch_is_demoted_before_fallible_updates(self) -> None:
        result, calls, _ = self.publish(True, EXISTING_READY='true', REPORT_ERROR='true')
        self.assertNotEqual(0, result.returncode)
        undo = next(i for i, call in enumerate(calls) if call[:2] == ['pr', 'ready'] and '--undo' in call)
        patch = next(i for i, call in enumerate(calls) if 'PATCH' in call)
        self.assertLess(undo, patch)
        self.assertFalse(any(call[:2] == ['pr', 'merge'] for call in calls))

    def contain_prior_batch(self) -> None:
        git(self.repo, 'switch', '-c', 'contained-batch', self.old_head)
        git(self.repo, 'merge', '--no-ff', '-m', 'retain current main', self.new_main)
        git(self.repo, 'merge', '--no-ff', '-m', 'include #1400', self.new_head)
        self.candidate = git(self.repo, 'rev-parse', 'HEAD')

    def test_verified_contained_complete_batch_can_close_predecessor(self) -> None:
        self.contain_prior_batch()
        result, calls, _ = self.publish(True)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertTrue(any('state=closed' in call for call in calls), calls)
        self.assertTrue(any(call[:2] == ['pr', 'merge'] for call in calls), calls)

    def test_comparison_failure_preserves_prior_work(self) -> None:
        self.contain_prior_batch()
        self.assert_preserved(complete=True, COMPARE_ERROR='true')

    def test_prior_branch_changed_during_publication_is_preserved(self) -> None:
        self.contain_prior_batch()
        self.assert_preserved(complete=True, MOVED_OLD_HEAD=self.new_head)

    def test_replacement_branch_moved_away_from_assembled_head_is_preserved(self) -> None:
        self.contain_prior_batch()
        self.assert_preserved(complete=True, MOVED_CANDIDATE=self.new_main)

    def test_failed_validation_preserves_even_contained_work(self) -> None:
        self.contain_prior_batch()
        self.assert_preserved(complete=True, VALIDATION_RESULT='failure')


if __name__ == '__main__':
    unittest.main()
