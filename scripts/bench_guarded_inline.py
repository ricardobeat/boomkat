#!/usr/bin/env python3
"""Interleave baseline and guarded-inlining runs; profile in separate processes."""
import argparse
import json
from pathlib import Path
import platform
import re
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('sources', nargs='*', type=Path)
parser.add_argument('--runs', type=int, default=7)
parser.add_argument('--output', type=Path, default=ROOT / 'test/benchmarks/guarded-inline-results.json')
args = parser.parse_args()
sources = args.sources or [ROOT / '.worktrees/octane/bench/mini' / (name + '.js')
                           for name in ('richards', 'deltablue')]
if args.runs < 1:
    parser.error('--runs must be positive')
for source in sources:
    if not source.is_file():
        parser.error(f'benchmark source missing: {source}; pass explicit source paths')


def run(source, enabled, profile=False):
    command = [str(ROOT / 'out/boomkat'), '--inline' if enabled else '--no-inline']
    if profile:
        command.append('--inline-stats')
    start = time.perf_counter()
    result = subprocess.run([*command, '--script', str(source)], capture_output=True,
                            text=True, timeout=120, check=True)
    seconds = time.perf_counter() - start
    match = re.search(r':\s+(\d+) ms', result.stdout)
    return seconds, int(match[1]) if match else None, result.stderr


report = {'platform': platform.platform(), 'runs': args.runs,
          'timing': 'separate unprofiled processes, alternating order; wall includes compilation',
          'benchmarks': {}}
for source in sources:
    for enabled in (False, True):
        run(source, enabled)
    samples = {'baseline': [], 'inline': []}
    runtime = {'baseline': [], 'inline': []}
    for repetition in range(args.runs):
        for enabled in ((False, True) if repetition % 2 == 0 else (True, False)):
            wall, ms, _ = run(source, enabled)
            label = 'inline' if enabled else 'baseline'
            samples[label].append(wall)
            runtime[label].append(ms)
    _, _, profile = run(source, True, True)
    counters = {key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', profile)}
    medians = {key: statistics.median(value) for key, value in samples.items()}
    row = {'wall_seconds': samples, 'benchmark_ms': runtime, 'median_seconds': medians,
           'inline_over_baseline': medians['inline'] / medians['baseline'], 'profile': counters}
    report['benchmarks'][source.stem] = row
    print(source.stem, json.dumps(row), flush=True)
args.output.write_text(json.dumps(report, indent=2) + '\n')
