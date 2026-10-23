#!/usr/bin/env python3
"""Run independent release candidates sequentially against one retained control."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import statistics
import subprocess
import sys


def summarize(result):
    rows = []
    for row in result['rows']:
        measured = [[], []]
        for sample in row['samples']:
            measured[sample['side']].append(sum(
                float(number) for run in sample['runs']
                for number in re.findall(r':\s*([0-9.]+)\s+ms', run['stdout'])))
        phase = [statistics.median(side) for side in measured]
        runtime = phase[1] / phase[0] if phase[0] > 0 else None
        cpu = row['medians']['cpu'][1] / row['medians']['cpu'][0]
        rows.append(dict(benchmark=Path(row['file']).stem, runtime_percent=100*(runtime-1) if runtime else None,
                         cpu_percent=100*(cpu-1), phase_ms=phase, rss=row['rss']))
    phase_ratios = [1+row['runtime_percent']/100 for row in rows if row['runtime_percent'] is not None]
    return dict(rows=rows, runtime_geomean_percent=100*(math.exp(sum(map(math.log,phase_ratios))/len(phase_ratios))-1),
                cpu_geomean_percent=100*(math.exp(sum(math.log(1+row['cpu_percent']/100) for row in rows)/len(rows))-1))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('variants', nargs='+')
    parser.add_argument('--pairs', type=int, default=3)
    parser.add_argument('--baseline', default='baseline-51e0e10e')
    parser.add_argument('--label', default='', help='Preserve independent batches under a suffix')
    args = parser.parse_args()
    output = Path('out/plan105-matrix')
    baseline = output/args.baseline
    baseline_digest = hashlib.sha256(baseline.read_bytes()).hexdigest()
    files = sorted(Path('.worktrees/octane/bench/mini').glob('*.js'))
    assert len(files) == 15
    manifest_path = output/'mini-attempts.json'
    attempts = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    for name in args.variants:
        candidate = output/name
        label = name + ('-' + args.label if args.label else '')
        digest = hashlib.sha256(candidate.read_bytes()).hexdigest()
        prior = attempts.get(label, {})
        if prior.get('sha256') == digest and prior.get('baseline_sha256') == baseline_digest and prior.get('pairs') == args.pairs and prior.get('state') == 'complete':
            print(name, 'already complete', flush=True)
            continue
        raw = output/(label+'-mini.json')
        log_path = output/(label+'-mini.log')
        attempts[label] = dict(state='running', sha256=digest, baseline_sha256=baseline_digest, pairs=args.pairs)
        manifest_path.write_text(json.dumps(attempts, indent=2)+'\n')
        command = [sys.executable, 'test/benchmarks/allocation-study/measure.py', str(baseline), str(candidate),
                   *map(str, files), '--pairs', str(args.pairs), '--out', str(raw)]
        print('START', name, flush=True)
        with log_path.open('w') as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = process.wait(timeout=600)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                code = -1
        if code == 0:
            data = json.loads(raw.read_text())
            assert len(data['rows']) == len(files)
            summary = summarize(data)
            attempts[label].update(state='complete', summary=summary)
            print('RESULT', name, 'runtime', round(summary['runtime_geomean_percent'], 2),
                  'CPU', round(summary['cpu_geomean_percent'], 2),
                  'regressions', [(r['benchmark'], round(r['runtime_percent'], 2)) for r in summary['rows']
                                  if r['runtime_percent'] is not None and r['runtime_percent'] > 2], flush=True)
        else:
            attempts[label].update(state='failed', returncode=code, log=log_path.read_text()[-4000:])
            print('FAILED', name, code, flush=True)
        manifest_path.write_text(json.dumps(attempts, indent=2)+'\n')


if __name__ == '__main__':
    main()
