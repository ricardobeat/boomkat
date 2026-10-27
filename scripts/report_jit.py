#!/usr/bin/env python3
"""Summarize --stats output, including the census from a SLJIT_STATS build.

Build diagnostics separately from the binary used for timing:
  c3c build boomkat -D SLJIT_STATS --output-dir /tmp/bk-jit-profile
  /tmp/bk-jit-profile/boomkat --jit --stats --script bench/mini/richards.js > /tmp/richards.stats
  python3 scripts/report_jit.py /tmp/richards.stats --source bench/mini/richards.js

Threaded handler entries include refusals retried by the switch. Neither these
counts nor native entry/exit counts measure time or native bytecode coverage.
"""
import argparse
import json
import re
from pathlib import Path


def parse(text):
    functions = {}
    exits = []
    totals = {}
    for line in text.splitlines():
        if not line.startswith('SLJIT '):
            continue
        fields = dict(re.findall(r'\b(\w+)=([^\s]+)', line))
        fields = {key: int(value) if value.isdecimal() else value for key, value in fields.items()}
        if line.startswith('SLJIT totals '):
            totals = fields
            continue
        if 'id' not in fields:
            continue
        ident = fields['id']
        row = functions.setdefault(ident, {'id': ident})
        if line.startswith('SLJIT coverage '):
            fields['name'] = line.split(' name=', 1)[1].split(' threaded=', 1)[0]
            fields['rejection'] = line.split(' rejection=', 1)[1]
            row['coverage'] = fields
        elif line.startswith('SLJIT native '):
            row['edges'] = fields
        elif line.startswith('SLJIT function '):
            fields['name'] = line[len('SLJIT function '):].split(' begin=', 1)[0]
            row['native'] = fields
        elif line.startswith('SLJIT exit '):
            fields['name'] = line[len('SLJIT exit '):].split(' begin=', 1)[0]
            exits.append(fields)
    edges = [f['edges'] for f in functions.values() if 'edges' in f]
    if edges:
        totals['native_calls'] = sum(e['calls'] for e in edges)
        totals['native_returns'] = sum(e['returns'] for e in edges)
    return {'functions': list(functions.values()), 'exits': exits, 'totals': totals}


def location(row, source):
    line = row.get('line', 0)
    name = row.get('name')
    if not name and source and line:
        # Source positions usually point just inside an anonymous method body.
        # Keep the source text available when the template has no function name.
        for text in reversed(source[max(0, line - 12):line]):
            found = re.search(r'([\w.$]+)\s*=\s*function\b', text)
            if found:
                name = found[1]
                break
    return f'{name or "<anonymous>"}:{line} [id={row["id"]}]'


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('log', type=Path)
    parser.add_argument('--source', type=Path)
    parser.add_argument('--limit', type=int, default=15)
    parser.add_argument('--json', type=Path, help='write all parsed rows, not just the displayed top rows')
    args = parser.parse_args()
    report = parse(args.log.read_text())
    source = args.source.read_text().splitlines() if args.source else None
    if args.json:
        args.json.write_text(json.dumps(report, indent=2) + '\n')
    coverage = [f['coverage'] for f in report['functions'] if 'coverage' in f]
    if coverage:
        total = sum(f['threaded'] for f in coverage)
        print('Hottest interpreted functions (handler entries include retries):')
        print(f'{"threaded":>12} {"share":>6} {"switch":>9} {"retired":>7}  function / admission')
        for row in sorted(coverage, key=lambda f: f['threaded'], reverse=True)[:args.limit]:
            share = row['threaded'] * 100 / total if total else 0
            print(f'{row["threaded"]:12,d} {share:5.1f}% {row["switch"]:9,d} {row["retired"]:7d}  '
                  f'{location(row, source)} / {row["rejection"]}')
        print(f'Total threaded entries: {total:,}; switch instructions: {sum(f["switch"] for f in coverage):,}')
    else:
        print('No function census: rebuild with -D SLJIT_STATS and run with --stats.')
    print('\nMost frequent native exits:')
    for row in sorted(report['exits'], key=lambda f: f['count'], reverse=True)[:args.limit]:
        print(f'{row["count"]:12,d}  {row.get("opcode", row["op"]):16} '
              f'{location(row, source)} pc={row["pc"]}')
    print('\nNative totals: ' + ', '.join(f'{k}={v:,}' if isinstance(v, int) else f'{k}={v}'
                                         for k, v in report['totals'].items()))


if __name__ == '__main__':
    main()
