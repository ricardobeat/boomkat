#!/usr/bin/env python3
"""Project an Octane composite score from the mini benchmarks.

The upstream Octane bundle is not part of this repository. `bench/mini` holds
short variants that `bench/mini/gen.sh` derives from it; each warms up for a
fixed number of iterations, as Octane does for a second, and prints the elapsed
milliseconds of the fixed number of runs that follow. A binary's Octane
composite is the geometric mean of the per-benchmark scores, and a score is
proportional to the reciprocal of a benchmark's runtime, so a matched pair of
mini runs gives every benchmark's projected score:

    projected = recorded * baseline_ms / candidate_ms

The recorded scores come from one full Octane run of a historical revision
(`pair1-baseline.log`). Two benchmarks failed in that run - NavierStokes on a
checksum and zlib on a missing `read` - so they are excluded, and the composite
covers thirteen.

Because both sides of the pair share the recorded constant, the projected
composite is the recorded composite scaled by the geometric mean of the time
ratios. It makes the goal readable in Octane terms; it is not an independent
measurement: the counts are fixed where Octane's are timed.

Usage: python3 scripts/octane_score.py [--pairs N] [--json PATH] base candidate
"""
import argparse
import json
import math
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MINI = ROOT / 'bench' / 'mini'
# A mini's result line: the timed runs, then the warm-up that preceded them.
TIMED_RE = re.compile(r': (\d+) ms, warm-up \d+ ms')

# Octane scores of the historical revision, from its full-suite log.
RECORDED = {
    'richards': 4646, 'deltablue': 3379, 'crypto': 4702, 'raytrace': 3099,
    'earley-boyer': 3566, 'regexp': 1137, 'splay': 8312, 'pdfjs': 6073,
    'mandreel': 2253, 'gbemu': 13092, 'code-load': 28742, 'box2d': 7135,
    'typescript': 22221,
}


def run(binary, case):
    out = subprocess.run([str(binary), '--jit', '--script', str(MINI / f'{case}.js')],
                         capture_output=True, text=True, timeout=900, cwd=ROOT)
    if out.returncode != 0:
        raise SystemExit(f'{binary} {case}: exit {out.returncode}\n{out.stderr[-400:]}')
    timed = TIMED_RE.findall(out.stdout)
    if not timed:
        raise SystemExit(f'{binary} {case}: no timing line\n{out.stdout[-400:]}')
    return float(sum(map(int, timed)))


def geomean(values):
    return math.exp(sum(math.log(value) for value in values) / len(values))


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--pairs', type=int, default=3)
    parser.add_argument('--json', type=Path)
    args = parser.parse_args()

    cases = [name for name in RECORDED if (MINI / f'{name}.js').exists()]
    best = {str(args.baseline): {}, str(args.candidate): {}}
    for pair in range(args.pairs):
        for index, case in enumerate(cases):
            order = [args.baseline, args.candidate]
            if (pair + index) % 2:
                order.reverse()
            for binary in order:
                ms = run(binary, case)
                seen = best[str(binary)].get(case)
                best[str(binary)][case] = ms if seen is None else min(seen, ms)

    rows = []
    for case in cases:
        base = best[str(args.baseline)][case]
        candidate = best[str(args.candidate)][case]
        speedup = base / candidate
        rows.append({
            'case': case,
            'baseline_ms': base,
            'candidate_ms': candidate,
            'speedup': speedup,
            'recorded_score': RECORDED[case],
            'projected_score': RECORDED[case] * speedup,
        })

    report = {
        'rows': rows,
        'geomean_speedup': geomean([row['speedup'] for row in rows]),
        'recorded_composite': geomean([row['recorded_score'] for row in rows]),
        'projected_composite': geomean([row['projected_score'] for row in rows]),
    }
    for row in sorted(rows, key=lambda r: r['speedup']):
        print('%-13s %7.0f ms %7.0f ms  x%.3f  score %7.0f -> %7.0f' % (
            row['case'], row['baseline_ms'], row['candidate_ms'], row['speedup'],
            row['recorded_score'], row['projected_score']))
    print('geomean speedup %.4f' % report['geomean_speedup'])
    print('composite score %.0f -> %.0f' % (report['recorded_composite'],
                                            report['projected_composite']))
    if args.json:
        args.json.write_text(json.dumps(report, indent=2) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
