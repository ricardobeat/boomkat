#!/usr/bin/env python3
"""Run sequential, alternating pairs and retain wall time, CPU time and RSS."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import tempfile
import time


def run(command):
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        start = time.perf_counter()
        process = subprocess.Popen(command, stdout=stdout, stderr=stderr)
        _, status, usage = os.wait4(process.pid, 0)
        process.returncode = os.waitstatus_to_exitcode(status)
        elapsed = time.perf_counter() - start
        stdout.seek(0)
        stderr.seek(0)
        text = stdout.read().decode()
        errors = stderr.read().decode()
    if process.returncode or 'FAIL' in text:
        raise RuntimeError(f'{command}: {process.returncode}\n{text}\n{errors}')
    return dict(wall=elapsed, cpu=usage.ru_utime + usage.ru_stime,
                rss=usage.ru_maxrss, stdout=text)


def normalize(text):
    text = re.sub(r'\b\d+(?:\.\d+)?\s*ms\b', '<time>ms', text)
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('files', nargs='+', type=Path)
    parser.add_argument('--pairs', type=int, default=3)
    parser.add_argument('--batch', type=int, default=1)
    parser.add_argument('--native', action='store_true')
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if args.pairs < 1 or args.batch < 1:
        parser.error('pairs and batch must be positive')
    binaries = [args.baseline.resolve(), args.candidate.resolve()]
    result = {'binaries': [dict(path=str(p), bytes=p.stat().st_size,
                              sha256=hashlib.sha256(p.read_bytes()).hexdigest(),
                              size=subprocess.run(['size', str(p)], capture_output=True, text=True).stdout)
                           for p in binaries], 'pairs': args.pairs,
              'batch': args.batch, 'rows': []}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    for path in args.files:
        row = {'file': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
               'samples': []}
        outputs = [set(), set()]
        for pair in range(-1, args.pairs):
            for side in ([0, 1] if pair % 2 == 0 else [1, 0]):
                samples = []
                for _ in range(args.batch):
                    command = [str(binaries[side])]
                    if not args.native:
                        command.append('--script')
                    command.append(str(path.resolve()))
                    sample = run(command)
                    samples.append(sample)
                    outputs[side].add(normalize(sample['stdout']))
                if pair >= 0:
                    row['samples'].append(dict(pair=pair, side=side,
                                               runs=samples))
        if outputs[0] != outputs[1]:
            raise RuntimeError(f'{path}: output mismatch: {outputs}')
        row['medians'] = {
            metric: [statistics.median(sum(run[metric] for run in sample['runs'])
                                       for sample in row['samples'] if sample['side'] == side)
                     for side in (0, 1)] for metric in ('wall', 'cpu')}
        row['rss'] = [statistics.median(run['rss'] for sample in row['samples']
                                       if sample['side'] == side for run in sample['runs'])
                      for side in (0, 1)]
        result['rows'].append(row)
        args.out.write_text(json.dumps(result, indent=2) + '\n')
        changes = {k: round(100 * (v[1] / v[0] - 1), 2)
                   for k, v in row['medians'].items()}
        print(path.name, changes, 'RSS', row['rss'], flush=True)


if __name__ == '__main__':
    main()
