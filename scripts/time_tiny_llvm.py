#!/usr/bin/env python3
"""Compare TINY probes using shuffled process timings and matching output."""
from pathlib import Path
import json
import random
import statistics
import subprocess
import time

root = Path(__file__).resolve().parents[1]
out = root / 'out/timings'
out.mkdir(parents=True, exist_ok=True)
variants = {
    'baseline': root / 'out/baseline-tiny',
    'separate': root / 'out/separate/boomkat_tiny',
    'no_unwind': root / 'out/no-unwind-separate-no-compact/boomkat_tiny',
    'outlined': root / 'out/combined-separate/no-compact',
}
rng = random.Random(42)
results = {}
for name in ['loop', 'function_call', 'property_lookup', 'ic_proto', 'array']:
    source = root / 'test' / 'benchmarks' / ('bench_' + name + '.js')
    image = out / (name + '.bkbc')
    subprocess.run([root / 'out/boomkat_tiny_compile', '--compile', image, source],
                   check=True, capture_output=True)
    outputs = [subprocess.check_output([exe, image]) for exe in variants.values()]
    assert all(x == outputs[0] for x in outputs)
    samples = {k: [] for k in variants}
    for repeat in range(15):
        order = list(variants)
        rng.shuffle(order)
        for name_ in order:
            start = time.perf_counter()
            subprocess.run([variants[name_], image], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=30)
            samples[name_].append(time.perf_counter() - start)
    medians = {k: statistics.median(v) for k, v in samples.items()}
    results[name] = {'median_seconds': medians, 'samples': samples,
                     'ratios': {k: v / medians['baseline'] for k, v in medians.items()}}
    print(name, results[name]['ratios'], flush=True)
(out / 'results-idle.json').write_text(json.dumps(results, indent=2) + '\n')
