#!/usr/bin/env python3
"""Compare explicit binaries in alternating A/B pairs; preserve raw results."""
import argparse
import json
from pathlib import Path
import re
import statistics
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('baseline', type=Path)
p.add_argument('candidate', type=Path)
p.add_argument('files', nargs='+', type=Path)
p.add_argument('--out', type=Path, required=True)
p.add_argument('--pairs', type=int, default=7)
a = p.parse_args()
a.out.mkdir(parents=True, exist_ok=True)
binaries = [a.baseline.resolve(), a.candidate.resolve()]
rows = []
use_time_l = True
for path in a.files:
    times, rss, outputs = [[], []], [[], []], [set(), set()]
    scene_total, scene_worst = [[], []], [[], []]
    for pair in range(-1, a.pairs):
        for side in ([0, 1] if pair % 2 == 0 else [1, 0]):
            start = time.perf_counter()
            command = [str(binaries[side]), '--script', str(path.resolve())]
            r = subprocess.run((['/usr/bin/time', '-l'] if use_time_l else []) + command,
                               capture_output=True, text=True, timeout=120)
            if use_time_l and r.returncode == 1 and 'sysctl kern.clockrate: Operation not permitted' in r.stderr:
                use_time_l = False
                start = time.perf_counter()
                r = subprocess.run(command, capture_output=True, text=True, timeout=120)
            elapsed = time.perf_counter() - start
            if r.returncode or 'FAIL' in r.stdout:
                raise RuntimeError(f'{path}: {r.returncode}\n{r.stdout}\n{r.stderr}')
            if pair >= 0:
                times[side].append(elapsed)
                outputs[side].add(r.stdout)
                scene = re.search(r'scene_churn:.*total=(\d+)ms worst_frame=(\d+)ms', r.stdout)
                if scene:
                    scene_total[side].append(int(scene[1]))
                    scene_worst[side].append(int(scene[2]))
                if use_time_l:
                    for line in r.stderr.splitlines():
                        if 'maximum resident set size' in line:
                            rss[side].append(int(line.split()[0]))
    def normalize(output):
        if path.stem in ('bench_date', 'bench_regexp'):
            output = re.sub(r'\b\d+(?:\.\d+)? ms\b', '<time> ms', output)
        if output.startswith('scene_churn:'):
            output = re.sub(r'\b(total|worst_frame)=\d+ms', r'\1=<time>ms', output)
        return output

    normalized = [{normalize(s) for s in group} for group in outputs]
    if normalized[0] != normalized[1]:
        raise RuntimeError(f'{path}: output mismatch: {outputs}')
    medians = [statistics.median(t) for t in times]
    delta = 100 * (medians[1] / medians[0] - 1)
    rows.append(dict(file=str(path), seconds=times, median=medians,
                     change_percent=delta, rss=rss, outputs=[sorted(s) for s in outputs],
                     scene_total_ms=scene_total, scene_worst_frame_ms=scene_worst))
    (a.out / 'results.json').write_text(json.dumps(rows, indent=2))
    print(f'{path.name}: {medians[0]:.4f} -> {medians[1]:.4f}s ({delta:+.1f}%)', flush=True)
    if scene_worst[0]:
        print('  median worst frame: '
              f'{statistics.median(scene_worst[0])} -> {statistics.median(scene_worst[1])} ms',
              flush=True)
