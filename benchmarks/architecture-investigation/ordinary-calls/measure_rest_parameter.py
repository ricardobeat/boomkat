"""Interleave the rest-parameter call phase across Boomkat variants and QuickJS."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--baseline', required=True, type=Path)
p.add_argument('--candidate', required=True, type=Path)
p.add_argument('--quickjs', required=True, type=Path)
p.add_argument('--out', type=Path, default=Path('rest-parameter-fastpath-results.json'))
p.add_argument('--runs', type=int, default=7)
a = p.parse_args()

report = Path(__file__).resolve().parent
bins = {name: path.resolve() for name, path in
        [('baseline', a.baseline), ('candidate', a.candidate), ('quickjs', a.quickjs)]}
source = report / 'rest-parameter-phase.js'
rows = []
for rep in range(-1, a.runs):
    order = list(bins)
    if rep % 2:
        order.reverse()
    for name in order:
        command = [str(bins[name]), str(source)] if name == 'quickjs' else [
            str(bins[name]), '--script', str(source)]
        start = time.perf_counter()
        result = subprocess.run(command, capture_output=True, text=True)
        wall_ms = (time.perf_counter() - start) * 1000
        if result.returncode:
            raise RuntimeError((name, result.stderr, result.stdout))
        phase = next((line.split()[-1] for line in result.stdout.splitlines()
                      if line.startswith('PHASE rest-parameter ')), None)
        if phase is None:
            raise RuntimeError((name, 'missing phase output', result.stdout))
        if rep >= 0:
            rows.append(dict(variant=name, rep=rep, wall_ms=wall_ms,
                             rest_parameter_ms=int(phase)))

summary = {name: {
    'wall_ms_median': statistics.median(row['wall_ms'] for row in rows
                                        if row['variant'] == name),
    'rest_parameter_ms_median': statistics.median(
        row['rest_parameter_ms'] for row in rows if row['variant'] == name)}
    for name in bins}
print(summary, flush=True)
out = a.out.resolve()
out.write_text(json.dumps(dict(
    description='Seven alternating isolated 400k five-argument rest-parameter calls; baseline and candidate differ only in direct rest-array initialization.',
    binaries={name: hashlib.sha256(path.read_bytes()).hexdigest()
              for name, path in bins.items()},
    summary=summary, runs=rows), indent=2) + '\n')
