#!/usr/bin/env python3
"""Check expansion, fallback, captures and frame semantics."""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / 'out/boomkat'
SOURCE = ROOT / 'test/guarded_bytecode_inline.js'


def run(*options):
    result = subprocess.run([str(ENGINE), *options, '--script', str(SOURCE)],
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr
    return result


baseline = run('--no-inline')
expanded = run('--inline', '--inline-stats')
assert baseline.stdout == expanded.stdout == 'guarded bytecode inlining passed\n'
stats = dict((key, int(value)) for key, value in re.findall(r'(\w+)=(\d+)', expanded.stderr))
assert stats['sites'] > 0 and stats['calls_avoided'] > 0, stats
assert stats['fallback'] > 0, stats
assert stats['bytecode_after'] > stats['bytecode_before'], stats
print('guarded inline regression passed:', stats)

cases = {
    'outer binding': '''
        var state = 4;
        function stateReader(x) { return (x & state) !== 0; }
        function use(x) { return stateReader(x); }
        if (!use(4) || use(2)) throw new Error('state');
        state = 2;
        if (!use(2) || use(4)) throw new Error('mutation');
    ''',
    'closure capture': '''
        function make(value) { return { reader: function() { return value; } }; }
        var a = make(3), b = make(9);
        function read(obj) { return obj.reader(); }
        if (read(a) !== 3 || read(b) !== 9 || read(a) !== 3) throw new Error('capture');
    ''',
    'arrow lexical this': '''
        function makeArrow() { return { arrowReader: () => this }; }
        var owner = {}, box = makeArrow.call(owner);
        function readArrow() { return box.arrowReader(); }
        if (readArrow() !== owner) throw new Error('lexical this');
    ''',
    'fused branches': '''
        function branchReader(x) { if (x < 0) return 1; if (x === 3) return 2; return 4; }
        function readBranch(x) { return branchReader(x); }
        if (readBranch(-2) !== 1 || readBranch(3) !== 2 || readBranch(8) !== 4) throw new Error('branch');
    ''',
}
for name, source in cases.items():
    result = subprocess.run([str(ENGINE), '--inline', '--inline-stats', '--script', '-'],
                            input=source, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, (name, result.stderr)
    stats = {key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', result.stderr)}
    assert stats['calls_avoided'] > 0, (name, stats)
    print(name + ' passed:', stats['calls_avoided'], 'calls avoided')
