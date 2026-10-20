"""Compare constructor probes and class benchmark with recorded binary order."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--baseline', required=True, type=Path)
p.add_argument('--putnew', required=True, type=Path)
p.add_argument('--combined', required=True, type=Path)
p.add_argument('--quickjs', required=True, type=Path)
p.add_argument('--out', type=Path, default=Path('constructor-results.json'))
p.add_argument('--runs', type=int, default=6)
a = p.parse_args()
report = Path(__file__).resolve().parent
bins = {name: path.resolve() for name, path in
        [('baseline', a.baseline), ('putnew', a.putnew), ('combined', a.combined), ('quickjs', a.quickjs)]}
cases = {'probes': report / 'constructor-probes.js', 'class': report.parent / 'class.js'}
rows = []
for case, source in cases.items():
    for rep in range(-1, a.runs):
        order = list(bins)
        offset = rep % len(order)
        order = order[offset:] + order[:offset]
        if rep % 2:
            order.reverse()
        for name in order:
            command = [str(bins[name]), str(source)] if name == 'quickjs' else [str(bins[name]), '--script', str(source)]
            start = time.perf_counter()
            result = subprocess.run(command, capture_output=True, text=True)
            wall_ms = (time.perf_counter() - start) * 1000
            if result.returncode:
                raise RuntimeError((case, name, result.stderr, result.stdout))
            phases = {}
            for line in result.stdout.splitlines():
                if not line.startswith('PHASE '):
                    continue
                if case == 'probes':
                    parts = line.split()
                    phases[parts[1]] = int(parts[2])
                else:
                    phases[line.rsplit(' ', 1)[0][6:]] = int(line.rsplit(' ', 1)[1])
            checksum = next((line for line in result.stdout.splitlines() if line.startswith('CHECK ')), None)
            if rep >= 0:
                rows.append(dict(case=case, variant=name, rep=rep, wall_ms=wall_ms,
                                 phases=phases, checksum=checksum))
    current = [row for row in rows if row['case'] == case]
    checksums = {row['checksum'] for row in current}
    if len(checksums) != 1:
        raise RuntimeError((case, 'checksum mismatch', checksums))
    print(case, {name: round(statistics.median(row['wall_ms'] for row in current
                                               if row['variant'] == name), 2) for name in bins}, flush=True)
    for phase in current[0]['phases']:
        print(phase, {name: statistics.median(row['phases'].get(phase, 0) for row in current
                                               if row['variant'] == name) for name in bins}, flush=True)
out = a.out.resolve()
out.write_text(json.dumps(dict(binaries={name: hashlib.sha256(path.read_bytes()).hexdigest()
                                         for name, path in bins.items()}, rows=rows), indent=2) + '\n')
