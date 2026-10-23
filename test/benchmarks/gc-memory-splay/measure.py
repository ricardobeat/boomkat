#!/usr/bin/env python3
"""Measure Octane Splay and peak RSS serially on macOS, rotating engine order."""
import argparse
import hashlib
import json
import re
import statistics
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
for name in ['benchmark', 'baseline', 'candidate', 'quickjs', 'output']:
    parser.add_argument('--' + name, type=Path, required=True)
parser.add_argument('--rounds', type=int, default=9)
args = parser.parse_args()
if args.rounds < 1:
    parser.error('--rounds must be positive')
engines = {
    'baseline': [str(args.baseline), '--script'],
    'candidate': [str(args.candidate), '--script'],
    'quickjs': [str(args.quickjs)],
}
result = {
    'benchmark': str(args.benchmark),
    'sha256': hashlib.sha256(args.benchmark.read_bytes()).hexdigest(),
    'engines': {name: {'command': command,
                     'sha256': hashlib.sha256(Path(command[0]).read_bytes()).hexdigest()}
                for name, command in engines.items()},
    'samples': [],
}
for turn in range(args.rounds):
    order = list(engines)
    order = order[turn % len(order):] + order[:turn % len(order)]
    for name in order:
        proc = subprocess.run(['/usr/bin/time', '-l', *engines[name], str(args.benchmark)],
                              capture_output=True, text=True, timeout=120, check=True)
        scores = {key: int(value) for key, value in
                  re.findall(r'^(Splay(?:Latency)?): (\d+)$', proc.stdout, re.M)}
        if set(scores) != {'Splay', 'SplayLatency'}:
            raise RuntimeError(f'{name}: missing scores\n{proc.stdout}\n{proc.stderr}')
        rss = int(re.search(r'(\d+)\s+maximum resident set size', proc.stderr)[1])
        sample = {'round': turn, 'engine': name, **scores, 'peak_rss_bytes': rss}
        result['samples'].append(sample)
        print(json.dumps(sample), flush=True)
result['medians'] = {
    name: {key: statistics.median(sample[key] for sample in result['samples']
                                 if sample['engine'] == name)
           for key in ['Splay', 'SplayLatency', 'peak_rss_bytes']}
    for name in engines
}
args.output.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result['medians'], indent=2))
