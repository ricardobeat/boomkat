"""Interleave LDCONST dispatch measurements across representative workloads."""
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
parser.add_argument('--out', type=Path,
                    default=Path('threaded-ldconst-results.json'))
parser.add_argument('--runs', type=int, default=7)
args = parser.parse_args()

base = Path(__file__).resolve().parent
repo = base.parents[2]
cases = {
    'object_phases': base / 'object-phases.js',
    'class': repo / 'benchmarks/architecture-investigation/class.js',
    'property_lookup': repo / 'benchmarks/bench_property_lookup.js',
    'string': repo / 'benchmarks/bench_string.js',
    'scene_churn': repo / 'benchmarks/bench_scene_churn.js',
}
bins = [('baseline', args.baseline.resolve()),
        ('candidate', args.candidate.resolve()),
        ('quickjs', args.quickjs.resolve())]
rows = []

for case, source in cases.items():
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
            result = subprocess.run(command, capture_output=True, text=True,
                                    timeout=45)
            wall_ms = (time.perf_counter() - start) * 1000
            if result.returncode:
                raise RuntimeError((name, case, result.stdout, result.stderr))
            phases = {}
            stable_lines = []
            for line in result.stdout.splitlines():
                if line.startswith('PHASE '):
                    parts = line.split()
                    phases[' '.join(parts[1:-1])] = int(parts[-1])
                elif case == 'scene_churn' and line.startswith(
                        'scene_churn: nodes=100000 frames=300 '):
                    stable_lines.append('scene_churn checksum passed')
                elif line.startswith('CHECK '):
                    stable_lines.append(line)
                elif case not in ('object_phases',):
                    stable_lines.append(line)
            if rep >= 0:
                rows.append(dict(case=case, variant=name, rep=rep,
                                 wall_ms=wall_ms, phases_ms=phases,
                                 stable_lines=stable_lines,
                                 stdout=result.stdout.strip()))

for case in cases:
    selected = [row for row in rows if row['case'] == case]
    checksums = {tuple(row['stable_lines']) for row in selected}
    if len(checksums) > 1:
        raise RuntimeError((case, 'output mismatch', checksums))

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
    description='Seven alternating release-process runs of object, class, property, string, and scene workloads.',
    binaries={name: dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest())
              for name, path in bins},
    summary=summary, runs=rows), indent=2) + '\n')
print(json.dumps(summary, indent=2), flush=True)
