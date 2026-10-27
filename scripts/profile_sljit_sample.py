#!/usr/bin/env python3
"""Attribute macOS sample self counts using a same-process SLJIT_MAP dump.

Build with -D SLJIT_STATS -D SLJIT_MAP and run with --jit --stats. Addresses
must come from the sampled process. Inlining creates overlapping ranges;
the deepest frame wins. Unknown/retired code remains explicitly unmapped.
Loop-tier ranges are attributed as whole loops, without per-opcode detail.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import re


def read_maps(text):
    ranges = []
    functions = {}
    for line in text.splitlines():
        if line.startswith('SLJIT coverage '):
            fields = dict(re.findall(r'(\w+)=(\S+)', line))
            functions[int(fields['id'])] = fields
        if not line.startswith('SLJIT map '):
            continue
        fields = dict(re.findall(r'(\w+)=(\S+)', line))
        fields['start'] = int(fields['start'], 0)
        fields['end'] = int(fields['end'], 0)
        fields['depth'] = int(fields.get('depth', 0))
        if fields['end'] > fields['start']:
            ranges.append(fields)
    return ranges, functions


def self_samples(text):
    """Subtract immediate children, rather than counting inclusive stacks."""
    graph = text.split('Call graph:', 1)[1].split('Total number in stack', 1)[0]
    nodes = []
    parents = []
    for line in graph.splitlines():
        match = re.match(r'([\s+!:|]*)(\d+) (.+)', line)
        if not match:
            continue
        indent, count, symbol = len(match[1]), int(match[2]), match[3]
        while parents and nodes[parents[-1]]['indent'] >= indent:
            parents.pop()
        if parents:
            nodes[parents[-1]]['self'] -= count
        nodes.append(dict(indent=indent, self=count, symbol=symbol))
        parents.append(len(nodes) - 1)
    for node in nodes:
        if node['self'] < 0:
            raise ValueError('sample tree has inconsistent child counts')
        if node['self']:
            yield node['self'], node['symbol']


def attribute(maps, sample):
    ranges, functions = read_maps(maps)
    categories, opcodes, sites, native_helpers = Counter(), Counter(), Counter(), Counter()
    total = 0
    for count, symbol in self_samples(sample):
        total += count
        address = re.search(r'\[(0x[\da-fA-F]+)\]', symbol)
        pc = int(address[1], 16) if address else -1
        candidates = [r for r in ranges if r['start'] <= pc < r['end']]
        if not candidates:
            category = 'unmapped_generated' if '<unknown binary>' in symbol else 'runtime'
            categories[category] += count
            if category == 'runtime':
                native_helpers[symbol.split('  (in ', 1)[0]] += count
            continue
        region = max(candidates, key=lambda r: (r['depth'], -(r['end'] - r['start'])))
        opcode = region.get('opcode', region['kind'])
        category = region['kind']
        if category == 'body':
            category = 'call_or_return' if opcode in ('CALL', 'CALL_VAR', 'CALL_GLOBAL', 'CALL_UNDEF_THIS', 'RET', 'RETUNDEF') else 'body'
        categories[category] += count
        opcodes[opcode] += count
        fn = functions.get(int(region['id']), {})
        line = region.get('target_line', fn.get('line', '?'))
        sites[f"id={region['id']} line={line} depth={region['depth']} pc={region.get('pc', '-')} {opcode}"] += count
    return dict(total_self_samples=total, mapped_ranges=len(ranges),
                categories=dict(categories.most_common()),
                category_percent={k: round(100 * v / total, 2) for k, v in categories.items()},
                opcodes=dict(opcodes.most_common()), top_sites=dict(sites.most_common(30)),
                runtime_helpers=dict(native_helpers.most_common(20)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('maps', type=Path)
    parser.add_argument('sample', type=Path)
    args = parser.parse_args()
    print(json.dumps(attribute(args.maps.read_text(), args.sample.read_text()), indent=2))


if __name__ == '__main__':
    main()
