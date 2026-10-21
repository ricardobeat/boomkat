#!/usr/bin/env python3
"""Require a complete branch-push CI run for the exact release commit."""
import argparse
import json
import subprocess
import time

REQUIRED_JOBS = {'filter', 'build', 'tests', 'reduced profiles',
                 'ts conformance', 'test262', 'library corpus'}


def api(path, key):
    result = subprocess.run(['gh', 'api', '--paginate', '--slurp', path],
                            check=True, capture_output=True, text=True, timeout=60)
    return [item for page in json.loads(result.stdout) for item in page[key]]


def select_run(runs, sha):
    candidates = [run for run in runs
                  if run['head_sha'] == sha and run['event'] == 'push']
    return max(candidates, key=lambda run: run['id'], default=None)


def verify_jobs(jobs):
    successful = {job['name'] for job in jobs if job['conclusion'] == 'success'}
    missing = REQUIRED_JOBS - successful
    if missing:
        raise RuntimeError('CI did not pass all required jobs: ' + ', '.join(sorted(missing)))


def wait(repo, sha, timeout=1800, missing_timeout=120, interval=20):
    started = time.monotonic()
    while True:
        runs = api(f'repos/{repo}/actions/workflows/ci.yml/runs'
                   f'?head_sha={sha}&event=push&per_page=100', 'workflow_runs')
        run = select_run(runs, sha)
        elapsed = time.monotonic() - started
        if run and run['status'] == 'completed':
            url = run['html_url']
            if run['conclusion'] != 'success':
                raise RuntimeError(f'CI concluded {run["conclusion"]}: {url}')
            jobs = api(f'repos/{repo}/actions/runs/{run["id"]}/jobs?per_page=100', 'jobs')
            verify_jobs(jobs)
            print(f'Release commit {sha} passed CI: {url}', flush=True)
            return
        if not run and elapsed >= missing_timeout:
            raise RuntimeError(f'No branch-push CI run found for {sha}. '
                               'Push the commit to a branch before releasing.')
        if elapsed >= timeout:
            raise RuntimeError(f'Timed out waiting for CI on {sha}')
        print(f'Waiting for CI on {sha}: '
              f'{run["html_url"] if run else "run not registered yet"}', flush=True)
        time.sleep(interval)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--sha', required=True)
    args = parser.parse_args()
    try:
        wait(args.repo, args.sha)
    except (RuntimeError, subprocess.SubprocessError, ValueError) as error:
        parser.exit(1, f'Release CI gate failed: {error}\n')


if __name__ == '__main__':
    main()
