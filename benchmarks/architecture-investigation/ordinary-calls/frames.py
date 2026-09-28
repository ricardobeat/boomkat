"""Measure frame percentiles using isolated clock builds and QuickJS's clock."""
import argparse
import gzip
import hashlib
import json
import math
from pathlib import Path
import statistics
import subprocess
import tempfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work-dir', required=True, type=Path)
args = p.parse_args()
base = Path(__file__).resolve().parent
root = base.parents[2]
bins = {n: args.work_dir.resolve() / (n + '-clock') for n in ['baseline', 'combined']}
bins['quickjs'] = root / 'out/qjs'
source = (root / 'benchmarks/bench_scene_churn.js').read_text()
source = source.replace('Date.now()', 'benchNow()').replace('var start = benchNow();', 'var samples=[];var start = benchNow();')
source = source.replace('    if (dt > worst)', '    samples.push(dt);\n    if (dt > worst)')
source += '\nif(totalChanges!==FRAMES*VIEW_SIZE)throw Error("checksum");print("METRICS "+JSON.stringify(samples));'
rows = []
with tempfile.TemporaryDirectory(prefix='ordinary-frames-') as directory:
    for nodes, frames in [(10000, 300), (100000, 3000)]:
        for rep in range(-1, 5):
            names = list(bins)
            names = names[rep % 3:] + names[:rep % 3]
            if rep % 2:
                names.reverse()
            for name in names:
                clock = 'performance.now()' if name == 'quickjs' else 'Date.now("__benchmark_monotonic")'
                path = Path(directory) / 'scene.js'
                path.write_text(f'function benchNow(){{return {clock};}}\nvar SCENE_NODES_OVERRIDE={nodes};var SCENE_FRAMES_OVERRIDE={frames};\n' + source)
                result = subprocess.run([str(bins[name]), '--script', str(path)], capture_output=True, text=True, timeout=30, check=True)
                samples = json.loads(next(line[8:] for line in result.stdout.splitlines() if line.startswith('METRICS ')))
                assert len(samples) == frames
                ordered = sorted(samples)
                if rep >= 0:
                    rows.append(dict(nodes=nodes, variant=name, rep=rep, p50=ordered[math.ceil(frames*.5)-1],
                                     p99=ordered[math.ceil(frames*.99)-1], maximum=max(samples), frames=samples))
        print(nodes, {name: {key: round(statistics.median(r[key] for r in rows if r['nodes']==nodes and r['variant']==name), 4)
                             for key in ['p50', 'p99', 'maximum']} for name in bins}, flush=True)
with gzip.open(base / 'frames.json.gz', 'wt') as out:
    json.dump(dict(binaries={name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in bins.items()}, rows=rows), out)
