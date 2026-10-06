#!/usr/bin/env python3
"""Render benchmark JSON from a file or stdin as a comparison table."""
import argparse
import json
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('file', nargs='?', type=argparse.FileType('r'), default=sys.stdin)
    args = parser.parse_args()
    with args.file as source:
        report = json.load(source)
    if report.get('schema_version') != 1:
        parser.error('unsupported benchmark schema version')
    engines = report['engines']
    comparisons = [engine for engine in engines if engine != 'boomkat']
    headers = ['Benchmark'] + [f'{engine} (ms)' for engine in engines] + [f'vs {engine}' for engine in comparisons]
    rows = []
    for benchmark in report['benchmarks']:
        results = benchmark['results']
        row = [benchmark['name'].removeprefix('bench_')]
        for engine in engines:
            result = results[engine]
            row.append(f"{result['mean_ms']:.1f}{'*' if result.get('cached') else ''}" if result['status'] == 'ok' else result['status'].upper())
        boomkat = results.get('boomkat', {}).get('mean_ms')
        for engine in comparisons:
            other = results[engine]['mean_ms']
            row.append(f'{boomkat / other:.2f}x' if boomkat is not None and other else '—')
        rows.append(row)
    widths = [max(len(row[i]) for row in [headers] + rows) for i in range(len(headers))]
    def line(row):
        return ' │ '.join(value.ljust(widths[i]) if i == 0 else value.rjust(widths[i]) for i, value in enumerate(row))
    print(f"Boomkat benchmarks · {report['iterations']} iterations · {report['generated_at']}")
    print()
    print(line(headers))
    print('─┼─'.join('─' * width for width in widths))
    for row in rows:
        print(line(row))
    print()
    print('Mean: ' + report['metric'] + '.')
    print('Cached third-party measurements are marked with *.')
    print('Ratios = boomkat / comparison engine; above 1 means boomkat is slower.')
    for benchmark in report['benchmarks']:
        for engine, result in benchmark['results'].items():
            if result.get('error'):
                print(f"\n{benchmark['name']} / {engine}: {result['error'].strip()}")


if __name__ == '__main__':
    main()
