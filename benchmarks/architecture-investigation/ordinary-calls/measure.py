"""Sequential, rotated comparisons; supply immutable binaries as name=path."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', action='append', required=True)
parser.add_argument('--out', type=Path, required=True)
parser.add_argument('--runs', type=int, default=5)
args = parser.parse_args()
root = Path(__file__).resolve().parents[3]
base = Path(__file__).resolve().parent
bins = {name: Path(path).resolve() for name, path in
        (entry.split('=', 1) for entry in args.binary)}
rows = []
with tempfile.TemporaryDirectory(prefix='ordinary-calls-') as directory:
    temp = Path(directory)
    cases = {'probes': base / 'probes.js', 'class': base.parent / 'class.js',
             'function-call': root / 'benchmarks/bench_function_call.js'}
    for nodes, frames in [(10000, 300), (100000, 3000)]:
        path = temp / f'scene-{nodes}.js'
        path.write_text(f'var SCENE_NODES_OVERRIDE={nodes};var SCENE_FRAMES_OVERRIDE={frames};\n'
                        + (root / 'benchmarks/bench_scene_churn.js').read_text()
                        + '\nif(totalChanges!==FRAMES*VIEW_SIZE || prev.items.length!==VIEW_SIZE)throw Error("scene checksum");')
        cases[f'scene-{nodes}'] = path
    for case, path in cases.items():
        for rep in range(-1, args.runs):
            order = list(bins)
            offset = rep % len(order)
            order = order[offset:] + order[:offset]
            if rep % 2:
                order.reverse()
            for name in order:
                with (temp / 'stdout').open('w') as out, (temp / 'stderr').open('w') as err:
                    start = time.perf_counter()
                    child = subprocess.Popen([str(bins[name]), '--script', str(path)], stdout=out, stderr=err)
                    _, status, usage = os.wait4(child.pid, 0)
                    child.returncode = os.waitstatus_to_exitcode(status)
                    elapsed = time.perf_counter() - start
                output = (temp / 'stdout').read_text()
                if child.returncode or 'FAIL' in output:
                    raise RuntimeError((name, case, output, (temp / 'stderr').read_text()))
                phases = {line[6:].rsplit(' ', 1)[0]: int(line.rsplit(' ', 1)[1])
                          for line in output.splitlines() if line.startswith('PHASE ')}
                if rep >= 0:
                    rows.append(dict(case=case, variant=name, rep=rep, wall_ms=elapsed*1000,
                                     rss_bytes=usage.ru_maxrss, phases_ms=phases, stdout=output))
        args.out.write_text(json.dumps(dict(binaries={name: dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest())
                                                      for name, path in bins.items()}, rows=rows), indent=2) + '\n')
        print(case, {name: round(statistics.median(row['wall_ms'] for row in rows
                                                  if row['case'] == case and row['variant'] == name), 2)
                     for name in bins}, flush=True)
