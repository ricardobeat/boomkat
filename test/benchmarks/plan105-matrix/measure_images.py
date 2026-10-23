#!/usr/bin/env python3
"""Compare source and precompiled images using the same compiler-enabled binary."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import statistics
import subprocess

spec = importlib.util.spec_from_file_location('measure', Path(__file__).parents[1]/'allocation-study/measure.py')
measure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measure)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('--pairs', type=int, default=3)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve()
    files = sorted(Path('.worktrees/octane/bench/mini').glob('*.js'))
    assert len(files) == 15
    images = args.out.parent/'images'
    images.mkdir(parents=True, exist_ok=True)
    result = dict(binary=str(binary), sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  pairs=args.pairs, rows=[])
    for source in files:
        image = images/(source.stem+'.bkbc')
        compiled = measure.run([str(binary), '--script', '--compile', str(image), str(source.resolve())])
        row = dict(file=str(source), sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                   source_bytes=source.stat().st_size, image_bytes=image.stat().st_size,
                   image_sha256=hashlib.sha256(image.read_bytes()).hexdigest(), compile=compiled, samples=[])
        outputs = [set(), set()]
        for pair in range(-1, args.pairs):
            for side in ([0, 1] if pair % 2 == 0 else [1, 0]):
                command = [str(binary), '--image', str(image.resolve())] if side else [str(binary), '--script', str(source.resolve())]
                sample = measure.run(command)
                outputs[side].add(measure.normalize(sample['stdout']))
                if pair >= 0:
                    row['samples'].append(dict(pair=pair, side=side, runs=[sample]))
        assert outputs[0] == outputs[1], (source, outputs)
        row['medians'] = {metric: [statistics.median(s['runs'][0][metric] for s in row['samples'] if s['side'] == side)
                                  for side in (0, 1)] for metric in ('wall', 'cpu')}
        row['rss'] = [statistics.median(s['runs'][0]['rss'] for s in row['samples'] if s['side'] == side) for side in (0, 1)]
        result['rows'].append(row)
        args.out.write_text(json.dumps(result, indent=2)+'\n')
        print(source.stem, {metric: round(100*(values[1]/values[0]-1), 2) for metric, values in row['medians'].items()}, flush=True)


if __name__ == '__main__':
    main()
