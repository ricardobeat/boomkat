#!/usr/bin/env python3
"""Run each Octane 2.0 benchmark in a fresh process from a full bundle.

The bundle must already contain base.js, every benchmark and run.js's driver
(as produced by scripts/octane_gate.py). For each suite a copy of the bundle
is written with a filter injected immediately before the final
BenchmarkSuite.RunSuites({ call, so only that suite is left in
BenchmarkSuite.suites when the driver reads it. SplayLatency and
MandreelLatency are emitted by the Splay and Mandreel suites themselves.

    python3 scripts/octane_perbench.py --bundle octane-all.js \\
        [--binary out/boomkat] [--engine-args '--jit --jit-stats'] \\
        [--runs 1] [--only Richards,Splay] [--out out/octane-perbench]

Each run uses /usr/bin/time -l on macOS to capture peak RSS. Scores, wall
time, RSS and the engine statistics lines from stderr go to
<out>/gate-<timestamp>.json, with medians per benchmark; raw output goes to
<out>/logs/. Run it on an idle machine, with no concurrent builds or profiling.
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
import tempfile
import time
from datetime import datetime
from pathlib import Path

SUITE_NAMES = [
    'Richards', 'DeltaBlue', 'Crypto', 'RayTrace', 'EarleyBoyer', 'RegExp', 'Splay',
    'NavierStokes', 'PdfJS', 'Mandreel', 'Gameboy', 'CodeLoad', 'Box2D', 'zlib',
    'Typescript',
]
RESULTS = [
    'Richards', 'DeltaBlue', 'Crypto', 'RayTrace', 'EarleyBoyer', 'RegExp', 'Splay',
    'SplayLatency', 'NavierStokes', 'PdfJS', 'Mandreel', 'MandreelLatency', 'Gameboy',
    'CodeLoad', 'Box2D', 'zlib', 'Typescript',
]
RUNSUITES_CALL = 'BenchmarkSuite.RunSuites({'
SUITE_RE = re.compile(r'new BenchmarkSuite\(\s*[\'"]([^\'"]+)[\'"]')
SCORE_RE = re.compile(r'^(\w+): (\d+)$')
COMPOSITE_RE = re.compile(r'^Score \(version \d+\): (\d+)$')
RSS_RE = re.compile(r'(\d+)\s+maximum resident set size')
# Same rule as scripts/octane_gate.py: --jit-stats / --jit-count-ops / --opt-log.
STATS_PREFIXES = ('jit:', 'jit ', 'opt:', 'opt ')


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_engine_stats(stderr: str):
    """Collect the engine statistics lines from a run's stderr."""
    lines = []
    for line in stderr.splitlines():
        text = line.strip()
        if text.startswith(STATS_PREFIXES):
            lines.append(text)
    return lines


def load_bundle(path: Path, p):
    """Check base.js's suite registration and locate the driver's final call."""
    try:
        text = path.read_text()
    except OSError as e:
        p.error(f'cannot read bundle {path}: {e}')
    if 'BenchmarkSuite.suites.push(this);' not in text:
        p.error(f'{path} does not contain base.js suite registration')
    found = set(SUITE_RE.findall(text))
    missing = [n for n in SUITE_NAMES if n not in found]
    if missing:
        p.error(f'{path} is not a full bundle; missing suites: {", ".join(missing)}')
    pos = text.rfind(RUNSUITES_CALL)
    if pos < 0:
        p.error(f'{path} has no {RUNSUITES_CALL} call')
    return text, pos


def make_suite_bundle(text: str, pos: int, name: str) -> str:
    """Inject the single-suite filter immediately before the RunSuites call."""
    line = ('BenchmarkSuite.suites = BenchmarkSuite.suites.filter('
            f'function (s) {{ return s.name === {json.dumps(name)}; }});\n\n')
    return text[:pos] + line + text[pos:]


def load_average():
    try:
        return os.getloadavg()
    except OSError:
        return None


def run_once(binary: Path, engine_args, suite_bundle: Path, log: Path):
    cmd = ['/usr/bin/time', '-l', str(binary), *engine_args,
           '--script', str(suite_bundle)]
    start = time.monotonic()
    proc = subprocess.run(cmd, capture_output=True, text=True)
    wall = time.monotonic() - start
    log.write_text(proc.stdout + '\n--- stderr ---\n' + proc.stderr)
    scores, extra = {}, []
    composite = None
    for line in proc.stdout.splitlines():
        m = SCORE_RE.match(line)
        if m:
            scores[m.group(1)] = int(m.group(2))
            continue
        m = COMPOSITE_RE.match(line)
        if m:
            composite = int(m.group(1))
            continue
        if line.strip() and line != '----':
            extra.append(line)
    m = RSS_RE.search(proc.stderr)
    return {
        'exit': proc.returncode, 'wall_s': round(wall, 2),
        'max_rss': int(m.group(1)) if m else None,
        'scores': scores, 'composite': composite, 'extra': extra,
        'engine_stats': parse_engine_stats(proc.stderr),
        'log': str(log), 'load_average': load_average(),
    }


def median(values):
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def report(runs, medians):
    runs_flat = [r for rs in runs.values() for r in rs]
    width = max([len(n) for n in medians] + [len('benchmark')])
    print(f'{"benchmark":{width}}  {"score":>10}  {"wall_s":>8}  {"rss_MiB":>9}')
    for name, score in medians.items():
        picked = (runs_flat if name == 'composite' else
                  [r for r in runs_flat if name in r['scores']])
        wall = median([r['wall_s'] for r in picked])
        rss = median([r['max_rss'] for r in picked])
        line = f'{name:{width}}  {score:>10.0f}' if score is not None else f'{name:{width}}  {"-":>10}'
        line += f'  {wall:>8.1f}' if wall is not None else f'  {"-":>8}'
        line += f'  {rss / (1 << 20):>9.0f}' if rss else f'  {"-":>9}'
        print(line)


def main():
    # argparse treats a value beginning with '-' (e.g. --engine-args '--jit')
    # as another option. Accept it by rewriting it to the --opt=value form.
    argv = sys.argv[1:]
    for i, token in enumerate(argv):
        if token == '--engine-args' and i + 1 < len(argv) and argv[i + 1].startswith('-'):
            argv[i] = '--engine-args=' + argv[i + 1]
            del argv[i + 1]
            break
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--bundle', required=True, type=Path, help='prebuilt full Octane 2.0 bundle')
    p.add_argument('--binary', type=Path, default=Path('out/boomkat'), help='engine binary (default out/boomkat)')
    p.add_argument('--engine-args', default='', help='extra engine flags, one token')
    p.add_argument('--out', type=Path, default=Path('out/octane-perbench'), help='results directory')
    p.add_argument('--runs', type=int, default=1, help='runs per benchmark (default 1)')
    p.add_argument('--only', action='append', metavar='NAME',
                   help='suite to run; repeat or comma-separate (default: all 15)')
    a = p.parse_args(argv)
    if a.runs < 1:
        p.error('--runs must be at least 1')
    names = []
    for value in a.only or []:
        for part in value.split(','):
            part = part.strip()
            if part and part not in names:
                names.append(part)
    unknown = [n for n in names if n not in SUITE_NAMES]
    if unknown:
        p.error(f'unknown suite name(s): {", ".join(unknown)}; '
                f'choose from {", ".join(SUITE_NAMES)}')
    suites = names or list(SUITE_NAMES)
    binary = a.binary.resolve()
    if not binary.is_file():
        p.error(f'binary not found: {binary}')
    if not a.bundle.is_file():
        p.error(f'bundle not found: {a.bundle}')
    text, pos = load_bundle(a.bundle, p)
    engine_args = a.engine_args.split()

    a.out.mkdir(parents=True, exist_ok=True)
    logs = a.out / 'logs'
    logs.mkdir(exist_ok=True)
    stamp = datetime.now().strftime('%Y%m%d-%H%M%S')
    runs = {name: [] for name in suites}
    print(f'bundle {a.bundle} sha256 {sha256(a.bundle)[:16]}; binary {binary} '
          f'sha256 {sha256(binary)[:16]}; load average {load_average()}', flush=True)

    with tempfile.TemporaryDirectory(prefix='octane-perbench-') as tmp:
        tmpdir = Path(tmp)
        for name in suites:
            suite_bundle = tmpdir / f'octane-{name}.js'
            suite_bundle.write_text(make_suite_bundle(text, pos, name))
            suite_sha = sha256(suite_bundle)
            for n in range(a.runs):
                log = logs / f'{stamp}-{name}-{n + 1}.log'
                r = run_once(binary, engine_args, suite_bundle, log)
                r['suite'] = name
                r['suite_bundle_sha256'] = suite_sha
                runs[name].append(r)
                status = f'composite {r["composite"]}' if r['composite'] else f'exit {r["exit"]}'
                print(f'run {n + 1} {name}: {status}, {r["wall_s"]}s', flush=True)
                for line in r['extra']:
                    print(f'    {line}')

    seen = {name for rs in runs.values() for r in rs for name in r['scores']}
    score_names = [name for name in RESULTS if name in seen]
    score_names += sorted(seen - set(score_names))
    medians = {name: median([r['scores'].get(name) for rs in runs.values() for r in rs])
               for name in score_names}
    medians['composite'] = median([r['composite'] for rs in runs.values() for r in rs])
    result = {
        'captured': stamp, 'machine': platform.platform(), 'engine_args': engine_args,
        'binary': str(binary), 'binary_sha256': sha256(binary),
        'bundle': str(a.bundle.resolve()), 'bundle_sha256': sha256(a.bundle),
        'runs_per_suite': a.runs, 'suites': suites,
        'medians': medians, 'runs': runs,
    }
    path = a.out / f'gate-{stamp}.json'
    path.write_text(json.dumps(result, indent=2))
    print()
    report(runs, medians)
    print(f'\nwritten {path}')
    return 0 if all(r['exit'] == 0 and r['composite']
                    for rs in runs.values() for r in rs) else 1


if __name__ == '__main__':
    sys.exit(main())
