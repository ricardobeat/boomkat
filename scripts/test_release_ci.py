"""Release gates must require complete CI for the exact commit."""
import unittest
from unittest.mock import patch

import wait_release_ci as gate


def run(identifier=1, sha='release', event='push', status='completed', conclusion='success'):
    return dict(id=identifier, head_sha=sha, event=event, status=status,
                conclusion=conclusion, html_url=f'https://example.com/{identifier}')


def jobs():
    return [dict(name=name, conclusion='success') for name in gate.REQUIRED_JOBS]


class ReleaseGateTests(unittest.TestCase):
    def test_only_exact_commit_push_runs(self):
        self.assertIsNone(gate.select_run([run(sha='other'), run(event='pull_request')], 'release'))

    def test_latest_run_overrides_old_success(self):
        latest = run(2, conclusion='failure')
        self.assertEqual(gate.select_run([latest, run()], 'release'), latest)

    def test_accepts_complete_ci(self):
        with patch.object(gate, 'api', side_effect=[[run()], jobs()]):
            gate.wait('owner/repo', 'release')

    def test_failure_blocks_release(self):
        for verdict in ('failure', 'cancelled', 'timed_out', 'neutral', 'skipped'):
            with self.subTest(verdict=verdict), patch.object(
                    gate, 'api', return_value=[run(conclusion=verdict)]):
                with self.assertRaisesRegex(RuntimeError, 'CI concluded'):
                    gate.wait('owner/repo', 'release')

    def test_filtered_or_incomplete_ci_blocks_release(self):
        for missing in gate.REQUIRED_JOBS:
            for verdict in (None, 'skipped', 'failure'):
                incomplete = [job for job in jobs() if job['name'] != missing]
                if verdict:
                    incomplete.append(dict(name=missing, conclusion=verdict))
                with self.subTest(job=missing, verdict=verdict), patch.object(
                        gate, 'api', side_effect=[[run()], incomplete]):
                    with self.assertRaisesRegex(RuntimeError, 'required jobs'):
                        gate.wait('owner/repo', 'release')

    def test_waits_for_registration_and_completion(self):
        with patch.object(gate, 'api', side_effect=[[], [run(status='in_progress')],
                                                   [run()], jobs()]), \
                patch.object(gate.time, 'sleep') as sleep:
            gate.wait('owner/repo', 'release')
            self.assertEqual(sleep.call_count, 2)

    def test_missing_run_and_timeout_fail_closed(self):
        with patch.object(gate, 'api', return_value=[]):
            with self.assertRaisesRegex(RuntimeError, 'No branch-push CI'):
                gate.wait('owner/repo', 'release', missing_timeout=0)
        with patch.object(gate, 'api', return_value=[run(status='queued')]):
            with self.assertRaisesRegex(RuntimeError, 'Timed out'):
                gate.wait('owner/repo', 'release', timeout=0)

    def test_api_pages_are_combined(self):
        import json
        import subprocess
        response = subprocess.CompletedProcess([], 0, json.dumps([
            {'jobs': [{'name': 'first'}]}, {'jobs': [{'name': 'second'}]}]))
        with patch.object(gate.subprocess, 'run', return_value=response):
            self.assertEqual(gate.api('endpoint', 'jobs'), [{'name': 'first'}, {'name': 'second'}])
