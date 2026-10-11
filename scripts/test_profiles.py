#!/usr/bin/env python3
"""Check SLIM source boundaries and the normal engine's retained semantics."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
def binary(name):
    path = ROOT / 'out' / name
    return path if path.exists() else path.with_suffix('.exe')


SLIM = binary('boomkat_slim')
NORMAL = binary('boomkat')


def run(engine, path, script=True):
    return subprocess.run([str(engine), *(['--script'] if script else []), str(path)],
                          capture_output=True, timeout=30)


def main():
    checks = 0
    help_text = subprocess.run([str(SLIM), '--help'], capture_output=True, timeout=30).stdout
    assert b'All code runs in strict mode' in help_text and b'JSX OPTIONS' not in help_text, help_text
    checks += 1
    result = run(SLIM, ROOT / 'test/slim/smoke.js')
    assert result.returncode == 0, result.stderr
    checks += 1
    with tempfile.TemporaryDirectory(prefix='boomkat-profiles-') as directory:
        tmp = Path(directory)
        bad = tmp / 'input.js'
        for source in ['with ({}) {}', 'function f(a,a) {}', 'var n = 077;',
                       'delete missing;', 'var n = 1n;',
                       'eval("with ({}) {}");', '(0, eval)("function f(a,a) {}");',
                       'Function("a", "a", "return a");',
                       '(function*(){}).constructor("with ({}) {}");',
                       '(async function(){}).constructor("with ({}) {}");']:
            bad.write_text(source)
            result = run(SLIM, bad)
            assert result.returncode != 0 and b'SyntaxError' in result.stderr, (source, result.stderr)
            checks += 1
        bad.write_text('missing = 1;')
        result = run(SLIM, bad)
        assert result.returncode != 0 and b'ReferenceError' in result.stderr, result.stderr
        checks += 1
        for suffix, source in [('ts', 'var x: number = 42;'), ('jsx', 'var x = <a/>;')]:
            path = tmp / ('input.' + suffix)
            path.write_text(source)
            result = run(SLIM, path, False)
            assert result.returncode != 0 and b'SyntaxError' in result.stderr, result.stderr
            checks += 1
        (tmp / 'dep.js').write_text('export const answer = 42;')
        module = tmp / 'main.js'
        module.write_text("import {answer} from './dep.js';\n"
                          "if (answer !== 42 || this !== undefined) throw new Error('module');\n"
                          "if (await Promise.resolve(answer) !== 42) throw new Error('async');\n")
        result = run(SLIM, module, False)
        assert result.returncode == 0, result.stderr
        checks += 1
        # Strict indirect eval gets its own variable environment.
        bad.write_text('var x = 1; (0,eval)("var x = 2;"); '
                       'if (x !== 1) throw new Error("eval scope");')
        result = run(SLIM, bad)
        assert result.returncode == 0, result.stderr
        checks += 1
        if NORMAL.exists():
            bad.write_text('function f(a,a) { return a; } '
                           'if (f(1,2) !== 2 || Function("return this")() !== globalThis) '
                           'throw new Error("sloppy"); '
                           'if (BigInt(41) + 1n !== 42n || new Proxy({x:42}, {}).x !== 42) '
                           'throw new Error("features");')
            result = run(NORMAL, bad)
            assert result.returncode == 0, result.stderr
            checks += 1
    print(f'Profile tests: {checks} checks passed')


if __name__ == '__main__':
    main()
