#!/usr/bin/env python3
"""Report hot sampled layout instability without rewriting application code."""
import argparse
import json
from pathlib import Path
import re

LINE = re.compile(
    r'^SHAPE_SITE samples=(\d+) shapes=(\[[^\]]*\]) sequence=(\[[^\]]*\]) '
    r'counts=(\[[^\]]*\]) overflow=(true|false) line=(\d+) column=(\d+) pc=(\d+) '
    r'function_hex=([0-9a-f]*) file_hex=([0-9a-f]*) key_hex=([0-9a-f]*)$')


def reports(text, minimum_samples=128):
    rows = []
    for line in text.splitlines():
        match = LINE.fullmatch(line)
        if not match:
            continue
        samples, shapes, sequence, counts, overflow, row, column, pc, function, filename, key = match.groups()
        samples, counts = int(samples), json.loads(counts)
        shapes = json.loads(shapes)
        misses = counts[2] + counts[3] + counts[4] + counts[8]
        if samples < minimum_samples or len(shapes) < 2 or misses == 0:
            continue
        decode = lambda value: bytes.fromhex(value).decode('utf-8', errors='replace')
        rows.append(dict(file=decode(filename), line=int(row), column=int(column), pc=int(pc),
                         function=decode(function), key=decode(key), samples=samples,
                         sampled_misses=misses, shapes=shapes, sequence=json.loads(sequence),
                         more_shapes=overflow == 'true',
                         suggestion='Review construction order and late field additions at this hot read; '
                                    'consistent layouts may help if property order and effects permit. '
                                    'Suppress this report if the polymorphism is intentional.'))
    return sorted(rows, key=lambda row: row['sampled_misses'], reverse=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('profile', type=Path, help='diagnostic stderr text or captured profile JSON')
    parser.add_argument('--minimum-samples', type=int, default=128)
    parser.add_argument('--limit', type=int, default=20)
    args = parser.parse_args()
    text = args.profile.read_text()
    if args.profile.suffix == '.json':
        text = json.loads(text)['stderr']
    print(json.dumps(reports(text, args.minimum_samples)[:args.limit], indent=2))


if __name__ == '__main__':
    main()
