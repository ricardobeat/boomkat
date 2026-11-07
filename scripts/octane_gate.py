#!/usr/bin/env python3
"""Run the full Octane 2.0 suite in one process and compare two binaries.

The suite is bundled from an Octane checkout (base.js, every benchmark in
suite order, then run.js's driver) and run with `--script`, or supplied as a
prebuilt concatenated bundle with --bundle. Exactly one of --octane DIR and
--bundle PATH is required. Each run prints the 17 results and the composite;
this script records them with the wall time, peak RSS, binary hash and any
engine statistics lines (--jit-stats / --jit-count-ops / --opt-log, read from
stderr), alternating between the two binaries so drift affects both sides
alike.

    python3 scripts/octane_gate.py (--octane DIR | --bundle PATH) \\
        [--runs 3] [--jit] [--engine-args ARGS] [--out DIR] BASE [CANDIDATE]

With one binary it records a measurement; with two it prints the median per
benchmark for each side, the ratio, and marks ratios outside 3%. Results go to
<out>/gate-<timestamp>.json, and each run's output to <out>/logs/. Run it on an
idle machine, with no concurrent builds or profiling.
"""
import argparse
import hashlib
import json
import os
import platform
import re
import statistics
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

BENCHMARKS = [
    'richards.js', 'deltablue.js', 'crypto.js', 'raytrace.js', 'earley-boyer.js',
    'regexp.js', 'splay.js', 'navier-stokes.js', 'pdfjs.js', 'mandreel.js',
    'gbemu-part1.js', 'gbemu-part2.js', 'code-load.js', 'box2d.js', 'zlib.js',
    'zlib-data.js', 'typescript.js', 'typescript-input.js', 'typescript-compiler.js',
]
RESULTS = [
    'Richards', 'DeltaBlue', 'Crypto', 'RayTrace', 'EarleyBoyer', 'RegExp', 'Splay',
    'SplayLatency', 'NavierStokes', 'PdfJS', 'Mandreel', 'MandreelLatency', 'Gameboy',
    'CodeLoad', 'Box2D', 'zlib', 'Typescript',
]
# zlib's shell detection probes `read`; no benchmark calls it.
SHIM = ('if (typeof read === "undefined") { globalThis.read = function (f) '
        '{ throw new Error("read " + f); }; }\n')
SCORE_RE = re.compile(r'^(\w+): (\d+)$')
COMPOSITE_RE = re.compile(r'^Score \(version \d+\): (\d+)$')
# Lines emitted by --jit-stats / --jit-count-ops / --opt-log on stderr.
STATS_PREFIXES = ('jit:', 'jit ', 'opt:', 'opt ')


def parse_engine_stats(stderr: str):
    """Collect the engine statistics lines from a run's stderr."""
    lines = []
    for line in stderr.splitlines():
        text = line.strip()
        if text.startswith(STATS_PREFIXES):
            lines.append(text)
    return lines


def make_bundle(octane: Path, out: Path) -> Path:
    run_js = (octane / 'run.js').read_text()
    driver = run_js[run_js.index('var success = true;'):]
    parts = [SHIM]
    for name in ['base.js'] + BENCHMARKS:
        parts.append((octane / name).read_text())
        parts.append('\n')
    parts.append(driver)
    bundle = out / 'octane-all.js'
    bundle.write_text(''.join(parts))
    return bundle


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def time_command():
    # /usr/bin/time reports the child's peak RSS; the suite needs one process.
    if platform.system() == 'Darwin':
        return ['/usr/bin/time', '-l'], re.compile(r'(\d+)\s+maximum resident set size'), 1
    return ['/usr/bin/time', '-v'], re.compile(r'Maximum resident set size \(kbytes\): (\d+)'), 1024


def run_once(binary: Path, args, bundle: Path, log: Path):
    prefix, rss_re, rss_unit = time_command()
    cmd = prefix + [str(binary), *args, '--script', str(bundle)]
    start = time.monotonic()
    proc = subprocess.run(cmd, capture_output=True, text=True)
    wall = time.monotonic() - start
    log.write_text(proc.stdout + '\n--- stderr ---\n' + proc.stderr)
    scores, extra = {}, []
    composite = None
    for line in proc.stdout.splitlines():
        m = SCORE_RE.match(line)
        if m and m.group(1) in RESULTS:
            scores[m.group(1)] = int(m.group(2))
            continue
        m = COMPOSITE_RE.match(line)
        if m:
            composite = int(m.group(1))
            continue
        if line.strip() and line != '----':
            extra.append(line)
    m = rss_re.search(proc.stderr)
    rss = int(m.group(1)) * rss_unit if m else None
    missing = [r for r in RESULTS if r not in scores]
    return {
        'exit': proc.returncode, 'wall_s': round(wall, 2), 'max_rss': rss,
        'scores': scores, 'composite': composite, 'missing': missing, 'extra': extra,
        'engine_stats': parse_engine_stats(proc.stderr),
    }


def load_average():
    try:
        return os.getloadavg()
    except OSError:
        return None


def median(values):
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def report(sides, runs):
    names = [s['name'] for s in sides]
    width = max(len(r) for r in RESULTS + ['composite'])
    header = f"{'':{width}}  " + '  '.join(f'{n:>12}' for n in names)
    if len(sides) == 2:
        header += '  ratio'
    print(header)
    rows = [(r, lambda run, r=r: run['scores'].get(r)) for r in RESULTS]
    rows.append(('composite', lambda run: run['composite']))
    for label, pick in rows:
        meds = [median([pick(run) for run in runs[n]]) for n in names]
        line = f'{label:{width}}  ' + '  '.join(f'{m:>12.0f}' if m else f'{"-":>12}' for m in meds)
        if len(sides) == 2 and meds[0] and meds[1]:
            ratio = meds[1] / meds[0]
            flag = ' *' if abs(ratio - 1) > 0.03 else ''
            line += f'  {ratio:5.3f}{flag}'
        print(line)
    for n in names:
        rss = median([run['max_rss'] for run in runs[n]])
        wall = median([run['wall_s'] for run in runs[n]])
        print(f'{n}: median wall {wall:.1f}s, median peak RSS '
              f'{rss / (1 << 20):.0f} MiB' if rss else f'{n}: median wall {wall:.1f}s')


def main():
    # argparse treats a value beginning with '-' (e.g. --engine-args '--jit-stats')
    # as another option. Accept it by rewriting it to the --opt=value form.
    argv = sys.argv[1:]
    for i, token in enumerate(argv):
        if token == '--engine-args' and i + 1 < len(argv) and argv[i + 1].startswith('-'):
            argv[i] = '--engine-args=' + argv[i + 1]
            del argv[i + 1]
            break
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--octane', type=Path, help='Octane 2.0 source directory; builds the bundle')
    p.add_argument('--bundle', type=Path, help='prebuilt concatenated bundle (alternative to --octane)')
    p.add_argument('--runs', type=int, default=3, help='runs per binary (default 3)')
    p.add_argument('--jit', action='store_true', help='pass --jit to both binaries')
    p.add_argument('--engine-args', default='', help='extra engine flags, one token')
    p.add_argument('--out', type=Path, default=Path('out/octane-gate'), help='results directory')
    p.add_argument('binaries', nargs='+', type=Path, metavar='BINARY')
    a = p.parse_args(argv)
    if (a.octane is None) == (a.bundle is None):
        p.error('exactly one of --octane DIR and --bundle PATH is required')
    if len(a.binaries) > 2:
        p.error('at most two binaries')
    engine_args = (['--jit'] if a.jit else []) + a.engine_args.split()

    a.out.mkdir(parents=True, exist_ok=True)
    logs = a.out / 'logs'
    logs.mkdir(exist_ok=True)
    if a.bundle is not None:
        bundle = a.bundle
        if not bundle.is_file():
            p.error(f'--bundle file not found: {bundle}')
    else:
        bundle = make_bundle(a.octane, a.out)
    stamp = datetime.now().strftime('%Y%m%d-%H%M%S')
    sides = []
    for i, b in enumerate(a.binaries):
        name = b.name if len(a.binaries) == 1 or a.binaries[0].name != a.binaries[1].name else f'{b.name}#{i}'
        sides.append({'name': name, 'path': str(b.resolve()), 'sha256': sha256(b)})
    runs = {s['name']: [] for s in sides}

    print(f'bundle {bundle} sha256 {sha256(bundle)[:16]}; load average {load_average()}')
    for n in range(a.runs):
        for s in sides:
            log = logs / f'{stamp}-{s["name"]}-{n + 1}.log'
            r = run_once(Path(s['path']), engine_args, bundle, log)
            r['load_average'] = load_average()
            runs[s['name']].append(r)
            status = f'composite {r["composite"]}' if r['composite'] else f'exit {r["exit"]}, missing {r["missing"]}'
            print(f'run {n + 1} {s["name"]}: {status}, {r["wall_s"]}s', flush=True)
            for line in r['extra']:
                print(f'    {line}')

    result = {
        'captured': stamp, 'machine': platform.platform(), 'engine_args': engine_args,
        'bundle_sha256': sha256(bundle),
        'octane_dir': str(a.octane.resolve()) if a.octane is not None else None,
        'sides': sides, 'runs': runs,
    }
    if a.bundle is not None:
        result['bundle'] = str(a.bundle.resolve())
    path = a.out / f'gate-{stamp}.json'
    path.write_text(json.dumps(result, indent=2))
    print()
    report(sides, runs)
    print(f'\nwritten {path}')
    return 0 if all(r['composite'] for rs in runs.values() for r in rs) else 1


if __name__ == '__main__':
    sys.exit(main())
