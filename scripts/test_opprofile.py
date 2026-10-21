#!/usr/bin/env python3
"""Compare threaded opcode counts and pairs against the switch interpreter."""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def parse(stderr):
    line = next(line for line in stderr.splitlines() if line.startswith('# OP_PROFILE'))
    totals = {key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', line)}
    singles, pairs = stderr.split('## dynamic singles\n')[1].split('## dynamic pairs\n')
    singles = {op: int(count) for count, op in re.findall(r'^(\d+)\t(\w+)$', singles, re.M)}
    pairs = {(left, right): int(count) for count, left, right in
             re.findall(r'^(\d+)\t(\w+) -> (\w+)$', pairs, re.M)}
    assert sum(singles.values()) == totals['executed_bytecodes'], totals
    assert totals['total_dispatches'] == totals['threaded_dispatches'] + totals['switch_dispatches'], totals
    assert totals['executed_bytecodes'] == totals['total_dispatches'] + totals['fused_bytecodes'], totals
    return totals, singles, pairs


CASES = {
    'arithmetic': 'var total=0; for(var i=0;i<4000;i++) total += (i*2+1)*(i-3);',
    'fused_add': '''function f(a,b,c) { return a+b+c; }
        for(var i=0;i<40;i++){f(1,2,3); f(.5,1.25,3.5); f("a",2,3);}''',
    'fused_branch_safepoint': '''function f(n) {
        var sum=0; for(var i=0;i<n;i++) sum+=i; return sum; } f(4000);''',
    'slow_retry': '''var obj={valueOf:function(){return 3;}};
        function f(x){return (x*2+1)*(x-1);}
        for(var i=0;i<30;i++){f(4); f(obj);}''',
    'returns': '''function f(x){return x*3+2;} function g(x){return f(x)+2;}
        for(var i=0;i<30;i++) g(i);''',
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--threaded', type=Path, default=ROOT / 'out/boomkat_opprofile')
    parser.add_argument('--switch', type=Path, default=ROOT / 'out/boomkat_opprofile_switch')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='boomkat-opprofile-') as raw:
        for name, source in CASES.items():
            path = Path(raw) / (name + '.js')
            path.write_text(source)
            profiles = []
            for binary in (args.threaded, args.switch):
                result = subprocess.run([str(binary), str(path)], capture_output=True,
                                        text=True, check=True, timeout=15)
                profiles.append(parse(result.stderr))
            threaded, reference = profiles
            assert threaded[1] == reference[1], (name, threaded[1], reference[1])
            assert threaded[2] == reference[2], (name, threaded[2], reference[2])
            assert threaded[0]['threaded_dispatches'] > 0, (name, threaded[0])
            assert reference[0]['threaded_dispatches'] == reference[0]['fused_bytecodes'] == 0
            if name.startswith('fused_'):
                assert threaded[0]['fused_bytecodes'] > 0, (name, threaded[0])
            print(name + ': opcode and pair counts match')


if __name__ == '__main__':
    main()
