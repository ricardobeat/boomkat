#!/usr/bin/env python3
"""Measure benchmark wall time or in-process execution time; emit JSON."""
import argparse
from datetime import datetime, timezone
import json
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import time
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]


def positive_int(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError('must be at least 1')
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('iterations', nargs='?', type=positive_int, default=3)
    parser.add_argument('--suite', choices=['core', 'es6'], default='core',
                        help='benchmark corpus to measure')
    parser.add_argument('--mode', choices=['wall', 'execution'], default='wall',
                        help='wall includes process lifecycle; execution times only the JS body')
    parser.add_argument('--all', action='store_true', help='include Duktape')
    parser.add_argument('--filter', default='*', help='benchmark glob after bench_')
    parser.add_argument('--timeout', type=positive_int, default=120, help='seconds per process')
    args = parser.parse_args()
    commands = {
        'boomkat': [str(ROOT / 'out/boomkat'), '--script'],
        'quickjs': [str(ROOT / 'out/qjs')],
        # The corpus uses the shell print() global. Node evaluates the same source
        # as a script rather than wrapping it in a CommonJS function.
        'node': ['node', '-e', "globalThis.print = console.log; require('vm').runInThisContext(require('fs').readFileSync(process.argv[1], 'utf8'), {filename: process.argv[1]});"],
    }
    if args.all and args.suite == 'es6':
        parser.error('Duktape cannot run the ES6 corpus')
    if args.all:
        commands['duktape'] = [str(ROOT / 'out/duktape')]
    for name, command in commands.items():
        if not shutil.which(command[0]):
            parser.error(f'{name} executable not found: {command[0]}')
    bench_dir = ROOT / 'benchmarks'
    if args.suite == 'es6':
        bench_dir /= 'es6'
    files = sorted(bench_dir.glob(f'bench_{args.filter}.js'))
    if not files:
        parser.error('no benchmarks match --filter')
    report = {
        'schema_version': 1,
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'iterations': args.iterations,
        'timeout_seconds': args.timeout,
        'suite': args.suite,
        'mode': args.mode,
        'metric': ('fresh-process wall time, including startup, compilation, execution and teardown'
                   if args.mode == 'wall' else
                   'JavaScript body execution time; Date.now() millisecond resolution'),
        'engines': list(commands),
        'benchmarks': [],
    }
    cache_dir = ROOT / 'out'
    cache_dir.mkdir(exist_ok=True)
    caches = {}
    fingerprints = {}
    for engine, command in commands.items():
        if engine == 'boomkat':
            continue
        executable = Path(shutil.which(command[0])).resolve()
        fingerprints[engine] = hashlib.sha256(executable.read_bytes()).hexdigest()
        cache_path = cache_dir / f'bench_cache_{engine}.json'
        try:
            caches[engine] = json.loads(cache_path.read_text())
            if not isinstance(caches[engine], dict):
                caches[engine] = {}
        except (OSError, ValueError):
            caches[engine] = {}
    temporary_directory = tempfile.TemporaryDirectory(prefix='boomkat-bench-')
    marker = '__BOOMKAT_TIMING_' + uuid.uuid4().hex + '__'
    for path in files:
        run_path = path
        if args.mode == 'execution':
            run_path = Path(temporary_directory.name) / path.name
            clock_name = '__boomkat_clock_' + uuid.uuid4().hex
            run_path.write_text(
                f'var {clock_name} = Date.now();\n' + path.read_text() +
                f'\nprint("{marker}" + (Date.now() - {clock_name}));\n')
        row = {'name': path.stem, 'results': {}}
        for engine, command in commands.items():
            cache_key = hashlib.sha256(json.dumps({
                'schema': 2, 'mode': args.mode, 'source': hashlib.sha256(path.read_bytes()).hexdigest(),
                'path': str(path), 'engine': fingerprints.get(engine),
                'command': command, 'iterations': args.iterations, 'timeout': args.timeout,
            }, sort_keys=True).encode()).hexdigest()
            cached = caches.get(engine, {}).get(cache_key)
            if cached:
                row['results'][engine] = dict(cached, cached=True)
                print(f"{path.stem}: {engine} {cached['mean_ms']:.1f} ms (cached)", file=sys.stderr)
                continue
            samples = []
            result = {'status': 'ok', 'samples_ms': samples, 'mean_ms': None, 'cached': False}
            for _ in range(args.iterations):
                start = time.perf_counter_ns()
                try:
                    process = subprocess.run(command + [str(run_path)], cwd=ROOT,
                                             stdout=(subprocess.PIPE if args.mode == 'execution' else subprocess.DEVNULL),
                                             stderr=subprocess.PIPE,
                                             timeout=args.timeout)
                except subprocess.TimeoutExpired:
                    result.update(status='timeout', error=f'exceeded {args.timeout}s')
                    break
                except OSError as error:
                    result.update(status='error', error=str(error))
                    break
                elapsed = (time.perf_counter_ns() - start) / 1_000_000
                if process.returncode:
                    result.update(status='error', exit_code=process.returncode,
                                  error=process.stderr.decode(errors='replace')[-2000:])
                    break
                if args.mode == 'execution':
                    timings = [line[len(marker):] for line in process.stdout.decode(errors='replace').splitlines()
                               if line.startswith(marker)]
                    try:
                        if len(timings) != 1:
                            raise ValueError('missing or duplicate timing record')
                        elapsed = int(timings[0])
                        if elapsed < 0:
                            raise ValueError('clock moved backwards')
                    except ValueError as error:
                        result.update(status='error', error=f'invalid execution timing: {error}')
                        break
                samples.append(elapsed)
            if result['status'] == 'ok':
                result['mean_ms'] = sum(samples) / len(samples)
                if engine in caches:
                    caches[engine][cache_key] = result
                    cache_path = cache_dir / f'bench_cache_{engine}.json'
                    temporary = cache_path.with_suffix('.json.tmp')
                    temporary.write_text(json.dumps(caches[engine], indent=2))
                    temporary.replace(cache_path)
            row['results'][engine] = result
            summary = f"{result['mean_ms']:.1f} ms" if result['status'] == 'ok' else result['status']
            print(f'{path.stem}: {engine} {summary}', file=sys.stderr)
        report['benchmarks'].append(row)
    temporary_directory.cleanup()
    json.dump(report, sys.stdout, indent=2, allow_nan=False)
    print()


if __name__ == '__main__':
    main()
