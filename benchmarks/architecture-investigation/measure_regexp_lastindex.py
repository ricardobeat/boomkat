"""Interleave RegExp lastIndex-focused and standard benchmark runs."""
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
                    default=Path('regexp-lastindex-results.json'))
parser.add_argument('--runs', type=int, default=9)
args = parser.parse_args()

root = Path(__file__).resolve().parents[2]
cases = {
    'bench_regexp': root / 'benchmarks/bench_regexp.js',
    'lastindex': root / 'benchmarks/architecture-investigation/regexp-lastindex.js',
}
bins = [('baseline', args.baseline.resolve()),
        ('candidate', args.candidate.resolve()),
        ('quickjs', args.quickjs.resolve())]
phase_patterns = {
    'bench_regexp': re.compile(r'^(.+): (\d+) ms \((\d+) iterations\)$'),
    'lastindex': re.compile(r'^PHASE (.+) (\d+)$'),
}
rows = []
expected_checks = {}

for case, source in cases.items():
    for rep in range(-1, args.runs):
        order = list(bins)
        offset = rep % len(order)
        order = order[offset:] + order[:offset]
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
            for line in result.stdout.splitlines():
                match = phase_patterns[case].match(line)
                if match:
                    phases[match.group(1)] = int(match.group(2))
                elif line.startswith('CHECK '):
                    checks.append(line)
            if case == 'bench_regexp' and 'done' not in result.stdout.splitlines():
                raise RuntimeError((name, 'benchmark did not finish', result.stdout))
            if case == 'lastindex':
                if not checks:
                    raise RuntimeError((name, 'missing check output', result.stdout))
                key = (case, rep)
                if key not in expected_checks:
                    expected_checks[key] = checks
                elif checks != expected_checks[key]:
                    raise RuntimeError((case, 'output mismatch', name, checks,
                                        expected_checks[key]))
            if not phases:
                raise RuntimeError((name, case, 'missing phase output', result.stdout))
            if rep >= 0:
                rows.append(dict(case=case, variant=name, rep=rep,
                                 wall_ms=wall_ms, phases_ms=phases,
                                 checks=checks))

summary = {}
for case in cases:
    summary[case] = {}
    phase_names = sorted({phase for row in rows if row['case'] == case
                          for phase in row['phases_ms']})
    for name, _ in bins:
        selected = [row for row in rows
                    if row['case'] == case and row['variant'] == name]
        summary[case][name] = dict(
            wall_ms_median=statistics.median(row['wall_ms'] for row in selected),
            phase_medians_ms={phase: statistics.median(
                row['phases_ms'][phase] for row in selected)
                for phase in phase_names})

out = args.out.resolve()
out.write_text(json.dumps(dict(
    description='Nine alternating release-process runs of bench_regexp.js and a lastIndex-focused probe.',
    binaries={name: dict(path=str(path),
                         sha256=hashlib.sha256(path.read_bytes()).hexdigest())
              for name, path in bins},
    summary=summary, runs=rows), indent=2) + '\n')
print(json.dumps(summary, indent=2), flush=True)
