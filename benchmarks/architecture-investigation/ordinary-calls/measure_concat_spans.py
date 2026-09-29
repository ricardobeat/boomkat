"""Interleave string and shape benchmark timings for direct concat allocation."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', required=True, type=Path)
parser.add_argument('--candidate', required=True, type=Path)
parser.add_argument('--quickjs', required=True, type=Path)
parser.add_argument('--out', type=Path, default=Path('concat-spans-results.json'))
parser.add_argument('--runs', type=int, default=7)
args = parser.parse_args()

base = Path(__file__).resolve().parent
repo = base.parents[2]
cases = {
    'string': repo / 'benchmarks/bench_string.js',
    'shape_no_call': repo / 'benchmarks/bench_shape_no_call.js',
    'shape_stress': repo / 'benchmarks/bench_shape_stress.js',
    'concat_spans': base / 'concat-spans.js',
}
bins = [('baseline', args.baseline.resolve()),
        ('candidate', args.candidate.resolve()),
        ('quickjs', args.quickjs.resolve())]
rows = []

for case, source in cases.items():
    for rep in range(args.runs):
        order = bins[rep % len(bins):] + bins[:rep % len(bins)]
        if rep % 2:
            order.reverse()
        for name, binary in order:
            command = ([str(binary), str(source)] if name == 'quickjs' else
                       [str(binary), '--script', str(source)])
            started = time.perf_counter()
            result = subprocess.run(command, capture_output=True, text=True,
                                    timeout=90)
            wall_ms = (time.perf_counter() - started) * 1000
            if result.returncode:
                raise RuntimeError((name, case, result.stdout, result.stderr))
            phases = {}
            checks = []
            stable_lines = []
            for line in result.stdout.splitlines():
                if line.startswith('PHASE '):
                    parts = line.split()
                    phases[' '.join(parts[1:-1])] = int(parts[-1])
                elif line.startswith('CHECK '):
                    checks.append(line)
                else:
                    stable_lines.append(line)
            if rep == 0:
                expected = checks
            elif checks != expected:
                raise RuntimeError((case, 'output mismatch', name, checks, expected))
            rows.append(dict(case=case, variant=name, rep=rep,
                             wall_ms=wall_ms, phases_ms=phases,
                             checks=checks, stable_lines=stable_lines))

summary = {}
for case in cases:
    summary[case] = {}
    for name, _ in bins:
        selected = [row for row in rows
                    if row['case'] == case and row['variant'] == name]
        phase_names = sorted({phase for row in selected
                              for phase in row['phases_ms']})
        summary[case][name] = dict(
            wall_ms_median=statistics.median(row['wall_ms'] for row in selected),
            phase_medians_ms={phase: statistics.median(
                row['phases_ms'][phase] for row in selected)
                for phase in phase_names})

out = args.out.resolve()
out.write_text(json.dumps(dict(
    description='Seven alternating runs of bench_string, both shape benchmarks, and focused concat probes.',
    binaries={name: dict(path=str(path),
                         sha256=hashlib.sha256(path.read_bytes()).hexdigest())
              for name, path in bins},
    summary=summary, runs=rows), indent=2) + '\n')
print(json.dumps(summary, indent=2), flush=True)
