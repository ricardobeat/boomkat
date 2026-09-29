"""Interleave the for-of diagnostic phases across Boomkat and QuickJS."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--baseline', required=True, type=Path)
p.add_argument('--candidate', type=Path)
p.add_argument('--quickjs', required=True, type=Path)
p.add_argument('--out', type=Path,
               default=Path('forof-array-thread-fastpath-results.json'))
p.add_argument('--runs', type=int, default=7)
a = p.parse_args()

report = Path(__file__).resolve().parent
source = report.parent / 'forof.js'
bins = [('baseline', a.baseline.resolve())]
if a.candidate is not None:
    bins.append(('candidate', a.candidate.resolve()))
bins.append(('quickjs', a.quickjs.resolve()))
rows = []
for rep in range(-1, a.runs):
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
        if result.returncode:
            raise RuntimeError((name, result.stderr, result.stdout))
        phases = {}
        for line in result.stdout.splitlines():
            if line.startswith('PHASE '):
                parts = line.split()
                phases[' '.join(parts[1:-1])] = int(parts[-1])
        checksum = next((line for line in result.stdout.splitlines()
                         if line.startswith('CHECK ')), None)
        if checksum is None:
            raise RuntimeError((name, 'missing checksum', result.stdout))
        if rep >= 0:
            rows.append(dict(variant=name, rep=rep, wall_ms=wall_ms,
                             phases_ms=phases, checksum=checksum))

checksums = {row['checksum'] for row in rows}
if len(checksums) != 1:
    raise RuntimeError(('checksum mismatch', checksums))
summary = {}
for name, _ in bins:
    current = [row for row in rows if row['variant'] == name]
    summary[name] = dict(
        wall_ms_median=statistics.median(row['wall_ms'] for row in current),
        phases_ms_median={key: statistics.median(row['phases_ms'][key]
                                                  for row in current)
                          for key in current[0]['phases_ms']})
print(summary, flush=True)
out = a.out.resolve()
out.write_text(json.dumps(dict(
    description='Seven alternating runs of benchmarks/architecture-investigation/forof.js.',
    binaries={name: hashlib.sha256(binary.read_bytes()).hexdigest()
              for name, binary in bins},
    summary=summary, runs=rows), indent=2) + '\n')
