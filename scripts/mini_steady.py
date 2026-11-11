#!/usr/bin/env python3
"""Measure the steady-state cost of the mini benchmarks, apart from warm-up.

    python3 scripts/mini_steady.py [--args "--jit --opt"] [--jsc] [--scale K] BIN [BIN2 ...] [-- bench ...]

Octane scores the runs that follow a warm-up, so the cost that matters is one steady iteration.
Each mini (bench/mini) runs twice per engine, with its timed run count and with double that after
the same warm-up; the difference of the two runs' retired instructions is the cost of the extra
iterations alone, free of start-up, compilation and warm-up. Printed per benchmark: instructions
per steady iteration, the instructions before the timed runs, the timed milliseconds per
iteration, and the instructions relative to the first engine's. --jsc adds the system
JavaScriptCore as a reference. Instruction counts repeat to about 0.3% on a busy machine; the
milliseconds do not. Needs /usr/bin/time -l (macOS).
"""
import argparse, re, subprocess, sys
from pathlib import Path

MINI = Path(__file__).resolve().parent.parent / 'bench' / 'mini'
JSC = '/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc'
COUNTS_RE = re.compile(r'MINI_WARM : (\d+);\s*var runs = typeof MINI_RUNS == "number" \? MINI_RUNS : (\d+);')
LINE_RE = re.compile(r': (\d+) ms, warm-up \d+ ms')
RETIRED_RE = re.compile(r'(\d+)\s+instructions retired')


def boomkat(binary, engine_args):
    """The CLI takes no script arguments: the counts go ahead of the mini on standard input."""
    def run(counts, path):
        return [binary] + engine_args + ['--script', '-'], counts.encode() + path.read_bytes()
    return run


def jsc(counts, path):
    return [JSC, '-e', counts, str(path)], None


def run(engine, path, warm, runs):
    """Retired instructions and timed milliseconds of one run of the mini at `path`."""
    cmd, stdin = engine('var MINI_WARM = %d, MINI_RUNS = %d;\n' % (warm, runs), path)
    out = subprocess.run(['/usr/bin/time', '-l'] + cmd, input=stdin, capture_output=True, timeout=1800)
    stdout, stderr = out.stdout.decode('latin-1'), out.stderr.decode('latin-1')
    timed, retired = LINE_RE.findall(stdout), RETIRED_RE.search(stderr)
    if out.returncode != 0 or not timed or not retired:
        sys.exit('%s failed (%d): %s' % (' '.join(cmd), out.returncode, (stdout + stderr)[-300:]))
    return int(retired.group(1)), sum(map(int, timed))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--args', default='--jit --opt', help='engine arguments (default: --jit --opt)')
    parser.add_argument('--jsc', action='store_true', help='add JavaScriptCore as a reference')
    parser.add_argument('--scale', type=int, default=1, help='multiply every warm-up and run count')
    parser.add_argument('binaries', nargs='+')
    argv = sys.argv[1:]
    cut = argv.index('--') if '--' in argv else len(argv)
    args = parser.parse_args(argv[:cut])
    names = [n.removesuffix('.js') for n in argv[cut + 1:]] or sorted(p.stem for p in MINI.glob('*.js'))
    engines = [(Path(b).name, boomkat(b, args.args.split())) for b in args.binaries]
    if args.jsc:
        engines.append(('jsc', jsc))
    print('%-13s %-16s %14s %14s %9s %9s' % ('benchmark', 'engine', 'instr/iter', 'before runs', 'ms/iter', 'vs first'))
    for name in names:
        path = MINI / (name + '.js')
        counts = COUNTS_RE.search(path.read_text('latin-1'))
        if not counts:
            continue
        warm, runs = (int(c) * args.scale for c in counts.groups())
        first = None
        for label, engine in engines:
            one, two = run(engine, path, warm, runs), run(engine, path, warm, 2 * runs)
            steady = (two[0] - one[0]) / runs
            first = first or steady
            print('%-13s %-16s %14.0f %14.0f %9.2f %8.1f%%' % (
                name, label, steady, one[0] - steady * runs, (two[1] - one[1]) / runs, 100 * steady / first))


if __name__ == '__main__':
    main()
