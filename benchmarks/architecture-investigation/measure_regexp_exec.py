"""Measure the regexp benchmark phases across alternating engine runs."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import statistics
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', required=True, type=Path)
parser.add_argument('--candidate', required=True, type=Path)
parser.add_argument('--quickjs', required=True, type=Path)
parser.add_argument('--out', type=Path,
                    default=Path('regexp-intrinsic-exec-results.json'))
parser.add_argument('--runs', type=int, default=7)
args = parser.parse_args()

root = Path(__file__).resolve().parents[2]
source = root / 'benchmarks/bench_regexp.js'
bins = [('baseline', args.baseline.resolve()),
        ('candidate', args.candidate.resolve()),
        ('quickjs', args.quickjs.resolve())]
rows = []
phase_pattern = re.compile(r'^(.+): (\d+) ms \((\d+) iterations\)$')

for rep in range(-1, args.runs):
    order = list(bins)
    offset = rep % len(order)
    order = order[offset:] + order[:offset]
    if rep % 2:
        order.reverse()
    for name, binary in order:
        command = [str(binary), str(source)] if name == 'quickjs' else [
            str(binary), '--script', str(source)]
        start = time.perf_counter()
        result = subprocess.run(command, capture_output=True, text=True)
        wall_ms = (time.perf_counter() - start) * 1000
        if result.returncode or 'done' not in result.stdout.splitlines():
            raise RuntimeError((name, result.returncode, result.stdout, result.stderr))
        phases = {}
        for line in result.stdout.splitlines():
            match = phase_pattern.match(line)
            if match:
                phases[match.group(1)] = int(match.group(2))
        if not phases:
            raise RuntimeError((name, 'missing phase output', result.stdout))
        if rep >= 0:
            rows.append(dict(variant=name, rep=rep, wall_ms=wall_ms,
                             phases_ms=phases, stdout=result.stdout.strip()))

phase_names = sorted(rows[0]['phases_ms'])
for row in rows:
    if sorted(row['phases_ms']) != phase_names:
        raise RuntimeError((row['variant'], 'phase list changed'))

summary = {}
for name, _ in bins:
    selected = [row for row in rows if row['variant'] == name]
    summary[name] = dict(
        wall_ms_median=statistics.median(row['wall_ms'] for row in selected),
        phase_medians_ms={phase: statistics.median(row['phases_ms'][phase]
                                                    for row in selected)
                          for phase in phase_names})

out = args.out.resolve()
out.write_text(json.dumps(dict(
    description='Seven alternating release-process runs of benchmarks/bench_regexp.js.',
    binaries={name: dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest())
              for name, path in bins},
    summary=summary, runs=rows), indent=2) + '\n')
print(json.dumps(summary, indent=2), flush=True)
