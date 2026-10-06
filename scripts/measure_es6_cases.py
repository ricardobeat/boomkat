#!/usr/bin/env python3
"""Measure constituent ES6 cases without changing the generic benchmark suite.

Run from the repository root. Times cover one call after fixture setup, using
Date.now; they exclude engine startup and are not steady-state JIT measurements.
"""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import tempfile

CASES = {
    'let_loop': ['letLoop(N)', 'letBody(N)', 'varLoop(N)', 'letCaptured(200000)'],
    'destructuring': ['arrayPattern(N)', 'objectPattern(N)', 'withDefaults(N)',
                      'restElement(N / 2)', 'params(N / 2)'],
    'spread_rest': ['arraySpread(N)', 'objectSpread(N)', 'callWithRest(N * 2)',
                    'spreadCall(N / 2)'],
    'closure_capture': ['capturedNotCalled(N)', 'capturedAndCalled(N / 3)', 'uncaptured(N)'],
    'forof': ['overArray(arr)', 'byIndex(arr)', 'overSet(set)', 'overMap(map)',
              'overString(str)', 'overGenerator(N / 3)'],
}


def measure(command):
    samples, results = [], []
    for run in range(6):
        output = subprocess.check_output(command, text=True, timeout=60)
        elapsed, result = json.loads(output.strip())
        results.append(result)
        if run:
            samples.append(elapsed)
    if len(set(results)) != 1:
        raise RuntimeError(f'Inconsistent result: {command}')
    return {'samples_ms': samples, 'median_ms': statistics.median(samples),
            'result': results[0]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    parser.add_argument('--boomkat', default='./out/boomkat')
    parser.add_argument('--quickjs', default='./out/qjs')
    options = parser.parse_args()
    rows = []
    with tempfile.TemporaryDirectory(prefix='boomkat-es6-') as directory:
        for suite, calls in CASES.items():
            fixture = Path(f'benchmarks/es6/bench_{suite}.js').read_text()
            source, separator, _ = fixture.partition('var r = 0;')
            if not separator:
                raise RuntimeError(f'Fixture entry point changed: {suite}')
            for call in calls:
                path = Path(directory) / (call.split('(')[0] + '.js')
                path.write_text(source + '\nvar started = Date.now();\n'
                                + f'var result = {call};\n'
                                + 'print(JSON.stringify([Date.now()-started,result]));\n')
                commands = {
                    'boomkat': [options.boomkat, '--script', str(path)],
                    'quickjs': [options.quickjs, str(path)],
                    'node': ['node', '-e', 'global.print=console.log;require('
                             + json.dumps(str(path)) + ')'],
                }
                engines = {name: measure(command) for name, command in commands.items()}
                if len({value['result'] for value in engines.values()}) != 1:
                    raise RuntimeError(f'Cross-engine result mismatch: {suite}/{call}')
                rows.append({'suite': suite, 'call': call, 'engines': engines})
                print(suite, call, {k: v['median_ms'] for k, v in engines.items()}, flush=True)
    report = {
        'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
        'method': 'Date.now around one constituent call after setup; six fresh processes '
                  'per engine, first discarded; no steady-state JIT warmup',
        'boomkat_sha256': hashlib.sha256(Path(options.boomkat).read_bytes()).hexdigest(),
        'rows': rows,
    }
    Path(options.output).write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
