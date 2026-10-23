#!/usr/bin/env python3
"""Compare two author-reviewed sources under one retained binary."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import statistics

spec = importlib.util.spec_from_file_location('measure', Path(__file__).parents[1]/'allocation-study/measure.py')
measure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measure)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--pairs', type=int, default=7)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve()
    files = [args.baseline.resolve(), args.candidate.resolve()]
    result = dict(binary=str(binary), binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  sources=[dict(path=str(f), sha256=hashlib.sha256(f.read_bytes()).hexdigest()) for f in files],
                  pairs=args.pairs, samples=[])
    outputs = [set(), set()]
    for pair in range(-1, args.pairs):
        for side in ([0, 1] if pair % 2 == 0 else [1, 0]):
            sample = measure.run([str(binary), '--script', str(files[side])])
            outputs[side].add(measure.normalize(sample['stdout']))
            if pair >= 0:
                result['samples'].append(dict(pair=pair, side=side, runs=[sample]))
    assert outputs[0] == outputs[1], outputs
    result['medians'] = {metric: [statistics.median(s['runs'][0][metric] for s in result['samples'] if s['side'] == side)
                                 for side in (0, 1)] for metric in ('wall', 'cpu', 'rss')}
    result['percent'] = {k: 100*(v[1]/v[0]-1) for k, v in result['medians'].items()}
    args.out.write_text(json.dumps(result, indent=2)+'\n')
    print(result['percent'], flush=True)


if __name__ == '__main__':
    main()
