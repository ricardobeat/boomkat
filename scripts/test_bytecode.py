#!/usr/bin/env python3
"""Exercise TINY compilation, strict Module semantics and image rejection."""
from pathlib import Path
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out'
GEN = OUT / 'boomkat_tiny_compile'
RUNNERS = [OUT / 'boomkat_tiny']


def run(command, expected=0):
    result = subprocess.run([str(x) for x in command], capture_output=True, timeout=30)
    if result.returncode != expected:
        raise AssertionError((command, result.returncode, result.stdout.decode(errors='replace'),
                              result.stderr.decode(errors='replace')))
    return result


def compile_file(generator, source, image):
    run([generator, '--compile', image, source])


def main():
    checks = 0
    with tempfile.TemporaryDirectory(prefix='boomkat-bytecode-') as raw:
        tmp = Path(raw)
        for name, expected in [('roundtrip', b'bytecode roundtrip passed\n'),
                               ('async', b'bytecode async passed\n'),
                               ('dynamic_disabled', b'dynamic compilation disabled\n'),
                               ('core_builtins', b'core builtins passed\n')]:
            image = tmp / (name + '.bkbc')
            compile_file(GEN, ROOT / 'test/bytecode' / (name + '.js'), image)
            for runner in RUNNERS:
                assert run([runner, image]).stdout == expected
                checks += 1
        empty = tmp / 'empty.js'
        empty.write_text('')
        image = tmp / 'empty.bkbc'
        compile_file(GEN, empty, image)
        for runner in RUNNERS:
            assert run([runner, image]).stdout == b''
            checks += 1
        wide = tmp / 'wide.js'
        names = [f'x{i}' for i in range(300)]
        wide.write_text('function f(' + ','.join(names) + ') { return x299; }\n'
                        'if (f(' + ','.join(str(i) for i in range(300)) + ') !== 299) throw new Error("WIDE");\n'
                        'var text = "é".repeat(100000);\n'
                        'if (text.length !== 100000) throw new Error("strings");\n'
                        'for (var i = 0; i < 10000; i++) { var o = {x: i, y: text}; if (o.x !== i) throw new Error("GC"); }\n'
                        'print("wide and GC passed");\n')
        wide_image = tmp / 'wide.bkbc'
        compile_file(GEN, wide, wide_image)
        for runner in RUNNERS:
            assert run([runner, wide_image]).stdout == b'wide and GC passed\n'
            checks += 1
        for source in ['with ({}) {}', 'function f(a,a) {}', 'missing = 1;',
                       'var x = 077;', 'delete missing;', 'return 1;',
                       "import x from './x.js';", "export {x} from './x.js';",
                       "import('./x.js');", 'var x = 1n;', 'var x = /a/;', '/a/.test("a");']:
            bad = tmp / 'bad.js'
            bad.write_text(source)
            # Undeclared assignment is a runtime strict-mode error.
            if source == 'missing = 1;':
                compile_file(GEN, bad, image)
                for runner in RUNNERS:
                    result = run([runner, image], 1)
                    assert b'ReferenceError' in result.stderr
                    checks += 1
            else:
                result = run([GEN, '--compile', image, bad], 1)
                assert b'SyntaxError' in result.stderr
                checks += 1
        for source in ['throw new Error("expected");', 'await Promise.reject(new Error("expected"));',
                       'Promise.reject(new Error("expected"));', 'await new Promise(() => {});']:
            bad = tmp / 'throw.js'
            bad.write_text(source)
            compile_file(GEN, bad, image)
            for runner in RUNNERS:
                run([runner, image], 1)
                checks += 1
        compile_file(GEN, ROOT / 'test/bytecode/roundtrip.js', image)
        valid = image.read_bytes()
        damaged = [valid[:n] for n in (0, 1, 4, 8, 12, 16, 20, 24, 60, len(valid)//2, len(valid)-1)]
        damaged += [valid + b'x']
        # A strict-only reader rejects sloppy function records independently
        # of the declared profile in the image header.
        sloppy = bytearray(valid)
        struct.pack_into('<I', sloppy, 24, struct.unpack_from('<I', valid, 24)[0] & ~0x80)
        damaged.append(sloppy)
        other_catalog = bytearray(valid)
        struct.pack_into('<I', other_catalog, 16, struct.unpack_from('<I', valid, 16)[0] ^ 2048)
        damaged.append(other_catalog)
        # The profile's strict bit alone cannot authorize sloppy or loading
        # instructions. Forge the first instruction while preserving the header.
        import re
        enum = re.sub(r'//[^\n]*', '', (ROOT / 'src/bytecode.c3').read_text())
        enum = enum.split('enum Opcode', 1)[1]
        enum = enum.split('{', 1)[1].split('}', 1)[0]
        opcodes = re.findall(r'^\s*([A-Z][A-Z0-9_]*)\s*,', enum, re.M)
        cursor = 24 + 7 * 4
        for _ in range(3):
            length = struct.unpack_from('<I', valid, cursor)[0]
            cursor += 4 + length
        assert struct.unpack_from('<I', valid, cursor)[0] > 0
        for opcode in ['DELVAR', 'WITH_START', 'WITH_END', 'WITHGET', 'WITHBASE', 'WTWR',
                       'DYN_IMPORT', 'DYN_IMPORT_DEFER', 'DYN_IMPORT_SOURCE', 'IMPORT_META']:
            data = bytearray(valid)
            struct.pack_into('<I', data, cursor + 4, opcodes.index(opcode))
            damaged.append(data)
        for offset, value in [(8, 999), (12, 0), (16, 0), (16, 0xFFFFFFFF), (20, 0xFFFFFFFF), (24, 1)]:
            data = bytearray(valid)
            struct.pack_into('<I', data, offset, value)
            damaged.append(data)
        for data in damaged:
            image.write_bytes(data)
            for runner in RUNNERS:
                result = run([runner, image], 1)
                assert b'Invalid or incompatible bytecode' in result.stderr
                checks += 1
        run([GEN, '--compile'], 2)
        run([GEN, '--script', '--compile', image, empty], 2)
        checks += 2
    print(f'Bytecode tests: {checks} checks passed')


if __name__ == '__main__':
    main()
