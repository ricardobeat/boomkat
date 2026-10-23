#!/usr/bin/env python3
"""Alternate two Boomkat binaries on CodeLoad and equal-work loading drivers."""
import argparse
import hashlib
import json
import platform
import re
import statistics
import subprocess
import tempfile
from pathlib import Path


def describe(path):
    return {'path': str(path), 'bytes': path.stat().st_size,
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--bench-dir', required=True, type=Path)
    parser.add_argument('--pairs', type=int, default=3)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    engines = {name: path.resolve() for name, path in
               [('baseline', args.baseline), ('candidate', args.candidate)]}
    benchmark = (args.bench_dir / 'code-load.js').resolve()
    source = benchmark.read_text()
    prefix = source.rsplit('BenchmarkSuite.RunSuites(', 1)[0]
    rows = []
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.out.parent) as directory:
        cases = {'CodeLoad': benchmark}
        for case, count, runner in [('Closure', 1000, 'runCodeLoadClosure'),
                                    ('JQuery', 100, 'runCodeLoadJQuery')]:
            path = Path(directory) / (case + '.js')
            path.write_text(prefix + '\nsetupCodeLoad();\nvar started=Date.now();\n'
                            + f'for(var i=0;i<{count};i++) {runner}();\n'
                            + 'print("Elapsed: "+(Date.now()-started));\n')
            cases[case] = path
        for turn in range(args.pairs):
            for case, path in cases.items():
                order = list(engines)[::1 if turn % 2 == 0 else -1]
                for name in order:
                    darwin = platform.system() == 'Darwin'
                    command = ['/usr/bin/time', '-l' if darwin else '-v',
                               str(engines[name]), '--script', '--memory-limit=2048', str(path)]
                    result = subprocess.run(command, capture_output=True, text=True,
                                            check=True, timeout=240)
                    value = int(re.search(r'^(?:CodeLoad|Elapsed): (\d+)$',
                                          result.stdout, re.M)[1])
                    pattern = (r'(\d+)\s+maximum resident set size' if darwin
                               else r'Maximum resident set size \(kbytes\): (\d+)')
                    rss = int(re.search(pattern, result.stderr)[1]) * (1 if darwin else 1024)
                    row = {'round': turn, 'case': case, 'engine': name,
                           'score' if case == 'CodeLoad' else 'ms': value,
                           'peak_rss_bytes': rss}
                    rows.append(row)
                    print(json.dumps(row), flush=True)
    medians = {}
    for case in cases:
        key = 'score' if case == 'CodeLoad' else 'ms'
        medians[case] = {name: {metric: statistics.median(
            row[metric] for row in rows if row['case'] == case and row['engine'] == name)
            for metric in [key, 'peak_rss_bytes']} for name in engines}
    args.out.write_text(json.dumps({'binaries': {name: describe(path) for name, path in engines.items()},
                                   'benchmark_sha256': hashlib.sha256(benchmark.read_bytes()).hexdigest(),
                                   'pairs': args.pairs, 'samples': rows, 'medians': medians}, indent=2) + '\n')


if __name__ == '__main__':
    main()
