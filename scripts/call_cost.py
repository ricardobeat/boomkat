#!/usr/bin/env python3
"""Measure the instructions one JS call and return cost, apart from the work around it.

    python3 scripts/call_cost.py [--jsc] [--n N] BIN [BIN2 ...]

Each shape runs a loop of N and of 2N calls, and the same loop with the call replaced by its
body; the difference of the four runs' retired instructions, over N, is what one call and return
adds. Shapes: a plain call of a two-argument function, a method call reading `this`, and a
recursive call (fib). Each runs under `--jit` (baseline code calling baseline code) and under
`--jit --opt --opt-no-inline` (optimized code making real calls). --jsc adds the system
JavaScriptCore, whose callees are kept out of line with noInline. Needs /usr/bin/time -l (macOS).
"""
import argparse, re, subprocess, sys

JSC = '/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc'
RETIRED_RE = re.compile(r'(\d+)\s+instructions retired')
PRELUDE = 'if (typeof noInline != "function") var noInline = function () {};\n'

# Each shape: (call body, inline body, setup). N iterations of the loop run in `run`.
SHAPES = {
    'plain': (
        'function f(x, y) { return (x + y) | 0; } noInline(f);\n'
        'function run(n) { var a = 0; for (var i = 0; i < n; i++) a = f(a, i); return a; }\n',
        'function run(n) { var a = 0; for (var i = 0; i < n; i++) a = (a + i) | 0; return a; }\n'),
    'method': (
        'function P(v) { this.v = v; } P.prototype.m = function (x) { return (this.v + x) | 0; };\n'
        'noInline(P.prototype.m); var o = new P(3);\n'
        'function run(n) { var a = 0; for (var i = 0; i < n; i++) a = o.m(a); return a; }\n',
        'function P(v) { this.v = v; } var o = new P(3);\n'
        'function run(n) { var a = 0; for (var i = 0; i < n; i++) a = (o.v + a) | 0; return a; }\n'),
}


def program(src, n):
    # A warm-up run compiles every tier first; the measured run follows.
    return PRELUDE + src + 'run(%d); run(%d);\n' % (min(n, 200000), n)


def fib_program(depth, reps):
    # fib(d) makes fib_calls(d) calls; reps repeats it.
    return (PRELUDE + 'function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); } noInline(fib);\n'
            'for (var w = 0; w < 20; w++) fib(15);\n'
            'for (var r = 0; r < %d; r++) fib(%d);\n' % (reps, depth))


def fib_calls(d):
    a, b = 1, 1  # calls for fib(0), fib(1)
    for _ in range(d - 1):
        a, b = b, a + b + 1
    return b if d >= 1 else a


def retired(cmd, stdin):
    out = subprocess.run(['/usr/bin/time', '-l'] + cmd, input=stdin, capture_output=True, timeout=1800)
    m = RETIRED_RE.search(out.stderr.decode('latin-1'))
    if out.returncode != 0 or not m:
        sys.exit('%s failed (%d): %s' % (' '.join(cmd), out.returncode, out.stderr.decode('latin-1')[-300:]))
    return int(m.group(1))


def engine_cmd(binary, args):
    if binary == 'jsc':
        return lambda src: ([JSC] + args + ['-e', src], None)
    return lambda src: ([binary] + args + ['--script', '-'], src.encode())


def per_call(run, shape, n):
    call_src, inline_src = SHAPES[shape]
    c1, c2 = retired(*run(program(call_src, n))), retired(*run(program(call_src, 2 * n)))
    l1, l2 = retired(*run(program(inline_src, n))), retired(*run(program(inline_src, 2 * n)))
    return ((c2 - c1) - (l2 - l1)) / n


def per_fib_call(run, n):
    d = 20
    reps = max(1, n // fib_calls(d))
    i1, i2 = retired(*run(fib_program(d, reps))), retired(*run(fib_program(d, 2 * reps)))
    return (i2 - i1) / (reps * fib_calls(d))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--jsc', action='store_true', help='add JavaScriptCore as a reference')
    parser.add_argument('--n', type=int, default=2000000, help='calls in the shorter run')
    parser.add_argument('binaries', nargs='+')
    args = parser.parse_args()
    configs = [('jit', ['--jit']), ('opt', ['--jit', '--opt', '--opt-no-inline'])]
    rows = [(b.split('/')[-1], name, engine_cmd(b, flags)) for b in args.binaries for name, flags in configs]
    if args.jsc:
        rows.append(('jsc', 'baseline', engine_cmd('jsc', ['--useDFGJIT=false'])))
        rows.append(('jsc', 'ftl', engine_cmd('jsc', [])))
    print('%-16s %-9s %9s %9s %9s' % ('engine', 'tier', 'plain', 'method', 'fib'))
    for label, tier, run in rows:
        cells = [per_call(run, s, args.n) for s in SHAPES] + [per_fib_call(run, args.n)]
        print('%-16s %-9s %9.1f %9.1f %9.1f' % (label, tier, *cells), flush=True)


if __name__ == '__main__':
    main()
