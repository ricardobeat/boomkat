"""Alternating release-process measurements for the array push CALL handler."""
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
parser.add_argument('--out', type=Path,
                    default=Path('threaded-array-push-results.json'))
parser.add_argument('--runs', type=int, default=7)
args = parser.parse_args()

base = Path(__file__).resolve().parent
repo = base.parents[2]
bins = {'baseline': args.baseline.resolve(),
        'candidate': args.candidate.resolve()}
cases = {'numeric_phases': base / 'array-phases.js',
         'object_push': base / 'array-push-object-probe.js',
         'bench_array': repo / 'benchmarks/bench_array.js',
         'compiled_call_control': repo / 'benchmarks/bench_function_call.js'}
rows = []

for case, source in cases.items():
    for rep in range(-1, args.runs):
        order = list(bins)
        offset = rep % len(order)
        order = order[offset:] + order[:offset]
        if rep % 2:
            order.reverse()
        for name in order:
            start = time.perf_counter()
            result = subprocess.run([str(bins[name]), '--script', str(source)],
                                    capture_output=True, text=True)
            wall_ms = (time.perf_counter() - start) * 1000
            if result.returncode:
                raise RuntimeError((name, case, result.stdout, result.stderr))
            phases = {}
            object_total_ms = None
            for line in result.stdout.splitlines():
                if line.startswith('PHASE '):
                    parts = line.split()
                    phases[' '.join(parts[1:-1])] = int(parts[-1])
                match = re.search(r'object_push_probe: .* total=(\d+)ms ', line)
                if match:
                    object_total_ms = int(match.group(1))
            if case == 'numeric_phases' and set(phases) != {'push', 'read', 'pop', 'write'}:
                raise RuntimeError((name, 'missing numeric phases', result.stdout))
            if case == 'object_push' and object_total_ms is None:
                raise RuntimeError((name, 'missing object push result', result.stdout))
            if case == 'bench_array' and result.stdout.strip() != '1249975000':
                raise RuntimeError((name, 'bench_array checksum mismatch', result.stdout))
            if case == 'compiled_call_control' and result.stdout.strip() != '26000000':
                raise RuntimeError((name, 'call control checksum mismatch', result.stdout))
            if rep >= 0:
                rows.append(dict(case=case, variant=name, rep=rep,
                                 wall_ms=wall_ms, phases_ms=phases,
                                 object_total_ms=object_total_ms,
                                 stdout=result.stdout.strip()))

summary = {}
for case in cases:
    summary[case] = {}
    for name in bins:
        selected = [row for row in rows
                    if row['case'] == case and row['variant'] == name]
        result = {'wall_ms_median': statistics.median(row['wall_ms'] for row in selected)}
        if case == 'numeric_phases':
            result['phase_medians_ms'] = {
                phase: statistics.median(row['phases_ms'][phase] for row in selected)
                for phase in ('push', 'read', 'pop', 'write')}
        elif case == 'object_push':
            result['engine_total_ms_median'] = statistics.median(
                row['object_total_ms'] for row in selected)
        summary[case][name] = result

out = args.out.resolve()
out.write_text(json.dumps(dict(
    description='Alternating release-process measurements for numeric and heap-valued array pushes.',
    binaries={name: dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest())
              for name, path in bins.items()},
    summary=summary, runs=rows), indent=2) + '\n')
print(json.dumps(summary, indent=2), flush=True)
