#!/usr/bin/env python3
"""Split frontend cost into initial full-unit parse versus body materialization.

Runs the javascript-zoo CodeLoad equal-work drivers under a FRONTEND_STATS
binary and reports the per-phase counters it dumps on stderr:

  initial_us       time inside index_begin for full units (prod/eval/script)
  materialize_us   time inside index_begin for deferred function bodies
  materialize_total_us  whole materialize_function_body (incl. emit and finish)
  finish_us        time inside CompilerContext.finish across every function
  liveness_*       move-elimination call, sweep, instruction and word counts

Build the binary with `c3c build boomkat_relexstats` (RELEX_STATS +
FRONTEND_STATS, no TRACE_VM, so eval deferral stays on).
"""
import argparse
import json
import re
import statistics
import subprocess
import tempfile
from pathlib import Path

CASES = [('JQuery', 100, 'runCodeLoadJQuery'), ('Closure', 1000, 'runCodeLoadClosure')]
PAIR_RE = re.compile(r'(\w+)=(\d+)')
ELAPSED_RE = re.compile(r'^Elapsed: (\d+)$', re.M)


def parse_dump(text):
    values = {}
    for line in text.splitlines():
        if line.startswith('# FRONTEND'):
            for key, value in PAIR_RE.findall(line):
                values[key] = int(value)
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=Path('out/boomkat_relexstats'))
    parser.add_argument('--bench-dir', type=Path, required=True)
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    benchmark = (args.bench_dir / 'code-load.js').resolve()
    prefix = benchmark.read_text().rsplit('BenchmarkSuite.RunSuites(', 1)[0]
    rows = []
    with tempfile.TemporaryDirectory() as directory:
        drivers = {}
        for case, count, runner in CASES:
            path = Path(directory) / (case + '.js')
            path.write_text(prefix + '\nsetupCodeLoad();\nvar started=Date.now();\n'
                            + f'for(var i=0;i<{count};i++) {runner}();\n'
                            + 'print("Elapsed: "+(Date.now()-started));\n')
            drivers[case] = path
        for run in range(args.runs):
            for case, path in drivers.items():
                result = subprocess.run([str(args.binary), str(path)],
                                        capture_output=True, text=True, check=True,
                                        timeout=240)
                elapsed = int(ELAPSED_RE.search(result.stdout)[1])
                counters = parse_dump(result.stderr)
                row = {'run': run, 'case': case, 'elapsed_ms': elapsed, **counters}
                rows.append(row)
                print(json.dumps(row), flush=True)
    summary = {}
    for case in drivers:
        subset = [row for row in rows if row['case'] == case]
        keys = sorted({key for row in subset for key in row})
        summary[case] = {key: statistics.median(row.get(key, 0) for row in subset)
                         for key in keys if key != 'case'}
    print('\nCase     elapsed_ms  initial_ms  mat_total_ms  finish_ms  mat_units  liveness_calls')
    for case, med in summary.items():
        print(f"{case:8s} {med.get('elapsed_ms', 0):10.0f} {med.get('initial_us', 0)/1000:11.1f}"
              f" {med.get('materialize_total_us', 0)/1000:13.1f} {med.get('finish_us', 0)/1000:10.1f}"
              f" {med.get('materialize_calls', 0):10.0f} {med.get('liveness_calls', 0):14.0f}")
    if args.out:
        args.out.write_text(json.dumps({'binary': str(args.binary.resolve()),
                                        'samples': rows, 'medians': summary}, indent=2) + '\n')


if __name__ == '__main__':
    main()
