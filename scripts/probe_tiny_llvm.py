#!/usr/bin/env python3
"""Recompile exported TINY IR with isolated LLVM code-generation options."""
import argparse
import concurrent.futures
import json
from pathlib import Path
import re
import shlex
import subprocess

p = argparse.ArgumentParser()
p.add_argument('variant', choices=['control', 'no-unwind', 'outline', 'outline-rerun', 'no-outline', 'combined'])
p.add_argument('--split', action='store_true')
p.add_argument('--core', action='store_true', help='Use the core-builtin profile export')
p.add_argument('--pipeline', action='store_true', help='Use independently optimized whole-module IR')
p.add_argument('--no-compact-unwind', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
suffix = '-separate' if a.split else ''
ir = root / ('out/ir' + suffix)
build = root / ('out/separate-ir' if a.split else 'out/base')
if a.core:
    assert a.split and not a.pipeline
    suffix = '-core-separate'
    ir = root / 'out/core-ir-separate'
    build = root / 'out/core-separate-ir'
if a.pipeline:
    assert not a.split
    suffix = '-pipeline'
    ir = root / 'out/ir-pipeline'
    build = root / 'out/raw'
if a.no_compact_unwind:
    suffix += '-no-compact'
dest = root / 'out' / (a.variant + suffix)
dest.mkdir(parents=True, exist_ok=True)
llc = '/opt/homebrew/opt/llvm/bin/llc'
no_unwind = a.variant in ['no-unwind', 'combined']
flags = []
if a.variant in ['outline', 'outline-rerun', 'combined']:
    flags += ['--enable-machine-outliner=always']
if a.variant in ['outline-rerun', 'combined']:
    flags += ['--machine-outliner-reruns=2']
if a.variant == 'no-outline':
    flags += ['--enable-machine-outliner=never']

def compile_ir(path):
    source = path
    if no_unwind:
        content = re.sub(r'\buwtable(?:\([^)]*\))?', '', path.read_text())
        content = re.sub(r'(!"uwtable", i32 )\d+', r'\g<1>0', content)
        source = dest / path.name
        source.write_text(content)
    obj = dest / (path.stem + '.o')
    subprocess.run([llc, '-O2', '-filetype=obj', '-relocation-model=pic', *flags,
                    str(source), '-o', str(obj)], check=True)
    return obj.name, str(obj)

with concurrent.futures.ThreadPoolExecutor(4) as pool:
    objects = dict(pool.map(compile_ir, sorted(ir.glob('*.ll'))))
assert objects, 'No exported IR found'
link = next(line for line in (build / 'build.log').read_text().splitlines() if line.startswith('cc '))
command = shlex.split(link)
command[command.index('-o') + 1] = str(dest / 'boomkat_tiny')
command = [objects.get(Path(arg).name, arg) if arg.endswith('.o') and 'tmp_c_compile' not in arg else arg for arg in command]
if a.no_compact_unwind:
    command += ['-Wl,-no_compact_unwind']
# C objects remain identical across these probes. Their small residual unwind
# contribution is reported in the resulting section sizes.
subprocess.run(command, check=True, cwd=root)
subprocess.run(['xcrun', 'strip', str(dest / 'boomkat_tiny')], check=True)
sections = subprocess.check_output(['xcrun', 'size', '-m', str(dest / 'boomkat_tiny')], text=True)
result = {'variant': a.variant + suffix, 'bytes': (dest / 'boomkat_tiny').stat().st_size,
          'sections': sections, 'llc_flags': flags, 'llvm': subprocess.check_output([llc, '--version'], text=True).splitlines()[0]}
(dest / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result), flush=True)
