#!/usr/bin/env python3
"""Check debugger coordinates across TS erasure and bytecode relocation.

Run after `just build boomkat_debug`: python3 test/debug_source_positions.py
"""
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / 'out/boomkat_debug'


def functions(node):
    yield node
    for child in node['inner_functions']:
        yield from functions(child)


def check(path, optimize=True):
    args = [str(BIN), '--format', 'json']
    if not optimize:
        args.append('--no-optimize')
    result = subprocess.run(args + [str(path)], check=True, capture_output=True, text=True)
    trees = json.loads(result.stdout)
    source = path.read_bytes()
    starts = [0] + [match.end() for match in re.finditer(b'\r\n|[\r\n]|\xe2\x80[\xa8\xa9]', source)]
    found = []
    for tree in trees:
        found.extend(functions(tree))
    for fn in found:
        assert fn['filename'] == str(path)
        instructions = fn['instructions']
        previous = None
        ranges = 0
        for pc, ins in enumerate(instructions):
            assert ins['idx'] == pc
            offset = ins['offset']
            assert 0 <= offset <= len(source), ins
            line = sum(start <= offset for start in starts)
            column = offset - starts[line - 1] + 1
            assert (ins['line'], ins['column']) == (line, column), ins
            position = (ins['line'], ins['column'], offset)
            ranges += position != previous
            previous = position
        assert fn['source_map_count'] == ranges
    return found


for file in ('test/test_source_columns.js', 'test/typescript/source_columns.ts'):
    path = ROOT / file
    optimized = check(path)
    unoptimized = check(path, optimize=False)
    assert any(fn['source_map_count'] < len(fn['instructions']) for fn in optimized)
    if path.suffix == '.js':
        # These functions exercise PC insertion and deletion in cell lowering.
        var_fn = next(fn for fn in optimized if fn['name'] == 'capturedVar')
        assert any(ins['text'].startswith('NEWCELLS') for ins in var_fn['instructions'])
        let_fn = next(fn for fn in optimized if fn['name'] == 'capturedLet')
        let_plain = next(fn for fn in unoptimized if fn['name'] == 'capturedLet')
        assert not any(ins['text'].startswith('PUSH_LEX') for ins in let_fn['instructions'])
        assert any(ins['text'].startswith('PUSH_LEX') for ins in let_plain['instructions'])

with tempfile.TemporaryDirectory(prefix='boomkat-source-positions-') as folder:
    folder = Path(folder)
    # JSON filenames and source offsets must survive quoting and CRLF/Unicode.
    mixed = folder / 'quoted"source.js'
    mixed.write_bytes("function mixed() {\r\n  var s = 'é😀';\r\n  return new Error(s);\u2028}\r\n".encode())
    check(mixed)
    check(mixed, optimize=False)

    wide = folder / 'wide.js'
    wide.write_text('function wide() {\n' + ''.join(
        f'var name{i} = "value{i}";\n' for i in range(320)) + 'return new Error(name319);\n}\n')
    for optimize in (True, False):
        dumped = check(wide, optimize)
        assert any(ins['text'].startswith('WIDE') for fn in dumped for ins in fn['instructions'])

print('PASS: debugger source positions (optimized, unoptimized, cells, WIDE, Unicode, CRLF)')
