#!/usr/bin/env python3
"""Compare prebuilt binaries for plan 102 AST optimizations.

Run from the repository root. Requires POSIX wait4 and libcorpus bundles.
One warmup pair precedes seven measured pairs, alternating execution order.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys
import tempfile
import time


def run(args):
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        start = time.perf_counter()
        process = subprocess.Popen(args, stdout=out, stderr=err)
        _, status, usage = os.wait4(process.pid, 0)
        elapsed = time.perf_counter() - start
        process.returncode = os.waitstatus_to_exitcode(status)
        out.seek(0)
        output = out.read()
        err.seek(0)
        if process.returncode:
            raise RuntimeError((args, process.returncode, err.read()[:1000], output[:1000]))
        # Scene output includes elapsed times; retain its other observable output.
        output = re.sub(rb'total=\d+ms worst_frame=\d+ms', b'timing', output)
        if b'FAIL' in output:
            raise RuntimeError(output)
        rss = usage.ru_maxrss * (1 if sys.platform == 'darwin' else 1024)
        return elapsed, rss, hashlib.sha256(output).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', required=True)
    parser.add_argument('--baseline-debug', required=True)
    parser.add_argument('--candidate', default='./out/boomkat')
    parser.add_argument('--candidate-debug', default='./out/boomkat_debug')
    parser.add_argument('--revision', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--runtime', action='append', help='runtime workload; repeat to replace the default set')
    options = parser.parse_args()
    results = {
        'baseline_revision': options.revision,
        'compiler': subprocess.check_output(['c3c', '--version'], text=True).strip(),
        'platform': sys.platform + ' ' + os.uname().machine,
        'optimization': 'project targets (O2)',
        'repetitions': 7,
        'results': [],
    }
    workloads = [('runtime', 'benchmarks/ast-optimization/' + name + '.js') for name in (
        'bench_ast_constants', 'bench_ast_constants_control',
    )]
    workloads += [('runtime', 'benchmarks/' + name + '.js') for name in (
        'bench_arithmetic',
        'bench_function_call', 'bench_recursion', 'bench_scene_churn',
    )]
    if options.runtime:
        workloads = [('runtime', path) for path in options.runtime]
    workloads += [('compile', 'test/libcorpus/' + name + '.js')
                  for name in ('babel', 'typescript')]
    for mode, path in workloads:
        binaries = ([options.baseline, options.candidate] if mode == 'runtime'
                    else [options.baseline_debug, options.candidate_debug])
        args = ['--script'] if mode == 'runtime' else ['--check']
        samples = [[], []]
        for iteration in range(8):
            for which in ([0, 1] if iteration % 2 == 0 else [1, 0]):
                value = run([binaries[which], *args, path])
                if iteration:
                    samples[which].append(value)
        if len({sample[2] for group in samples for sample in group}) != 1:
            raise RuntimeError('output differs: ' + path)
        rows = []
        for group in samples:
            times = [sample[0] for sample in group]
            rows.append({
                'median_s': statistics.median(times),
                'min_s': min(times), 'max_s': max(times),
                'peak_rss_bytes': max(sample[1] for sample in group),
                'samples_s': times,
            })
        row = {
            'mode': mode, 'path': path, 'baseline': rows[0], 'candidate': rows[1],
            'time_ratio': rows[1]['median_s'] / rows[0]['median_s'],
        }
        results['results'].append(row)
        print(path, round(row['time_ratio'], 3), flush=True)
    results['binaries'] = {
        path: {'bytes': os.path.getsize(path),
               'sha256': hashlib.sha256(Path(path).read_bytes()).hexdigest()}
        for path in (options.baseline, options.candidate,
                     options.baseline_debug, options.candidate_debug)
    }
    Path(options.output).write_text(json.dumps(results, indent=2) + '\n')


if __name__ == '__main__':
    main()
