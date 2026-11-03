#!/usr/bin/env python3
"""Compile-check C3 SLJIT constants and ABI widths against the bundled C API.

Uses the host C compiler; no generated code is executed. Opaque pointers remain
opaque. This checks the current host ABI, not cross-target calling conventions.
"""
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = '\n'.join(p.read_text() for p in sorted((ROOT / 'src/jit').glob('sljit_*.c3')))
checks = ['#include <stdint.h>', '#include "sljitLir.h"']
constants = re.findall(r'const int (SLJIT_\w+)\s*=\s*([^;]+);', source)
for name, value in constants:
    args = re.fullmatch(r'SLJIT_ARGS([1-4])W+(_R)?', name)
    expression = name
    if args:
        count = int(args[1])
        argument = 'W_R' if args[2] else 'W'
        expression = f'SLJIT_ARGS{count}(W, ' + ', '.join([argument] * count) + ')'
    checks.append(f'_Static_assert(({expression}) == ({value}), "{name}");')

widths = {'int': 'int32_t', 'long': 'int64_t', 'usz': 'uintptr_t', 'void*': 'void*', 'ZString': 'char*'}
header = (ROOT / 'vendor/sljit/sljit_src/sljitLir.h').read_text()
header = re.sub(r'/\*.*?\*/', '', header, flags=re.S)
prototypes = {name: params for name, params in re.findall(
    r'SLJIT_API_FUNC_ATTRIBUTE\s+[^;{}]*?\b(sljit_\w+)\(([^;{}]*)\);', header, re.S)}
parameters = 0
returns = 0
for result, name, params in re.findall(r'extern fn ([\w*]+) (\w+)\(([^;]*)\);', source):
    if name.startswith('sljit_shim_'):
        continue
    c_params = [] if prototypes[name].strip() in ('', 'void') else [p.strip() for p in prototypes[name].split(',')]
    c3_params = [p.strip() for p in params.split(',')] if params.strip() else []
    assert len(c_params) == len(c3_params), f'{name}: parameter count differs'
    for index, (c_param, c3_param) in enumerate(zip(c_params, c3_params)):
        c_type = re.sub(r'\b\w+$', '', c_param).strip()
        c3_type = c3_param.rsplit(' ', 1)[0]
        checks.append(f'_Static_assert(sizeof({c_type}) == sizeof({widths[c3_type]}), "{name} argument {index} width");')
        parameters += 1
    if result not in widths:
        continue
    arguments = ', '.join('0' for _ in params.split(',')) if params else ''
    checks.append(f'_Static_assert(sizeof({name}({arguments})) == sizeof({widths[result]}), "{name} return width");')
    returns += 1
with tempfile.TemporaryDirectory(prefix='boomkat-sljit-abi-') as directory:
    path = Path(directory) / 'bindings.c'
    path.write_text('\n'.join(checks) + '\n')
    subprocess.run([*shlex.split(os.environ.get('CC', 'cc')), '-std=c11', '-fsyntax-only',
                    '-I', str(ROOT / 'vendor/sljit/sljit_src'), str(path)], check=True)
print(f'SLJIT bindings: {len(constants)} constants, {returns} return widths, {parameters} argument widths match bundled header')
